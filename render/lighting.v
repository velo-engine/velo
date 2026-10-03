module render

import math
import sokol.gfx
import sokol.sgl
import sokol.sapp
import velo.core

// Drawing for core.Lighting / core.Light2D. Each frame the lights are drawn (added together, on top of the ambient
// color) into a small off-screen light map, then the world drawn so far is multiplied by it with one full-screen
// quad. That happens when the first Canvas node is about to draw (or at the end when there is none), so HUDs stay
// bright. The light map is 1/`resolution` of the window and stretched with linear filtering, which also softens it.

const light_texture_size = 128

struct LightGpu {
mut:
	inited  bool
	ok      bool
	ctx     sgl.Context  // draws the lights into the light map (same format as the target)
	add_pip sgl.Pipeline // additive blend, made inside `ctx`
	mul_pip sgl.Pipeline // multiply blend, made inside the default context
	// the light map
	img  gfx.Image
	smp  gfx.Sampler
	atts gfx.Attachments
	w    int
	h    int
	// light textures: white with an alpha falloff; spots are cached per cone angle (5 degree steps)
	tex_smp gfx.Sampler
	point   gfx.Image
	spots   map[int]gfx.Image
}

fn zeroed[T]() T {
	mut v := T{}
	unsafe { vmemset(&v, 0, int(sizeof(T))) }
	return v
}

// light_init creates everything that does not depend on the window size. false: lighting is not available.
fn (mut r Renderer) light_init() bool {
	if r.light.inited {
		return r.light.ok
	}
	r.light.inited = true
	mut cd := zeroed[sgl.ContextDesc]()
	cd.color_format = .rgba8
	cd.depth_format = .none
	cd.sample_count = 1
	r.light.ctx = sgl.make_context(&cd)
	if r.light.ctx.id == 0 {
		eprintln('[render] lighting: cannot create the light map context')
		return false
	}
	mut sd := gfx.SamplerDesc{
		min_filter: .linear
		mag_filter: .linear
		wrap_u:     .clamp_to_edge
		wrap_v:     .clamp_to_edge
	}
	r.light.tex_smp = gfx.make_sampler(&sd)
	r.light.smp = gfx.make_sampler(&sd)
	r.light.point = make_light_texture(0)
	// additive: the light map keeps what it has and adds color * falloff
	sgl.set_context(r.light.ctx)
	mut pd := zeroed[gfx.PipelineDesc]()
	pd.label = c'velo-light-add'
	pd.colors[0] = gfx.ColorTargetState{
		blend: gfx.BlendState{
			enabled:        true
			src_factor_rgb: .src_alpha
			dst_factor_rgb: .one
		}
	}
	r.light.add_pip = sgl.make_pipeline(&pd)
	sgl.set_context(sgl.default_context())
	// multiply the world by the light map
	mut md := zeroed[gfx.PipelineDesc]()
	md.label = c'velo-light-multiply'
	md.colors[0] = gfx.ColorTargetState{
		blend: gfx.BlendState{
			enabled:          true
			src_factor_rgb:   .dst_color
			dst_factor_rgb:   .zero
			src_factor_alpha: .zero
			dst_factor_alpha: .one
		}
	}
	r.light.mul_pip = sgl.make_pipeline(&md)
	r.light.ok = true
	return true
}

// make_light_texture: a white square whose alpha is the falloff of a light centered in it; `cone` > 0 makes it a
// spot pointing along +x.
fn make_light_texture(cone f32) gfx.Image {
	n := light_texture_size
	mut px := []u8{len: n * n * 4}
	half := f32(n) / 2
	for y in 0 .. n {
		for x in 0 .. n {
			dx := (f32(x) + 0.5 - half) / half
			dy := (f32(y) + 0.5 - half) / half
			mut a := core.light_falloff(f32(math.sqrt(dx * dx + dy * dy)), 1)
			if cone > 0 {
				a *= core.spot_factor(f32(math.atan2(dy, dx) * 180.0 / math.pi), cone)
			}
			i := (y * n + x) * 4
			px[i] = 255
			px[i + 1] = 255
			px[i + 2] = 255
			px[i + 3] = u8(a * 255 + 0.5)
		}
	}
	mut d := zeroed[gfx.ImageDesc]()
	d.width = n
	d.height = n
	d.pixel_format = .rgba8
	d.label = c'velo-light-texture'
	d.data.subimage[0][0] = gfx.Range{
		ptr:  px.data
		size: usize(px.len)
	}
	return gfx.make_image(&d)
}

// light_target (re)creates the light map when the window size or `resolution` changed.
fn (mut r Renderer) light_target(tw int, th int) {
	if r.light.w == tw && r.light.h == th {
		return
	}
	if r.light.w > 0 {
		gfx.destroy_attachments(r.light.atts)
		gfx.destroy_image(r.light.img)
	}
	mut d := zeroed[gfx.ImageDesc]()
	d.render_target = true
	d.width = tw
	d.height = th
	d.pixel_format = .rgba8
	d.sample_count = 1
	d.label = c'velo-light-map'
	r.light.img = gfx.make_image(&d)
	mut ad := zeroed[gfx.AttachmentsDesc]()
	ad.colors[0].image = r.light.img
	ad.label = c'velo-light-map-attachments'
	r.light.atts = gfx.make_attachments(&ad)
	r.light.w = tw
	r.light.h = th
}

