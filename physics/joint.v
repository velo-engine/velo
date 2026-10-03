module physics

import math
import velo.core

// Joints connect two bodies. Put one on the node of a RigidBody and name the other node in `other` (a path from the
// scene root, e.g. "World/Door"); leave `other` empty to pin the joint to the world at its anchor.
//
//   node Door {
//     RigidBody { }  BoxCollider { size = [10, 80] }
//     HingeJoint { anchor = [0, -40]  enable_limit = true  lower_angle = -90  upper_angle = 0 }
//   }
//   node Ball { RigidBody { }  CircleCollider { }  SpringJoint { other = "Level/Ceiling"  length = 120  hertz = 3 } }
//
// All of them need a PhysicsWorld above them and a RigidBody on both nodes (the world side needs none). The joint is
// made on the first frame both bodies exist and goes away with either node. Anchors and lengths are in world units;
// angles are degrees.
//
//   HingeJoint   pivot: the bodies rotate around the anchor (a door, a pendulum, a wheel when motorized)
//   SpringJoint  keeps a distance like a spring (`hertz` = stiffness, `damping`) or, with hertz 0, rigidly
//   RopeJoint    at most `max_length` apart, free to go slack
//   WeldJoint    glues the bodies together at the anchor

// JointEnds — the two bodies of a joint and where it attaches to each (Box2D meters, body space).
struct JointEnds {
	world    &PhysicsWorld
	a        C.b2BodyId
	b        C.b2BodyId
	local_a  C.b2Vec2
	local_b  C.b2Vec2
	own_body bool // `b` is a static body made for a world anchor: the joint destroys it
}

// body_of: the node's RigidBody once its Box2D body exists.
fn body_of(n &core.Node) ?&RigidBody {
	rb := n.get_component[RigidBody]() or { return none }
	if !rb.created {
		return none
	}
	return rb
}

fn body_scale(n &core.Node) core.Vec2 {
	sc := n.world_matrix().scale()
	return core.vec2(f32(math.abs(sc.x)), f32(math.abs(sc.y)))
}

// joint_ends works out both bodies and the local anchors. `anchor` is in `node`'s space; `other_anchor` is in the
// other node's space (or a world position when there is no other node). none: not ready yet (a body is missing).
fn joint_ends(node &core.Node, other string, anchor core.Vec2, other_anchor core.Vec2, hinge_like bool) ?JointEnds {
	ra := body_of(node) or { return none }
	if ra.world == unsafe { nil } {
		return none
	}
	mut w := ra.world
	ppm := w.ppm()
	sa := body_scale(node)
	local_a := b2vec(core.vec2(anchor.x * sa.x, anchor.y * sa.y).mul(1 / ppm))
	world_anchor := node.world_matrix().apply(anchor)
	if other == '' {
		// pinned to the world: a static body at the anchor (or at other_anchor for two-anchor joints)
		at := if hinge_like { world_anchor } else { other_anchor }
		mut def := C.b2DefaultBodyDef()
		def.@type = body_static
		def.position = w.to_b2(at)
		body := C.b2CreateBody(w.id, &def)
		return JointEnds{
			world:    w
			a:        ra.id
			b:        body
			local_a:  local_a
			local_b:  C.b2Vec2{}
			own_body: true
		}
	}
	on := node.scene.find(other) or { return none }
	rb := body_of(on) or { return none }
	sb := body_scale(on)
	pt := if hinge_like { on.world_matrix().inverse().apply(world_anchor) } else { other_anchor }
	local_b := b2vec(core.vec2(pt.x * sb.x, pt.y * sb.y).mul(1 / ppm))
	return JointEnds{
		world:   w
		a:       ra.id
		b:       rb.id
		local_a: local_a
		local_b: local_b
	}
}

// JointState — shared by the joint components (embedded, so not serialized).
struct JointState {
mut:
	joint     C.b2JointId
	made      bool
	anchor_id C.b2BodyId
	has_body  bool
}

fn (mut s JointState) adopt(j C.b2JointId, e JointEnds) {
	s.joint = j
	s.made = true
	if e.own_body {
		s.anchor_id = e.b
		s.has_body = true
	}
}

fn (mut s JointState) destroy() {
	if s.made && C.b2Joint_IsValid(s.joint) {
		C.b2DestroyJoint(s.joint)
	}
	if s.has_body && C.b2Body_IsValid(s.anchor_id) {
		C.b2DestroyBody(s.anchor_id)
	}
	s.made = false
	s.has_body = false
}

// is_valid: the joint exists in the world (false until both bodies are ready, and after either is destroyed).
fn (s &JointState) is_valid() bool {
	return s.made && C.b2Joint_IsValid(s.joint)
}

// HingeJoint — the two bodies turn around the anchor.
@[heap]
pub struct HingeJoint {
	core.Component
	JointState
pub mut:
	other             string
	anchor            core.Vec2 // in this node's space
	enable_limit      bool
	lower_angle       f32 // degrees, relative to how the bodies started
	upper_angle       f32
	motor_speed       f32 // degrees per second, with max_motor_torque > 0
	max_motor_torque  f32 // 0 = no motor
	hertz             f32 // > 0: a torsion spring pulling back to the start angle
	damping           f32 = 0.5
	collide_connected bool
}

