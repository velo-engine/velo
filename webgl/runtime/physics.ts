// velo.physics for the WebGL runtime. Desktop builds use Box2D v3; the browser build has a small rigid body
// solver with the same components, fields and methods (PhysicsWorld, RigidBody, Box/Circle/CapsuleCollider,
// contacts polled as touching/began/ended, raycast). It handles what 2D games mostly need — dynamic, kinematic
// and static bodies with rotation, friction, restitution, damping, sensors — with sequential impulses; it is
// not a full Box2D (no joints, no continuous collision for bullets, simpler stacking).
//
// Internally everything is in meters (world units / pixels_per_meter), like Box2D, so masses match desktop.

import * as V from './v.ts'
import * as core from './core.ts'
import type * as serialize from './serialize.ts'

type FieldSpec = core.FieldSpec
const { Vec2, vec2 } = core
type Vec2 = core.Vec2

// ---------- API types ----------

export class Contact {
	static __vname = 'physics.Contact'
	node: core.Node
	normal: Vec2
	point: Vec2
	sensor: boolean
	other: ColliderState | null
	constructor(node: core.Node, normal = new Vec2(), point = new Vec2(), sensor = false, other: ColliderState | null = null) {
		this.node = node
		this.normal = normal
		this.point = point
		this.sensor = sensor
		this.other = other
	}
	clone(): Contact {
		return new Contact(this.node, this.normal.clone(), this.point.clone(), this.sensor, this.other)
	}
}

export class RayHit {
	static __vname = 'physics.RayHit'
	node: core.Node
	point: Vec2
	normal: Vec2
	fraction: number
	constructor(node: core.Node, point: Vec2, normal: Vec2, fraction: number) {
		this.node = node
		this.point = point
		this.normal = normal
		this.fraction = fraction
	}
	clone(): RayHit {
		return new RayHit(this.node, this.point.clone(), this.normal.clone(), this.fraction)
	}
}

// ---------- Internal geometry (meters) ----------

type ShapeKind = 'circle' | 'polygon' | 'capsule'

// Shape — a collider's geometry in body space: circle (c0, radius), polygon (verts, normals), capsule (c0-c1, radius).
interface Shape {
	kind: ShapeKind
	c0x: number
	c0y: number
	c1x: number
	c1y: number
	radius: number
	verts: number[] // polygon (and the capsule's hull), counter-clockwise in screen coordinates (y down)
	normals: number[]
	area: number
	inertia: number // about the body origin, per unit density
}

interface WShape {
	// a shape transformed to world space for one step
	kind: ShapeKind
	c0x: number
	c0y: number
	c1x: number
	c1y: number
	radius: number
	verts: number[]
	normals: number[]
	minx: number
	miny: number
	maxx: number
	maxy: number
}

class Body {
	type: 'dynamic' | 'kinematic' | 'static' = 'dynamic'
	x = 0
	y = 0
	angle = 0 // radians
	vx = 0
	vy = 0
	w = 0
	fx = 0
	fy = 0
	torque = 0
	mass = 0
	inv_mass = 0
	inertia = 0
	inv_i = 0
	gravity_scale = 1
	linear_damping = 0
	angular_damping = 0
	fixed_rotation = false
	shapes: ColliderState[] = []
	awake = true

	update_mass() {
		let m = 0
		let i = 0
		for (const st of this.shapes) {
			if (st.shape === null || st.sensor) continue
			m += st.shape.area * st.density
			i += st.shape.inertia * st.density
		}
		this.mass = m
		if (this.type !== 'dynamic') {
			this.inv_mass = 0
			this.inv_i = 0
			return
		}
		if (m <= 0) {
			this.mass = 1
			m = 1
		}
		this.inv_mass = 1 / m
		this.inertia = i
		this.inv_i = this.fixed_rotation || i <= 0 ? 0 : 1 / i
	}
}

function make_circle(cx: number, cy: number, r: number): Shape {
	const area = Math.PI * r * r
	return { kind: 'circle', c0x: cx, c0y: cy, c1x: cx, c1y: cy, radius: r, verts: [], normals: [], area, inertia: area * (0.5 * r * r + cx * cx + cy * cy) }
}

function make_box(cx: number, cy: number, hw: number, hh: number): Shape {
	const verts = [cx - hw, cy - hh, cx + hw, cy - hh, cx + hw, cy + hh, cx - hw, cy + hh]
	const area = 4 * hw * hh
	const s: Shape = { kind: 'polygon', c0x: cx, c0y: cy, c1x: cx, c1y: cy, radius: 0, verts, normals: [], area, inertia: area * ((4 * (hw * hw + hh * hh)) / 12 + cx * cx + cy * cy) }
	s.normals = poly_normals(verts)
	return s
}

function make_capsule(ax: number, ay: number, bx: number, by: number, r: number): Shape {
	const len = Math.hypot(bx - ax, by - ay)
	const area = Math.PI * r * r + 2 * r * len
	const mx = (ax + bx) / 2
	const my = (ay + by) / 2
	const s: Shape = {
		kind: 'capsule',
		c0x: ax,
		c0y: ay,
		c1x: bx,
		c1y: by,
		radius: r,
		verts: [],
		normals: [],
		area,
		inertia: area * ((len * len) / 12 + (r * r) / 2 + mx * mx + my * my),
	}
	// convex hull approximation, used against polygons
	const ang = Math.atan2(by - ay, bx - ax)
	const seg = 6
	for (let i = 0; i <= seg; i++) {
		const a = ang + Math.PI / 2 + (i / seg) * Math.PI
		s.verts.push(ax + Math.cos(a) * r, ay + Math.sin(a) * r)
	}
	for (let i = 0; i <= seg; i++) {
		const a = ang - Math.PI / 2 + (i / seg) * Math.PI
		s.verts.push(bx + Math.cos(a) * r, by + Math.sin(a) * r)
	}
	s.normals = poly_normals(s.verts)
	return s
}

