import velo.core
import velo.physics
import velo.render
import velo.serialize
import math

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
	assert names == ['size', 'offset', 'density', 'friction', 'restitution', 'sensor', 'layer',
		'collides_with', 'one_way']
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

// ---------- Layers, queries, one-way platforms, joints ----------

fn ball(name string, x f32, y f32, layer int, collides_with []int) &core.Node {
	mut n := core.Node.new(name)
	n.position = core.vec2(x, y)
	n.add_component(&physics.CircleCollider{
		radius:        10
		layer:         layer
		collides_with: collides_with
	})
	n.add_component(&physics.RigidBody{})
	return n
}

fn ground(mut scene core.Scene, y f32) {
	mut g := core.Node.new('Ground')
	g.position = core.vec2(200, y)
	g.add_component(&physics.BoxCollider{
		size: core.vec2(2000, 20)
	})
	scene.add(mut g)
}

fn test_layers_filter_what_collides() {
	mut scene, _ := new_world(core.vec2(0, 980))
	ground(mut scene, 400) // layer 0, collides with everything: top at y = 390
	mut wall := core.Node.new('Platform')
	wall.position = core.vec2(200, 250)
	wall.add_component(&physics.BoxCollider{
		size:          core.vec2(300, 10)
		layer:         3
		collides_with: [3]
	})
	scene.add(mut wall)
	mut a :=
		ball('A', 150, 100, 1, [0]) // ignores layer 3: falls through the platform to the ground
	mut b :=
		ball('B', 250, 100, 3, [3]) // collides with layer 3 only: lands on the platform, ignores the ground
	scene.add(mut a)
	scene.add(mut b)
	run(mut scene, 3)
	assert a.position.y > 375 && a.position.y < 385
	assert b.position.y > 230 && b.position.y < 240 // platform top 245, radius 10
}

fn test_overlap_queries_and_raycast_all_with_layers() {
	mut scene, mut w := new_world(core.vec2(0, 0))
	mut crate := core.Node.new('Crate')
	crate.position = core.vec2(100, 100)
	crate.add_component(&physics.BoxCollider{
		size:  core.vec2(40, 40)
		layer: 1
	})
	mut rock := core.Node.new('Rock')
	rock.position = core.vec2(300, 100)
	rock.add_component(&physics.CircleCollider{
		radius: 20
		layer:  2
	})
	scene.add(mut crate)
	scene.add(mut rock)
	scene.update(1.0 / 60.0)
	assert w.overlap_circle(core.vec2(100, 100), 5).map(it.name) == ['Crate']
	assert w.overlap_circle(core.vec2(200, 100), 5).len == 0
	assert w.overlap_circle(core.vec2(200, 100), 200).len == 2 // reaches both
	assert w.overlap_circle(core.vec2(200, 100), 200, layers: [2]).map(it.name) == [
		'Rock',
	]
	assert w.overlap_point(core.vec2(110, 110)).map(it.name) == ['Crate']
	assert w.overlap_point(core.vec2(160, 100)).len == 0
	assert w.overlap_box(core.vec2(300, 100), core.vec2(10, 10), 45).map(it.name) == [
		'Rock',
	]
	hits := w.raycast_all(core.vec2(0, 100), core.vec2(500, 100))
	assert hits.map(it.node.name) == ['Crate', 'Rock'] // nearest first
	assert hits[0].fraction < hits[1].fraction && hits[0].point.x > 70 && hits[0].point.x < 90
	assert w.raycast_all(core.vec2(0, 100), core.vec2(500, 100), layers: [2]).map(it.node.name) == [
		'Rock',
	]
	r := w.raycast(core.vec2(0, 100), core.vec2(500, 100), layers: [2])?
	assert r.node.name == 'Rock'
	assert w.raycast(core.vec2(0, 500), core.vec2(500, 500)) == none
}

fn test_one_way_platform_lets_things_up_but_holds_them_from_above() {
	mut scene, _ := new_world(core.vec2(0, 980))
	mut p := core.Node.new('Platform')
	p.position = core.vec2(200, 300)
	p.add_component(&physics.BoxCollider{
		size:    core.vec2(300, 10)
		one_way: true
	})
	scene.add(mut p)
	mut rising := ball('Rising', 160, 420, 0, [])
	mut rb := rising.get_component[physics.RigidBody]()?
	scene.add(mut rising)
	rb.set_velocity(core.vec2(0, -700)) // jumps up from below, through the platform
	mut falling := ball('Falling', 240, 100, 0, [])
	scene.add(mut falling)
	run(mut scene, 0.5)
	assert rising.position.y < 300 // went through it
	run(mut scene, 4)
	// both rest on top of the platform (its top is 295, the ball's radius 10)
	assert rising.position.y > 280 && rising.position.y < 290
	assert falling.position.y > 280 && falling.position.y < 290
}

