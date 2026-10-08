module render

import gg
import math
import sokol.sgl
import velo.core

// Sliced (9-slice) and tiled Sprites. The frame is cut by the four `border_*` lines into a 3x3 grid:
//
//     +----+----------+----+       corners keep their size (border pixels * pixel_scale),
//     | TL |    T     | TR |       T/B stretch (sliced) or repeat (tiled) horizontally,
//     +----+----------+----+       L/R vertically, and the center both ways.
//     | L  |  center  | R  |
//     +----+----------+----+       When `size` is smaller than two borders, both borders shrink
//     | BL |    B     | BR |       proportionally so they still meet.
//     +----+----------+----+
//
// 'tiled' without borders just repeats the whole frame; the last row/column is cropped to fit.
// Everything is drawn as textured quads in one batch, so the sprite rotates, scales and flips with its node.
//
//   Sprite { texture = @asset("5d2c9e10")  size = [240, 96]  draw_mode = "sliced"
//            border_left = 12  border_top = 12  border_right = 12  border_bottom = 12 }

// SpriteQuad — one piece of a sprite: a node-space rectangle and the texture pixels it shows.
// u0/v0 map to the rectangle's left/top edge, u1/v1 to its right/bottom edge (swapped when flipped).
pub struct SpriteQuad {
pub:
	x  f32
	y  f32
	w  f32
	h  f32
	u0 f32
	v0 f32
	u1 f32
	v1 f32
}

// Seg — one piece along an axis: [d0, d1] in the destination, [s0, s1] texture pixels; `mid` = center band.
struct Seg {
	d0  f32
	d1  f32
	s0  f32
	s1  f32
	mid bool
}

const max_tiles_per_axis = 256 // beyond this the repeat step grows, so a huge size can't explode the vertex count

// is_sliced_mode: true when the sprite is drawn as quads (sliced or tiled) rather than one stretched image.
pub fn (s &Sprite) is_sliced_mode() bool {
	return s.draw_mode in ['sliced', 'tiled']
}

// borders: the four borders clamped to the frame (left, top, right, bottom), in texture pixels.
pub fn (s &Sprite) borders() (int, int, int, int) {
	if s.tex == unsafe { nil } {
		return 0, 0, 0, 0
	}
	l, r := clamp_pair(s.border_left, s.border_right, s.tex.frame_w())
	t, b := clamp_pair(s.border_top, s.border_bottom, s.tex.frame_h())
	return l, t, r, b
}

// clamp_pair keeps two borders >= 0 with a sum no larger than the frame's length.
fn clamp_pair(a int, b int, len int) (int, int) {
	mut x := math.max(a, 0)
	mut y := math.max(b, 0)
	if x + y > len {
		x = math.min(x, len)
		y = len - x
	}
	return x, y
}

// slice_lines: where the four border lines fall in node space (left x, top y, right x, bottom y), after
// shrinking for a small size — the editor draws them as guides. Ignores flips.
pub fn (s &Sprite) slice_lines() (f32, f32, f32, f32) {
	x, y, w, h := s.local_rect()
	l, t, r, b := s.borders()
	scale := sprite_pixel_scale(s.pixel_scale)
	dl, dr := fit_borders(f32(l) * scale, f32(r) * scale, w)
	dt, db := fit_borders(f32(t) * scale, f32(b) * scale, h)
	return x + dl, y + dt, x + w - dr, y + h - db
}

fn sprite_pixel_scale(v f32) f32 {
	return if v > 0 { v } else { 1 }
}

// fit_borders shrinks two destination borders proportionally when they don't fit in `len`.
fn fit_borders(a f32, b f32, len f32) (f32, f32) {
	if a + b <= len || a + b <= 0 {
		return a, b
	}
	k := math.max(len, 0) / (a + b)
	return a * k, b * k
}

// axis_segments cuts one axis: `len` destination units showing texture pixels [start, start + src_len)
// with borders b0/b1; `tile` repeats the center band every (src center * scale) units instead of stretching it.
// `out` is cleared and filled, so the renderer can reuse its memory every frame.
fn axis_segments(mut out []Seg, len f32, start int, src_len int, b0 int, b1 int, scale f32, tile bool) {
	out.clear()
	if len <= 0 || src_len <= 0 {
		return
	}
	d0, d1 := fit_borders(f32(b0) * scale, f32(b1) * scale, len)
	s := f32(start)
	e := f32(start + src_len)
	if d0 > 0 {
		out << Seg{0, d0, s, s + f32(b0), false}
	}
	mid_src0 := s + f32(b0)
	mid_src1 := e - f32(b1)
	mid_len := len - d0 - d1
	if mid_len > 0 && mid_src1 > mid_src0 {
		if tile {
			mut step := (mid_src1 - mid_src0) * scale
			if mid_len / step > max_tiles_per_axis {
				step = mid_len / max_tiles_per_axis
			}
			mut p := d0
			end := len - d1
			for p < end - 0.001 {
				q := math.min(p + step, end)
				// a cropped last tile shows the start of the band, proportionally
				out << Seg{p, q, mid_src0, mid_src0 + (mid_src1 - mid_src0) * (q - p) / step, true}
				p = q
			}
		} else {
			out << Seg{d0, len - d1, mid_src0, mid_src1, true}
		}
	}
	if d1 > 0 {
		out << Seg{len - d1, len, e - f32(b1), e, false}
	}
}

// quads: the pieces the sprite is drawn with, in node space (one for 'simple', up to 9 for 'sliced',
// many for 'tiled'). Empty without a loaded texture.
pub fn (s &Sprite) quads() []SpriteQuad {
	mut sc := &QuadScratch{}
	s.quads_into(mut sc)
	return sc.quads
}

