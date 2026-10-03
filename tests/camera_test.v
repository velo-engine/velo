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

fn node_at(mut s core.Scene, name string, x f32, y f32) &core.Node {
	mut n := core.Node.new(name)
	n.position = core.vec2(x, y)
	s.add(mut n)
	return n
}

fn test_deadzone_lets_target_roam() {
	mut s, mut cam := cam_scene()
	mut p := node_at(mut s, 'P', 0, 0)
	mut c := cam.get_component[core.Camera]()?
	c.follow = 'P'
	c.deadzone = core.vec2(100, 60)
	s.update(0.016)
	assert near(cam.world_position(), core.vec2(0, 0))
	p.position = core.vec2(40, -20) // inside the 100x60 box
	s.update(0.016)
	assert near(cam.world_position(), core.vec2(0, 0))
	p.position =
		core.vec2(80, 0) // 30 beyond the box edge (x 50): the camera moves just enough to keep it on the edge
	s.update(0.016)
	assert near(cam.world_position(), core.vec2(30, 0))
	p.position = core.vec2(80, -100) // above the box too (edge y -30)
	s.update(0.016)
	assert near(cam.world_position(), core.vec2(30, -70))
}

fn test_look_ahead_leads_the_movement() {
	mut s, mut cam := cam_scene()
	mut p := node_at(mut s, 'P', 0, 0)
	mut c := cam.get_component[core.Camera]()?
	c.follow = 'P'
	c.look_ahead = 0.5
	for i in 0 .. 60 { // moving right at 200 units/s for a second
		p.position = core.vec2(f32(i + 1) * 200.0 / 60.0, 0)
		s.update(1.0 / 60.0)
	}
	lead := cam.world_position().x - p.position.x
	assert lead > 60 && lead <= 100 // approaches 200 * 0.5 = 100
	for _ in 0 .. 120 { // stops: the lead fades
		s.update(1.0 / 60.0)
	}
	assert math.abs(cam.world_position().x - p.position.x) < 3
}

fn test_zoom_to_eases_and_ends_exactly() {
	mut s, mut cam := cam_scene()
	mut c := cam.get_component[core.Camera]()?
	c.zoom_to(3, 1.0)
	s.update(0.5)
	assert c.zoom > 1.5 && c.zoom < 2.5 // sine in-out: about the middle at half time
	s.update(0.6)
	assert c.zoom == 3
	c.zoom_to(1, 0) // 0 seconds = at once
	assert c.zoom == 1
}

fn test_follow_several_targets_and_fit() {
	mut s, mut cam := cam_scene()
	node_at(mut s, 'A', 0, 0)
	node_at(mut s, 'B', 400, 0)
	mut c := cam.get_component[core.Camera]()?
	c.follow = 'A, B'
	c.zoom = 2
	s.update(0.016)
	assert near(cam.world_position(), core.vec2(200, 0)) // the middle
	assert c.fit_zoom == 0 // fit is off without a margin
	c.fit_margin = 100
	s.update(0.016)
	// the 800 px wide view must show 400 + 2 * 100 = 600 world units: zoom 800 / 600
	assert math.abs(c.fit_zoom - 800.0 / 600.0) < 0.01
	assert math.abs(c.view().zoom - c.fit_zoom) < 0.001
	// alone near each other, it zooms in only up to `zoom`
	mut b := s.find('B')?
	b.position = core.vec2(10, 0)
	s.update(0.016)
	assert c.fit_zoom == 2
}

fn test_priority_picks_camera_and_blends() {
	mut s := core.Scene.new('Test')
	s.view_size = core.vec2(800, 600)
	mut a := core.Node.new('A').with(&core.Camera{})
	a.position = core.vec2(0, 0)
	s.add(mut a)
	mut b := core.Node.new('B').with(&core.Camera{
		priority:   5
		blend_time: 1
		zoom:       2
	})
	b.position = core.vec2(1000, 0)
	b.active = false
	s.add(mut b)
	s.update(0.016)
	assert s.active_camera()?.node.name == 'A'
	assert near(s.camera_center(), core.vec2(0, 0))
	b.active = true // higher priority: takes over, blending from A's view
	s.update(0.016)
	assert s.active_camera()?.node.name == 'B'
	assert s.camera_center().x < 100 // just started: still near A
	s.update(0.5)
	mid := s.camera_center().x
	assert mid > 300 && mid < 700 // about half way
	assert s.view_matrix().apply(core.vec2(mid, 0)).x > 399 // the blended center is drawn at the screen middle
	s.update(0.6)
	assert near(s.camera_center(), core.vec2(1000, 0))
	assert s.shown_view()?.zoom == 2
	// switching back to a camera with blend_time 0 is a cut
	a.get_component[core.Camera]()?.blend_time = 0
	b.active = false
	s.update(0.016)
	assert near(s.camera_center(), core.vec2(0, 0))
}

fn test_blend_zoom_is_by_ratio_and_rotation_short_way() {
	a := core.CameraView{
		zoom:     1
		rotation: 350
	}
	b := core.CameraView{
		zoom:     4
		rotation: 10
	}
	m := core.lerp_view(a, b, 0.5)
	assert math.abs(m.zoom - 2) < 0.001
	assert math.abs(m.rotation - 360) < 0.01 // through 0, not back through 180
}

fn test_parallax_moves_layers_with_the_camera() {
	mut s, mut cam := cam_scene()
	mut far := node_at(mut s, 'Far', 100, 50)
	far.add_component(&core.Parallax{
		factor: core.vec2(0.25, 0)
	})
	mut near_n := node_at(mut s, 'Near', 0, 0)
	near_n.add_component(&core.Parallax{
		factor: core.vec2(1, 1)
	})
	cam.position = core.vec2(500, 300)
	s.update(0.016) // first apply: remembers where the camera was
	assert near(far.position, core.vec2(100, 50))
	cam.position = core.vec2(900, 300) // camera moved 400 right
	s.update(0.016)
	// the layer should look like it moved 0.25 * 400 on screen: the node shifts by (1 - 0.25) * 400
	assert near(far.position, core.vec2(100 + 300, 50))
	assert near(near_n.position, core.vec2(0, 0)) // factor 1: the world moves it, nothing added
	far.destroy()
	s.update(0)
	assert s.parallaxes.len == 1
}
