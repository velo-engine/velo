module physics

import math
import velo.core

// RigidBody — makes the node move with Box2D. The colliders on the same node become its shapes.
// The body follows the node's world position/rotation; setting node.position from code teleports it.
//
//   RigidBody { body_type = "dynamic"  fixed_rotation = true }
//   BoxCollider { size = [32, 48] }
@[heap]
pub struct RigidBody {
	core.Component
pub mut:
	body_type       string = 'dynamic' // 'dynamic' | 'kinematic' | 'static'
	gravity_scale   f32    = 1
	linear_damping  f32
	angular_damping f32
	fixed_rotation  bool
	bullet          bool // continuous collision against other dynamic bodies (fast projectiles)
	world           &PhysicsWorld = unsafe { nil } @[hide]
	id              C.b2BodyId    @[hide]
	created         bool          @[hide]
	synced_pos      core.Vec2     @[hide]
	synced_rot      f32           @[hide]
}

pub fn (mut r RigidBody) on_load() {
	if r.created {
		return
	}
	mut w := world_of(r.node) or {
		eprintln('[RigidBody] ${r.node.path()}: no PhysicsWorld on this node or its ancestors')
		return
	}
	pos, rot := world_transform(r.node)
	mut def := C.b2DefaultBodyDef()
	def.@type = r.b2_type()
	def.position = w.to_b2(pos)
	def.rotation = b2rot(rot)
	def.gravityScale = r.gravity_scale
	def.linearDamping = r.linear_damping
	def.angularDamping = r.angular_damping
	def.fixedRotation = r.fixed_rotation
	def.isBullet = r.bullet
	r.world = w
	r.id = C.b2CreateBody(w.id, &def)
	r.created = true
	r.synced_pos, r.synced_rot = pos, rot
	w.bodies << &r
	// Colliders listed before the RigidBody loaded first and are waiting for it.
	for c in r.node.components {
		if c is Collider {
			mut col := c as Collider
			attach_collider(mut col)
		}
	}
}

pub fn (mut r RigidBody) on_destroy() {
	if !r.created {
		return
	}
	for c in r.node.components {
		if c is Collider {
			mut col := c as Collider
			mut st := col.collider_state()
			if st.body_owner == &r {
				st.detach()
			}
		}
	}
	if C.b2Body_IsValid(r.id) {
		C.b2DestroyBody(r.id)
	}
	if r.world != unsafe { nil } {
		r.world.remove_body(r)
	}
	r.created = false
}

// is_valid: the Box2D body exists (the node is in a scene with a PhysicsWorld).
pub fn (r &RigidBody) is_valid() bool {
	return r.created && C.b2Body_IsValid(r.id)
}

// velocity in pixels/s.
pub fn (r &RigidBody) velocity() core.Vec2 {
	if !r.is_valid() {
		return core.Vec2{}
	}
	return r.world.from_b2(C.b2Body_GetLinearVelocity(r.id))
}

pub fn (mut r RigidBody) set_velocity(v core.Vec2) {
	if r.is_valid() {
		C.b2Body_SetLinearVelocity(r.id, r.world.to_b2(v))
	}
}

// angular_velocity in degrees/s (positive = clockwise on screen).
pub fn (r &RigidBody) angular_velocity() f32 {
	if !r.is_valid() {
		return 0
	}
	return f32(C.b2Body_GetAngularVelocity(r.id) * 180.0 / math.pi)
}

pub fn (mut r RigidBody) set_angular_velocity(deg_per_s f32) {
	if r.is_valid() {
		C.b2Body_SetAngularVelocity(r.id, f32(deg_per_s * math.pi / 180.0))
	}
}

// apply_force pushes the body continuously (call every frame); `f` is mass * pixels/s².
pub fn (mut r RigidBody) apply_force(f core.Vec2) {
	if r.is_valid() {
		C.b2Body_ApplyForceToCenter(r.id, r.world.to_b2(f), true)
	}
}

// apply_impulse changes the velocity at once (a jump, a hit); `i` is mass * pixels/s.
pub fn (mut r RigidBody) apply_impulse(i core.Vec2) {
	if r.is_valid() {
		C.b2Body_ApplyLinearImpulseToCenter(r.id, r.world.to_b2(i), true)
	}
}

// apply_torque, in mass * pixels² / s² (positive = clockwise).
pub fn (mut r RigidBody) apply_torque(t f32) {
	if r.is_valid() {
		ppm := r.world.ppm()
		C.b2Body_ApplyTorque(r.id, t / (ppm * ppm), true)
	}
}

// mass in kg (from the colliders' density and area in m²).
pub fn (r &RigidBody) mass() f32 {
	if !r.is_valid() {
		return 0
	}
	return C.b2Body_GetMass(r.id)
}

// set_body_type switches between 'dynamic', 'kinematic' and 'static' at runtime.
pub fn (mut r RigidBody) set_body_type(t string) {
	r.body_type = t
	if r.is_valid() {
		C.b2Body_SetType(r.id, r.b2_type())
	}
}

fn (r &RigidBody) b2_type() int {
	return match r.body_type {
		'static' { body_static }
		'kinematic' { body_kinematic }
		else { body_dynamic }
	}
}

// push_transform teleports the body if game code moved the node since the last step.
fn (mut r RigidBody) push_transform() {
	if !r.is_valid() {
		return
	}
	pos, rot := world_transform(r.node)
	if moved(pos, r.synced_pos, rot, r.synced_rot) {
		C.b2Body_SetTransform(r.id, r.world.to_b2(pos), b2rot(rot))
		C.b2Body_SetAwake(r.id, true)
		r.synced_pos, r.synced_rot = pos, rot
	}
}

// pull_transform writes the simulated position/rotation back to the node.
fn (mut r RigidBody) pull_transform() {
	if !r.is_valid() || r.body_type == 'static' {
		return
	}
	t := C.b2Body_GetTransform(r.id)
	pos := r.world.from_b2(t.p)
	mut n := r.node
	set_world_transform(mut n, pos, rot_deg(t.q))
	r.synced_pos, r.synced_rot = world_transform(n)
}