// poly_normals: outward unit normals of a polygon's edges (vertex order made consistent first).
function poly_normals(verts: number[]): number[] {
	const n = verts.length / 2
	let area2 = 0
	for (let i = 0; i < n; i++) {
		const j = (i + 1) % n
		area2 += verts[i * 2] * verts[j * 2 + 1] - verts[j * 2] * verts[i * 2 + 1]
	}
	if (area2 < 0) {
		// reverse to a positive winding
		for (let i = 0, j = n - 1; i < j; i++, j--) {
			const tx = verts[i * 2]
			const ty = verts[i * 2 + 1]
			verts[i * 2] = verts[j * 2]
			verts[i * 2 + 1] = verts[j * 2 + 1]
			verts[j * 2] = tx
			verts[j * 2 + 1] = ty
		}
	}
	const out: number[] = []
	for (let i = 0; i < n; i++) {
		const j = (i + 1) % n
		const ex = verts[j * 2] - verts[i * 2]
		const ey = verts[j * 2 + 1] - verts[i * 2 + 1]
		const l = Math.hypot(ex, ey) || 1
		out.push(ey / l, -ex / l)
	}
	return out
}

function to_world(s: Shape, b: Body): WShape {
	const c = Math.cos(b.angle)
	const sn = Math.sin(b.angle)
	const tx = (x: number, y: number) => b.x + c * x - sn * y
	const ty = (x: number, y: number) => b.y + sn * x + c * y
	const w: WShape = {
		kind: s.kind,
		c0x: tx(s.c0x, s.c0y),
		c0y: ty(s.c0x, s.c0y),
		c1x: tx(s.c1x, s.c1y),
		c1y: ty(s.c1x, s.c1y),
		radius: s.radius,
		verts: [],
		normals: [],
		minx: 0,
		miny: 0,
		maxx: 0,
		maxy: 0,
	}
	for (let i = 0; i < s.verts.length; i += 2) w.verts.push(tx(s.verts[i], s.verts[i + 1]), ty(s.verts[i], s.verts[i + 1]))
	for (let i = 0; i < s.normals.length; i += 2) w.normals.push(c * s.normals[i] - sn * s.normals[i + 1], sn * s.normals[i] + c * s.normals[i + 1])
	if (s.kind === 'polygon') {
		bounds_of_points(w, w.verts)
	} else {
		w.minx = Math.min(w.c0x, w.c1x) - s.radius
		w.miny = Math.min(w.c0y, w.c1y) - s.radius
		w.maxx = Math.max(w.c0x, w.c1x) + s.radius
		w.maxy = Math.max(w.c0y, w.c1y) + s.radius
	}
	return w
}

function bounds_of_points(w: WShape, v: number[]) {
	w.minx = Infinity
	w.miny = Infinity
	w.maxx = -Infinity
	w.maxy = -Infinity
	for (let i = 0; i < v.length; i += 2) {
		w.minx = Math.min(w.minx, v[i])
		w.maxx = Math.max(w.maxx, v[i])
		w.miny = Math.min(w.miny, v[i + 1])
		w.maxy = Math.max(w.maxy, v[i + 1])
	}
}

// ---------- Narrow phase ----------

interface Manifold {
	nx: number // normal from A to B
	ny: number
	points: { x: number; y: number; depth: number }[]
}

function closest_on_segment(px: number, py: number, ax: number, ay: number, bx: number, by: number): [number, number] {
	const dx = bx - ax
	const dy = by - ay
	const l2 = dx * dx + dy * dy
	let t = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0
	t = Math.max(0, Math.min(1, t))
	return [ax + dx * t, ay + dy * t]
}

// segments_closest: the closest points of two segments.
function segments_closest(a0x: number, a0y: number, a1x: number, a1y: number, b0x: number, b0y: number, b1x: number, b1y: number): [number, number, number, number] {
	let best = Infinity
	let r: [number, number, number, number] = [a0x, a0y, b0x, b0y]
	const tryp = (px: number, py: number, qx: number, qy: number) => {
		const d = (px - qx) ** 2 + (py - qy) ** 2
		if (d < best) {
			best = d
			r = [px, py, qx, qy]
		}
	}
	let [x, y] = closest_on_segment(a0x, a0y, b0x, b0y, b1x, b1y)
	tryp(a0x, a0y, x, y)
	;[x, y] = closest_on_segment(a1x, a1y, b0x, b0y, b1x, b1y)
	tryp(a1x, a1y, x, y)
	;[x, y] = closest_on_segment(b0x, b0y, a0x, a0y, a1x, a1y)
	tryp(x, y, b0x, b0y)
	;[x, y] = closest_on_segment(b1x, b1y, a0x, a0y, a1x, a1y)
	tryp(x, y, b1x, b1y)
	return r
}

// round_vs_round: circles and capsules (a segment with a radius; a circle is a zero-length segment).
function round_vs_round(a: WShape, b: WShape): Manifold | null {
	const [px, py, qx, qy] = segments_closest(a.c0x, a.c0y, a.c1x, a.c1y, b.c0x, b.c0y, b.c1x, b.c1y)
	let dx = qx - px
	let dy = qy - py
	const d = Math.hypot(dx, dy)
	const rr = a.radius + b.radius
	if (d >= rr) return null
	if (d > 1e-9) {
		dx /= d
		dy /= d
	} else {
		dx = 0
		dy = 1
	}
	return { nx: dx, ny: dy, points: [{ x: px + dx * a.radius, y: py + dy * a.radius, depth: rr - d }] }
}

