module physics

import math
import velo.core

// Collider — BoxCollider, CircleCollider and CapsuleCollider.
// A collider becomes a shape of the RigidBody on the same node; without one it gets its own static body
// (walls, ground, trigger zones). Shapes are sized once, with the node's world scale when they load.
pub interface Collider {
mut:
	node &core.Node
	collider_state() &ColliderState
	make_shape(body C.b2BodyId, st &ColliderState, ppm f32, scale core.Vec2) C.b2ShapeId
}

// ColliderState — the part every collider shares (embedded, so not serialized): contacts and the Box2D shape.
//
//   if col := node.get_component[physics.BoxCollider]() {
//       for c in col.began { println('hit ${c.node.name}') }
//   }
pub struct ColliderState {
pub mut:
	touching  []Contact // everything this collider currently touches
	began     []Contact // contacts that started this frame (one frame, like Button.clicked)
	ended     []Contact // contacts that ended this frame
	owner     &core.Node    = unsafe { nil }
	world     &PhysicsWorld = unsafe { nil }
	shape_id  C.b2ShapeId
	has_shape bool
	// The RigidBody the shape belongs to, or nil when the collider owns a static body.
	body_owner &RigidBody = unsafe { nil }
	own_body   C.b2BodyId
	owns_body  bool
	synced_pos core.Vec2
	synced_rot f32
}

pub fn (mut s ColliderState) collider_state() &ColliderState {
	return unsafe { &s }
}

// is_touching: true while this collider touches a collider of `n`.
pub fn (s &ColliderState) is_touching(n &core.Node) bool {
	for c in s.touching {
		if c.node == n {
			return true
		}
	}
	return false
}

fn attach_collider(mut c Collider) {
	mut st := c.collider_state()
	if st.has_shape || c.node == unsafe { nil } || c.node.scene == unsafe { nil } {
		return
	}
	node := c.node
	mut body := C.b2BodyId{}
	mut w := unsafe { &PhysicsWorld(nil) }
	if rb := node.get_component[RigidBody]() {
		if !rb.created {
			return
		}
		w = rb.world
		body = rb.id
		st.body_owner = rb
	} else {
		w = world_of(node) or {
			eprintln('[Collider] ${node.path()}: no PhysicsWorld on this node or its ancestors')
			return
		}
		pos, rot := world_transform(node)
		mut def := C.b2DefaultBodyDef()
		def.@type = body_static
		def.position = w.to_b2(pos)
		def.rotation = b2rot(rot)
		body = C.b2CreateBody(w.id, &def)
		st.own_body = body
		st.owns_body = true
		st.synced_pos, st.synced_rot = pos, rot
	}
	sc := node.world_matrix().scale()
	st.owner = node
	st.world = w
	st.shape_id = c.make_shape(body, st, w.ppm(), core.vec2(f32(math.abs(sc.x)),
		f32(math.abs(sc.y))))
	st.has_shape = true
	w.colliders << st
}

// detach destroys the shape (and the collider's own static body).
fn (mut s ColliderState) detach() {
	if s.has_shape && C.b2Shape_IsValid(s.shape_id) {
		C.b2DestroyShape(s.shape_id, true)
	}
	if s.owns_body && C.b2Body_IsValid(s.own_body) {
		C.b2DestroyBody(s.own_body)
	}
	if s.world != unsafe { nil } {
		s.world.remove_collider(s)
	}
	s.reset()
}

fn (mut s ColliderState) reset() {
	s.has_shape = false
	s.owns_body = false
	s.body_owner = unsafe { nil }
	s.world = unsafe { nil }
	s.touching.clear()
}

// push_transform moves the collider's own static body along with its node.
fn (mut s ColliderState) push_transform() {
	if !s.owns_body || !C.b2Body_IsValid(s.own_body) {
		return
	}
	pos, rot := world_transform(s.owner)
	if moved(pos, s.synced_pos, rot, s.synced_rot) {
		C.b2Body_SetTransform(s.own_body, s.world.to_b2(pos), b2rot(rot))
		s.synced_pos, s.synced_rot = pos, rot
	}
}

fn shape_def(st &ColliderState, density f32, friction f32, restitution f32, sensor bool) C.b2ShapeDef {
	mut def := C.b2DefaultShapeDef()
	def.userData = voidptr(st)
	def.density = density
	def.material.friction = friction
	def.material.restitution = restitution
	def.isSensor = sensor
	def.enableSensorEvents = true
	def.enableContactEvents = true
	return def
}

fn outline_color(sensor bool) core.Color {
	return if sensor { core.rgba(255, 200, 60, 230) } else { core.rgba(90, 240, 120, 230) }
}

// BoxCollider — a rectangle of `size` centered on `offset` (node space).
@[heap]
pub struct BoxCollider {
	core.Component
	ColliderState
pub mut:
	size        core.Vec2 = core.Vec2{32, 32}
	offset      core.Vec2
	density     f32 = 1
	friction    f32 = 0.6
	restitution f32
	sensor      bool // detects overlaps (began/ended/touching) without colliding
}

pub fn (mut b BoxCollider) on_load() {
	attach_collider(mut b)
}

