import velo.core
import velo.physics
import velo.render
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

// ---------- TileMapCollider ----------
// (the TileMap is built without a tileset: solid boxes only need the cells and the tile size)

fn wall_map(mut scene core.Scene) (&core.Node, &render.TileMap, &physics.TileMapCollider) {
	mut n := core.Node.new('Walls')
	mut tm := n.add_component(&render.TileMap{
		columns:   6
		rows:      3
		tile_size: core.vec2(20, 20)
	})
	tm.clear()
	tm.fill_rect(0, 2, 5, 2, 1) // a 6 wide floor along the bottom row
	tm.set(0, 1, 1) // a wall on the left
	tm.set(0, 0, 1)
	mut col := n.add_component(&physics.TileMapCollider{})
	scene.add(mut n)
	return n, tm, col
}

fn test_tilemap_collider_builds_merged_boxes_and_holds_a_body() {
	mut scene, _ := new_world(core.vec2(0, 980))
	n, mut tm, col := wall_map(mut scene)
	assert col.count == 2 // the floor row and the 1x2 wall above its first cell: (0,0..1) and (0..5, 2)
	assert n.children.filter(it.name.starts_with('_solid')).len == 2
	mut ball := core.Node.new('Ball')
	ball.position = core.vec2(60, 10) // above the floor, inside the map's x range
	ball.add_component(&physics.BoxCollider{
		size: core.vec2(10, 10)
	})
	ball.add_component(&physics.RigidBody{})
	scene.add(mut ball)
	run(mut scene, 2)
	// the floor's top is at y = 40 (row 2 of 20 px cells): the ball stops on it, half its height above
	assert ball.position.y > 30 && ball.position.y < 36
	// painting a hole under the ball rebuilds the boxes and the ball falls through
	tm.set(3, 2, -1)
	scene.update(1.0 / 60.0)
	assert col.count == 3 // the floor is cut in two + the wall
	run(mut scene, 1)
	assert ball.position.y > 60
}

fn test_tilemap_collider_solid_tiles_filter_and_cleanup() {
	mut scene, _ := new_world(core.vec2(0, 0))
	mut n := core.Node.new('Map')
	mut tm := n.add_component(&render.TileMap{
		columns:   3
		rows:      1
		tile_size: core.vec2(10, 10)
	})
	tm.clear()
	tm.set(0, 0, 1)
	tm.set(1, 0, 2)
	tm.set(2, 0, 1)
	mut col := n.add_component(&physics.TileMapCollider{
		solid_tiles: [2]
	})
	scene.add(mut n)
	assert col.count == 1 // only the tile 2
	boxes := n.children.filter(it.name.starts_with('_solid'))
	assert boxes.len == 1 && boxes[0].position == core.vec2(15, 5) // center of cell (1, 0)
	n.destroy()
	scene.update(0)
	assert scene.root.children.len == 0
}
