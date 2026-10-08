module render

import gg
import velo.core
import velo.assets
import math

struct GpuImage {
	img     gg.Image
	version int
}

// DebugShape — a component with an outline to show in debug mode (F1) and in the editor, e.g. physics colliders.
// Any component with these two methods qualifies; render does not depend on the component's module.
pub interface DebugShape {
	debug_outline() []core.Vec2 // closed polygon, node space
	debug_color() core.Color
}

// Renderer draws the node tree in tree order (parent first, children after => children draw over the parent),
// reordered by Node.z_index / Node.y_sort, world first and Canvas (screen space) nodes last, and draws Sprite/Label with gg (a 2D drawing layer on top of sokol: Metal / D3D11 / OpenGL).
@[heap]
pub struct Renderer {
mut:
	ctx   &gg.Context
	db    &assets.AssetDatabase
	gpu   map[string]GpuImage // texture ID -> GPU image
	atlas Atlas               // small textures packed together (see atlas.v)
	light LightGpu            // the light map of core.Lighting (see lighting.v)
	// Set by draw_scene for the frame: the scene whose lights apply_lighting draws before the first Canvas node.
	light_scene  &core.Scene = unsafe { nil }
	light_window core.Affine2
	shaders      map[string]GpuShader // shader asset ID -> pipeline
	draw_list    &DrawList = unsafe { nil } // draw_tree's, kept between frames so drawing does not allocate it
	batch        SpriteBatch // the open run of plain sprites (see batch.v)
	sgl_warned   bool
pub mut:
	debug bool // F1: draw node bounds + center
	// Pack small textures into shared pages for plain sprites (see atlas.v). Off: every texture is its own GPU image.
	atlas_on bool = true
	// Draw DebugShape outlines (colliders) even when `debug` is off (the editor turns it on).
	show_shapes bool
	draw_calls  int
	culled      int // sprites skipped this frame because they were outside the clip rect (see batch.v)
	// Screen area the tree is drawn into (the editor's scene view); ScrollView clipping stays inside it.
	// Zero size = the whole window.
	base_clip Rect
	clip      Rect @[hide]
}

pub fn new_renderer(ctx &gg.Context, db &assets.AssetDatabase) &Renderer {
	return &Renderer{
		ctx: ctx
		db:  db
	}
}

// draw_scene draws the scene; `window` maps screen units to window points (see core.ScreenFit.to_window).
pub fn (mut r Renderer) draw_scene(scene &core.Scene, window core.Affine2) {
	r.light_scene = unsafe { nil }
	if _ := scene.lighting() {
		r.light_scene = scene
	}
	r.light_window = window
	r.draw_tree(scene.root, window, scene.view_matrix())
	ins := scene.safe_insets
	if r.debug && !ins.is_zero() {
		o := scene.view_origin
		sz := scene.view_size
		r.draw_quad_empty(window, Rect{o.x + ins.left, o.y + ins.top, sz.x - ins.left - ins.right,
			sz.y - ins.top - ins.bottom}, gg.Color{255, 80, 80, 200})
	}
}

// draw_tree draws the node tree. `camera` maps the world to the screen (scene.view_matrix(); nodes under a
// Canvas skip it) and `view` maps the screen into the window (the scale mode in the game, pan/zoom in the editor).
pub fn (mut r Renderer) draw_tree(root &core.Node, view core.Affine2, camera core.Affine2) {
	r.draw_calls = 0
	r.culled = 0
	r.atlas_begin_frame() // also done by atlas_lookup, which cached sprites skip
	base := r.base_rect()
	r.clip = base
	mut lit := r.light_scene == unsafe { nil }
	// take the list: a nested draw_tree (e.g. from a component) then makes its own instead of overwriting it
	mut list := if r.draw_list != unsafe { nil } { r.draw_list } else { &DrawList{} }
	r.draw_list = unsafe { nil }
	collect_draw_items(mut list, root, view, camera, base)
	for it in list.items {
		if !lit && it.canvas {
			lit = true // the world is done: light it before the HUD draws
			r.flush_sprites()
			r.apply_lighting(r.light_scene, r.light_window)
		}
		if it.clip != r.clip {
			r.clip = it.clip
			r.set_scissor(r.clip)
		}
		r.draw_node(it.node, it.m)
	}
	r.flush_sprites()
	if !lit {
		r.apply_lighting(r.light_scene, r.light_window) // no Canvas: light everything
	}
	r.light_scene = unsafe { nil }
	r.clip = base
	r.set_scissor(base)
	r.draw_list = list
	r.check_sgl_overflow()
}