pub fn (mut j HingeJoint) update(dt f32) {
	if j.made {
		return
	}
	e := joint_ends(j.node, j.other, j.anchor, core.Vec2{}, true) or { return }
	mut def := C.b2DefaultRevoluteJointDef()
	def.bodyIdA = e.a
	def.bodyIdB = e.b
	def.localAnchorA = e.local_a
	def.localAnchorB = e.local_b
	def.enableLimit = j.enable_limit
	def.lowerAngle = f32(math.radians(j.lower_angle))
	def.upperAngle = f32(math.radians(j.upper_angle))
	def.enableMotor = j.max_motor_torque > 0
	def.maxMotorTorque = j.max_motor_torque
	def.motorSpeed = f32(math.radians(j.motor_speed))
	def.enableSpring = j.hertz > 0
	def.hertz = j.hertz
	def.dampingRatio = j.damping
	def.collideConnected = j.collide_connected
	j.adopt(C.b2CreateRevoluteJoint(e.world.id, &def), e)
}

pub fn (mut j HingeJoint) on_destroy() {
	j.JointState.destroy()
}

// SpringJoint — keeps the anchors `length` apart like a spring (hertz > 0), or rigidly (hertz = 0). `min_length` /
// `max_length` (0 = none) also limit how far it may compress or stretch.
@[heap]
pub struct SpringJoint {
	core.Component
	JointState
pub mut:
	other             string
	anchor            core.Vec2 // in this node's space
	other_anchor      core.Vec2 // in the other node's space; a world position when `other` is empty
	length            f32       // 0 = the distance the anchors have when the joint is made
	hertz             f32 = 4
	damping           f32 = 0.5
	min_length        f32
	max_length        f32
	collide_connected bool
}

pub fn (mut j SpringJoint) update(dt f32) {
	if j.made {
		return
	}
	e := joint_ends(j.node, j.other, j.anchor, j.other_anchor, false) or { return }
	mut def := C.b2DefaultDistanceJointDef()
	def.bodyIdA = e.a
	def.bodyIdB = e.b
	def.localAnchorA = e.local_a
	def.localAnchorB = e.local_b
	ppm := e.world.ppm()
	len := if j.length > 0 {
		j.length
	} else {
		rest_distance(j.node, j.other, j.anchor, j.other_anchor)
	}
	def.length = len / ppm
	def.enableSpring = j.hertz > 0
	def.hertz = j.hertz
	def.dampingRatio = j.damping
	if j.min_length > 0 || j.max_length > 0 {
		def.enableLimit = true
		def.minLength = (if j.min_length > 0 { j.min_length } else { 0.05 * ppm }) / ppm
		def.maxLength = (if j.max_length > 0 { j.max_length } else { 1e6 }) / ppm
	}
	def.collideConnected = j.collide_connected
	j.adopt(C.b2CreateDistanceJoint(e.world.id, &def), e)
}

pub fn (mut j SpringJoint) on_destroy() {
	j.JointState.destroy()
}

// RopeJoint — the anchors may be at most `max_length` apart and move freely closer (it goes slack).
@[heap]
pub struct RopeJoint {
	core.Component
	JointState
pub mut:
	other             string
	anchor            core.Vec2
	other_anchor      core.Vec2
	max_length        f32 = 100
	collide_connected bool
}

pub fn (mut j RopeJoint) update(dt f32) {
	if j.made {
		return
	}
	e := joint_ends(j.node, j.other, j.anchor, j.other_anchor, false) or { return }
	mut def := C.b2DefaultDistanceJointDef()
	def.bodyIdA = e.a
	def.bodyIdB = e.b
	def.localAnchorA = e.local_a
	def.localAnchorB = e.local_b
	ppm := e.world.ppm()
	def.length = j.max_length / ppm
	// a spring with no stiffness applies no force: only the limit acts
	def.enableSpring = true
	def.hertz = 0
	def.dampingRatio = 0
	def.enableLimit = true
	def.minLength = 0.05
	def.maxLength = j.max_length / ppm
	def.collideConnected = j.collide_connected
	j.adopt(C.b2CreateDistanceJoint(e.world.id, &def), e)
}

pub fn (mut j RopeJoint) on_destroy() {
	j.JointState.destroy()
}

// WeldJoint — glues the bodies together at the anchor (`hertz` > 0 makes it a little springy).
@[heap]
pub struct WeldJoint {
	core.Component
	JointState
pub mut:
	other             string
	anchor            core.Vec2
	hertz             f32
	damping           f32 = 1
	collide_connected bool
}

pub fn (mut j WeldJoint) update(dt f32) {
	if j.made {
		return
	}
	e := joint_ends(j.node, j.other, j.anchor, core.Vec2{}, true) or { return }
	mut def := C.b2DefaultWeldJointDef()
	def.bodyIdA = e.a
	def.bodyIdB = e.b
	def.localAnchorA = e.local_a
	def.localAnchorB = e.local_b
	def.linearHertz = j.hertz
	def.angularHertz = j.hertz
	def.linearDampingRatio = j.damping
	def.angularDampingRatio = j.damping
	def.collideConnected = j.collide_connected
	j.adopt(C.b2CreateWeldJoint(e.world.id, &def), e)
}

pub fn (mut j WeldJoint) on_destroy() {
	j.JointState.destroy()
}

// rest_distance: the world distance between the two anchors right now.
fn rest_distance(node &core.Node, other string, anchor core.Vec2, other_anchor core.Vec2) f32 {
	a := node.world_matrix().apply(anchor)
	b := if other == '' {
		other_anchor
	} else if on := node.scene.find(other) {
		on.world_matrix().apply(other_anchor)
	} else {
		a
	}
	return (b - a).length()
}

// is_valid: the joint exists (false until both bodies are ready, and after either node is destroyed).
pub fn (j &HingeJoint) is_valid() bool {
	return j.JointState.is_valid()
}

pub fn (j &SpringJoint) is_valid() bool {
	return j.JointState.is_valid()
}

pub fn (j &RopeJoint) is_valid() bool {
	return j.JointState.is_valid()
}

pub fn (j &WeldJoint) is_valid() bool {
	return j.JointState.is_valid()
}
