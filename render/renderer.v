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
	r.draw_node(root, view)
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
		}
	}
	if r.debug {
		p := m.position()
		r.ctx.draw_circle_filled(p.x, p.y, 3, gg.Color{255, 0, 255, 255})
	}
	for ch in n.children {
		r.draw_node(ch, m)
	}
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
	p := m.position()
	sc := m.scale()
	align := match l.align {
		'center' { gg.HorizontalAlign.center }
		'right' { gg.HorizontalAlign.right }
		else { gg.HorizontalAlign.left }
	}

	r.ctx.draw_text(int(p.x), int(p.y), l.text,
		size:  int(f32(l.size) * sc.y)
		color: gg.Color{l.color.r, l.color.g, l.color.b, l.color.a}
		align: align
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