// draw_order: the visible nodes of the tree in the order they are drawn (last = on top), e.g. for picking.
pub fn draw_order(root &core.Node) []&core.Node {
	mut list := &DrawList{}
	collect_draw_items(mut list, root, core.Affine2.identity(), core.Affine2.identity(), Rect{})
	return list.items.map(it.node)
}

fn (r &Renderer) base_rect() Rect {
	if r.base_clip.w > 0 && r.base_clip.h > 0 {
		return r.base_clip
	}
	sz := r.ctx.window_size()
	return Rect{0, 0, sz.width, sz.height}
}

// DrawItem — one node to draw, with its node -> window matrix and the clip rect it is drawn in.
struct DrawItem {
	node   &core.Node
	m      core.Affine2
	clip   Rect
	canvas bool // under a Canvas: drawn after (over) the world
	z      int  // effective z_index (the sum of the node's and its ancestors')
	seq    int  // tree order (y_sort already applied), keeps equal z in order
}

// DrawList — the draw items, on the heap: V's -prod GC keepalive walks every element of a local array of
// pointer-holding structs around each call that takes its address, which made drawing quadratic in the node count.
@[heap]
struct DrawList {
mut:
	items []DrawItem
}

struct CollectState {
	view     core.Affine2
	view_cam core.Affine2
mut:
	list &DrawList
}

// collect_draw_items fills `list` (cleared first, its memory reused) with the visible nodes sorted by draw order:
// world before Canvas, then z_index, then tree order.
fn collect_draw_items(mut list DrawList, root &core.Node, view core.Affine2, camera core.Affine2, clip Rect) {
	list.items.clear()
	mut st := CollectState{
		view:     view
		view_cam: view.mul(camera)
		list:     list
	}
	collect_node(mut st, root, core.Affine2.identity(), false, 0, clip)
	// most scenes are already in draw order (no z_index, no Canvas in the middle): skip the sort then
	mut ordered := true
	for i in 1 .. list.items.len {
		if compare_draw_items(&list.items[i - 1], &list.items[i]) > 0 {
			ordered = false
			break
		}
	}
	if !ordered {
		list.items.sort_with_compare(compare_draw_items)
	}
}

fn collect_node(mut st CollectState, n &core.Node, parent_world core.Affine2, canvas bool, z int, clip Rect) {
	if !n.active || n.destroyed {
		return
	}
	w := parent_world.mul(n.local_matrix())
	mut in_canvas := canvas
	if !in_canvas {
		if _ := n.get_component[core.Canvas]() {
			in_canvas = true
		}
	}
	m := if in_canvas { st.view.mul(w) } else { st.view_cam.mul(w) }
	zz := z + n.z_index
	st.list.items << DrawItem{
		node:   n
		m:      m
		clip:   clip
		canvas: in_canvas
		z:      zz
		seq:    st.list.items.len
	}
	// ScrollView: children only show inside the viewport (screen-aligned bounds of the rect)
	mut child_clip := clip
	if sv := n.get_component[ScrollView]() {
		if sv.enabled && sv.clip {
			if vr := node_rect(n) {
				child_clip = clip.intersect(screen_bounds(m, vr))
			}
		}
	}
	if n.y_sort && n.children.len > 1 {
		for ch in y_sorted(n.children, w) {
			collect_node(mut st, ch, w, in_canvas, zz, child_clip)
		}
	} else {
		for ch in n.children {
			collect_node(mut st, ch, w, in_canvas, zz, child_clip)
		}
	}
}

struct YKey {
	y     f32
	index int
}

// y_sorted: the children ordered by their world y (ties keep the child order).
fn y_sorted(children []&core.Node, parent_world core.Affine2) []&core.Node {
	mut keys := []YKey{cap: children.len}
	for i, ch in children {
		keys << YKey{parent_world.apply(ch.position).y, i}
	}
	keys.sort_with_compare(fn (a &YKey, b &YKey) int {
		if a.y != b.y {
			return if a.y < b.y { -1 } else { 1 }
		}
		return a.index - b.index
	})
	return keys.map(children[it.index])
}

fn compare_draw_items(a &DrawItem, b &DrawItem) int {
	if a.canvas != b.canvas {
		return if a.canvas { 1 } else { -1 }
	}
	if a.z != b.z {
		return if a.z < b.z { -1 } else { 1 }
	}
	return a.seq - b.seq
}

