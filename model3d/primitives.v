module model3d

import math
import velo.core

// Built-in meshes for prototyping, levels and characters made of parts. All are centered on the origin
// (the plane lies on y = 0) with outward normals and 0..1 uvs.

// primitive builds a mesh by name: cube, sphere, cylinder, cone, capsule, plane, torus (none = unknown name).
pub fn primitive(name string) ?MeshData {
	return match name {
		'cube', 'box' { cube(1) }
		'sphere' { sphere(0.5, 24, 16) }
		'cylinder' { cylinder(0.5, 1, 24) }
		'cone' { cone(0.5, 1, 24) }
		'capsule' { capsule(0.5, 2, 24, 8) }
		'plane' { plane(1, 1) }
		'torus' { torus(0.5, 0.15, 32, 12) }
		'ring' { torus(0.5, 0.035, 48, 8) }
		'disc' { disc(0.5, 48) }
		else { none }
	}
}

pub const primitive_names = ['cube', 'sphere', 'cylinder', 'cone', 'capsule', 'plane', 'torus',
	'ring', 'disc']

fn (mut m MeshData) vert(p core.Vec3, n core.Vec3, u f32, v f32) u32 {
	m.positions << p.x
	m.positions << p.y
	m.positions << p.z
	m.normals << n.x
	m.normals << n.y
	m.normals << n.z
	m.uvs << u
	m.uvs << v
	return u32(m.positions.len / 3 - 1)
}

fn (mut m MeshData) tri(a u32, b u32, c u32) {
	m.indices << a
	m.indices << b
	m.indices << c
}

// quad a b c d, counter-clockwise seen from the front.
fn (mut m MeshData) quad(a u32, b u32, c u32, d u32) {
	m.tri(a, b, c)
	m.tri(a, c, d)
}

// cube: a box with edge `size`, one flat face per side.
pub fn cube(size f32) MeshData {
	mut m := MeshData{
		name: 'cube'
	}
	h := size / 2
	// normal, u axis, v axis
	faces := [
		[core.vec3(1, 0, 0), core.vec3(0, 0, -1), core.vec3(0, -1, 0)],
		[core.vec3(-1, 0, 0), core.vec3(0, 0, 1), core.vec3(0, -1, 0)],
		[core.vec3(0, 1, 0), core.vec3(1, 0, 0), core.vec3(0, 0, 1)],
		[core.vec3(0, -1, 0), core.vec3(1, 0, 0), core.vec3(0, 0, -1)],
		[core.vec3(0, 0, 1), core.vec3(1, 0, 0), core.vec3(0, -1, 0)],
		[core.vec3(0, 0, -1), core.vec3(-1, 0, 0), core.vec3(0, -1, 0)],
	]
	for f in faces {
		n, u, v := f[0], f[1], f[2]
		c := n.mul(h)
		a := m.vert(c - u.mul(h) - v.mul(h), n, 0, 0)
		b := m.vert(c - u.mul(h) + v.mul(h), n, 0, 1)
		cc := m.vert(c + u.mul(h) + v.mul(h), n, 1, 1)
		d := m.vert(c + u.mul(h) - v.mul(h), n, 1, 0)
		m.quad(a, b, cc, d)
	}
	return m
}

// plane: a w x d rectangle on y = 0 facing +y, its uvs repeating once.
pub fn plane(w f32, d f32) MeshData {
	mut m := MeshData{
		name: 'plane'
	}
	n := core.vec3(0, 1, 0)
	a := m.vert(core.vec3(-w / 2, 0, -d / 2), n, 0, 0)
	b := m.vert(core.vec3(-w / 2, 0, d / 2), n, 0, 1)
	c := m.vert(core.vec3(w / 2, 0, d / 2), n, 1, 1)
	e := m.vert(core.vec3(w / 2, 0, -d / 2), n, 1, 0)
	m.quad(a, b, c, e)
	return m
}

// grid: a plane of `cells` x `cells` quads whose uvs repeat once per cell (tiled ground textures).
pub fn grid(size f32, cells int) MeshData {
	mut m := MeshData{
		name: 'grid'
	}
	n := core.vec3(0, 1, 0)
	step := size / f32(cells)
	for z in 0 .. cells + 1 {
		for x in 0 .. cells + 1 {
			m.vert(core.vec3(-size / 2 + f32(x) * step, 0, -size / 2 + f32(z) * step), n, f32(x),
				f32(z))
		}
	}
	w := u32(cells + 1)
	for z in 0 .. u32(cells) {
		for x in 0 .. u32(cells) {
			i := z * w + x
			m.quad(i, i + w, i + w + 1, i + 1)
		}
	}
	return m
}

// sphere: a uv sphere.
pub fn sphere(radius f32, segments int, rings int) MeshData {
	mut m := MeshData{
		name: 'sphere'
	}
	for r in 0 .. rings + 1 {
		v := f32(r) / f32(rings)
		phi := v * math.pi
		for s in 0 .. segments + 1 {
			u := f32(s) / f32(segments)
			th := u * 2 * math.pi
			n := core.vec3(f32(math.sin(phi) * math.sin(th)), f32(math.cos(phi)),
				f32(math.sin(phi) * math.cos(th)))
			m.vert(n.mul(radius), n, u, v)
		}
	}
	w := u32(segments + 1)
	for r in 0 .. u32(rings) {
		for s in 0 .. u32(segments) {
			i := r * w + s
			m.quad(i, i + w, i + w + 1, i + 1)
		}
	}
	return m
}

