module physics

import velo.core

// PhysicsWorld — one Box2D world. Put it on the scene root (or any ancestor of the bodies that use it):
// RigidBody and colliders look for the nearest PhysicsWorld above them.
//
// Every value is in world units (pixels) and degrees like the rest of the engine; the world converts to
// Box2D's meters with `pixels_per_meter`. Mass and density stay in Box2D units (kg, kg/m²).
//
// The world steps at a fixed rate in its own update(). It runs before its children update (parents tick
// first), so game code always sees this frame's positions and contacts.
@[heap]
pub struct PhysicsWorld {
	core.Component
pub mut:
	gravity          core.Vec2 = core.Vec2{0, 980} // pixels/s², y down
	pixels_per_meter f32       = 50
	fixed_step       f32       = f32(1.0 / 60.0) // seconds per step
	sub_steps        int       = 4
	max_steps        int       = 5 // per frame; the rest of a long frame is dropped
	id               C.b2WorldId      @[hide]
	created          bool             @[hide]
	accumulator      f32              @[hide]
	bodies           []&RigidBody     @[hide]
	colliders        []&ColliderState @[hide]
}

pub fn (mut w PhysicsWorld) on_load() {
	w.ensure()
}

pub fn (mut w PhysicsWorld) on_destroy() {
	if !w.created {
		return
	}
	for mut b in w.bodies {
		b.created = false
	}
	for mut c in w.colliders {
		c.reset()
	}
	w.bodies.clear()
	w.colliders.clear()
	C.b2DestroyWorld(w.id)
	w.created = false
}

// ensure creates the Box2D world if needed (bodies call it too, in case they load first).
pub fn (mut w PhysicsWorld) ensure() {
	if w.created {
		return
	}
	mut def := C.b2DefaultWorldDef()
	def.gravity = w.to_b2(w.gravity)
	w.id = C.b2CreateWorld(&def)
	w.created = true
	C.b2World_SetPreSolveCallback(w.id, voidptr(presolve_cb), voidptr(w))
}

// set_gravity changes the gravity at runtime (pixels/s²).
pub fn (mut w PhysicsWorld) set_gravity(g core.Vec2) {
	w.gravity = g
	if w.created {
		C.b2World_SetGravity(w.id, w.to_b2(g))
	}
}

pub fn (mut w PhysicsWorld) update(dt f32) {
	if !w.created {
		return
	}
	for mut c in w.colliders {
		c.began.clear()
		c.ended.clear()
	}
	// Nodes moved by game code (or the editor) teleport their bodies.
	for mut b in w.bodies {
		b.push_transform()
	}
	for mut c in w.colliders {
		c.push_transform()
	}
	step := if w.fixed_step > 0 { w.fixed_step } else { f32(1.0 / 60.0) }
	w.accumulator += dt
	mut steps := 0
	for w.accumulator >= step - 1e-5 && steps < w.max_steps {
		w.step(step)
		w.accumulator -= step
		steps++
	}
	if steps == w.max_steps {
		w.accumulator = 0
	}
	if steps > 0 {
		for mut b in w.bodies {
			b.pull_transform()
		}
	}
}

// step advances the simulation by `dt` seconds and collects contact events (normally called by update).
pub fn (mut w PhysicsWorld) step(dt f32) {
	C.b2World_Step(w.id, dt, if w.sub_steps > 0 { w.sub_steps } else { 4 })
	w.collect_events()
}

// QueryOptions — what a query may hit: only colliders on these layers (empty = all). Sensors are never hit.
@[params]
pub struct QueryOptions {
pub:
	layers []int
}

fn (w &PhysicsWorld) query_filter(o QueryOptions) C.b2QueryFilter {
	mut f := C.b2DefaultQueryFilter()
	f.maskBits = layers_mask(o.layers)
	return f
}

// raycast returns the closest collider hit by the segment `from` -> `to` (world units).
pub fn (w &PhysicsWorld) raycast(from core.Vec2, to core.Vec2, o QueryOptions) ?RayHit {
	if !w.created {
		return none
	}
	r := C.b2World_CastRayClosest(w.id, w.to_b2(from), w.to_b2(to - from), w.query_filter(o))
	if !r.hit {
		return none
	}
	st := state_of(r.shapeId) or { return none }
	return RayHit{
		node:     st.owner
		point:    w.from_b2(r.point)
		normal:   from_b2(r.normal)
		fraction: r.fraction
	}
}

struct RayCollect {
mut:
	world &PhysicsWorld = unsafe { nil }
	hits  []RayHit
}