// poly_vs_circle: polygon A against circle B.
function poly_vs_circle(a: WShape, b: WShape): Manifold | null {
	const n = a.verts.length / 2
	const cx = b.c0x
	const cy = b.c0y
	let sep = -Infinity
	let edge = 0
	for (let i = 0; i < n; i++) {
		const s = a.normals[i * 2] * (cx - a.verts[i * 2]) + a.normals[i * 2 + 1] * (cy - a.verts[i * 2 + 1])
		if (s > b.radius) return null
		if (s > sep) {
			sep = s
			edge = i
		}
	}
	const v1x = a.verts[edge * 2]
	const v1y = a.verts[edge * 2 + 1]
	const j = (edge + 1) % n
	const v2x = a.verts[j * 2]
	const v2y = a.verts[j * 2 + 1]
	if (sep < 1e-9) {
		// center inside the polygon
		const nx = a.normals[edge * 2]
		const ny = a.normals[edge * 2 + 1]
		return { nx, ny, points: [{ x: cx - nx * b.radius, y: cy - ny * b.radius, depth: b.radius - sep }] }
	}
	const [qx, qy] = closest_on_segment(cx, cy, v1x, v1y, v2x, v2y)
	let dx = cx - qx
	let dy = cy - qy
	const d = Math.hypot(dx, dy)
	if (d > b.radius) return null
	if (d > 1e-9) {
		dx /= d
		dy /= d
	} else {
		dx = a.normals[edge * 2]
		dy = a.normals[edge * 2 + 1]
	}
	return { nx: dx, ny: dy, points: [{ x: qx, y: qy, depth: b.radius - d }] }
}

// max_separation: the edge of A with the largest separation from B (SAT).
function max_separation(a: WShape, b: WShape): [number, number] {
	const na = a.verts.length / 2
	const nb = b.verts.length / 2
	let best = -Infinity
	let best_i = 0
	for (let i = 0; i < na; i++) {
		const nx = a.normals[i * 2]
		const ny = a.normals[i * 2 + 1]
		const vx = a.verts[i * 2]
		const vy = a.verts[i * 2 + 1]
		let si = Infinity
		for (let k = 0; k < nb; k++) {
			const s = nx * (b.verts[k * 2] - vx) + ny * (b.verts[k * 2 + 1] - vy)
			if (s < si) si = s
		}
		if (si > best) {
			best = si
			best_i = i
		}
	}
	return [best, best_i]
}

// poly_vs_poly: SAT with reference/incident edge clipping (up to two contact points).
function poly_vs_poly(a: WShape, b: WShape): Manifold | null {
	const [sep_a, edge_a] = max_separation(a, b)
	if (sep_a > 0) return null
	const [sep_b, edge_b] = max_separation(b, a)
	if (sep_b > 0) return null
	let ref: WShape
	let inc: WShape
	let edge: number
	let flip = false
	if (sep_b > sep_a + 0.0005) {
		ref = b
		inc = a
		edge = edge_b
		flip = true
	} else {
		ref = a
		inc = b
		edge = edge_a
	}
	const nrx = ref.normals[edge * 2]
	const nry = ref.normals[edge * 2 + 1]
	// incident edge: the one most anti-parallel to the reference normal
	const ni = inc.verts.length / 2
	let inc_edge = 0
	let min_dot = Infinity
	for (let i = 0; i < ni; i++) {
		const d = nrx * inc.normals[i * 2] + nry * inc.normals[i * 2 + 1]
		if (d < min_dot) {
			min_dot = d
			inc_edge = i
		}
	}
	const nr = ref.verts.length / 2
	const r1x = ref.verts[edge * 2]
	const r1y = ref.verts[edge * 2 + 1]
	const r2x = ref.verts[((edge + 1) % nr) * 2]
	const r2y = ref.verts[((edge + 1) % nr) * 2 + 1]
	let pts = [
		[inc.verts[inc_edge * 2], inc.verts[inc_edge * 2 + 1]],
		[inc.verts[((inc_edge + 1) % ni) * 2], inc.verts[((inc_edge + 1) % ni) * 2 + 1]],
	]
	// clip against the side planes of the reference edge
	let tx = r2x - r1x
	let ty = r2y - r1y
	const tl = Math.hypot(tx, ty) || 1
	tx /= tl
	ty /= tl
	pts = clip(pts, -tx, -ty, -(tx * r1x + ty * r1y))
	if (pts.length < 2) return null
	pts = clip(pts, tx, ty, tx * r2x + ty * r2y)
	if (pts.length < 2) return null
	const out: Manifold = { nx: flip ? -nrx : nrx, ny: flip ? -nry : nry, points: [] }
	for (const p of pts) {
		const s = nrx * (p[0] - r1x) + nry * (p[1] - r1y)
		if (s <= 0) out.points.push({ x: p[0], y: p[1], depth: -s })
	}
	return out.points.length > 0 ? out : null
}

// clip keeps the part of segment `pts` where n·p <= c.
function clip(pts: number[][], nx: number, ny: number, c: number): number[][] {
	const out: number[][] = []
	const d0 = nx * pts[0][0] + ny * pts[0][1] - c
	const d1 = nx * pts[1][0] + ny * pts[1][1] - c
	if (d0 <= 0) out.push(pts[0])
	if (d1 <= 0) out.push(pts[1])
	if (d0 * d1 < 0) {
		const t = d0 / (d0 - d1)
		out.push([pts[0][0] + (pts[1][0] - pts[0][0]) * t, pts[0][1] + (pts[1][1] - pts[0][1]) * t])
	}
	return out
}