fn (mut r Renderer) set_scissor(c Rect) {
	r.flush_sprites()
	r.ctx.scissor_rect(int(c.x), int(c.y), int(c.w), int(c.h))
}

// on_asset_event: the renderer deletes the GPU image when a texture is unloaded or removed from disk.
pub fn (mut r Renderer) on_asset_event(ev assets.AssetEvent) {
	if ev.kind in [.unloaded, .removed] {
		r.release_gpu(ev.id)
		r.atlas_forget(ev.id)
		r.release_shader(ev.id)
	}
}

fn (mut r Renderer) release_gpu(id string) {
	if g := r.gpu[id] {
		r.ctx.remove_cached_image_by_idx(g.img.id)
		r.gpu.delete(id)
	}
}

// draw_node draws the components of one node (not its children) through `m` (node -> window).
fn (mut r Renderer) draw_node(n &core.Node, m core.Affine2) {
	for c in n.components {
		if !c.enabled {
			continue
		}
		if c !is Sprite {
			r.flush_sprites() // everything but plain sprites draws through gg
		}
		if c is Sprite {
			r.draw_sprite(c, m)
		} else if c is Label {
			r.draw_label(c, m)
		} else if c is Panel {
			r.draw_panel(c, m)
		} else if c is ProgressBar {
			r.draw_progress(c, m)
		} else if c is TileMap {
			r.draw_tilemap(c, m)
		} else if c is TextInput {
			r.draw_text_input(c, m)
		} else if c is MeshDrawable {
			for mesh in c.meshes() {
				r.draw_mesh(mesh, m)
			}
		}
		if (r.debug || r.show_shapes) && c is DebugShape {
			r.flush_sprites()
			r.draw_outline(m, c.debug_outline(), c.debug_color())
		}
	}
	if r.debug {
		r.flush_sprites()
		p := m.position()
		r.ctx.draw_circle_filled(p.x, p.y, 3, gg.Color{255, 0, 255, 255})
		if t := n.get_component[UITransform]() {
			r.draw_quad_empty(m, t.rect(), gg.Color{0, 200, 255, 160})
		}
	}
}

