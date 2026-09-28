import engine.core
import math

struct Tracker {
	core.Component
mut:
	log []string
}

fn (mut t Tracker) on_load() {
	t.log << 'load'
}

fn (mut t Tracker) start() {
	t.log << 'start'
}

fn (mut t Tracker) update(_ f32) {
	t.log << 'update'
}

fn (mut t Tracker) on_destroy() {
	t.log << 'destroy'
}

struct Mover {
	core.Component
pub mut:
	speed f32 = 10
}

fn (mut m Mover) update(dt f32) {
	m.node.position.x += m.speed * dt
}

fn test_lifecycle_order() {
	mut scene := core.Scene.new('test')
	mut n := core.Node.new('A')
	mut t := n.add_component(&Tracker{})
	assert t.log == [] // no on_load before entering the scene
	scene.add(mut n)
	assert t.log == ['load']
	scene.update(0.016)
	scene.update(0.016)
	assert t.log == ['load', 'start', 'update', 'update']
	n.destroy()
	assert n.destroyed
	scene.update(0.016)
	assert t.log.last() == 'destroy'
	assert scene.find('A') == none
}

fn test_get_component_and_mutation() {
	mut n := core.Node.new('P').with(&Mover{ speed: 5 })
	if mut m := n.get_component[Mover]() {
		m.speed = 42
	}
	m2 := n.get_component[Mover]() or { panic('Mover not found') }
	assert m2.speed == 42
	assert n.get_component[Tracker]() == none
	assert n.component_by_type_name('Mover') != none
}

fn test_find_and_paths() {
	mut scene := core.Scene.new('Main')
	mut world := core.Node.new('World')
	mut player := core.Node.new('Player')
	mut weapon := core.Node.new('Weapon')
	player.add_child(mut weapon)
	world.add_child(mut player)
	scene.add(mut world)
	w := scene.find('World/Player/Weapon') or { panic('Weapon not found') }
	assert w.path() == 'Main/World/Player/Weapon'
	back := w.find('../..') or { panic('') }
	assert back.name == 'World'
	assert scene.node_count() == 4
}

fn test_update_moves_node() {
	mut scene := core.Scene.new('s')
	mut n := core.Node.new('m').with(&Mover{ speed: 100 })
	scene.add(mut n)
	scene.update(0.5)
	assert n.position.x == 50
}

fn test_world_transform() {
	mut parent := core.Node.new('parent')
	parent.position = core.vec2(100, 0)
	parent.rotation = 90
	parent.scale = core.vec2(2, 2)
	mut child := core.Node.new('child')
	child.position = core.vec2(10, 0)
	parent.add_child(mut child)
	wp := child.world_position()
	// rotate 90 degrees clockwise (y points down): (10,0)*2 -> (0,20)
	assert math.abs(wp.x - 100) < 0.001
	assert math.abs(wp.y - 20) < 0.001
	child.set_world_position(core.vec2(0, 0))
	assert child.world_position().distance(core.vec2(0, 0)) < 0.001
}

fn test_inactive_node_skips_update() {
	mut scene := core.Scene.new('s')
	mut n := core.Node.new('m').with(&Mover{ speed: 100 })
	n.active = false
	scene.add(mut n)
	scene.update(1)
	assert n.position.x == 0
}

fn test_input_axis() {
	mut i := core.Input{}
	i.key_down(int(core.Key.right))
	assert i.axis_x() == 1
	assert i.was_pressed(.right)
	i.end_frame()
	assert !i.was_pressed(.right)
	assert i.is_down(.right)
	i.key_up(int(core.Key.right))
	assert i.axis_x() == 0
}