function collide(a: WShape, b: WShape): Manifold | null {
	const ra = a.kind !== 'polygon'
	const rb = b.kind !== 'polygon'
	if (ra && rb) {
		if (a.kind === 'circle' || b.kind === 'circle' || true) return round_vs_round(a, b)
	}
	if (a.kind === 'polygon' && b.kind === 'circle') return poly_vs_circle(a, b)
	if (a.kind === 'circle' && b.kind === 'polygon') return flip_manifold(poly_vs_circle(b, a))
	// capsule vs polygon: the capsule's hull
	return poly_vs_poly(a, b)
}

function flip_manifold(m: Manifold | null): Manifold | null {
	if (m === null) return null
	// points were on the polygon (B): move them onto the circle's surface side consistently (any point works for the solver)
	return { nx: -m.nx, ny: -m.ny, points: m.points }
}

// ---------- Components ----------

// ColliderState — what every collider has: its contacts this frame, and its link to the physics world.
export class ColliderState extends core.Component {
	static __vname = 'physics.ColliderState'
	touching: Contact[] = []
	began: Contact[] = []
	ended: Contact[] = []
	owner: core.Node | null = null
	world: PhysicsWorld | null = null
	has_shape = false
	body_owner: RigidBody | null = null
	own_body: Body | null = null
	owns_body = false
	synced_pos = new Vec2()
	synced_rot = 0
	// internal
	body: Body | null = null
	shape: Shape | null = null
	wshape: WShape | null = null
	density = 1
	friction = 0.6
	restitution = 0
	sensor = false
	offset = new Vec2()

	collider_state(): ColliderState {
		return this
	}
	is_touching(n: core.Node): boolean {
		return this.touching.some((c) => c.node === n)
	}
	// make_shape builds the geometry in meters (each collider type overrides it).
	make_shape(_ppm: number, _scale: Vec2): Shape | null {
		return null
	}
	on_load() {
		attach_collider(this)
	}
	on_destroy() {
		this.detach()
	}
	detach() {
		const w = this.world
		if (w !== null) {
			if (this.body !== null) {
				const b = this.body
				b.shapes = b.shapes.filter((s) => s !== this)
				b.update_mass()
				if (this.owns_body) w.raw_bodies = w.raw_bodies.filter((x) => x !== b)
			}
			w.remove_collider(this)
		}
		this.reset()
	}
	reset() {
		this.has_shape = false
		this.owns_body = false
		this.body_owner = null
		this.world = null
		this.body = null
		this.own_body = null
		this.touching.length = 0
	}
	push_transform() {
		if (!this.owns_body || this.own_body === null || this.owner === null || this.world === null) return
		const [pos, rot] = world_transform(this.owner)
		if (moved(pos, this.synced_pos, rot, this.synced_rot)) {
			const ppm = this.world.ppm()
			this.own_body.x = pos.x / ppm
			this.own_body.y = pos.y / ppm
			this.own_body.angle = (rot * Math.PI) / 180
			this.synced_pos = pos
			this.synced_rot = rot
		}
	}
}

const collider_fields: FieldSpec[] = [
	{ name: 'offset', type: 'Vec2' },
	{ name: 'density', type: 'f32' },
	{ name: 'friction', type: 'f32' },
	{ name: 'restitution', type: 'f32' },
	{ name: 'sensor', type: 'bool' },
]

export class BoxCollider extends ColliderState {
	static __vname = 'physics.BoxCollider'
	static __fields: FieldSpec[] = [{ name: 'size', type: 'Vec2' }, ...collider_fields]
	size = new Vec2(32, 32)
	make_shape(ppm: number, scale: Vec2): Shape {
		return make_box((this.offset.x * scale.x) / ppm, (this.offset.y * scale.y) / ppm, (this.size.x * scale.x) / 2 / ppm, (this.size.y * scale.y) / 2 / ppm)
	}
	debug_outline(): Vec2[] {
		const h = this.size.mul(0.5)
		const o = this.offset
		return [vec2(o.x - h.x, o.y - h.y), vec2(o.x + h.x, o.y - h.y), vec2(o.x + h.x, o.y + h.y), vec2(o.x - h.x, o.y + h.y)]
	}
	debug_color(): core.Color {
		return outline_color(this.sensor)
	}
}

export class CircleCollider extends ColliderState {
	static __vname = 'physics.CircleCollider'
	static __fields: FieldSpec[] = [{ name: 'radius', type: 'f32' }, ...collider_fields]
	radius = 16
	make_shape(ppm: number, scale: Vec2): Shape {
		const s = Math.max(scale.x, scale.y)
		return make_circle((this.offset.x * scale.x) / ppm, (this.offset.y * scale.y) / ppm, (this.radius * s) / ppm)
	}
	debug_outline(): Vec2[] {
		return arc(this.offset, this.radius, 0, 360, 32)
	}
	debug_color(): core.Color {
		return outline_color(this.sensor)
	}
}

export class CapsuleCollider extends ColliderState {
	static __vname = 'physics.CapsuleCollider'
	static __fields: FieldSpec[] = [{ name: 'size', type: 'Vec2' }, ...collider_fields]
	size = new Vec2(32, 64)
	make_shape(ppm: number, scale: Vec2): Shape {
		const [a, b, r] = capsule_points(this.offset.op_mul(scale), this.size.op_mul(scale))
		return make_capsule(a.x / ppm, a.y / ppm, b.x / ppm, b.y / ppm, r / ppm)
	}
	debug_outline(): Vec2[] {
		const [a, b, r] = capsule_points(this.offset, this.size)
		if (this.size.y >= this.size.x) return [...arc(a, r, 180, 360, 16), ...arc(b, r, 0, 180, 16)]
		return [...arc(b, r, -90, 90, 16), ...arc(a, r, 90, 270, 16)]
	}
	debug_color(): core.Color {
		return outline_color(this.sensor)
	}
}