pub fn (mut b BoxCollider) on_destroy() {
	b.detach()
}

fn (b &BoxCollider) make_shape(body C.b2BodyId, st &ColliderState, ppm f32, scale core.Vec2) C.b2ShapeId {
	def := shape_def(st, b.density, b.friction, b.restitution, b.sensor)
	poly := C.b2MakeOffsetBox(b.size.x * scale.x / 2 / ppm, b.size.y * scale.y / 2 / ppm,
		b2vec((b.offset * scale).mul(1 / ppm)), b2rot(0))
	return C.b2CreatePolygonShape(body, &def, &poly)
}

// debug_outline / debug_color: drawn by the renderer in debug mode (F1) and in the editor.
pub fn (b &BoxCollider) debug_outline() []core.Vec2 {
	h := b.size.mul(0.5)
	o := b.offset
	return [core.vec2(o.x - h.x, o.y - h.y), core.vec2(o.x + h.x, o.y - h.y),
		core.vec2(o.x + h.x, o.y + h.y), core.vec2(o.x - h.x, o.y + h.y)]
}

pub fn (b &BoxCollider) debug_color() core.Color {
	return outline_color(b.sensor)
}

// CircleCollider — a circle of `radius` centered on `offset` (node space).
@[heap]
pub struct CircleCollider {
	core.Component
	ColliderState
pub mut:
	radius      f32 = 16
	offset      core.Vec2
	density     f32 = 1
	friction    f32 = 0.6
	restitution f32
	sensor      bool
}

pub fn (mut c CircleCollider) on_load() {
	attach_collider(mut c)
}

pub fn (mut c CircleCollider) on_destroy() {
	c.detach()
}

fn (c &CircleCollider) make_shape(body C.b2BodyId, st &ColliderState, ppm f32, scale core.Vec2) C.b2ShapeId {
	def := shape_def(st, c.density, c.friction, c.restitution, c.sensor)
	s := if scale.x > scale.y { scale.x } else { scale.y }
	circle := C.b2Circle{
		center: b2vec((c.offset * scale).mul(1 / ppm))
		radius: c.radius * s / ppm
	}
	return C.b2CreateCircleShape(body, &def, &circle)
}

pub fn (c &CircleCollider) debug_outline() []core.Vec2 {
	return arc(c.offset, c.radius, 0, 360, 32)
}

pub fn (c &CircleCollider) debug_color() core.Color {
	return outline_color(c.sensor)
}

// CapsuleCollider — a pill that fits `size`: vertical when taller than wide (characters), else horizontal.
@[heap]
pub struct CapsuleCollider {
	core.Component
	ColliderState
pub mut:
	size        core.Vec2 = core.Vec2{32, 64}
	offset      core.Vec2
	density     f32 = 1
	friction    f32 = 0.6
	restitution f32
	sensor      bool
}

pub fn (mut c CapsuleCollider) on_load() {
	attach_collider(mut c)
}

pub fn (mut c CapsuleCollider) on_destroy() {
	c.detach()
}

fn (c &CapsuleCollider) make_shape(body C.b2BodyId, st &ColliderState, ppm f32, scale core.Vec2) C.b2ShapeId {
	def := shape_def(st, c.density, c.friction, c.restitution, c.sensor)
	a, b, r := capsule_points(c.offset * scale, c.size * scale)
	capsule := C.b2Capsule{
		center1: b2vec(a.mul(1 / ppm))
		center2: b2vec(b.mul(1 / ppm))
		radius:  r / ppm
	}
	return C.b2CreateCapsuleShape(body, &def, &capsule)
}

pub fn (c &CapsuleCollider) debug_outline() []core.Vec2 {
	a, b, r := capsule_points(c.offset, c.size)
	if c.size.y >= c.size.x {
		mut pts := arc(a, r, 180, 360, 16)
		pts << arc(b, r, 0, 180, 16)
		return pts
	}
	mut pts := arc(b, r, -90, 90, 16)
	pts << arc(a, r, 90, 270, 16)
	return pts
}

pub fn (c &CapsuleCollider) debug_color() core.Color {
	return outline_color(c.sensor)
}

// capsule_points: the two cap centers and the radius of the capsule that fits `size` around `center`.
fn capsule_points(center core.Vec2, size core.Vec2) (core.Vec2, core.Vec2, f32) {
	if size.y >= size.x {
		r := size.x / 2
		d := size.y / 2 - r
		return center + core.vec2(0, -d), center + core.vec2(0, d), r
	}
	r := size.y / 2
	d := size.x / 2 - r
	return center + core.vec2(-d, 0), center + core.vec2(d, 0), r
}

// arc: points on a circle from `from_deg` to `to_deg` (inclusive; clockwise on screen).
fn arc(center core.Vec2, r f32, from_deg f32, to_deg f32, segments int) []core.Vec2 {
	mut pts := []core.Vec2{cap: segments + 1}
	for i in 0 .. segments + 1 {
		t := (from_deg + (to_deg - from_deg) * f32(i) / f32(segments)) * math.pi / 180
		pts << center + core.vec2(f32(math.cos(t)), f32(math.sin(t))).mul(r)
	}
	return pts
}
