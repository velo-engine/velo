module physics

import math
import velo.core

// Bindings for the parts of Box2D v3 (C API) the physics components use.
// Desktop: Box2D is linked as a system library: `brew install box2d` (macOS), or build/install it from
// https://github.com/erincatto/box2d (v3.1+) so that <box2d/box2d.h> and libbox2d are on the default paths.
// Android/iOS (or `-d box2d_source` anywhere): Box2D is compiled from source into the game, from
// thirdparty/box2d (`velo deps` downloads it; `velo build android|ios` does so automatically).

$if android || ios || box2d_source ? {
	#flag -I @VMODROOT/thirdparty/box2d/include
	#include <box2d/box2d.h>
	#include "@VMODROOT/physics/box2d_source.c"
} $else {
	#flag darwin -I/opt/homebrew/include
	#flag darwin -L/opt/homebrew/lib
	#flag darwin -I/usr/local/include
	#flag darwin -L/usr/local/lib
	#flag -lbox2d
	#include <box2d/box2d.h>
}

@[typedef]
pub struct C.b2Vec2 {
mut:
	x f32
	y f32
}

@[typedef]
pub struct C.b2Rot {
mut:
	c f32
	s f32
}

@[typedef]
pub struct C.b2Transform {
	p C.b2Vec2
	q C.b2Rot
}

@[typedef]
pub struct C.b2WorldId {
	index1     u16
	generation u16
}

@[typedef]
pub struct C.b2BodyId {
	index1     int
	world0     u16
	generation u16
}

@[typedef]
pub struct C.b2ShapeId {
	index1     int
	world0     u16
	generation u16
}

@[typedef]
struct C.b2WorldDef {
mut:
	gravity C.b2Vec2
}

@[typedef]
struct C.b2BodyDef {
mut:
	type           int
	position       C.b2Vec2
	rotation       C.b2Rot
	linearDamping  f32
	angularDamping f32
	gravityScale   f32
	userData       voidptr
	fixedRotation  bool
	isBullet       bool
}

@[typedef]
struct C.b2SurfaceMaterial {
mut:
	friction    f32
	restitution f32
}

@[typedef]
struct C.b2Filter {
mut:
	categoryBits u64
	maskBits     u64
	groupIndex   int
}

@[typedef]
struct C.b2ShapeDef {
mut:
	userData             voidptr
	material             C.b2SurfaceMaterial
	density              f32
	filter               C.b2Filter
	isSensor             bool
	enableSensorEvents   bool
	enableContactEvents  bool
	enablePreSolveEvents bool
}

@[typedef]
struct C.b2Polygon {}

@[typedef]
struct C.b2Circle {
mut:
	center C.b2Vec2
	radius f32
}

@[typedef]
struct C.b2Capsule {
mut:
	center1 C.b2Vec2
	center2 C.b2Vec2
	radius  f32
}

@[typedef]
struct C.b2ManifoldPoint {
	point C.b2Vec2
}

@[typedef]
struct C.b2Manifold {
	normal     C.b2Vec2
	points     [2]C.b2ManifoldPoint
	pointCount int
}

@[typedef]
struct C.b2ContactBeginTouchEvent {
	shapeIdA C.b2ShapeId
	shapeIdB C.b2ShapeId
	manifold C.b2Manifold
}

@[typedef]
struct C.b2ContactEndTouchEvent {
	shapeIdA C.b2ShapeId
	shapeIdB C.b2ShapeId
}

@[typedef]
struct C.b2ContactEvents {
	beginEvents &C.b2ContactBeginTouchEvent
	endEvents   &C.b2ContactEndTouchEvent
	beginCount  int
	endCount    int
}

@[typedef]
struct C.b2SensorBeginTouchEvent {
	sensorShapeId  C.b2ShapeId
	visitorShapeId C.b2ShapeId
}

@[typedef]
struct C.b2SensorEndTouchEvent {
	sensorShapeId  C.b2ShapeId
	visitorShapeId C.b2ShapeId
}