export const Collider = V.iface('physics.Collider', ['collider_state', 'make_shape'])

function capsule_points(center: Vec2, size: Vec2): [Vec2, Vec2, number] {
	if (size.y >= size.x) {
		const r = size.x / 2
		const d = size.y / 2 - r
		return [center.op_add(vec2(0, -d)), center.op_add(vec2(0, d)), r]
	}
	const r = size.y / 2
	const d = size.x / 2 - r
	return [center.op_add(vec2(-d, 0)), center.op_add(vec2(d, 0)), r]
}

function arc(center: Vec2, r: number, from_deg: number, to_deg: number, segments: number): Vec2[] {
	const pts: Vec2[] = []
	for (let i = 0; i <= segments; i++) {
		const t = ((from_deg + ((to_deg - from_deg) * i) / segments) * Math.PI) / 180
		pts.push(center.op_add(vec2(Math.cos(t), Math.sin(t)).mul(r)))
	}
	return pts
}

function outline_color(sensor: boolean): core.Color {
	return sensor ? core.rgba(255, 200, 60, 230) : core.rgba(90, 240, 120, 230)
}

function attach_collider(c: ColliderState) {
	if (c.has_shape || !c.node || !c.node.scene) return
	const node = c.node
	let body: Body
	let w: PhysicsWorld
	const rb = node.get_component<RigidBody>(RigidBody)
	if (rb !== null) {
		if (!rb.created || rb.world === null || rb.body === null) return
		w = rb.world
		body = rb.body
		c.body_owner = rb
	} else {
		const found = world_of(node)
		if (found === null) {
			console.error(`[Collider] ${node.path()}: no PhysicsWorld on this node or its ancestors`)
			return
		}
		w = found
		const [pos, rot] = world_transform(node)
		body = new Body()
		body.type = 'static'
		body.x = pos.x / w.ppm()
		body.y = pos.y / w.ppm()
		body.angle = (rot * Math.PI) / 180
		c.own_body = body
		c.owns_body = true
		c.synced_pos = pos
		c.synced_rot = rot
		w.raw_bodies.push(body)
	}
	const sc = node.world_matrix().scale()
	c.owner = node
	c.world = w
	c.body = body
	c.shape = c.make_shape(w.ppm(), vec2(Math.abs(sc.x), Math.abs(sc.y)))
	c.has_shape = c.shape !== null
	body.shapes.push(c)
	body.update_mass()
	w.colliders.push(c)
}

export class RigidBody extends core.Component {
	static __vname = 'physics.RigidBody'
	static __fields: FieldSpec[] = [
		{ name: 'body_type', type: 'string', choices: ['dynamic', 'kinematic', 'static'] },
		{ name: 'gravity_scale', type: 'f32' },
		{ name: 'linear_damping', type: 'f32' },
		{ name: 'angular_damping', type: 'f32' },
		{ name: 'fixed_rotation', type: 'bool' },
		{ name: 'bullet', type: 'bool' },
	]
	body_type = 'dynamic'
	gravity_scale = 1
	linear_damping = 0
	angular_damping = 0
	fixed_rotation = false
	bullet = false
	world: PhysicsWorld | null = null
	body: Body | null = null
	created = false
	synced_pos = new Vec2()
	synced_rot = 0

	on_load() {
		if (this.created) return
		const w = world_of(this.node)
		if (w === null) {
			console.error(`[RigidBody] ${this.node.path()}: no PhysicsWorld on this node or its ancestors`)
			return
		}
		const [pos, rot] = world_transform(this.node)
		const b = new Body()
		b.type = body_kind(this.body_type)
		b.x = pos.x / w.ppm()
		b.y = pos.y / w.ppm()
		b.angle = (rot * Math.PI) / 180
		b.gravity_scale = this.gravity_scale
		b.linear_damping = this.linear_damping
		b.angular_damping = this.angular_damping
		b.fixed_rotation = this.fixed_rotation
		this.world = w
		this.body = b
		this.created = true
		this.synced_pos = pos
		this.synced_rot = rot
		w.bodies.push(this)
		w.raw_bodies.push(b)
		for (const c of this.node.components) if (c instanceof ColliderState) attach_collider(c)
		b.update_mass()
	}
	on_destroy() {
		if (!this.created) return
		for (const c of this.node.components) {
			if (c instanceof ColliderState && c.body_owner === this) c.detach()
		}
		if (this.world !== null) this.world.remove_body(this)
		this.created = false
		this.body = null
	}
	is_valid(): boolean {
		return this.created && this.body !== null
	}
	velocity(): Vec2 {
		if (!this.is_valid()) return new Vec2()
		const ppm = this.world!.ppm()
		return vec2(this.body!.vx * ppm, this.body!.vy * ppm)
	}
	set_velocity(v: Vec2) {
		if (!this.is_valid()) return
		const ppm = this.world!.ppm()
		this.body!.vx = v.x / ppm
		this.body!.vy = v.y / ppm
	}
	angular_velocity(): number {
		return this.is_valid() ? (this.body!.w * 180) / Math.PI : 0
	}
	set_angular_velocity(deg_per_s: number) {
		if (this.is_valid()) this.body!.w = (deg_per_s * Math.PI) / 180
	}
	apply_force(f: Vec2) {
		if (!this.is_valid()) return
		const ppm = this.world!.ppm()
		this.body!.fx += f.x / ppm
		this.body!.fy += f.y / ppm
	}
	apply_impulse(i: Vec2) {
		if (!this.is_valid()) return
		const b = this.body!
		const ppm = this.world!.ppm()
		b.vx += (i.x / ppm) * b.inv_mass
		b.vy += (i.y / ppm) * b.inv_mass
	}
	apply_torque(t: number) {
		if (!this.is_valid()) return
		const ppm = this.world!.ppm()
		this.body!.torque += t / (ppm * ppm)
	}
	mass(): number {
		return this.is_valid() ? this.body!.mass : 0
	}
	set_body_type(t: string) {
		this.body_type = t
		if (this.is_valid()) {
			this.body!.type = body_kind(t)
			if (this.body!.type === 'static') {
				this.body!.vx = 0
				this.body!.vy = 0
				this.body!.w = 0
			}
			this.body!.update_mass()
		}
	}
	push_transform() {
		if (!this.is_valid()) return
		const [pos, rot] = world_transform(this.node)
		if (moved(pos, this.synced_pos, rot, this.synced_rot)) {
			const ppm = this.world!.ppm()
			this.body!.x = pos.x / ppm
			this.body!.y = pos.y / ppm
			this.body!.angle = (rot * Math.PI) / 180
			this.synced_pos = pos
			this.synced_rot = rot
		}
	}
	pull_transform() {
		if (!this.is_valid() || this.body_type === 'static') return
		const ppm = this.world!.ppm()
		set_world_transform(this.node, vec2(this.body!.x * ppm, this.body!.y * ppm), (this.body!.angle * 180) / Math.PI)
		const [p, r] = world_transform(this.node)
		this.synced_pos = p
		this.synced_rot = r
	}
}

