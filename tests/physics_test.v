import velo.core
import velo.physics
import velo.serialize

// Box2D runs headless, so these need no GPU (only the box2d library, see physics/box2d.v).

fn new_world(gravity core.Vec2) (&core.Scene, &physics.PhysicsWorld) {
	mut scene := core.Scene.new('test')
	mut w := scene.root.add_component(&physics.PhysicsWorld{
		gravity: gravity
	})
	return scene, w
}

fn run(mut scene core.Scene, seconds f32) {
	for _ in 0 .. int(seconds * 60) {
		scene.update(1.0 / 60.0)
	}
}

fn test_body_falls_and_lands_on_static_ground() {
	mut scene, _ := new_world(core.vec2(0, 980))
	mut ground := core.Node.new('Ground')
	ground.position = core.vec2(0, 300)
	ground.add_component(&physics.BoxCollider{
		size: core.vec2(1000, 20)
	})
	scene.add(mut ground)

	mut box := core.Node.new('Box')
	// Collider listed before the RigidBody: the body picks it up when it loads.
	col := box.add_component(&physics.BoxCollider{
		size: core.vec2(20, 20)
	})
	body := box.add_component(&physics.RigidBody{})
	scene.add(mut box)
	assert body.is_valid()
	assert body.mass() > 0

	scene.update(1.0 / 60.0)
	assert box.position.y > 0 // gravity pulls down (y down)

	run(mut scene, 3)
	// Resting on top of the ground: ground top = 290, box half height = 10.
	assert box.position.y > 275 && box.position.y < 285
	assert col.is_touching(ground)
	assert col.touching.len == 1
	assert col.touching[0].normal.y > 0.9 // toward the ground
}

fn test_began_and_ended_last_one_frame() {
	mut scene, _ := new_world(core.vec2(0, 980))
	mut ground := core.Node.new('Ground')
	ground.position = core.vec2(0, 100)
	gcol := ground.add_component(&physics.BoxCollider{
		size: core.vec2(1000, 20)
	})
	scene.add(mut ground)
	mut ball := core.Node.new('Ball')
	ball.add_component(&physics.RigidBody{})
	ball.add_component(&physics.CircleCollider{
		radius: 10
	})
	scene.add(mut ball)

	mut began_frames := 0
	for _ in 0 .. 120 {
		scene.update(1.0 / 60.0)
		if gcol.began.len > 0 {
			began_frames++
			assert gcol.began[0].node == ball
		}
	}
	assert began_frames == 1
	assert gcol.is_touching(ball)

	ball.destroy()
	scene.update(1.0 / 60.0)
	scene.update(1.0 / 60.0)
	assert !gcol.is_touching(ball)
}

fn test_sensor_reports_overlap_without_collision() {
	mut scene, _ := new_world(core.vec2(0, 980))
	mut zone := core.Node.new('Zone')
	zone.position = core.vec2(0, 100)
	zone_col := zone.add_component(&physics.BoxCollider{
		size:   core.vec2(200, 20)
		sensor: true
	})
	scene.add(mut zone)
	mut ball := core.Node.new('Ball')
	ball.add_component(&physics.RigidBody{})
	ball.add_component(&physics.CircleCollider{
		radius: 5
	})
	scene.add(mut ball)

	mut seen := false
	for _ in 0 .. 60 {
		scene.update(1.0 / 60.0)
		for c in zone_col.began {
			seen = seen || (c.node == ball && c.sensor)
		}
	}
	assert seen
	assert ball.position.y > 150 // fell through the sensor
}

fn test_moving_node_teleports_body_and_velocity_api() {
	mut scene, _ := new_world(core.vec2(0, 0))
	mut n := core.Node.new('Puck')
	mut body := n.add_component(&physics.RigidBody{})
	n.add_component(&physics.CircleCollider{})
	scene.add(mut n)

	n.position = core.vec2(200, 50)
	body.set_velocity(core.vec2(120, 0))
	run(mut scene, 1)
	assert n.position.x > 315 && n.position.x < 325
	assert n.position.y > 49 && n.position.y < 51
	v := body.velocity()
	assert v.x > 119 && v.x < 121
}

fn test_body_under_moved_parent_uses_world_space() {
	mut scene, _ := new_world(core.vec2(0, 0))
	mut parent := core.Node.new('Parent')
	parent.position = core.vec2(100, 100)
	parent.rotation = 90
	scene.add(mut parent)
	mut child := core.Node.new('Child')
	child.position = core.vec2(10, 0)
	child.add_component(&physics.RigidBody{})
	child.add_component(&physics.BoxCollider{})
	parent.add_child(mut child)
	run(mut scene, 0.5)
	wp := child.world_position()
	assert wp.distance(core.vec2(100, 110)) < 0.1
	assert child.position.distance(core.vec2(10, 0)) < 0.1
}

fn test_raycast_hits_closest_collider() {
	mut scene, mut w := new_world(core.vec2(0, 0))
	for i, x in [f32(100), 200] {
		mut wall := core.Node.new('Wall${i}')
		wall.position = core.vec2(x, 0)
		wall.add_component(&physics.BoxCollider{
			size: core.vec2(20, 100)
		})
		scene.add(mut wall)
	}
	hit := w.raycast(core.vec2(0, 0), core.vec2(500, 0)) or { panic('no hit') }
	assert hit.node.name == 'Wall0'
	assert hit.point.x > 89 && hit.point.x < 91
	assert hit.normal.x < -0.9
	if _ := w.raycast(core.vec2(0, 200), core.vec2(500, 200)) {
		assert false
	}
}

fn test_no_world_does_not_crash() {
	mut scene := core.Scene.new('test')
	mut n := core.Node.new('Lonely')
	body := n.add_component(&physics.RigidBody{})
	n.add_component(&physics.BoxCollider{})
	scene.add(mut n)
	scene.update(1.0 / 60.0)
	assert !body.is_valid()
}

fn test_components_are_serializable() {
	mut reg := serialize.new_registry()
	physics.register_builtins(mut reg)
	t := reg.get('BoxCollider') or { panic('not registered') }
	names := t.fields.map(it.name)
	assert names == ['size', 'offset', 'density', 'friction', 'restitution', 'sensor']
	rb := reg.get('RigidBody') or { panic('not registered') }
	assert 'body_type' in rb.fields.map(it.name)
	assert 'id' !in rb.fields.map(it.name)
}
