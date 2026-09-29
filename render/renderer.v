module render

import gg
import velo.core
import velo.assets

struct GpuImage {
	img     gg.Image
	version int
}

// Renderer walks the node tree in order (parent first, children after => children draw over the parent)
// and draws Sprite/Label with gg (a 2D drawing layer on top of sokol: Metal / D3D11 / OpenGL).
@[heap]
pub struct Renderer {
mut:
	ctx &gg.Context
	db  &assets.AssetDatabase
	gpu map[string]GpuImage // texture ID -> GPU image
pub mut:
	debug      bool // F1: draw node bounds + center
	draw_calls int
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
	r.draw_tree(scene.root, core.Affine2.identity())
}

// draw_tree draws the node tree through the `view` matrix (used by the editor to pan/zoom the scene view).
pub fn (mut r Renderer) draw_tree(root &core.Node, view core.Affine2) {
	r.draw_calls = 0
	r.clip = if r.base_clip.w > 0 && r.base_clip.h > 0 {
		r.base_clip
	} else {
		sz := gg.window_size()
		Rect{0, 0, sz.width, sz.height}
	}
	r.draw_node(root, view)
	r.set_scissor(r.clip)
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

fn (mut r Renderer) draw_node(n &core.Node, parent core.Affine2) {
	if !n.active || n.destroyed {
		return
	}
	m := parent.mul(n.local_matrix())
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
		}
	}
	if r.debug {
		p := m.position()
		r.ctx.draw_circle_filled(p.x, p.y, 3, gg.Color{255, 0, 255, 255})
		if t := n.get_component[UITransform]() {
			r.draw_quad_empty(m, t.rect(), gg.Color{0, 200, 255, 160})
		}
	}
	// ScrollView: children only show inside the viewport (screen-aligned bounds of the rect)
	old_clip := r.clip
	mut clipped := false
	if sv := n.get_component[ScrollView]() {
		if sv.enabled && sv.clip {
			if vr := node_rect(n) {
				r.clip = old_clip.intersect(screen_bounds(m, vr))
				r.set_scissor(r.clip)
				clipped = true
			}
		}
	}
	for ch in n.children {
		r.draw_node(ch, m)
	}
	if clipped {
		r.clip = old_clip
		r.set_scissor(old_clip)
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
