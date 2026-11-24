module core

import math

// ---------- 3D math (velo.render3d, velo.model3d) ----------
// Right-handed, y up, -z forward (OpenGL / glTF / FBX y-up). Angles in degrees unless stated otherwise.
// Matrices are column-major (m[col * 4 + row]) and act on column vectors: p' = M * p.

// Vec3 — 3D vector.
pub struct Vec3 {
pub mut:
	x f32
	y f32
	z f32
}

pub fn vec3(x f32, y f32, z f32) Vec3 {
	return Vec3{x, y, z}
}

pub fn (a Vec3) + (b Vec3) Vec3 {
	return Vec3{a.x + b.x, a.y + b.y, a.z + b.z}
}

pub fn (a Vec3) - (b Vec3) Vec3 {
	return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}
}

// Component-wise multiplication (used for scale).
pub fn (a Vec3) * (b Vec3) Vec3 {
	return Vec3{a.x * b.x, a.y * b.y, a.z * b.z}
}

pub fn (a Vec3) mul(s f32) Vec3 {
	return Vec3{a.x * s, a.y * s, a.z * s}
}

pub fn (a Vec3) neg() Vec3 {
	return Vec3{-a.x, -a.y, -a.z}
}

pub fn (a Vec3) dot(b Vec3) f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

pub fn (a Vec3) cross(b Vec3) Vec3 {
	return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

pub fn (a Vec3) length() f32 {
	return f32(math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z))
}

pub fn (a Vec3) distance(b Vec3) f32 {
	return (a - b).length()
}

pub fn (a Vec3) normalized() Vec3 {
	l := a.length()
	if l < 1e-8 {
		return Vec3{}
	}
	return Vec3{a.x / l, a.y / l, a.z / l}
}

pub fn (a Vec3) lerp(b Vec3, t f32) Vec3 {
	return Vec3{a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t}
}

// xz: the ground-plane part (x, z) as a Vec2, for top-down logic on a 3D world.
pub fn (a Vec3) xz() Vec2 {
	return Vec2{a.x, a.z}
}

pub fn (a Vec3) str() string {
	return '(${a.x}, ${a.y}, ${a.z})'
}

// ---------- Quaternion ----------

// Quat — a rotation (unit quaternion). Quat{} is not valid; use Quat.identity().
pub struct Quat {
pub mut:
	x f32
	y f32
	z f32
	w f32 = 1
}

pub fn Quat.identity() Quat {
	return Quat{0, 0, 0, 1}
}

// Quat.axis_angle: a rotation of `deg` degrees around `axis` (right-hand rule).
pub fn Quat.axis_angle(axis Vec3, deg f32) Quat {
	a := axis.normalized()
	h := f32(deg * math.pi / 360.0)
	s := f32(math.sin(h))
	return Quat{a.x * s, a.y * s, a.z * s, f32(math.cos(h))}
}

// Quat.euler: rotation from euler angles in degrees, applied X first, then Y, then Z (FBX's default order,
// Unity applies Z, X, Y) — the matrix Rz * Ry * Rx.
pub fn Quat.euler(e Vec3) Quat {
	qx := Quat.axis_angle(Vec3{1, 0, 0}, e.x)
	qy := Quat.axis_angle(Vec3{0, 1, 0}, e.y)
	qz := Quat.axis_angle(Vec3{0, 0, 1}, e.z)
	return qz.mul(qy).mul(qx)
}

// Quat.yaw: a rotation around +y (turning on the ground) by `deg` degrees.
pub fn Quat.yaw(deg f32) Quat {
	return Quat.axis_angle(Vec3{0, 1, 0}, deg)
}

// mul: q * r = apply r first, then q.
pub fn (q Quat) mul(r Quat) Quat {
	return Quat{
		x: q.w * r.x + q.x * r.w + q.y * r.z - q.z * r.y
		y: q.w * r.y - q.x * r.z + q.y * r.w + q.z * r.x
		z: q.w * r.z + q.x * r.y - q.y * r.x + q.z * r.w
		w: q.w * r.w - q.x * r.x - q.y * r.y - q.z * r.z
	}
}

pub fn (q Quat) normalized() Quat {
	l := f32(math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w))
	if l < 1e-12 {
		return Quat.identity()
	}
	return Quat{q.x / l, q.y / l, q.z / l, q.w / l}
}

pub fn (q Quat) conjugate() Quat {
	return Quat{-q.x, -q.y, -q.z, q.w}
}

// rotate applies the rotation to a vector.
pub fn (q Quat) rotate(v Vec3) Vec3 {
	u := Vec3{q.x, q.y, q.z}
	t := u.cross(v).mul(2)
	return v + t.mul(q.w) + u.cross(t)
}