// cylinder: radius `r`, height `h` along y, with caps.
pub fn cylinder(r f32, h f32, segments int) MeshData {
	mut m := MeshData{
		name: 'cylinder'
	}
	m.add_tube(r, r, h, segments)
	m.add_cap(r, h / 2, segments, true)
	m.add_cap(r, -h / 2, segments, false)
	return m
}

// cone: base radius `r` at y = -h/2, tip at y = h/2.
pub fn cone(r f32, h f32, segments int) MeshData {
	mut m := MeshData{
		name: 'cone'
	}
	m.add_tube(r, 0.0001, h, segments)
	m.add_cap(r, -h / 2, segments, false)
	return m
}

fn (mut m MeshData) add_tube(r0 f32, r1 f32, h f32, segments int) {
	slope := (r0 - r1) / h
	base := u32(m.positions.len / 3)
	for s in 0 .. segments + 1 {
		u := f32(s) / f32(segments)
		th := u * 2 * math.pi
		dx, dz := f32(math.sin(th)), f32(math.cos(th))
		n := core.vec3(dx, slope, dz).normalized()
		m.vert(core.vec3(dx * r0, -h / 2, dz * r0), n, u, 1)
		m.vert(core.vec3(dx * r1, h / 2, dz * r1), n, u, 0)
	}
	for s in 0 .. u32(segments) {
		i := base + s * 2
		m.quad(i, i + 2, i + 3, i + 1)
	}
}

fn (mut m MeshData) add_cap(r f32, y f32, segments int, up bool) {
	n := core.vec3(0, if up { f32(1) } else { f32(-1) }, 0)
	c := m.vert(core.vec3(0, y, 0), n, 0.5, 0.5)
	base := u32(m.positions.len / 3)
	for s in 0 .. segments + 1 {
		th := f32(s) / f32(segments) * 2 * math.pi
		dx, dz := f32(math.sin(th)), f32(math.cos(th))
		m.vert(core.vec3(dx * r, y, dz * r), n, 0.5 + dx / 2, 0.5 - dz / 2)
	}
	for s in 0 .. u32(segments) {
		if up {
			m.tri(c, base + s, base + s + 1)
		} else {
			m.tri(c, base + s + 1, base + s)
		}
	}
}

// disc: a flat circle on y = 0 facing +y.
pub fn disc(r f32, segments int) MeshData {
	mut m := MeshData{
		name: 'disc'
	}
	m.add_cap(r, 0, segments, true)
	return m
}

// capsule: radius `r`, total height `h` (>= 2r) along y.
pub fn capsule(r f32, h f32, segments int, cap_rings int) MeshData {
	mut m := MeshData{
		name: 'capsule'
	}
	half := f32_max(h / 2 - r, 0)
	rings := cap_rings * 2 + 1
	for ri in 0 .. rings + 1 {
		// rings 0..cap_rings: top hemisphere, then the bottom one
		top := ri <= cap_rings
		k := if top { ri } else { ri - 1 }
		phi := f32(k) / f32(cap_rings * 2) * math.pi
		y_off := if top { half } else { -half }
		for s in 0 .. segments + 1 {
			u := f32(s) / f32(segments)
			th := u * 2 * math.pi
			n := core.vec3(f32(math.sin(phi) * math.sin(th)), f32(math.cos(phi)),
				f32(math.sin(phi) * math.cos(th)))
			p := n.mul(r) + core.vec3(0, y_off, 0)
			m.vert(p, n, u, (h / 2 - p.y) / h)
		}
	}
	w := u32(segments + 1)
	for ri in 0 .. u32(rings) {
		for s in 0 .. u32(segments) {
			i := ri * w + s
			m.quad(i, i + w, i + w + 1, i + 1)
		}
	}
	return m
}

// torus: a ring of radius `r` around y, its tube `tube` thick.
pub fn torus(r f32, tube f32, segments int, sides int) MeshData {
	mut m := MeshData{
		name: 'torus'
	}
	for s in 0 .. segments + 1 {
		u := f32(s) / f32(segments)
		th := u * 2 * math.pi
		cx, cz := f32(math.sin(th)), f32(math.cos(th))
		for k in 0 .. sides + 1 {
			v := f32(k) / f32(sides)
			ph := v * 2 * math.pi
			n := core.vec3(cx * f32(math.cos(ph)), f32(math.sin(ph)), cz * f32(math.cos(ph)))
			p := core.vec3(cx * r, 0, cz * r) + n.mul(tube)
			m.vert(p, n, u, v)
		}
	}
	w := u32(sides + 1)
	for s in 0 .. u32(segments) {
		for k in 0 .. u32(sides) {
			i := s * w + k
			m.quad(i, i + w, i + w + 1, i + 1)
		}
	}
	return m
}