function body_kind(t: string): 'dynamic' | 'kinematic' | 'static' {
	return t === 'static' ? 'static' : t === 'kinematic' ? 'kinematic' : 'dynamic'
}

// ---------- World ----------

interface PointConstraint {
	rax: number
	ray: number
	rbx: number
	rby: number
	normal_mass: number
	tangent_mass: number
	bias: number
	pn: number
	pt: number
}

interface Pair {
	a: ColliderState
	b: ColliderState
	m: Manifold
	friction: number
	restitution: number
	points: PointConstraint[]
}

export class PhysicsWorld extends core.Component {
	static __vname = 'physics.PhysicsWorld'
	static __fields: FieldSpec[] = [
		{ name: 'gravity', type: 'Vec2' },
		{ name: 'pixels_per_meter', type: 'f32' },
		{ name: 'fixed_step', type: 'f32' },
		{ name: 'sub_steps', type: 'int' },
		{ name: 'max_steps', type: 'int' },
	]
	gravity = new Vec2(0, 980)
	pixels_per_meter = 50
	fixed_step = 1 / 60
	sub_steps = 4
	max_steps = 5
	created = false
	accumulator = 0
	bodies: RigidBody[] = []
	colliders: ColliderState[] = []
	raw_bodies: Body[] = []
	// pairs touching after the last step, by key
	contacts = new Map<string, { a: ColliderState; b: ColliderState; normal: Vec2; point: Vec2; sensor: boolean }>()
	ids = new WeakMap<ColliderState, number>()
	next_id = 1

	on_load() {
		this.ensure()
	}
	on_destroy() {
		if (!this.created) return
		for (const b of this.bodies) b.created = false
		for (const c of this.colliders) c.reset()
		this.bodies.length = 0
		this.colliders.length = 0
		this.raw_bodies.length = 0
		this.contacts.clear()
		this.created = false
	}
	ensure() {
		this.created = true
	}
	set_gravity(g: Vec2) {
		this.gravity = g.clone()
	}
	ppm(): number {
		return this.pixels_per_meter > 0 ? this.pixels_per_meter : 50
	}
	update(dt: number) {
		if (!this.created) return
		for (const c of this.colliders) {
			c.began.length = 0
			c.ended.length = 0
		}
		for (const b of this.bodies) b.push_transform()
		for (const c of this.colliders) c.push_transform()
		const step = this.fixed_step > 0 ? this.fixed_step : 1 / 60
		this.accumulator += dt
		let steps = 0
		while (this.accumulator >= step - 1e-5 && steps < this.max_steps) {
			this.step(step)
			this.accumulator -= step
			steps++
		}
		if (steps === this.max_steps) this.accumulator = 0
		if (steps > 0) for (const b of this.bodies) b.pull_transform()
	}

	step(dt: number) {
		const n = this.sub_steps > 0 ? this.sub_steps : 4
		const h = dt / n
		const ppm = this.ppm()
		const gx = this.gravity.x / ppm
		const gy = this.gravity.y / ppm
		let pairs: Pair[] = []
		for (let s = 0; s < n; s++) {
			// integrate velocities
			for (const b of this.raw_bodies) {
				if (b.type !== 'dynamic') continue
				b.vx += h * (b.gravity_scale * gx + b.fx * b.inv_mass)
				b.vy += h * (b.gravity_scale * gy + b.fy * b.inv_mass)
				b.w += h * b.torque * b.inv_i
				b.vx *= 1 / (1 + h * b.linear_damping)
				b.vy *= 1 / (1 + h * b.linear_damping)
				b.w *= 1 / (1 + h * b.angular_damping)
				if (b.fixed_rotation) b.w = 0
			}
			pairs = this.find_pairs(h)
			// solve contacts
			for (let it = 0; it < 8; it++) for (const p of pairs) this.solve(p)
			// integrate positions
			for (const b of this.raw_bodies) {
				if (b.type === 'static') continue
				b.x += h * b.vx
				b.y += h * b.vy
				b.angle += h * b.w
			}
		}
		for (const b of this.raw_bodies) {
			b.fx = 0
			b.fy = 0
			b.torque = 0
		}
		this.update_events(pairs)
	}