// nlerp: normalized linear blend along the shorter arc (good enough for animation keys a frame apart).
pub fn (a Quat) nlerp(b Quat, t f32) Quat {
	d := a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
	s := if d < 0 { f32(-1) } else { f32(1) }
	return Quat{
		x: a.x + (b.x * s - a.x) * t
		y: a.y + (b.y * s - a.y) * t
		z: a.z + (b.z * s - a.z) * t
		w: a.w + (b.w * s - a.w) * t
	}.normalized()
}

// slerp: constant-speed spherical blend along the shorter arc.
pub fn (a Quat) slerp(b Quat, t f32) Quat {
	mut d := a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
	mut bb := b
	if d < 0 {
		d = -d
		bb = Quat{-b.x, -b.y, -b.z, -b.w}
	}
	if d > 0.9995 {
		return a.nlerp(bb, t)
	}
	th := math.acos(d)
	sn := math.sin(th)
	wa := f32(math.sin((1 - t) * th) / sn)
	wb := f32(math.sin(t * th) / sn)
	return Quat{a.x * wa + bb.x * wb, a.y * wa + bb.y * wb, a.z * wa + bb.z * wb, a.w * wa +
		bb.w * wb}
}

// ---------- 4x4 matrix ----------

// Mat4 — column-major 4x4 matrix (the layout GPUs take as is).
pub struct Mat4 {
pub mut:
	m [16]f32
}

pub fn Mat4.identity() Mat4 {
	return Mat4{
		m: [f32(1), 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]!
	}
}

pub fn Mat4.translation(t Vec3) Mat4 {
	mut r := Mat4.identity()
	r.m[12] = t.x
	r.m[13] = t.y
	r.m[14] = t.z
	return r
}

pub fn Mat4.scaling(s Vec3) Mat4 {
	mut r := Mat4.identity()
	r.m[0] = s.x
	r.m[5] = s.y
	r.m[10] = s.z
	return r
}

pub fn Mat4.rotation(q Quat) Mat4 {
	x, y, z, w := q.x, q.y, q.z, q.w
	return Mat4{
		m: [
			1 - 2 * (y * y + z * z),
			2 * (x * y + z * w),
			2 * (x * z - y * w),
			0,
			2 * (x * y - z * w),
			1 - 2 * (x * x + z * z),
			2 * (y * z + x * w),
			0,
			2 * (x * z + y * w),
			2 * (y * z - x * w),
			1 - 2 * (x * x + y * y),
			0,
			0,
			0,
			0,
			1,
		]!
	}
}

// Mat4.trs: translation * rotation * scale (scale first, then rotate, then move).
pub fn Mat4.trs(t Vec3, r Quat, s Vec3) Mat4 {
	mut m := Mat4.rotation(r)
	m.m[0] *= s.x
	m.m[1] *= s.x
	m.m[2] *= s.x
	m.m[4] *= s.y
	m.m[5] *= s.y
	m.m[6] *= s.y
	m.m[8] *= s.z
	m.m[9] *= s.z
	m.m[10] *= s.z
	m.m[12] = t.x
	m.m[13] = t.y
	m.m[14] = t.z
	return m
}

// Mat4.perspective: a right-handed projection with depth mapped to -1..1 (`fov_y` in degrees).
pub fn Mat4.perspective(fov_y f32, aspect f32, near f32, far f32) Mat4 {
	f := f32(1.0 / math.tan(fov_y * math.pi / 360.0))
	mut r := Mat4{}
	r.m[0] = f / aspect
	r.m[5] = f
	r.m[10] = (far + near) / (near - far)
	r.m[11] = -1
	r.m[14] = 2 * far * near / (near - far)
	return r
}

// Mat4.look_at: the view matrix of a camera at `eye` looking at `target`.
pub fn Mat4.look_at(eye Vec3, target Vec3, up Vec3) Mat4 {
	f := (target - eye).normalized()
	mut s := f.cross(up).normalized()
	if s.length() < 1e-6 {
		s = f.cross(Vec3{0, 0, 1}).normalized()
	}
	u := s.cross(f)
	mut r := Mat4.identity()
	r.m[0] = s.x
	r.m[4] = s.y
	r.m[8] = s.z
	r.m[1] = u.x
	r.m[5] = u.y
	r.m[9] = u.z
	r.m[2] = -f.x
	r.m[6] = -f.y
	r.m[10] = -f.z
	r.m[12] = -s.dot(eye)
	r.m[13] = -u.dot(eye)
	r.m[14] = f.dot(eye)
	return r
}

// Mat4.from_f64: a column-major matrix of doubles (as FBX stores them).
pub fn Mat4.from_f64(a []f64) Mat4 {
	mut r := Mat4.identity()
	if a.len >= 16 {
		for i in 0 .. 16 {
			r.m[i] = f32(a[i])
		}
	}
	return r
}

