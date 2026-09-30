import os
import time
import math
import velo.core
import velo.assets
import velo.serialize
import velo.render

fn near(a core.Vec2, b core.Vec2) bool {
	return math.abs(a.x - b.x) < 0.01 && math.abs(a.y - b.y) < 0.01
}

fn cam_scene() (&core.Scene, &core.Node) {
	mut s := core.Scene.new('Test')
	s.view_size = core.vec2(800, 600)
	mut cam := core.Node.new('Cam').with(&core.Camera{})
	s.add(mut cam)
	return s, cam
}

fn test_no_camera_means_world_is_screen() {
	s := core.Scene.new('Test')
	assert s.active_camera() == none
	assert s.world_to_screen(core.vec2(12, 34)) == core.vec2(12, 34)
	assert s.screen_to_world(core.vec2(12, 34)) == core.vec2(12, 34)
}

fn test_camera_centers_and_zooms() {
	mut s, mut cam := cam_scene()
	cam.position = core.vec2(1000, 500)
	assert near(s.world_to_screen(core.vec2(1000, 500)), core.vec2(400, 300))
	assert near(s.world_to_screen(core.vec2(1010, 500)), core.vec2(410, 300))
	cam.get_component[core.Camera]()?.zoom = 2
	assert near(s.world_to_screen(core.vec2(1010, 500)), core.vec2(420, 300))
	assert near(s.screen_to_world(core.vec2(420, 300)), core.vec2(1010, 500))
	// the camera node's rotation turns the view the other way
	cam.rotation = 90
	assert near(s.world_to_screen(core.vec2(1010, 500)), core.vec2(400, 280))
}

fn test_disabled_or_inactive_camera_is_ignored() {
	mut s, mut cam := cam_scene()
	cam.position = core.vec2(1000, 500)
	cam.active = false
	assert s.active_camera() == none
	cam.active = true
	cam.get_component[core.Camera]()?.enabled = false
	assert s.world_to_screen(core.vec2(5, 5)) == core.vec2(5, 5)
	cam.get_component[core.Camera]()?.enabled = true
	cam.destroy()
	s.update(0)
	assert s.cameras.len == 0
}

fn test_camera_follows_after_updates_with_limits() {
	mut s, mut cam := cam_scene()
	mut world := core.Node.new('World')
	mut player := core.Node.new('Player')
	world.add_child(mut player)
	s.add(mut world)
	mut c := cam.get_component[core.Camera]()?
	c.follow = 'World/Player'
	c.follow_offset = core.vec2(0, -20)
	player.position = core.vec2(900, 700)
	s.update(0.016)
	assert near(cam.world_position(), core.vec2(900, 680))
	// limits keep the 800x600 view inside [0, 0]..[1000, 800]
	c.limit_max = core.vec2(1000, 800)
	assert near(c.center(), core.vec2(600, 500))
	// smoothing: part of the way there
	c.smoothing = 5
	player.position = core.vec2(100, 680)
	s.update(0.1)
	x := cam.world_position().x
	assert x < 900 && x > 100
}

fn test_shake_moves_view_then_stops() {
	mut s, mut cam := cam_scene()
	mut c := cam.get_component[core.Camera]()?
	c.shake(10, 0.5)
	s.update(0.1)
	o := c.shake_offset
	assert math.abs(o.x) <= 10 && math.abs(o.y) <= 10
	s.update(0.5)
	assert c.shake_offset == core.Vec2{}
	assert near(c.center(), cam.world_position())
}

fn test_canvas_ignores_camera_for_hits() {
	mut s, mut cam := cam_scene()
	cam.position = core.vec2(1400, 300) // world x 1000..1800 is on screen
	mut hud := core.Node.new('HUD').with(&core.Canvas{})
	mut btn := core.Node.new('Btn').with(&render.UITransform{
		size: core.vec2(100, 40)
	})
	btn.position = core.vec2(100, 100)
	hud.add_child(mut btn)
	mut sign := core.Node.new('Sign').with(&render.UITransform{
		size: core.vec2(100, 40)
	})
	sign.position = core.vec2(1100, 100)
	s.add(mut hud)
	s.add(mut sign)
	assert btn.in_canvas() && !sign.in_canvas()
	assert render.hit_test(btn, core.vec2(100, 100))
	assert render.hit_test(sign, core.vec2(100, 100)) // world 1100 is at screen 100
	assert !render.hit_test(sign, core.vec2(1100, 100))
	assert render.hit_test_world(sign, core.vec2(1100, 100))
}

fn names(nodes []&core.Node) []string {
	return nodes.map(it.name)
}

fn test_draw_order_z_index_y_sort_and_canvas() {
	mut root := core.Node.new('Root')
	mut hud := core.Node.new('HUD').with(&core.Canvas{})
	mut a := core.Node.new('A')
	mut b := core.Node.new('B')
	b.z_index = -1
	mut c := core.Node.new('C')
	mut c1 := core.Node.new('C1')
	c1.z_index = 1 // relative: draws at 1, over A and D
	c.add_child(mut c1)
	mut d := core.Node.new('D')
	mut hidden := core.Node.new('Hidden')
	hidden.active = false
	root.add_child(mut hud) // first child, but a Canvas draws after the world
	root.add_child(mut a)
	root.add_child(mut b)
	root.add_child(mut c)
	root.add_child(mut d)
	root.add_child(mut hidden)
	hud.z_index = -5 // z only orders nodes within the same Canvas / world group
	assert names(render.draw_order(root)) == ['B', 'Root', 'A', 'C', 'D', 'C1', 'HUD']

	mut ys := core.Node.new('YS')
	ys.y_sort = true
	mut tree := core.Node.new('Tree')
	tree.position = core.vec2(0, 300)
	mut leaf := core.Node.new('Leaf')
	tree.add_child(mut leaf)
	mut hero := core.Node.new('Hero')
	hero.position = core.vec2(0, 200)
	ys.add_child(mut tree)
	ys.add_child(mut hero)
	assert names(render.draw_order(ys)) == ['YS', 'Hero', 'Tree', 'Leaf']
	hero.position.y = 400
	assert names(render.draw_order(ys)) == ['YS', 'Tree', 'Leaf', 'Hero']
}

fn test_camera_and_node_order_props_load_and_save() {
	dir := os.join_path(os.temp_dir(), 'velo_camera_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	db := assets.open(dir)!
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut l := serialize.new_loader(reg, db)
	src := '
node Main {
  y_sort = true
  node Cam { Camera { zoom = 1.5  follow = "Hero"  limit_max = [2000, 1000] } }
  node Hero { z_index = 3 }
  node HUD { Canvas { } }
}'
	n := l.instantiate_source(src, 'main.scene')!
	assert n.y_sort
	assert n.find('Hero')?.z_index == 3
	cam := n.find('Cam')?.get_component[core.Camera]()?
	assert cam.zoom == 1.5 && cam.follow == 'Hero' && cam.limit_max == core.vec2(2000, 1000)
	assert n.find('HUD')?.get_component[core.Canvas]() != none
	text := l.save_node(n)!
	assert text.contains('y_sort = true')
	assert text.contains('z_index = 3')
	assert text.contains('zoom = 1.5')
	assert !text.contains('shake')
}