@[typedef]
struct C.b2SensorEvents {
	beginEvents &C.b2SensorBeginTouchEvent
	endEvents   &C.b2SensorEndTouchEvent
	beginCount  int
	endCount    int
}

@[typedef]
struct C.b2QueryFilter {
mut:
	categoryBits u64
	maskBits     u64
}

@[typedef]
struct C.b2ShapeProxy {
mut:
	points [8]C.b2Vec2
	count  int
	radius f32
}

@[typedef]
struct C.b2TreeStats {}

@[typedef]
pub struct C.b2JointId {
	index1     int
	world0     u16
	generation u16
}

@[typedef]
struct C.b2RevoluteJointDef {
mut:
	bodyIdA          C.b2BodyId
	bodyIdB          C.b2BodyId
	localAnchorA     C.b2Vec2
	localAnchorB     C.b2Vec2
	enableSpring     bool
	hertz            f32
	dampingRatio     f32
	enableLimit      bool
	lowerAngle       f32
	upperAngle       f32
	enableMotor      bool
	maxMotorTorque   f32
	motorSpeed       f32
	collideConnected bool
}

@[typedef]
struct C.b2DistanceJointDef {
mut:
	bodyIdA          C.b2BodyId
	bodyIdB          C.b2BodyId
	localAnchorA     C.b2Vec2
	localAnchorB     C.b2Vec2
	length           f32
	enableSpring     bool
	hertz            f32
	dampingRatio     f32
	enableLimit      bool
	minLength        f32
	maxLength        f32
	collideConnected bool
}

@[typedef]
struct C.b2WeldJointDef {
mut:
	bodyIdA             C.b2BodyId
	bodyIdB             C.b2BodyId
	localAnchorA        C.b2Vec2
	localAnchorB        C.b2Vec2
	linearHertz         f32
	angularHertz        f32
	linearDampingRatio  f32
	angularDampingRatio f32
	collideConnected    bool
}

@[typedef]
struct C.b2RayResult {
	shapeId  C.b2ShapeId
	point    C.b2Vec2
	normal   C.b2Vec2
	fraction f32
	hit      bool
}

fn C.b2DefaultWorldDef() C.b2WorldDef
fn C.b2CreateWorld(def &C.b2WorldDef) C.b2WorldId
fn C.b2DestroyWorld(id C.b2WorldId)
fn C.b2World_IsValid(id C.b2WorldId) bool
fn C.b2World_Step(id C.b2WorldId, time_step f32, sub_steps int)
fn C.b2World_SetGravity(id C.b2WorldId, gravity C.b2Vec2)
fn C.b2World_GetContactEvents(id C.b2WorldId) C.b2ContactEvents
fn C.b2World_GetSensorEvents(id C.b2WorldId) C.b2SensorEvents
fn C.b2World_CastRayClosest(id C.b2WorldId, origin C.b2Vec2, translation C.b2Vec2, filter C.b2QueryFilter) C.b2RayResult
fn C.b2DefaultQueryFilter() C.b2QueryFilter
fn C.b2World_OverlapShape(id C.b2WorldId, proxy &C.b2ShapeProxy, filter C.b2QueryFilter, fcn voidptr, ctx voidptr) C.b2TreeStats
fn C.b2World_CastRay(id C.b2WorldId, origin C.b2Vec2, translation C.b2Vec2, filter C.b2QueryFilter, fcn voidptr, ctx voidptr) C.b2TreeStats
fn C.b2World_SetPreSolveCallback(id C.b2WorldId, fcn voidptr, ctx voidptr)