pub fn (a Mat4) * (b Mat4) Mat4 {
	mut r := Mat4{}
	for c in 0 .. 4 {
		for row in 0 .. 4 {
			r.m[c * 4 + row] = a.m[row] * b.m[c * 4] + a.m[4 + row] * b.m[c * 4 + 1] + a.m[8 +
				row] * b.m[c * 4 + 2] + a.m[12 + row] * b.m[c * 4 + 3]
		}
	}
	return r
}

pub fn (a Mat4) transform_point(p Vec3) Vec3 {
	return Vec3{a.m[0] * p.x + a.m[4] * p.y + a.m[8] * p.z + a.m[12], a.m[1] * p.x + a.m[5] * p.y +
		a.m[9] * p.z + a.m[13], a.m[2] * p.x + a.m[6] * p.y + a.m[10] * p.z + a.m[14]}
}

// transform_dir: rotation and scale only (no translation).
pub fn (a Mat4) transform_dir(d Vec3) Vec3 {
	return Vec3{a.m[0] * d.x + a.m[4] * d.y + a.m[8] * d.z, a.m[1] * d.x + a.m[5] * d.y +
		a.m[9] * d.z, a.m[2] * d.x + a.m[6] * d.y + a.m[10] * d.z}
}

// project: a point through a projection matrix, divided by w (clip space -> normalized device coordinates).
pub fn (a Mat4) project(p Vec3) (Vec3, f32) {
	x := a.m[0] * p.x + a.m[4] * p.y + a.m[8] * p.z + a.m[12]
	y := a.m[1] * p.x + a.m[5] * p.y + a.m[9] * p.z + a.m[13]
	z := a.m[2] * p.x + a.m[6] * p.y + a.m[10] * p.z + a.m[14]
	w := a.m[3] * p.x + a.m[7] * p.y + a.m[11] * p.z + a.m[15]
	if w == 0 {
		return Vec3{}, 0
	}
	return Vec3{x / w, y / w, z / w}, w
}

pub fn (a Mat4) translation_part() Vec3 {
	return Vec3{a.m[12], a.m[13], a.m[14]}
}

// axis: column `i` (0 = x, 1 = y, 2 = z) as a vector, e.g. a node's right / up / back direction.
pub fn (a Mat4) axis(i int) Vec3 {
	return Vec3{a.m[i * 4], a.m[i * 4 + 1], a.m[i * 4 + 2]}
}

pub fn (a Mat4) transposed() Mat4 {
	mut r := Mat4{}
	for c in 0 .. 4 {
		for row in 0 .. 4 {
			r.m[row * 4 + c] = a.m[c * 4 + row]
		}
	}
	return r
}

