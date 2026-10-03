import math
import velo.assets
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

// ---------- Gradient, easing, sheet animation, alignment, trails, presets ----------

// one particle, frozen at progress `k` of its life (speed 0, no gravity)
fn at_progress(ps &render.ParticleSystem, k f32) (&core.Scene, &render.ParticleSystem) {
	mut s, mut p := emitter(ps)
	p.playing = false
	p.emit(1)
	s.update(k * p.lifetime)
	return s, p
}

fn test_mid_color_gradient() {
	base := render.ParticleSystem{
		rate:          0
		lifetime:      1
		speed:         0
		start_color:   core.rgba(0, 0, 0, 255)
		mid_color:     core.rgba(200, 100, 0, 255)
		end_color:     core.rgba(0, 0, 0, 0)
		use_mid_color: true
		mid_time:      0.5
	}
	mut a := base
	_, pa := at_progress(&a, 0.5)
	assert pa.meshes()[0].colors[0] == core.rgba(200, 100, 0, 255) // exactly the mid color at mid_time
	mut b := base
	_, pb := at_progress(&b, 0.25)
	c := pb.meshes()[0].colors[0]
	assert c.r > 90 && c.r < 110 // half way from the start to the mid color
	mut off := base
	off.use_mid_color = false
	_, po := at_progress(&off, 0.5)
	assert po.meshes()[0].colors[0].r < 5 // start -> end only: both are black
}

fn test_size_ease_changes_the_curve() {
	mut lin := render.ParticleSystem{
		rate:       0
		lifetime:   1
		speed:      0
		start_size: 0
		end_size:   100
	}
	mut eased := render.ParticleSystem{
		rate:       0
		lifetime:   1
		speed:      0
		start_size: 0
		end_size:   100
		size_ease:  'quad_out'
	}
	_, pl := at_progress(&lin, 0.5)
	_, pe := at_progress(&eased, 0.5)
	width := fn (ps &render.ParticleSystem) f32 {
		m := ps.meshes()[0]
		return m.positions[2] - m.positions[0] // the quad's width
	}
	assert math.abs(width(pl) - 50) < 1 // linear: half the size at half the life
	assert math.abs(width(pe) - 75) < 1 // quad_out: 1 - (1 - 0.5)^2 = 0.75 of the way
}

fn test_unknown_ease_falls_back_to_linear() {
	mut ps := render.ParticleSystem{
		rate:       0
		lifetime:   1
		speed:      0
		start_size: 0
		end_size:   100
		size_ease:  'wobbly'
	}
	_, p := at_progress(&ps, 0.5)
	m := p.meshes()[0]
	assert math.abs((m.positions[2] - m.positions[0]) - 50) < 1
}

fn test_align_to_velocity_turns_the_quad() {
	mut ps := render.ParticleSystem{
		rate:              0
		lifetime:          10
		speed:             100
		angle:             90 // moving down the screen
		spread:            0
		start_size:        10
		end_size:          10
		align_to_velocity: true
	}
	mut s, mut p := emitter(&ps)
	p.playing = false
	p.emit(1)
	s.update(0.1)
	m := p.meshes()[0]
	// the corner (-1,-1) of a quad turned 90 degrees ends up at (+h, -h) relative to the center
	cx := (m.positions[0] + m.positions[2] + m.positions[4] + m.positions[6]) / 4
	cy := (m.positions[1] + m.positions[3] + m.positions[5] + m.positions[7]) / 4
	assert near(m.positions[0] - cx, 5) && near(m.positions[1] - cy, -5)
}

fn near(a f32, b f32) bool {
	return math.abs(a - b) < 0.01
}