fn ray_cb(shape C.b2ShapeId, point C.b2Vec2, normal C.b2Vec2, fraction f32, ctx voidptr) f32 {
	mut c := unsafe { &RayCollect(ctx) }
	st := state_of(shape) or { return 1 }
	c.hits << RayHit{
		node:     st.owner
		point:    c.world.from_b2(point)
		normal:   from_b2(normal)
		fraction: fraction
	}
	return 1 // keep going: we want every hit
}

// raycast_all returns every collider the segment crosses, nearest first.
pub fn (mut w PhysicsWorld) raycast_all(from core.Vec2, to core.Vec2, o QueryOptions) []RayHit {
	if !w.created {
		return []
	}
	mut c := RayCollect{
		world: w
	}
	C.b2World_CastRay(w.id, w.to_b2(from), w.to_b2(to - from), w.query_filter(o), voidptr(ray_cb),
		voidptr(&c))
	c.hits.sort(a.fraction < b.fraction)
	return c.hits
}

struct OverlapCollect {
mut:
	nodes []&core.Node
}

fn overlap_cb(shape C.b2ShapeId, ctx voidptr) bool {
	mut c := unsafe { &OverlapCollect(ctx) }
	st := state_of(shape) or { return true }
	for n in c.nodes {
		if voidptr(n) == voidptr(st.owner) {
			return true
		}
	}
	c.nodes << st.owner
	return true
}

fn (mut w PhysicsWorld) overlap(proxy &C.b2ShapeProxy, o QueryOptions) []&core.Node {
	if !w.created {
		return []
	}
	mut c := OverlapCollect{}
	C.b2World_OverlapShape(w.id, proxy, w.query_filter(o), voidptr(overlap_cb), voidptr(&c))
	return c.nodes
}

// overlap_circle returns the nodes with a collider touching the circle (world units), each once.
pub fn (mut w PhysicsWorld) overlap_circle(center core.Vec2, radius f32, o QueryOptions) []&core.Node {
	mut proxy := C.b2ShapeProxy{}
	proxy.count = 1
	proxy.points[0] = w.to_b2(center)
	proxy.radius = radius / w.ppm()
	return w.overlap(&proxy, o)
}

// overlap_box returns the nodes with a collider touching the box (center and size in world units, turned by
// `rotation` degrees).
pub fn (mut w PhysicsWorld) overlap_box(center core.Vec2, size core.Vec2, rotation f32, o QueryOptions) []&core.Node {
	mut proxy := C.b2ShapeProxy{}
	proxy.count = 4
	h := size.mul(0.5)
	rot := core.Affine2.trs(center, rotation, core.vec2(1, 1))
	for i, c in [core.vec2(-h.x, -h.y), core.vec2(h.x, -h.y),
		core.vec2(h.x, h.y), core.vec2(-h.x, h.y)] {
		proxy.points[i] = w.to_b2(rot.apply(c))
	}
	return w.overlap(&proxy, o)
}

// overlap_point returns the nodes with a collider under the point.
pub fn (mut w PhysicsWorld) overlap_point(p core.Vec2, o QueryOptions) []&core.Node {
	return w.overlap_circle(p, 0, o)
}

// presolve_cb runs for every contact between a one-way platform and something else, before it is solved: the
// contact is dropped unless it pushes the other body along the platform's up side (the node's -y direction).
fn presolve_cb(a C.b2ShapeId, b C.b2ShapeId, manifold &C.b2Manifold, ctx voidptr) bool {
	sa := state_of(a) or { return true }
	sb := state_of(b) or { return true }
	n := from_b2(manifold.normal) // from shape A toward shape B
	if sa.one_way && !platform_blocks(sa, n) {
		return false
	}
	if sb.one_way && !platform_blocks(sb, n.mul(-1)) {
		return false
	}
	return true
}

// platform_blocks: `toward_other` points from the platform to what touches it; it blocks only from above.
fn platform_blocks(platform &ColliderState, toward_other core.Vec2) bool {
	if platform.owner == unsafe { nil } {
		return true
	}
	rot := platform.owner.world_matrix().rotation_deg()
	up := core.Affine2.trs(core.Vec2{}, rot, core.vec2(1, 1)).apply(core.vec2(0, -1))
	return toward_other.x * up.x + toward_other.y * up.y > 0.5
}

