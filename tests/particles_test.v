import velo.core
import velo.render

fn emitter(ps &render.ParticleSystem) (&core.Scene, &render.ParticleSystem) {
	mut s := core.Scene.new('Test')
	mut n := core.Node.new('Fx')
	p := n.add_component(ps)
	s.add(mut n)
	return s, p
}

fn test_rate_and_burst() {
	mut s, ps := emitter(&render.ParticleSystem{
		rate:     10
		burst:    5
		lifetime: 100
	})
	s.update(0.5) // burst 5 + 0.5 s * 10/s
	assert ps.alive() == 10
	s.update(0.25) // 2.5 more: the half particle carries over
	assert ps.alive() == 12
	s.update(0.25)
	assert ps.alive() == 15
}

fn test_lifetime_and_max_particles() {
	mut s, mut ps := emitter(&render.ParticleSystem{
		rate:          0
		burst:         50
		max_particles: 20
		lifetime:      1
	})
	s.update(0.1)
	assert ps.alive() == 20
	ps.emit(5) // capped
	assert ps.alive() == 20
	s.update(1.0)
	assert ps.alive() == 0
}

fn test_one_shot_auto_destroy() {
	mut s, ps := emitter(&render.ParticleSystem{
		rate:         0
		burst:        8
		looping:      false
		duration:     0
		lifetime:     0.3
		auto_destroy: true
	})
	s.update(0.1)
	assert !ps.playing
	assert ps.alive() == 8
	assert s.find('Fx') != none
	s.update(0.3)
	assert ps.is_done()
	assert s.find('Fx') == none
}

fn test_motion_gravity_and_world_space() {
	mut s, mut ps := emitter(&render.ParticleSystem{
		rate:     0
		speed:    100
		angle:    0
		spread:   0
		lifetime: 10
		gravity:  core.vec2(0, 100)
	})
	mut node := s.find('Fx')?
	node.position = core.vec2(200, 50)
	ps.emit(1)
	assert ps.particles[0].pos == core.vec2(200, 50)
	ps.simulate(1)
	p := ps.particles[0]
	assert p.vel == core.vec2(100, 100)
	assert p.pos == core.vec2(300, 150)
	// world space: moving the node leaves the particle where it is, so it moves back in node space
	node.position = core.vec2(0, 0)
	m := ps.meshes()[0]
	cx := (m.positions[0] + m.positions[4]) / 2
	cy := (m.positions[1] + m.positions[5]) / 2
	assert cx == 300 && cy == 150
}

fn test_node_rotation_turns_emission() {
	mut s, mut ps := emitter(&render.ParticleSystem{
		rate:   0
		speed:  10
		angle:  0
		spread: 0
	})
	mut node := s.find('Fx')?
	node.rotation = 90
	ps.emit(1)
	v := ps.particles[0].vel
	assert v.x > -0.001 && v.x < 0.001
	assert v.y > 9.999 && v.y < 10.001
}

fn test_mesh_quads_and_colors() {
	mut s, mut ps := emitter(&render.ParticleSystem{
		rate:        0
		spread:      0
		speed:       0
		lifetime:    1
		start_size:  10
		end_size:    30
		start_color: core.rgba(255, 0, 0, 255)
		end_color:   core.rgba(0, 0, 255, 0)
		additive:    true
	})
	ps.emit(3)
	ps.simulate(0.5)
	meshes := ps.meshes()
	assert meshes.len == 1
	m := meshes[0]
	assert m.texture == unsafe { nil } // no texture: plain squares
	assert m.additive
	assert m.positions.len == 3 * 8
	assert m.indices.len == 3 * 6
	assert m.colors.len == 3 * 4
	assert m.colors[0] == core.rgba(128, 0, 128, 128)
	assert m.positions[4] - m.positions[0] == 20 // halfway from 10 to 30
	s.update(0)
}

fn test_stop_and_play() {
	mut s, mut ps := emitter(&render.ParticleSystem{
		rate:     0
		burst:    4
		lifetime: 0.2
	})
	s.update(0.1)
	assert ps.alive() == 4
	ps.stop()
	s.update(0.2)
	assert ps.is_done()
	ps.play()
	s.update(0.01)
	assert ps.alive() == 4
}

fn test_shapes_stay_inside() {
	_, mut ps := emitter(&render.ParticleSystem{
		rate:       0
		shape:      'box'
		shape_size: core.vec2(40, 20)
	})
	ps.emit(100)
	for p in ps.particles {
		assert p.pos.x >= -20 && p.pos.x <= 20 && p.pos.y >= -10 && p.pos.y <= 10
	}
	ps.clear()
	ps.shape = 'circle'
	ps.shape_size = core.vec2(15, 0)
	ps.emit(100)
	for p in ps.particles {
		assert p.pos.length() <= 15.001
	}
}

// the editor calls preview through render.Previewable on every component of the edited scene
fn preview_all(mut n core.Node, dt f32) {
	for mut c in n.components {
		if mut c is render.Previewable {
			c.preview(dt)
		}
	}
}

fn test_preview_keeps_saved_fields_and_replays() {
	mut s, ps := emitter(&render.ParticleSystem{
		rate:         0
		burst:        6
		looping:      false
		duration:     0
		lifetime:     0.2
		auto_destroy: true
	})
	mut node := s.find('Fx')?
	preview_all(mut node, 0.05)
	assert ps.alive() == 6
	for _ in 0 .. 5 {
		preview_all(mut node, 0.1)
	}
	// particles died: still playing, node not destroyed
	assert ps.alive() == 0
	assert ps.playing
	assert !node.destroyed
	// after a short pause the one-shot effect plays again
	for _ in 0 .. 6 {
		preview_all(mut node, 0.1)
	}
	assert ps.alive() == 6
}

fn test_preview_looping_emits() {
	mut s, ps := emitter(&render.ParticleSystem{
		rate:     20
		lifetime: 5
	})
	mut node := s.find('Fx')?
	preview_all(mut node, 0.5)
	assert ps.alive() == 10
}