// screen_bounds: the axis-aligned bounds of the node-space rect `rc` after the transform `m`.
fn screen_bounds(m core.Affine2, rc Rect) Rect {
	pts := quad_points(m, rc)
	mut x0, mut y0 := pts[0].x, pts[0].y
	mut x1, mut y1 := x0, y0
	for p in pts {
		x0 = if p.x < x0 { p.x } else { x0 }
		y0 = if p.y < y0 { p.y } else { y0 }
		x1 = if p.x > x1 { p.x } else { x1 }
		y1 = if p.y > y1 { p.y } else { y1 }
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

fn quad_points(m core.Affine2, rc Rect) []core.Vec2 {
	return [m.apply(core.vec2(rc.x, rc.y)), m.apply(core.vec2(rc.x + rc.w, rc.y)),
		m.apply(core.vec2(rc.x + rc.w, rc.y + rc.h)), m.apply(core.vec2(rc.x, rc.y + rc.h))]
}

fn to_gg(c core.Color) gg.Color {
	return gg.Color{c.r, c.g, c.b, c.a}
}

// fill_quad fills a node-space rect; rounded corners only when the transform has no rotation/flip.
fn (mut r Renderer) fill_quad(m core.Affine2, rc Rect, radius f32, c core.Color) {
	if c.a == 0 || rc.w <= 0 || rc.h <= 0 {
		return
	}
	if radius > 0 && m.b == 0 && m.c == 0 && m.a > 0 && m.d > 0 {
		b := screen_bounds(m, rc)
		rad := radius * m.a
		r.ctx.draw_rounded_rect_filled(b.x, b.y, b.w, b.h, if rad * 2 > b.w || rad * 2 > b.h {
			if b.w < b.h { b.w / 2 } else { b.h / 2 }
		} else {
			rad
		}, to_gg(c))
	} else {
		pts := quad_points(m, rc)
		r.ctx.draw_convex_poly([pts[0].x, pts[0].y, pts[1].x, pts[1].y, pts[2].x, pts[2].y, pts[3].x,
			pts[3].y], to_gg(c))
	}
	r.draw_calls++
}

fn (mut r Renderer) draw_quad_empty(m core.Affine2, rc Rect, c gg.Color) {
	pts := quad_points(m, rc)
	r.ctx.draw_poly_empty([pts[0].x, pts[0].y, pts[1].x, pts[1].y, pts[2].x, pts[2].y, pts[3].x,
		pts[3].y], c)
}

fn (mut r Renderer) draw_outline(m core.Affine2, pts []core.Vec2, c core.Color) {
	if pts.len < 2 {
		return
	}
	mut prev := m.apply(pts[pts.len - 1])
	for p in pts {
		q := m.apply(p)
		r.ctx.draw_line(prev.x, prev.y, q.x, q.y, to_gg(c))
		prev = q
	}
}

fn (mut r Renderer) draw_panel(p &Panel, m core.Affine2) {
	t := p.node.get_component[UITransform]() or { return }
	rc := t.rect()
	r.fill_quad(m, rc, p.radius, p.color)
	if p.border_width <= 0 || p.border_color.a == 0 {
		return
	}
	col := to_gg(p.border_color)
	rounded := p.radius > 0 && m.b == 0 && m.c == 0 && m.a > 0 && m.d > 0
	for i in 0 .. p.border_width {
		inset := f32(i) + 0.5
		ri := Rect{rc.x + inset, rc.y + inset, rc.w - inset * 2, rc.h - inset * 2}
		if ri.w <= 0 || ri.h <= 0 {
			break
		}
		if rounded {
			b := screen_bounds(m, ri)
			r.ctx.draw_rounded_rect_empty(b.x, b.y, b.w, b.h, p.radius * m.a - inset, col)
		} else {
			r.draw_quad_empty(m, ri, col)
		}
	}
}

fn (mut r Renderer) draw_progress(p &ProgressBar, m core.Affine2) {
	t := p.node.get_component[UITransform]() or { return }
	rc := t.rect()
	r.fill_quad(m, rc, p.radius, p.back_color)
	r.fill_quad(m, p.fill_rect(rc), p.radius, p.fill_color)
}

fn (mut r Renderer) draw_sprite(s &Sprite, m core.Affine2) {
	if s.tex == unsafe { nil } {
		return
	}
	if s.shader_data != unsafe { nil } {
		if pip := r.pipeline_for(s.shader_data) {
			r.flush_sprites()
			r.draw_sprite_shaded(s, m, pip)
			return
		}
	}
	if s.is_sliced_mode() {
		r.flush_sprites()
		r.draw_sprite_quads(s, m)
		return
	}
	mut img_id := 0
	mut ox := 0
	mut oy := 0
	if id, x, y := r.atlas_cached(s) {
		img_id, ox, oy = id, x, y
	} else if id, x, y := r.atlas_lookup(s.tex) {
		img_id, ox, oy = id, x, y
		mut ms := unsafe { s }
		ms.atlas_cache =
			AtlasCache{voidptr(r), r.atlas.gen, voidptr(s.tex), s.tex.version, id, x, y}
	} else {
		img := r.image_for(s.tex) or { return }
		img_id = img.id
	}
	fx, fy, fw, fh := s.tex.frame_rect(s.frame)
	r.batch_sprite(s, m, img_id, fx + ox, fy + oy, fw, fh)
	if r.debug {
		r.flush_sprites()
		x, y, w, h := s.local_rect()
		r.draw_quad_empty(m, Rect{x, y, w, h}, gg.Color{0, 255, 0, 160})
	}
}

// GgMeasure measures text with gg (see TextMeasurer).
struct GgMeasure {
	ctx    &gg.Context
	family string
}

fn (g GgMeasure) width(s string, size f32) f32 {
	g.ctx.set_text_cfg(size: int(size + 0.5), family: g.family)
	return g.ctx.text_width_f(s)
}

// label_layout lays out a label's text (wrapped / shrunk), recomputing only when something it depends on changed.
fn (r &Renderer) label_layout(l &Label) TextBlock {
	mut box := Rect{}
	if t := l.node.get_component[UITransform]() {
		box = t.rect()
	}
	family := font_family(l.font_data)
	key := '${l.text}|${l.size}|${l.wrap}|${l.shrink}|${l.line_spacing}|${box.w}|${box.h}|${family}'
	if key == l.layout_key {
		return l.layout
	}
	block := layout_text(l.text, l.size, l.line_spacing, l.wrap, l.shrink, if l.wrap || l.shrink {
		box.w
	} else {
		0
	}, if l.shrink { box.h } else { 0 }, 6, GgMeasure{r.ctx, family})
	mut ml := unsafe { l }
	ml.layout_key = key
	ml.layout = block
	return block
}

// rich_layout lays out a rich label (wrapped / shrunk), recomputing only when something it depends on changed.
fn (r &Renderer) rich_layout(l &Label) RichBlock {
	mut box := Rect{}
	if t := l.node.get_component[UITransform]() {
		box = t.rect()
	}
	family := font_family(l.font_data)
	key := '${l.text}|${l.size}|${l.wrap}|${l.shrink}|${l.line_spacing}|${box.w}|${box.h}|${family}'
	if key == l.rich_key {
		return l.rich_block
	}
	block := layout_rich_fit(parse_rich(l.text), l.size, l.line_spacing, l.wrap, l.shrink, box.w,
		box.h, 6, GgMeasure{r.ctx, family})
	mut ml := unsafe { l }
	ml.rich_key = key
	ml.rich_block = block
	return block
}

// draw_rich_label draws a label with BBCode: every piece in its own color / size, underlines and strikes as lines.
fn (mut r Renderer) draw_rich_label(l &Label, m core.Affine2) {
	block := r.rich_layout(l)
	sc := m.scale()
	k := if sc.y < 0 { -sc.y } else { sc.y }
	anchor := l.text_point()
	top := match l.valign {
		'middle' { anchor.y - block.height / 2 }
		'bottom' { anchor.y - block.height }
		else { anchor.y }
	}

	family := font_family(l.font_data)
	measure := GgMeasure{r.ctx, family}
	mut y := top
	for li, line in block.lines {
		x0 := match l.align {
			'center' { anchor.x - line.width / 2 }
			'right' { anchor.x - line.width }
			else { anchor.x }
		}

		for pc in line.pieces {
			text := pc.text.trim_right(' ')
			if text == '' {
				continue
			}
			mut col := if pc.style.has_color { pc.style.color } else { l.color }
			col = core.Color{col.r, col.g, col.b, u8(u32(col.a) * l.color.a / 255)}
			py := y + (line.size - pc.size) // bottoms of the pieces line up
			p := m.apply(core.vec2(x0 + pc.x, py))
			cfg := gg.TextCfg{
				size:           int(pc.size * k + 0.5)
				color:          to_gg(col)
				align:          .left
				vertical_align: .top
				family:         family
			}
			r.draw_text_fx(l, p, text, cfg, k)
			if pc.style.bold { // heavier: the same text again a pixel to the right
				r.ctx.draw_text(int(p.x) + 1, int(p.y), text, cfg)
			}
			w := measure.width(text, pc.size)
			if pc.style.underline || pc.style.strike {
				thick := math.max(pc.size * k / 14, f32(1))
				a := m.apply(core.vec2(x0 + pc.x, py))
				b := m.apply(core.vec2(x0 + pc.x + w, py))
				if pc.style.underline {
					r.ctx.draw_rect_filled(a.x, a.y + pc.size * k * 0.98, b.x - a.x, thick,
						to_gg(col))
				}
				if pc.style.strike {
					r.ctx.draw_rect_filled(a.x, a.y + pc.size * k * 0.55, b.x - a.x, thick,
						to_gg(col))
				}
			}
		}
		y += block.line_height[li]
	}
}

fn (mut r Renderer) draw_label(l &Label, m core.Affine2) {
	if l.text == '' {
		return
	}
	if l.rich {
		r.draw_rich_label(l, m)
		return
	}
	sc := m.scale()
	k := if sc.y < 0 { -sc.y } else { sc.y }
	align := match l.align {
		'center' { gg.HorizontalAlign.center }
		'right' { gg.HorizontalAlign.right }
		else { gg.HorizontalAlign.left }
	}

	family := font_family(l.font_data)
	anchor := l.text_point()
	if !l.wrap && !l.shrink && !l.text.contains('\n') {
		// one line: gg aligns it vertically itself
		valign := match l.valign {
			'middle' { gg.VerticalAlign.middle }
			'bottom' { gg.VerticalAlign.bottom }
			else { gg.VerticalAlign.top }
		}

		p := m.apply(anchor)
		r.draw_text_fx(l, p, l.text, gg.TextCfg{
			size:           int(f32(l.size) * k)
			color:          to_gg(l.color)
			align:          align
			vertical_align: valign
			family:         family
		}, k)
		return
	}
	block := r.label_layout(l)
	top := match l.valign {
		'middle' { anchor.y - block.height() / 2 }
		'bottom' { anchor.y - block.height() }
		else { anchor.y }
	}

	cfg := gg.TextCfg{
		size:           int(block.size * k)
		color:          to_gg(l.color)
		align:          align
		vertical_align: .top
		family:         family
	}
	for i, line in block.lines {
		if line == '' {
			continue
		}
		r.draw_text_fx(l, m.apply(core.vec2(anchor.x, top + i * block.line_height)), line, cfg, k)
	}
}

// draw_text_fx draws one line with the label's outline and shadow under it (`k` = node scale, for offsets).
fn (mut r Renderer) draw_text_fx(l &Label, p core.Vec2, text string, cfg gg.TextCfg, k f32) {
	if l.shadow_color.a > 0 {
		o := l.shadow_offset.mul(k)
		r.ctx.draw_text(int(p.x + o.x), int(p.y + o.y), text, gg.TextCfg{
			...cfg
			color: to_gg(l.shadow_color)
		})
		r.draw_calls++
	}
	if l.outline_color.a > 0 && l.outline_width > 0 {
		w := l.outline_width * k
		oc := gg.TextCfg{
			...cfg
			color: to_gg(l.outline_color)
		}
		for d in outline_dirs {
			r.ctx.draw_text(int(p.x + d.x * w + 0.5), int(p.y + d.y * w + 0.5), text, oc)
		}
		r.draw_calls += outline_dirs.len
	}
	r.ctx.draw_text(int(p.x), int(p.y), text, cfg)
	r.draw_calls++
}

// draw_text_input draws the field's text (or placeholder) and caret, clipped to its box and scrolled so the
// caret stays visible.
fn (mut r Renderer) draw_text_input(t &TextInput, m core.Affine2) {
	tr := t.node.get_component[UITransform]() or { return }
	rc := tr.rect()
	sc := m.scale()
	k := if sc.y < 0 { -sc.y } else { sc.y }
	family := font_family(t.font_data)
	meas := GgMeasure{r.ctx, family}
	shown := t.shown()
	runes := shown.runes()
	ci := if t.caret < 0 {
		0
	} else if t.caret > runes.len {
		runes.len
	} else {
		t.caret
	}
	caret_x := meas.width(runes[..ci].string(), t.size)
	text_w := meas.width(shown, t.size)
	mut mt := unsafe { t }
	scroll := mt.update_scroll(caret_x, text_w, rc.w - 2 * t.padding)

	old := r.clip
	r.clip = old.intersect(screen_bounds(m, rc))
	r.set_scissor(r.clip)
	mid := rc.y + rc.h / 2
	x0 := rc.x + t.padding - scroll
	p := m.apply(core.vec2(x0, mid))
	empty := shown == ''
	if !empty || t.placeholder != '' {
		r.ctx.draw_text(int(p.x), int(p.y), if empty { t.placeholder } else { shown },
			size:           int(f32(t.size) * k)
			color:          to_gg(if empty { t.placeholder_color } else { t.color })
			vertical_align: .middle
			family:         family
		)
		r.draw_calls++
	}
	if t.caret_visible() {
		cx := if empty { rc.x + t.padding } else { x0 + caret_x }
		half := f32(t.size) * 0.55
		r.fill_quad(m, Rect{cx, mid - half, 1.5, half * 2}, 0, t.caret_color)
	}
	r.clip = old
	r.set_scissor(old)
}

const outline_dirs = [core.vec2(-1, 0), core.vec2(1, 0), core.vec2(0, -1),
	core.vec2(0, 1), core.vec2(-0.7, -0.7), core.vec2(0.7, -0.7),
	core.vec2(-0.7, 0.7), core.vec2(0.7, 0.7)]

// image_for uploads the texture to the GPU on first use, and re-uploads it when the file changes (hot reload).
fn (mut r Renderer) image_for(t &assets.Texture) ?gg.Image {
	if g := r.gpu[t.id] {
		if g.version == t.version {
			return g.img
		}
		r.release_gpu(t.id)
	}
	filter := if t.filter == 'nearest' { gg.TextureFilter.nearest } else { gg.TextureFilter.linear }
	img := r.ctx.create_image(t.path, texture_filter: filter) or {
		eprintln('[render] cannot create image ${t.path}: ${err}')
		return none
	}
	// gg (0.5.x) stores the image in its cache BEFORE uploading to the GPU when called mid-frame,
	// so write the uploaded version back into the cache so draw_image_with_config can use it.
	mut cached := r.ctx.get_cached_image_by_idx(img.id)
	unsafe {
		*cached = img
	}
	r.gpu[t.id] = GpuImage{img, t.version}
	return img
}