fn (mut w PhysicsWorld) collect_events() {
	ce := C.b2World_GetContactEvents(w.id)
	for i in 0 .. ce.beginCount {
		ev := unsafe { ce.beginEvents[i] }
		m := ev.manifold
		normal := from_b2(m.normal)
		point := if m.pointCount > 0 { w.from_b2(m.points[0].point) } else { core.Vec2{} }
		touch_begin(ev.shapeIdA, ev.shapeIdB, normal, point, false)
		touch_begin(ev.shapeIdB, ev.shapeIdA, normal.mul(-1), point, false)
	}
	for i in 0 .. ce.endCount {
		ev := unsafe { ce.endEvents[i] }
		touch_end(ev.shapeIdA, ev.shapeIdB)
		touch_end(ev.shapeIdB, ev.shapeIdA)
	}
	se := C.b2World_GetSensorEvents(w.id)
	for i in 0 .. se.beginCount {
		ev := unsafe { se.beginEvents[i] }
		touch_begin(ev.sensorShapeId, ev.visitorShapeId, core.Vec2{}, core.Vec2{}, true)
		touch_begin(ev.visitorShapeId, ev.sensorShapeId, core.Vec2{}, core.Vec2{}, true)
	}
	for i in 0 .. se.endCount {
		ev := unsafe { se.endEvents[i] }
		touch_end(ev.sensorShapeId, ev.visitorShapeId)
		touch_end(ev.visitorShapeId, ev.sensorShapeId)
	}
}

// touch_begin records on `self` that it started touching `other` (a destroyed shape on either side is ignored).
fn touch_begin(self C.b2ShapeId, other C.b2ShapeId, normal core.Vec2, point core.Vec2, sensor bool) {
	mut me := state_of(self) or { return }
	them := state_of(other) or { return }
	c := Contact{
		node:     them.owner
		normal:   normal
		point:    point
		sensor:   sensor
		shape_id: other
	}
	me.began << c
	me.touching << c
}

// touch_end: `other` may already be destroyed (end events are sent when a shape goes away), so match by shape id.
fn touch_end(self C.b2ShapeId, other C.b2ShapeId) {
	mut me := state_of(self) or { return }
	for i, c in me.touching {
		if shape_eq(c.shape_id, other) {
			me.ended << c
			me.touching.delete(i)
			return
		}
	}
}

fn state_of(id C.b2ShapeId) ?&ColliderState {
	if !C.b2Shape_IsValid(id) {
		return none
	}
	p := C.b2Shape_GetUserData(id)
	if p == unsafe { nil } {
		return none
	}
	return unsafe { &ColliderState(p) }
}

fn (w &PhysicsWorld) to_b2(v core.Vec2) C.b2Vec2 {
	return b2vec(v.mul(1 / w.ppm()))
}

fn (w &PhysicsWorld) from_b2(v C.b2Vec2) core.Vec2 {
	return from_b2(v).mul(w.ppm())
}

fn (w &PhysicsWorld) ppm() f32 {
	return if w.pixels_per_meter > 0 { w.pixels_per_meter } else { 50 }
}

fn (mut w PhysicsWorld) remove_body(b &RigidBody) {
	for i, x in w.bodies {
		if x == b {
			w.bodies.delete(i)
			return
		}
	}
}

fn (mut w PhysicsWorld) remove_collider(c &ColliderState) {
	for i, x in w.colliders {
		if x == c {
			w.colliders.delete(i)
			return
		}
	}
}

// world_of finds the PhysicsWorld on `n` or its nearest ancestor.
pub fn world_of(n &core.Node) ?&PhysicsWorld {
	mut cur := unsafe { n }
	for cur != unsafe { nil } {
		if mut w := cur.get_component[PhysicsWorld]() {
			w.ensure()
			return w
		}
		cur = cur.parent
	}
	return none
}

// world_transform: the node's world position and rotation (degrees).
fn world_transform(n &core.Node) (core.Vec2, f32) {
	m := n.world_matrix()
	return m.position(), m.rotation_deg()
}

// set_world_transform moves the node so its world position/rotation match (keeps its local scale).
fn set_world_transform(mut n core.Node, pos core.Vec2, rot f32) {
	n.set_world_position(pos)
	n.rotation = if n.parent == unsafe { nil } {
		rot
	} else {
		rot - n.parent.world_matrix().rotation_deg()
	}
}

fn moved(a core.Vec2, b core.Vec2, ra f32, rb f32) bool {
	d := a - b
	mut dr := ra - rb
	for dr > 180 {
		dr -= 360
	}
	for dr < -180 {
		dr += 360
	}
	return d.x * d.x + d.y * d.y > 0.0001 || dr > 0.01 || dr < -0.01
}
