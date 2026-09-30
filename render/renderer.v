module render

import gg
import velo.core
import velo.assets

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
	ctx &gg.Context
	db  &assets.AssetDatabase
	gpu map[string]GpuImage // texture ID -> GPU image
pub mut:
	debug bool // F1: draw node bounds + center
	// Draw DebugShape outlines (colliders) even when `debug` is off (the editor turns it on).
	show_shapes bool
	draw_calls  int
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

pub fn (mut r Renderer) draw_scene(scene &core.Scene) {
	r.draw_tree(scene.root, core.Affine2.identity(), scene.view_matrix())
	ins := scene.safe_insets
	if r.debug && !ins.is_zero() {
		sz := scene.view_size
		r.ctx.draw_rect_empty(ins.left, ins.top, sz.x - ins.left - ins.right, sz.y - ins.top -
			ins.bottom, gg.Color{255, 80, 80, 200})
	}
}

// draw_tree draws the node tree. `camera` maps the world to the screen (scene.view_matrix(); nodes under a
// Canvas skip it) and `view` maps the screen into the window (the editor's pan/zoom; identity in the game).
pub fn (mut r Renderer) draw_tree(root &core.Node, view core.Affine2, camera core.Affine2) {
	r.draw_calls = 0
	base := r.base_rect()
	r.clip = base
	for it in collect_draw_items(root, view, camera, base) {
		if it.clip != r.clip {
			r.clip = it.clip
			r.set_scissor(r.clip)
		}
		r.draw_node(it.node, it.m)
	}
	r.clip = base
	r.set_scissor(base)
}

// draw_order: the visible nodes of the tree in the order they are drawn (last = on top), e.g. for picking.
pub fn draw_order(root &core.Node) []&core.Node {
	return collect_draw_items(root, core.Affine2.identity(), core.Affine2.identity(), Rect{}).map(it.node)
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

struct CollectState {
	view     core.Affine2
	view_cam core.Affine2
mut:
	items []DrawItem
}

// collect_draw_items lists the visible nodes sorted by draw order: world before Canvas, then z_index, then tree order.
fn collect_draw_items(root &core.Node, view core.Affine2, camera core.Affine2, clip Rect) []DrawItem {
	mut st := CollectState{
		view:     view
		view_cam: view.mul(camera)
	}
	collect_node(mut st, root, core.Affine2.identity(), false, 0, clip)
	st.items.sort_with_compare(compare_draw_items)
	return st.items
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
	st.items << DrawItem{
		node:   n
		m:      m
		clip:   clip
		canvas: in_canvas
		z:      zz
		seq:    st.items.len
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
	r.ctx.scissor_rect(int(c.x), int(c.y), int(c.w), int(c.h))
}

// on_asset_event: the renderer deletes the GPU image when a texture is unloaded or removed from disk.
pub fn (mut r Renderer) on_asset_event(ev assets.AssetEvent) {
	if ev.kind in [.unloaded, .removed] {
		r.release_gpu(ev.id)
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
		} else if c is MeshDrawable {
			for mesh in c.meshes() {
				r.draw_mesh(mesh, m)
			}
		}
		if (r.debug || r.show_shapes) && c is DebugShape {
			r.draw_outline(m, c.debug_outline(), c.debug_color())
		}
	}
	if r.debug {
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
	if s.is_sliced_mode() {
		r.draw_sprite_quads(s, m)
		return
	}
	img := r.image_for(s.tex) or { return }
	sz := s.display_size()
	sc := m.scale()
	w := sz.x * sc.x
	h := sz.y * sc.y
	aw := if w < 0 { -w } else { w }
	ah := if h < 0 { -h } else { h }
	rot := m.rotation_deg()
	// gg rotates around the rectangle's center, so compute the center from the node's anchor point.
	offset := core.Affine2.trs(core.Vec2{}, rot, core.vec2(1, 1)).apply(core.vec2((0.5 - s.anchor.x) * aw,
		(0.5 - s.anchor.y) * ah))
	center := m.position() + offset
	fx, fy, fw, fh := s.tex.frame_rect(s.frame)
	r.ctx.draw_image_with_config(
		img_id:    img.id
		img_rect:  gg.Rect{center.x - aw / 2, center.y - ah / 2, aw, ah}
		part_rect: gg.Rect{fx, fy, fw, fh}
		rotation:  -rot
		flip_x:    s.flip_x != (w < 0)
		flip_y:    s.flip_y != (h < 0)
		color:     gg.Color{s.color.r, s.color.g, s.color.b, s.color.a}
	)
	r.draw_calls++
	if r.debug {
		r.ctx.draw_rect_empty(center.x - aw / 2, center.y - ah / 2, aw, ah, gg.Color{0, 255, 0, 160})
	}
}

fn (mut r Renderer) draw_label(l &Label, m core.Affine2) {
	if l.text == '' {
		return
	}
	p := m.apply(l.text_point())
	sc := m.scale()
	align := match l.align {
		'center' { gg.HorizontalAlign.center }
		'right' { gg.HorizontalAlign.right }
		else { gg.HorizontalAlign.left }
	}

	valign := match l.valign {
		'middle' { gg.VerticalAlign.middle }
		'bottom' { gg.VerticalAlign.bottom }
		else { gg.VerticalAlign.top }
	}

	r.ctx.draw_text(int(p.x), int(p.y), l.text,
		size:           int(f32(l.size) * (if sc.y < 0 { -sc.y } else { sc.y }))
		color:          to_gg(l.color)
		align:          align
		vertical_align: valign
	)
	r.draw_calls++
}

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