fn (mut r Renderer) spot_texture(cone f32) gfx.Image {
	key := int(cone / 5 + 0.5) * 5
	if img := r.light.spots[key] {
		return img
	}
	img := make_light_texture(f32(math.max(key, 5)))
	r.light.spots[key] = img
	return img
}

// apply_lighting draws the light map and multiplies the world by it (once per frame, see draw_tree).
fn (mut r Renderer) apply_lighting(scene &core.Scene, window core.Affine2) {
	lighting := scene.lighting() or { return }
	if !r.light_init() {
		return
	}
	pw := sapp.width()
	ph := sapp.height()
	if pw <= 0 || ph <= 0 {
		return
	}
	res := int(math.clamp(lighting.resolution, 1, 8))
	r.light_target(math.max(pw / res, 1), math.max(ph / res, 1))
	cam := scene.view_matrix()
	s := r.ctx.scale
	t := scene.time

	// 1. the lights, into the light context
	sgl.set_context(r.light.ctx)
	sgl.defaults()
	sgl.matrix_mode_projection()
	sgl.ortho(0.0, f32(pw), f32(ph), 0.0, -1.0, 1.0)
	sgl.viewport(0, 0, r.light.w, r.light.h, true)
	sgl.load_pipeline(r.light.add_pip)
	sgl.enable_texture()
	for l in scene.lights {
		if !l.enabled || l.node == unsafe { nil } || l.node.destroyed
			|| !l.node.is_active_in_hierarchy() || l.radius <= 0 {
			continue
		}
		strength := l.current_intensity(t)
		if strength <= 0 {
			continue
		}
		m := window.mul(cam).mul(l.node.world_matrix())
		c := m.apply(core.Vec2{})
		sc := m.scale()
		rad := l.radius * f32(math.max(math.abs(sc.x), math.abs(sc.y)))
		rot := f32(m.rotation_deg() * math.pi / 180.0)
		img := if l.kind == 'spot' { r.spot_texture(l.cone) } else { r.light.point }
		sgl.texture(img, r.light.tex_smp)
		passes := int(math.ceil(strength))
		each := strength / f32(passes)
		cr, cg, cb := u8(f32(l.color.r) * each), u8(f32(l.color.g) * each), u8(f32(l.color.b) * each)
		for _ in 0 .. passes {
			sgl.begin_quads()
			// the square around the light, turned by the node's rotation (it matters for spots)
			cs, sn := f32(math.cos(rot)), f32(math.sin(rot))
			for uv in [[f32(0), f32(0)], [f32(1), f32(0)], [f32(1), f32(1)],
				[f32(0), f32(1)]] {
				lx := (uv[0] * 2 - 1) * rad
				ly := (uv[1] * 2 - 1) * rad
				x := c.x + lx * cs - ly * sn
				y := c.y + lx * sn + ly * cs
				sgl.v2f_t2f_c4b(x * s, y * s, uv[0], uv[1], cr, cg, cb, 255)
			}
			sgl.end()
		}
	}
	sgl.disable_texture()
	// 2. the light map pass: start from the ambient color, add the recorded lights
	a := lighting.ambient
	mut pass := zeroed[gfx.Pass]()
	pass.action.colors[0] = gfx.ColorAttachmentAction{
		load_action: .clear
		clear_value: gfx.Color{f32(a.r) / 255.0, f32(a.g) / 255.0, f32(a.b) / 255.0, 1}
	}
	pass.attachments = r.light.atts
	pass.label = c'velo-light-pass'
	gfx.begin_pass(&pass)
	sgl.context_draw(r.light.ctx)
	gfx.end_pass()
	sgl.set_context(sgl.default_context())

	// 3. multiply the world drawn so far by the light map
	r.set_scissor(r.base_rect())
	sgl.load_pipeline(r.light.mul_pip)
	sgl.enable_texture()
	sgl.texture(r.light.img, r.light.smp)
	sgl.begin_quads()
	w, h := f32(pw), f32(ph)
	flip := !gfx.query_features().origin_top_left // GL render targets are upside down compared to Metal/D3D
	v0, v1 := if flip { f32(1), f32(0) } else { f32(0), f32(1) }
	sgl.v2f_t2f_c4b(0, 0, 0, v0, 255, 255, 255, 255)
	sgl.v2f_t2f_c4b(w, 0, 1, v0, 255, 255, 255, 255)
	sgl.v2f_t2f_c4b(w, h, 1, v1, 255, 255, 255, 255)
	sgl.v2f_t2f_c4b(0, h, 0, v1, 255, 255, 255, 255)
	sgl.end()
	sgl.disable_texture()
	sgl.load_default_pipeline()
	r.set_scissor(r.clip)
	r.draw_calls++
}