fn test_sheet_animation_advances_with_the_life() {
	// a texture whose frames are numbered 0..3 left to right: the uvs of the first corner reveal the frame
	tex := &assets.Texture{
		width:       40
		height:      10
		frame_width: 10
	}
	mut ps := render.ParticleSystem{
		rate:          0
		lifetime:      1
		speed:         0
		animate_sheet: true
	}
	mut s, mut p := emitter(&ps)
	p.tex = tex
	p.playing = false
	p.emit(1)
	frame_at := fn (mut s core.Scene, mut p render.ParticleSystem, dt f32) int {
		s.update(dt)
		return int(math.round(p.meshes()[0].uvs[0] * 4)) // u0 = frame / 4
	}
	assert frame_at(mut s, mut p, 0.05) == 0
	assert frame_at(mut s, mut p, 0.25) == 1 // 0.30 of the life
	assert frame_at(mut s, mut p, 0.25) == 2 // 0.55
	assert frame_at(mut s, mut p, 0.30) == 3 // 0.85
	// two cycles: runs through the sheet twice
	mut ps2 := render.ParticleSystem{
		rate:          0
		lifetime:      1
		speed:         0
		animate_sheet: true
		sheet_cycles:  2
	}
	mut s2, mut p2 := emitter(&ps2)
	p2.tex = tex
	p2.playing = false
	p2.emit(1)
	assert frame_at(mut s2, mut p2, 0.55) == 0 // 0.55 * 2 * 4 = 4.4 -> frame 0 of the second lap
}

fn test_trail_builds_a_fading_ribbon_behind_the_quads() {
	mut ps := render.ParticleSystem{
		rate:           0
		lifetime:       10
		speed:          100
		angle:          0
		spread:         0
		start_size:     10
		end_size:       10
		start_color:    core.rgba(255, 255, 255, 200)
		end_color:      core.rgba(255, 255, 255, 200)
		trail:          true
		trail_length:   5
		trail_interval: 0.1
		trail_width:    1
	}
	mut s, mut p := emitter(&ps)
	p.playing = false
	p.emit(1)
	assert p.meshes().len == 1 // no samples yet: only the quad
	for _ in 0 .. 10 {
		s.update(0.1)
	}
	ms := p.meshes()
	assert ms.len == 2 && ms[0].texture == unsafe { nil } // the ribbon first (behind), untextured
	assert ms[1].positions.len == 8 // then the particle's one quad
	ribbon := ms[0]
	// 5 samples (the newest sits on the particle, so no extra head point), two vertices each; the tail is
	// transparent and the head keeps the alpha
	assert ribbon.colors.len == 10
	assert ribbon.colors[0].a == 0 && ribbon.colors[ribbon.colors.len - 1].a == 200
	assert ribbon.indices.len == 4 * 6
	// the ribbon is as wide as the particle at the head and a point at the tail
	head_w :=
		math.abs(ribbon.positions[ribbon.positions.len - 1] - ribbon.positions[ribbon.positions.len - 3])
	tail_w := math.abs(ribbon.positions[1] - ribbon.positions[3])
	assert head_w > 9 && head_w < 11 && tail_w < 0.01
	// turning trails off drops the history
	p.trail = false
	s.update(0.1)
	assert p.meshes().len == 1
}

fn test_presets_apply_reset_and_keep_texture_and_playing() {
	mut ps := render.ParticleSystem{
		texture:     assets.ref[assets.Texture]('tex001')
		playing:     false
		rate:        7
		trail:       true
		spin:        99
		size_ease:   'back_out'
		start_color: core.rgba(1, 2, 3, 4)
	}
	_, mut p := emitter(&ps)
	assert !p.apply_preset('nope')
	assert p.rate == 7 // unchanged
	for name in render.particle_preset_names() {
		assert p.apply_preset(name)
		assert p.texture.id == 'tex001' && !p.playing // kept
	}
	assert p.apply_preset('fire')
	assert p.additive && p.use_mid_color && !p.trail && p.spin == 40 && p.size_ease == 'quad_out'
	assert p.apply_preset('sparks') // starting over: nothing of the fire is left
	assert p.trail && p.align_to_velocity && !p.use_mid_color && p.size_ease == 'linear'
		&& p.spin == 0
	assert p.apply_preset('explosion')
	assert !p.looping && p.burst > 0 && p.rate == 0
	assert p.alive() == 0 // cleared
}

fn test_presets_look_alive() {
	// every preset, played for a while, ends up with particles that have a size and a visible color
	for name in render.particle_preset_names() {
		mut s, mut p := emitter(&render.ParticleSystem{})
		assert p.apply_preset(name)
		p.play()
		for _ in 0 .. 60 {
			s.update(1.0 / 60.0)
		}
		assert p.alive() > 0 || name == 'explosion' || name == 'confetti'
		if p.alive() > 0 {
			m := p.meshes()
			assert m.len > 0 && m.last().positions.len >= 8
		}
	}
}
