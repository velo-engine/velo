module render

import sokol.sgl
import velo.core

// Sprite batching: plain sprites (simple draw mode, no shader) are written straight into one open sokol_gl quad
// list per texture, with their corners transformed by the node matrix. gg.draw_image_with_config costs a pipeline
// load, a texture switch and a begin/end per sprite, plus a matrix push and rotate for rotated sprites, which also
// stops sokol_gl from merging them into one draw. Here consecutive sprites on the same texture (an atlas page, see
// atlas.v) are one draw whatever their rotation, scale or flip.
//
// While a run is open nothing else may draw through gg or sgl: everything else in the renderer calls
// flush_sprites() first (draw_node for other components, set_scissor, apply_lighting, the end of draw_tree).

// sokol_gl's buffers, for gg's context too. With the defaults (131072 vertices = 32768 quads, 32768 draws) a frame
// that needed more drew nothing at all: sokol_gl skips the whole frame once a buffer is full. This is 131072 quads.
// One vertex is ~24 bytes, kept twice (CPU + GPU).
// sokol_gl.h only sets its defaults when these are not defined.
#flag -D_SGL_DEFAULT_MAX_VERTICES=524288
#flag -D_SGL_DEFAULT_MAX_COMMANDS=65536

struct SpriteBatch {
mut:
	open   bool
	img_id int
}

// batch_sprite draws one plain sprite into the open run. `img_id` is a gg image cache id; `fx, fy, fw, fh` is the
// part of that image to show, in pixels.
fn (mut r Renderer) batch_sprite(s &Sprite, m core.Affine2, img_id int, fx f32, fy f32, fw f32, fh f32) {
	img := r.ctx.get_cached_image_by_idx(img_id)
	if !img.simg_ok || img.width <= 0 || img.height <= 0 {
		return
	}
	iw := f32(img.width)
	ih := f32(img.height)
	mut u0 := fx / iw
	mut u1 := (fx + fw) / iw
	mut v0 := fy / ih
	mut v1 := (fy + fh) / ih
	// the node's own negative scale already mirrors the corners; flip_x/flip_y mirror the texture on top of that
	if s.flip_x {
		u0, u1 = u1, u0
	}
	if s.flip_y {
		v0, v1 = v1, v0
	}
	sz := s.display_size()
	x0 := -s.anchor.x * sz.x
	y0 := -s.anchor.y * sz.y
	x1 := x0 + sz.x
	y1 := y0 + sz.y
	// corners in window points
	ax, ay := m.a * x0 + m.c * y0 + m.tx, m.b * x0 + m.d * y0 + m.ty
	bx, by := m.a * x1 + m.c * y0 + m.tx, m.b * x1 + m.d * y0 + m.ty
	cx, cy := m.a * x1 + m.c * y1 + m.tx, m.b * x1 + m.d * y1 + m.ty
	dx, dy := m.a * x0 + m.c * y1 + m.tx, m.b * x0 + m.d * y1 + m.ty
	// culling: skip a sprite whose bounds are entirely outside the clip rect (the window, the scene view or a
	// ScrollView), so off-screen sprites cost no vertices
	cl := r.clip
	if max4(ax, bx, cx, dx) < cl.x || min4(ax, bx, cx, dx) > cl.x + cl.w
		|| max4(ay, by, cy, dy) < cl.y || min4(ay, by, cy, dy) > cl.y + cl.h {
		r.culled++
		return
	}
	if !r.batch.open || r.batch.img_id != img_id {
		r.flush_sprites()
		sgl.load_pipeline(r.ctx.pipeline.alpha)
		sgl.enable_texture()
		sgl.texture(img.simg, img.ssmp)
		sgl.begin_quads()
		r.batch.open = true
		r.batch.img_id = img_id
		r.draw_calls++ // one per run: what sokol_gl actually issues
	}
	k := r.ctx.scale // gg draws in window points; sokol_gl works in framebuffer pixels
	sgl.c4b(s.color.r, s.color.g, s.color.b, s.color.a)
	sgl.v2f_t2f(ax * k, ay * k, u0, v0)
	sgl.v2f_t2f(bx * k, by * k, u1, v0)
	sgl.v2f_t2f(cx * k, cy * k, u1, v1)
	sgl.v2f_t2f(dx * k, dy * k, u0, v1)
}

@[inline]
fn min4(a f32, b f32, c f32, d f32) f32 {
	ab := if a < b { a } else { b }
	cd := if c < d { c } else { d }
	return if ab < cd { ab } else { cd }
}

@[inline]
fn max4(a f32, b f32, c f32, d f32) f32 {
	ab := if a > b { a } else { b }
	cd := if c > d { c } else { d }
	return if ab > cd { ab } else { cd }
}

// check_sgl_overflow warns (once) when this frame ran out of sokol_gl space: sokol_gl then draws nothing that frame.
fn (mut r Renderer) check_sgl_overflow() {
	if r.sgl_warned {
		return
	}
	err := sgl.error()
	if err in [.vertices_full, .commands_full, .uniforms_full] {
		eprintln('[render] sokol_gl ${err}: the frame was not drawn (too many quads; see batch.v)')
		r.sgl_warned = true
	}
}

// flush_sprites closes the open sprite run so something else can draw.
fn (mut r Renderer) flush_sprites() {
	if !r.batch.open {
		return
	}
	sgl.end()
	sgl.disable_texture()
	r.batch.open = false
}