	private id_of(c: ColliderState): number {
		let id = this.ids.get(c)
		if (id === undefined) {
			id = this.next_id++
			this.ids.set(c, id)
		}
		return id
	}

	private find_pairs(h: number): Pair[] {
		const cols = this.colliders.filter((c) => c.has_shape && c.body !== null && c.shape !== null && c.enabled && c.node && c.node.is_active_in_hierarchy())
		for (const c of cols) c.wshape = to_world(c.shape!, c.body!)
		const pairs: Pair[] = []
		for (let i = 0; i < cols.length; i++) {
			const a = cols[i]
			const wa = a.wshape!
			for (let j = i + 1; j < cols.length; j++) {
				const b = cols[j]
				if (a.body === b.body) continue
				const ba = a.body!
				const bb = b.body!
				if (ba.type !== 'dynamic' && bb.type !== 'dynamic' && !a.sensor && !b.sensor) continue
				const wb = b.wshape!
				if (wa.maxx < wb.minx || wb.maxx < wa.minx || wa.maxy < wb.miny || wb.maxy < wa.miny) continue
				const m = collide(wa, wb)
				if (m === null) continue
				const pair: Pair = {
					a,
					b,
					m,
					friction: Math.sqrt(a.friction * b.friction),
					restitution: Math.max(a.restitution, b.restitution),
					points: [],
				}
				if (!a.sensor && !b.sensor) this.prepare(pair, h)
				pairs.push(pair)
			}
		}
		return pairs
	}

	private prepare(p: Pair, h: number) {
		const A = p.a.body!
		const B = p.b.body!
		const nx = p.m.nx
		const ny = p.m.ny
		const tx = -ny
		const ty = nx
		for (const pt of p.m.points) {
			const rax = pt.x - A.x
			const ray = pt.y - A.y
			const rbx = pt.x - B.x
			const rby = pt.y - B.y
			const rna = rax * ny - ray * nx
			const rnb = rbx * ny - rby * nx
			const kn = A.inv_mass + B.inv_mass + A.inv_i * rna * rna + B.inv_i * rnb * rnb
			const rta = rax * ty - ray * tx
			const rtb = rbx * ty - rby * tx
			const kt = A.inv_mass + B.inv_mass + A.inv_i * rta * rta + B.inv_i * rtb * rtb
			// relative normal velocity, for restitution
			const dvx = B.vx - B.w * rby - (A.vx - A.w * ray)
			const dvy = B.vy + B.w * rbx - (A.vy + A.w * rax)
			const vn = dvx * nx + dvy * ny
			let bias = (0.2 / h) * Math.max(0, pt.depth - 0.005)
			if (vn < -1) bias = Math.max(bias, -p.restitution * vn)
			p.points.push({
				rax,
				ray,
				rbx,
				rby,
				normal_mass: kn > 0 ? 1 / kn : 0,
				tangent_mass: kt > 0 ? 1 / kt : 0,
				bias,
				pn: 0,
				pt: 0,
			})
		}
	}

	private solve(p: Pair) {
		if (p.points.length === 0) return
		const A = p.a.body!
		const B = p.b.body!
		const nx = p.m.nx
		const ny = p.m.ny
		const tx = -ny
		const ty = nx
		for (const c of p.points) {
			let dvx = B.vx - B.w * c.rby - (A.vx - A.w * c.ray)
			let dvy = B.vy + B.w * c.rbx - (A.vy + A.w * c.rax)
			// normal
			const vn = dvx * nx + dvy * ny
			let dpn = c.normal_mass * (-vn + c.bias)
			const pn0 = c.pn
			c.pn = Math.max(pn0 + dpn, 0)
			dpn = c.pn - pn0
			apply(A, B, c, nx * dpn, ny * dpn)
			// friction
			dvx = B.vx - B.w * c.rby - (A.vx - A.w * c.ray)
			dvy = B.vy + B.w * c.rbx - (A.vy + A.w * c.rax)
			const vt = dvx * tx + dvy * ty
			let dpt = c.tangent_mass * -vt
			const max_f = p.friction * c.pn
			const pt0 = c.pt
			c.pt = Math.max(-max_f, Math.min(pt0 + dpt, max_f))
			dpt = c.pt - pt0
			apply(A, B, c, tx * dpt, ty * dpt)
		}
	}

	private update_events(pairs: Pair[]) {
		const ppm = this.ppm()
		const now = new Map<string, { a: ColliderState; b: ColliderState; normal: Vec2; point: Vec2; sensor: boolean }>()
		for (const p of pairs) {
			const ia = this.id_of(p.a)
			const ib = this.id_of(p.b)
			const key = ia < ib ? `${ia}:${ib}` : `${ib}:${ia}`
			const sensor = p.a.sensor || p.b.sensor
			const pt = p.m.points[0]
			now.set(key, {
				a: p.a,
				b: p.b,
				normal: sensor ? new Vec2() : vec2(p.m.nx, p.m.ny),
				point: sensor || !pt ? new Vec2() : vec2(pt.x * ppm, pt.y * ppm),
				sensor,
			})
		}
		for (const [key, c] of now) {
			if (this.contacts.has(key)) continue
			const ca = new Contact(c.b.owner!, c.normal.clone(), c.point.clone(), c.sensor, c.b)
			const cb = new Contact(c.a.owner!, c.normal.mul(-1), c.point.clone(), c.sensor, c.a)
			c.a.began.push(ca)
			c.a.touching.push(ca)
			c.b.began.push(cb)
			c.b.touching.push(cb)
		}
		for (const [key, c] of this.contacts) {
			if (now.has(key)) continue
			end_touch(c.a, c.b)
			end_touch(c.b, c.a)
		}
		this.contacts = now
	}