fn pivot_world(g core.Vec2) (&core.Scene, &physics.PhysicsWorld) {
	return new_world(g)
}

fn test_hinge_pinned_to_the_world_swings_on_a_circle() {
	mut scene, _ := pivot_world(core.vec2(0, 980))
	mut bob := ball('Bob', 300, 100, 0, [])
	// the pivot is 100 units to the left of the bob, pinned in the air (no `other`)
	bob.add_component(&physics.HingeJoint{
		anchor: core.vec2(-100, 0)
	})
	scene.add(mut bob)
	pivot := core.vec2(200, 100)
	mut max_y := f32(0)
	for _ in 0 .. 180 {
		scene.update(1.0 / 60.0)
		assert math.abs((bob.position - pivot).length() - 100) < 3 // stays on its circle
		max_y = math.max(max_y, bob.position.y)
	}
	assert max_y > 150 // it did swing down
	hinge := bob.get_component[physics.HingeJoint]()?
	assert hinge.is_valid()
	bob.destroy()
	scene.update(1.0 / 60.0)
	scene.update(1.0 / 60.0)
}

fn test_hinge_limit_stops_the_swing() {
	mut scene, _ := pivot_world(core.vec2(0, 980))
	mut door := core.Node.new('Door')
	door.position = core.vec2(300, 100)
	door.add_component(&physics.CircleCollider{
		radius: 10
	})
	door.add_component(&physics.RigidBody{})
	door.add_component(&physics.HingeJoint{
		anchor:       core.vec2(-100, 0)
		enable_limit: true
		lower_angle:  -10
		upper_angle:  10
	})
	scene.add(mut door)
	run(mut scene, 3)
	// without the limit it would hang straight down (y = 200); the +-10 degree limit keeps it near the start
	assert door.position.y < 100 + 100 * math.sin(math.radians(10.0)) + 8
}

fn test_spring_stretches_and_rope_limits_distance() {
	mut scene, _ := pivot_world(core.vec2(0, 980))
	mut weight := ball('Weight', 100, 150, 0, [])
	weight.add_component(&physics.SpringJoint{
		other_anchor: core.vec2(100, 50) // world point (no `other`)
		hertz:        2
		damping:      0.3
	})
	scene.add(mut weight)
	run(mut scene, 4)
	d := (weight.position - core.vec2(100, 50)).length()
	assert d > 101 && d < 200 // hangs below its rest length of 100, held by the spring
	mut hanger := ball('Hanger', 400, 80, 0, [])
	hanger.add_component(&physics.RopeJoint{
		other_anchor: core.vec2(400, 50)
		max_length:   100
	})
	scene.add(mut hanger)
	run(mut scene, 0.1)
	assert hanger.position.y > 80 // slack: it fell freely at first
	run(mut scene, 2)
	assert (hanger.position - core.vec2(400, 50)).length() < 106 // taut: never farther than the rope
	assert hanger.position.y > 140 // and it did hang down to the end of it
}

fn test_weld_keeps_two_bodies_rigid() {
	mut scene, _ := pivot_world(core.vec2(0, 0))
	mut a := ball('A', 100, 100, 0, [])
	mut b := ball('B', 150, 100, 0, [])
	a.add_component(&physics.WeldJoint{
		other:  'B'
		anchor: core.vec2(25, 0)
	})
	mut ra := a.get_component[physics.RigidBody]()?
	scene.add(mut a)
	scene.add(mut b)
	ra.set_angular_velocity(6) // spin A: welded B must swing along instead of staying put
	run(mut scene, 1)
	assert math.abs((b.position - a.position).length() - 50) < 2
	assert b.position.y != 100 // B moved around A
	// destroying the other body removes the joint without a crash
	b.destroy()
	scene.update(1.0 / 60.0)
	scene.update(1.0 / 60.0)
	assert !a.get_component[physics.WeldJoint]()?.is_valid()
}