// inverse: the general 4x4 inverse (identity if the matrix is singular).
pub fn (a Mat4) inverse() Mat4 {
	m := a.m
	mut inv := [16]f64{}
	inv[0] = f64(m[5]) * m[10] * m[15] - f64(m[5]) * m[11] * m[14] - f64(m[9]) * m[6] * m[15] +
		f64(m[9]) * m[7] * m[14] + f64(m[13]) * m[6] * m[11] - f64(m[13]) * m[7] * m[10]
	inv[4] = -f64(m[4]) * m[10] * m[15] + f64(m[4]) * m[11] * m[14] + f64(m[8]) * m[6] * m[15] -
		f64(m[8]) * m[7] * m[14] - f64(m[12]) * m[6] * m[11] + f64(m[12]) * m[7] * m[10]
	inv[8] = f64(m[4]) * m[9] * m[15] - f64(m[4]) * m[11] * m[13] - f64(m[8]) * m[5] * m[15] +
		f64(m[8]) * m[7] * m[13] + f64(m[12]) * m[5] * m[11] - f64(m[12]) * m[7] * m[9]
	inv[12] = -f64(m[4]) * m[9] * m[14] + f64(m[4]) * m[10] * m[13] + f64(m[8]) * m[5] * m[14] -
		f64(m[8]) * m[6] * m[13] - f64(m[12]) * m[5] * m[10] + f64(m[12]) * m[6] * m[9]
	inv[1] = -f64(m[1]) * m[10] * m[15] + f64(m[1]) * m[11] * m[14] + f64(m[9]) * m[2] * m[15] -
		f64(m[9]) * m[3] * m[14] - f64(m[13]) * m[2] * m[11] + f64(m[13]) * m[3] * m[10]
	inv[5] = f64(m[0]) * m[10] * m[15] - f64(m[0]) * m[11] * m[14] - f64(m[8]) * m[2] * m[15] +
		f64(m[8]) * m[3] * m[14] + f64(m[12]) * m[2] * m[11] - f64(m[12]) * m[3] * m[10]
	inv[9] = -f64(m[0]) * m[9] * m[15] + f64(m[0]) * m[11] * m[13] + f64(m[8]) * m[1] * m[15] -
		f64(m[8]) * m[3] * m[13] - f64(m[12]) * m[1] * m[11] + f64(m[12]) * m[3] * m[9]
	inv[13] = f64(m[0]) * m[9] * m[14] - f64(m[0]) * m[10] * m[13] - f64(m[8]) * m[1] * m[14] +
		f64(m[8]) * m[2] * m[13] + f64(m[12]) * m[1] * m[10] - f64(m[12]) * m[2] * m[9]
	inv[2] = f64(m[1]) * m[6] * m[15] - f64(m[1]) * m[7] * m[14] - f64(m[5]) * m[2] * m[15] +
		f64(m[5]) * m[3] * m[14] + f64(m[13]) * m[2] * m[7] - f64(m[13]) * m[3] * m[6]
	inv[6] = -f64(m[0]) * m[6] * m[15] + f64(m[0]) * m[7] * m[14] + f64(m[4]) * m[2] * m[15] -
		f64(m[4]) * m[3] * m[14] - f64(m[12]) * m[2] * m[7] + f64(m[12]) * m[3] * m[6]
	inv[10] = f64(m[0]) * m[5] * m[15] - f64(m[0]) * m[7] * m[13] - f64(m[4]) * m[1] * m[15] +
		f64(m[4]) * m[3] * m[13] + f64(m[12]) * m[1] * m[7] - f64(m[12]) * m[3] * m[5]
	inv[14] = -f64(m[0]) * m[5] * m[14] + f64(m[0]) * m[6] * m[13] + f64(m[4]) * m[1] * m[14] -
		f64(m[4]) * m[2] * m[13] - f64(m[12]) * m[1] * m[6] + f64(m[12]) * m[2] * m[5]
	inv[3] = -f64(m[1]) * m[6] * m[11] + f64(m[1]) * m[7] * m[10] + f64(m[5]) * m[2] * m[11] -
		f64(m[5]) * m[3] * m[10] - f64(m[9]) * m[2] * m[7] + f64(m[9]) * m[3] * m[6]
	inv[7] = f64(m[0]) * m[6] * m[11] - f64(m[0]) * m[7] * m[10] - f64(m[4]) * m[2] * m[11] +
		f64(m[4]) * m[3] * m[10] + f64(m[8]) * m[2] * m[7] - f64(m[8]) * m[3] * m[6]
	inv[11] = -f64(m[0]) * m[5] * m[11] + f64(m[0]) * m[7] * m[9] + f64(m[4]) * m[1] * m[11] -
		f64(m[4]) * m[3] * m[9] - f64(m[8]) * m[1] * m[7] + f64(m[8]) * m[3] * m[5]
	inv[15] = f64(m[0]) * m[5] * m[10] - f64(m[0]) * m[6] * m[9] - f64(m[4]) * m[1] * m[10] +
		f64(m[4]) * m[2] * m[9] + f64(m[8]) * m[1] * m[6] - f64(m[8]) * m[2] * m[5]
	det := f64(m[0]) * inv[0] + f64(m[1]) * inv[4] + f64(m[2]) * inv[8] + f64(m[3]) * inv[12]
	if math.abs(det) < 1e-20 {
		return Mat4.identity()
	}
	mut r := Mat4{}
	for i in 0 .. 16 {
		r.m[i] = f32(inv[i] / det)
	}
	return r
}

// decompose: translation, rotation and scale of an affine matrix without shear.
pub fn (a Mat4) decompose() (Vec3, Quat, Vec3) {
	t := a.translation_part()
	mut sx := a.axis(0).length()
	sy := a.axis(1).length()
	sz := a.axis(2).length()
	if a.axis(0).cross(a.axis(1)).dot(a.axis(2)) < 0 {
		sx = -sx
	}
	if sx == 0 || sy == 0 || sz == 0 {
		return t, Quat.identity(), Vec3{sx, sy, sz}
	}
	m00, m10, m20 := a.m[0] / sx, a.m[1] / sx, a.m[2] / sx
	m01, m11, m21 := a.m[4] / sy, a.m[5] / sy, a.m[6] / sy
	m02, m12, m22 := a.m[8] / sz, a.m[9] / sz, a.m[10] / sz
	tr := m00 + m11 + m22
	mut q := Quat{}
	if tr > 0 {
		s := f32(math.sqrt(tr + 1.0) * 2)
		q = Quat{(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s}
	} else if m00 > m11 && m00 > m22 {
		s := f32(math.sqrt(1.0 + m00 - m11 - m22) * 2)
		q = Quat{0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s}
	} else if m11 > m22 {
		s := f32(math.sqrt(1.0 + m11 - m00 - m22) * 2)
		q = Quat{(m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s}
	} else {
		s := f32(math.sqrt(1.0 + m22 - m00 - m11) * 2)
		q = Quat{(m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s}
	}
	return t, q.normalized(), Vec3{sx, sy, sz}
}