fn C.b2DefaultRevoluteJointDef() C.b2RevoluteJointDef
fn C.b2DefaultDistanceJointDef() C.b2DistanceJointDef
fn C.b2DefaultWeldJointDef() C.b2WeldJointDef
fn C.b2CreateRevoluteJoint(world C.b2WorldId, def &C.b2RevoluteJointDef) C.b2JointId
fn C.b2CreateDistanceJoint(world C.b2WorldId, def &C.b2DistanceJointDef) C.b2JointId
fn C.b2CreateWeldJoint(world C.b2WorldId, def &C.b2WeldJointDef) C.b2JointId
fn C.b2DestroyJoint(id C.b2JointId)
fn C.b2Joint_IsValid(id C.b2JointId) bool

fn C.b2DefaultBodyDef() C.b2BodyDef
fn C.b2CreateBody(world C.b2WorldId, def &C.b2BodyDef) C.b2BodyId
fn C.b2DestroyBody(id C.b2BodyId)
fn C.b2Body_IsValid(id C.b2BodyId) bool
fn C.b2Body_SetType(id C.b2BodyId, typ int)
fn C.b2Body_GetTransform(id C.b2BodyId) C.b2Transform
fn C.b2Body_SetTransform(id C.b2BodyId, position C.b2Vec2, rotation C.b2Rot)
fn C.b2Body_GetLinearVelocity(id C.b2BodyId) C.b2Vec2
fn C.b2Body_SetLinearVelocity(id C.b2BodyId, v C.b2Vec2)
fn C.b2Body_GetAngularVelocity(id C.b2BodyId) f32
fn C.b2Body_SetAngularVelocity(id C.b2BodyId, w f32)
fn C.b2Body_ApplyForceToCenter(id C.b2BodyId, force C.b2Vec2, wake bool)
fn C.b2Body_ApplyLinearImpulseToCenter(id C.b2BodyId, impulse C.b2Vec2, wake bool)
fn C.b2Body_ApplyTorque(id C.b2BodyId, torque f32, wake bool)
fn C.b2Body_GetMass(id C.b2BodyId) f32
fn C.b2Body_SetAwake(id C.b2BodyId, awake bool)
fn C.b2Body_IsAwake(id C.b2BodyId) bool

fn C.b2DefaultShapeDef() C.b2ShapeDef
fn C.b2MakeOffsetBox(half_width f32, half_height f32, center C.b2Vec2, rotation C.b2Rot) C.b2Polygon
fn C.b2CreatePolygonShape(body C.b2BodyId, def &C.b2ShapeDef, polygon &C.b2Polygon) C.b2ShapeId
fn C.b2CreateCircleShape(body C.b2BodyId, def &C.b2ShapeDef, circle &C.b2Circle) C.b2ShapeId
fn C.b2CreateCapsuleShape(body C.b2BodyId, def &C.b2ShapeDef, capsule &C.b2Capsule) C.b2ShapeId
fn C.b2DestroyShape(id C.b2ShapeId, update_body_mass bool)
fn C.b2Shape_IsValid(id C.b2ShapeId) bool
fn C.b2Shape_GetUserData(id C.b2ShapeId) voidptr

const body_static = 0
const body_kinematic = 1
const body_dynamic = 2

fn shape_eq(a C.b2ShapeId, b C.b2ShapeId) bool {
	return a.index1 == b.index1 && a.world0 == b.world0 && a.generation == b.generation
}

fn b2vec(v core.Vec2) C.b2Vec2 {
	return C.b2Vec2{
		x: v.x
		y: v.y
	}
}

fn from_b2(v C.b2Vec2) core.Vec2 {
	return core.vec2(v.x, v.y)
}

// b2rot: engine rotations are degrees, clockwise on screen (y down) — the same direction as Box2D's
// counter-clockwise radians once y points down, so no sign flip is needed.
fn b2rot(deg f32) C.b2Rot {
	r := f64(deg) * math.pi / 180.0
	return C.b2Rot{
		c: f32(math.cos(r))
		s: f32(math.sin(r))
	}
}

fn rot_deg(q C.b2Rot) f32 {
	return f32(math.atan2(q.s, q.c) * 180.0 / math.pi)
}