	raycast(from: Vec2, to: Vec2): RayHit | null {
		if (!this.created) return null
		const ppm = this.ppm()
		const ox = from.x / ppm
		const oy = from.y / ppm
		const dx = (to.x - from.x) / ppm
		const dy = (to.y - from.y) / ppm
		let best: RayHit | null = null
		let best_t = 1
		for (const c of this.colliders) {
			if (!c.has_shape || c.body === null || c.shape === null || c.sensor || c.owner === null) continue
			const w = to_world(c.shape, c.body)
			const hit = ray_shape(ox, oy, dx, dy, w)
			if (hit !== null && hit[0] <= best_t) {
				best_t = hit[0]
				best = new RayHit(c.owner, vec2((ox + dx * hit[0]) * ppm, (oy + dy * hit[0]) * ppm), vec2(hit[1], hit[2]), hit[0])
			}
		}
		return best
	}

	remove_body(b: RigidBody) {
		this.bodies = this.bodies.filter((x) => x !== b)
		if (b.body !== null) this.raw_bodies = this.raw_bodies.filter((x) => x !== b.body)
	}

	remove_collider(c: ColliderState) {
		this.colliders = this.colliders.filter((x) => x !== c)
		for (const [key, e] of this.contacts) {
			if (e.a === c || e.b === c) {
				end_touch(e.a === c ? e.b : e.a, c)
				this.contacts.delete(key)
			}
		}
	}
}

function apply(A: Body, B: Body, c: PointConstraint, px: number, py: number) {
	A.vx -= px * A.inv_mass
	A.vy -= py * A.inv_mass
	A.w -= A.inv_i * (c.rax * py - c.ray * px)
	B.vx += px * B.inv_mass
	B.vy += py * B.inv_mass
	B.w += B.inv_i * (c.rbx * py - c.rby * px)
}

function end_touch(me: ColliderState, other: ColliderState) {
	const i = me.touching.findIndex((t) => t.other === other)
	if (i >= 0) {
		me.ended.push(me.touching[i])
		me.touching.splice(i, 1)
	}
}

// ray_shape: [fraction, normal x, normal y] of the first hit of the ray o + t*d (t in 0..1), or null.
function ray_shape(ox: number, oy: number, dx: number, dy: number, w: WShape): [number, number, number] | null {
	if (w.kind === 'circle') return ray_circle(ox, oy, dx, dy, w.c0x, w.c0y, w.radius)
	if (w.kind === 'capsule') {
		let best: [number, number, number] | null = null
		for (const h of [ray_circle(ox, oy, dx, dy, w.c0x, w.c0y, w.radius), ray_circle(ox, oy, dx, dy, w.c1x, w.c1y, w.radius), ray_poly(ox, oy, dx, dy, w)]) {
			if (h !== null && (best === null || h[0] < best[0])) best = h
		}
		return best
	}
	return ray_poly(ox, oy, dx, dy, w)
}

function ray_circle(ox: number, oy: number, dx: number, dy: number, cx: number, cy: number, r: number): [number, number, number] | null {
	const fx = ox - cx
	const fy = oy - cy
	const a = dx * dx + dy * dy
	const b = 2 * (fx * dx + fy * dy)
	const c = fx * fx + fy * fy - r * r
	const disc = b * b - 4 * a * c
	if (a === 0 || disc < 0) return null
	const t = (-b - Math.sqrt(disc)) / (2 * a)
	if (t < 0 || t > 1) return null
	const hx = ox + dx * t - cx
	const hy = oy + dy * t - cy
	const l = Math.hypot(hx, hy) || 1
	return [t, hx / l, hy / l]
}

function ray_poly(ox: number, oy: number, dx: number, dy: number, w: WShape): [number, number, number] | null {
	let lower = 0
	let upper = 1
	let idx = -1
	const n = w.verts.length / 2
	for (let i = 0; i < n; i++) {
		const nx = w.normals[i * 2]
		const ny = w.normals[i * 2 + 1]
		const num = nx * (w.verts[i * 2] - ox) + ny * (w.verts[i * 2 + 1] - oy)
		const den = nx * dx + ny * dy
		if (den === 0) {
			if (num < 0) return null
		} else if (den < 0 && num < lower * den) {
			lower = num / den
			idx = i
		} else if (den > 0 && num < upper * den) {
			upper = num / den
		}
		if (upper < lower) return null
	}
	if (idx < 0) return null
	return [lower, w.normals[idx * 2], w.normals[idx * 2 + 1]]
}

// ---------- Helpers ----------

export function world_of(n: core.Node): PhysicsWorld | null {
	let cur: core.Node | null = n
	while (cur !== null) {
		const w = cur.get_component<PhysicsWorld>(PhysicsWorld)
		if (w !== null) {
			w.ensure()
			return w
		}
		cur = cur.parent
	}
	return null
}

function world_transform(n: core.Node): [Vec2, number] {
	const m = n.world_matrix()
	return [m.position(), m.rotation_deg()]
}

function set_world_transform(n: core.Node, pos: Vec2, rot: number) {
	n.set_world_position(pos)
	n.rotation = n.parent === null ? rot : rot - n.parent.world_matrix().rotation_deg()
}

function moved(a: Vec2, b: Vec2, ra: number, rb: number): boolean {
	const dx = a.x - b.x
	const dy = a.y - b.y
	let dr = ra - rb
	while (dr > 180) dr -= 360
	while (dr < -180) dr += 360
	return dx * dx + dy * dy > 0.0001 || dr > 0.01 || dr < -0.01
}

export function register_builtins(r: serialize.Registry) {
	r.register(PhysicsWorld)
	r.register(RigidBody)
	r.register(BoxCollider)
	r.register(CircleCollider)
	r.register(CapsuleCollider)
}
