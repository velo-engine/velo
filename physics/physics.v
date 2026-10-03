module physics

import velo.core
import velo.serialize

// register_builtins registers the physics components so .scene files (and the editor) can use them.
// Physics is opt-in: call it from the game's component registration.
pub fn register_builtins(mut r serialize.Registry) {
	r.register[PhysicsWorld]()
	r.register[RigidBody]()
	r.register[BoxCollider]()
	r.register[CircleCollider]()
	r.register[CapsuleCollider]()
	r.register[TileMapCollider]()
	r.register[HingeJoint]()
	r.register[SpringJoint]()
	r.register[RopeJoint]()
	r.register[WeldJoint]()
}

// Contact — one collider touching another.
pub struct Contact {
pub:
	node   &core.Node // the other collider's node
	normal core.Vec2  // unit vector from this collider toward the other (zero for sensors)
	point  core.Vec2  // a contact point in world units (zero for sensors)
	sensor bool       // one of the two is a sensor: an overlap, no collision response
mut:
	shape_id C.b2ShapeId
}

// RayHit — the result of PhysicsWorld.raycast.
pub struct RayHit {
pub:
	node     &core.Node
	point    core.Vec2 // world units
	normal   core.Vec2
	fraction f32 // 0..1 along the ray
}
