module core

import math

// Vec2 — 2D vector. Screen coordinate system: x to the right, y downward.
pub struct Vec2 {
pub mut:
	x f32
	y f32
}

pub fn vec2(x f32, y f32) Vec2 {
	return Vec2{x, y}
}

pub fn (a Vec2) + (b Vec2) Vec2 {
	return Vec2{a.x + b.x, a.y + b.y}
}

pub fn (a Vec2) - (b Vec2) Vec2 {
	return Vec2{a.x - b.x, a.y - b.y}
}

// Component-wise multiplication (used for scale).
pub fn (a Vec2) * (b Vec2) Vec2 {
	return Vec2{a.x * b.x, a.y * b.y}
}

pub fn (a Vec2) mul(s f32) Vec2 {
	return Vec2{a.x * s, a.y * s}
}

pub fn (a Vec2) length() f32 {
	return f32(math.sqrt(a.x * a.x + a.y * a.y))
}

pub fn (a Vec2) distance(b Vec2) f32 {
	return (a - b).length()
}

pub fn (a Vec2) normalized() Vec2 {
	l := a.length()
	if l < 1e-6 {
		return Vec2{}
	}
	return Vec2{a.x / l, a.y / l}
}

pub fn (a Vec2) lerp(b Vec2, t f32) Vec2 {
	return Vec2{a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t}
}

pub fn (a Vec2) str() string {
	return '(${a.x}, ${a.y})'
}

// Color — 8-bit RGBA color.
pub struct Color {
pub mut:
	r u8 = 255
	g u8 = 255
	b u8 = 255
	a u8 = 255
}

pub fn rgba(r u8, g u8, b u8, a u8) Color {
	return Color{r, g, b, a}
}

pub const white = Color{}
pub const black = Color{0, 0, 0, 255}

// Affine2 — 2D transformation matrix:
//   | a  c  tx |
//   | b  d  ty |
pub struct Affine2 {
pub:
	a  f32 = 1
	b  f32
	c  f32
	d  f32 = 1
	tx f32
	ty f32
}

pub fn Affine2.identity() Affine2 {
	return Affine2{}
}

// Affine2.trs builds a matrix from position, rotation (degrees, clockwise on screen) and scale.
pub fn Affine2.trs(pos Vec2, rotation_deg f32, scale Vec2) Affine2 {
	r := f64(rotation_deg) * math.pi / 180.0
	cs := f32(math.cos(r))
	sn := f32(math.sin(r))
	return Affine2{
		a:  cs * scale.x
		b:  sn * scale.x
		c:  -sn * scale.y
		d:  cs * scale.y
		tx: pos.x
		ty: pos.y
	}
}

// mul returns m * o (applies o first, then m).
pub fn (m Affine2) mul(o Affine2) Affine2 {
	return Affine2{
		a:  m.a * o.a + m.c * o.b
		b:  m.b * o.a + m.d * o.b
		c:  m.a * o.c + m.c * o.d
		d:  m.b * o.c + m.d * o.d
		tx: m.a * o.tx + m.c * o.ty + m.tx
		ty: m.b * o.tx + m.d * o.ty + m.ty
	}
}

pub fn (m Affine2) apply(p Vec2) Vec2 {
	return Vec2{m.a * p.x + m.c * p.y + m.tx, m.b * p.x + m.d * p.y + m.ty}
}

pub fn (m Affine2) position() Vec2 {
	return Vec2{m.tx, m.ty}
}

pub fn (m Affine2) rotation_deg() f32 {
	return f32(math.atan2(m.b, m.a) * 180.0 / math.pi)
}

pub fn (m Affine2) scale() Vec2 {
	sx := f32(math.sqrt(m.a * m.a + m.b * m.b))
	det := m.a * m.d - m.b * m.c
	sy := f32(math.sqrt(m.c * m.c + m.d * m.d))
	return Vec2{sx, if det < 0 { -sy } else { sy }}
}

pub fn (m Affine2) inverse() Affine2 {
	det := m.a * m.d - m.b * m.c
	if math.abs(det) < 1e-9 {
		return Affine2{}
	}
	inv := 1.0 / det
	return Affine2{
		a:  m.d * inv
		b:  -m.b * inv
		c:  -m.c * inv
		d:  m.a * inv
		tx: (m.c * m.ty - m.d * m.tx) * inv
		ty: (m.b * m.tx - m.a * m.ty) * inv
	}
}