// QuadScratch — the buffers quads_into fills; the renderer keeps one so drawing a sliced sprite does not allocate.
@[heap]
struct QuadScratch {
mut:
	quads []SpriteQuad
	xs    []Seg
	ys    []Seg
}

// quads_into puts the sprite's quads (see quads) in `sc.quads`, reusing the memory of all of sc's buffers.
fn (s &Sprite) quads_into(mut sc QuadScratch) {
	sc.quads.clear()
	if s.tex == unsafe { nil } {
		return
	}
	x, y, w, h := s.local_rect()
	fx, fy, fw, fh := s.tex.frame_rect(s.frame)
	if !s.is_sliced_mode() {
		sc.quads << s.flipped(x, y, w, h, Seg{0, w, f32(fx), f32(fx + fw), false}, Seg{0, h, f32(fy), f32(
			fy + fh), false})
		return
	}
	l, t, r, b := s.borders()
	scale := sprite_pixel_scale(s.pixel_scale)
	tile := s.draw_mode == 'tiled'
	axis_segments(mut sc.xs, w, fx, fw, l, r, scale, tile)
	axis_segments(mut sc.ys, h, fy, fh, t, b, scale, tile)
	for sy in sc.ys {
		for sx in sc.xs {
			if !s.fill_center && sx.mid && sy.mid {
				continue
			}
			sc.quads << s.flipped(x, y, w, h, sx, sy)
		}
	}
}

// flipped places a piece in the sprite's rectangle (x, y, w, h), mirrored by flip_x / flip_y.
fn (s &Sprite) flipped(x f32, y f32, w f32, h f32, sx Seg, sy Seg) SpriteQuad {
	mut qx, mut qw, mut u0, mut u1 := x + sx.d0, sx.d1 - sx.d0, sx.s0, sx.s1
	if s.flip_x {
		qx = x + w - sx.d1
		u0, u1 = sx.s1, sx.s0
	}
	mut qy, mut qh, mut v0, mut v1 := y + sy.d0, sy.d1 - sy.d0, sy.s0, sy.s1
	if s.flip_y {
		qy = y + h - sy.d1
		v0, v1 = sy.s1, sy.s0
	}
	return SpriteQuad{qx, qy, qw, qh, u0, v0, u1, v1}
}

// draw_sprite_shaded draws any sprite (simple, sliced or tiled) through a shader pipeline (see shader.v).
fn (mut r Renderer) draw_sprite_shaded(s &Sprite, m core.Affine2, pip sgl.Pipeline) {
	tex := s.tex
	fx, fy, fw, fh := tex.frame_rect(s.frame)
	tw, th := f32(tex.width), f32(tex.height)
	if tw <= 0 || th <= 0 {
		return
	}
	frame := [f32(fx) / tw, f32(fy) / th, f32(fx + fw) / tw, f32(fy + fh) / th]!
	r.draw_sprite_batch(s, m, pip, shader_uniforms(shader_time(s.node), tw, th, s.shader_params,
		s.shader_color, frame))
}

// draw_sprite_batch draws the sprite's quads with `pip`; `uniforms` (16 floats, or none) go in sokol_gl's
// texture matrix, which a velo shader reads as its built-ins.
fn (mut r Renderer) draw_sprite_batch(s &Sprite, m core.Affine2, pip sgl.Pipeline, uniforms []f32) {
	tex := s.tex
	if tex.width <= 0 || tex.height <= 0 {
		return
	}
	img := r.image_for(tex) or { return }
	if !img.simg_ok {
		return
	}
	mut qs := r.quad_scratch
	s.quads_into(mut qs)
	if qs.quads.len == 0 {
		return
	}
	tw, th := f32(tex.width), f32(tex.height)
	sc := r.ctx.scale
	col := s.color
	sgl.load_pipeline(pip)
	if uniforms.len == 16 {
		sgl.matrix_mode_texture()
		sgl.push_matrix()
		sgl.load_matrix(uniforms)
	}
	sgl.enable_texture()
	sgl.texture(img.simg, img.ssmp)
	sgl.begin_quads()
	for q in qs.quads {
		u0, v0, u1, v1 := q.u0 / tw, q.v0 / th, q.u1 / tw, q.v1 / th
		a := m.apply(core.vec2(q.x, q.y))
		b := m.apply(core.vec2(q.x + q.w, q.y))
		d := m.apply(core.vec2(q.x + q.w, q.y + q.h))
		e := m.apply(core.vec2(q.x, q.y + q.h))
		sgl.v2f_t2f_c4b(a.x * sc, a.y * sc, u0, v0, col.r, col.g, col.b, col.a)
		sgl.v2f_t2f_c4b(b.x * sc, b.y * sc, u1, v0, col.r, col.g, col.b, col.a)
		sgl.v2f_t2f_c4b(d.x * sc, d.y * sc, u1, v1, col.r, col.g, col.b, col.a)
		sgl.v2f_t2f_c4b(e.x * sc, e.y * sc, u0, v1, col.r, col.g, col.b, col.a)
	}
	sgl.end()
	sgl.disable_texture()
	if uniforms.len == 16 {
		// back to the identity texture matrix the default shader needs, and to the projection mode gg leaves set
		sgl.pop_matrix()
		sgl.matrix_mode_projection()
		sgl.load_pipeline(r.ctx.pipeline.alpha)
	}
	r.draw_calls++
	if r.debug {
		x, y, w, h := s.local_rect()
		r.draw_quad_empty(m, Rect{x, y, w, h}, gg.Color{0, 255, 0, 160})
	}
}
