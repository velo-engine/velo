module render

import velo.core

// Ready-made looks for a ParticleSystem. `ps.apply_preset('fire')` resets the emitter's settings to their defaults and
// then sets the ones of the effect; the texture, and whether it is playing, stay as they were. Without a texture the
// particles are plain squares, which suits most of them (fire, sparks, magic look best additive; give smoke and
// dust a soft round texture). The editor's Inspector has a button for each.
//
//   fire  smoke  sparks  explosion  rain  snow  magic  dust  confetti  fountain

pub fn particle_preset_names() []string {
	return ['fire', 'smoke', 'sparks', 'explosion', 'rain', 'snow', 'magic', 'dust', 'confetti',
		'fountain']
}

// reset_fields puts every saved setting back to its default (not the texture, not `playing`).
fn (mut ps ParticleSystem) reset_fields() {
	d := ParticleSystem{}
	playing := ps.playing
	$for f in ParticleSystem.fields {
		$if f.typ is f32 {
			if 'hide' !in f.attrs {
				ps.$(f.name) = d.$(f.name)
			}
		} $else $if f.typ is int {
			if 'hide' !in f.attrs {
				ps.$(f.name) = d.$(f.name)
			}
		} $else $if f.typ is bool {
			if 'hide' !in f.attrs {
				ps.$(f.name) = d.$(f.name)
			}
		} $else $if f.typ is string {
			if 'hide' !in f.attrs {
				ps.$(f.name) = d.$(f.name)
			}
		} $else $if f.typ is core.Vec2 {
			if 'hide' !in f.attrs {
				ps.$(f.name) = d.$(f.name)
			}
		} $else $if f.typ is core.Color {
			if 'hide' !in f.attrs {
				ps.$(f.name) = d.$(f.name)
			}
		}
	}
	ps.playing = playing
}

// apply_preset sets the emitter up for a named effect (see particle_preset_names). false: no such preset
// (nothing changes). Live particles are cleared so the new look shows at once.
pub fn (mut ps ParticleSystem) apply_preset(name string) bool {
	if name !in particle_preset_names() {
		return false
	}
	ps.reset_fields()
	rgba := core.rgba
	match name {
		'fire' {
			ps.rate = 60
			ps.lifetime = 0.8
			ps.lifetime_var = 0.3
			ps.speed = 60
			ps.speed_var = 20
			ps.angle = -90
			ps.spread = 14
			ps.gravity = core.vec2(0, -60)
			ps.shape = 'circle'
			ps.shape_size = core.vec2(14, 0)
			ps.start_size = 26
			ps.end_size = 4
			ps.size_var = 5
			ps.start_color = rgba(255, 235, 130, 255)
			ps.use_mid_color = true
			ps.mid_color = rgba(255, 110, 20, 210)
			ps.mid_time = 0.45
			ps.end_color = rgba(70, 20, 10, 0)
			ps.size_ease = 'quad_out'
			ps.spin = 40
			ps.spin_var = 60
			ps.random_angle = true
			ps.additive = true
		}
		'smoke' {
			ps.rate = 14
			ps.lifetime = 2.4
			ps.lifetime_var = 0.6
			ps.speed = 30
			ps.speed_var = 10
			ps.angle = -90
			ps.spread = 18
			ps.gravity = core.vec2(0, -25)
			ps.damping = 0.3
			ps.start_size = 18
			ps.end_size = 64
			ps.start_color = rgba(170, 170, 170, 0)
			ps.use_mid_color = true
			ps.mid_color = rgba(150, 150, 150, 150)
			ps.mid_time = 0.25
			ps.end_color = rgba(110, 110, 110, 0)
			ps.spin = 20
			ps.spin_var = 20
			ps.random_angle = true
		}
		'sparks' {
			ps.rate = 40
			ps.lifetime = 0.6
			ps.lifetime_var = 0.25
			ps.speed = 260
			ps.speed_var = 120
			ps.angle = -90
			ps.spread = 70
			ps.gravity = core.vec2(0, 500)
			ps.start_size = 6
			ps.end_size = 2
			ps.start_color = rgba(255, 240, 160, 255)
			ps.end_color = rgba(255, 110, 20, 0)
			ps.align_to_velocity = true
			ps.trail = true
			ps.trail_length = 6
			ps.trail_interval = 0.02
			ps.trail_width = 0.5
			ps.additive = true
		}
		'explosion' {
			ps.rate = 0
			ps.burst = 60
			ps.looping = false
			ps.duration = 0.1
			ps.lifetime = 0.7
			ps.lifetime_var = 0.3
			ps.speed = 220
			ps.speed_var = 110
			ps.angle = 0
			ps.spread = 180
			ps.damping = 1.6
			ps.start_size = 26
			ps.end_size = 4
			ps.size_var = 6
			ps.start_color = rgba(255, 240, 150, 255)
			ps.use_mid_color = true
			ps.mid_color = rgba(255, 120, 30, 230)
			ps.mid_time = 0.35
			ps.end_color = rgba(60, 30, 30, 0)
			ps.size_ease = 'quad_out'
			ps.random_angle = true
			ps.spin_var = 200
			ps.additive = true
		}
		'rain' {
			ps.rate = 150
			ps.lifetime = 1.2
			ps.speed = 600
			ps.speed_var = 100
			ps.angle = 100
			ps.spread = 3
			ps.shape = 'box'
			ps.shape_size = core.vec2(960, 0)
			ps.max_particles = 800
			ps.start_size = 4
			ps.end_size = 4
			ps.start_color = rgba(170, 200, 255, 200)
			ps.end_color = rgba(170, 200, 255, 200)
			ps.align_to_velocity = true
			ps.trail = true
			ps.trail_length = 4
			ps.trail_interval = 0.012
			ps.trail_width = 1
		}
		'snow' {
			ps.rate = 40
			ps.lifetime = 6
			ps.speed = 30
			ps.speed_var = 15
			ps.angle = 90
			ps.spread = 40
			ps.gravity = core.vec2(0, 10)
			ps.shape = 'box'
			ps.shape_size = core.vec2(960, 0)
			ps.max_particles = 400
			ps.start_size = 6
			ps.end_size = 5
			ps.size_var = 3
			ps.start_color = rgba(255, 255, 255, 220)
			ps.use_mid_color = true
			ps.mid_color = rgba(255, 255, 255, 220)
			ps.mid_time = 0.8
			ps.end_color = rgba(255, 255, 255, 0)
		}
		'magic' {
			ps.rate = 35
			ps.lifetime = 1.2
			ps.speed = 50
			ps.speed_var = 20
			ps.angle = -90
			ps.spread = 180
			ps.gravity = core.vec2(0, -30)
			ps.start_size = 12
			ps.end_size = 2
			ps.start_color = rgba(170, 130, 255, 255)
			ps.end_color = rgba(80, 200, 255, 0)
			ps.spin = 90
			ps.random_angle = true
			ps.trail = true
			ps.trail_length = 8
			ps.trail_interval = 0.03
			ps.trail_width = 0.6
			ps.additive = true
		}
		'dust' {
			ps.rate = 10
			ps.lifetime = 1.5
			ps.lifetime_var = 0.4
			ps.speed = 20
			ps.speed_var = 15
			ps.angle = -90
			ps.spread = 180
			ps.gravity = core.vec2(0, -5)
			ps.shape = 'circle'
			ps.shape_size = core.vec2(30, 0)
			ps.start_size = 8
			ps.end_size = 22
			ps.start_color = rgba(190, 170, 140, 120)
			ps.end_color = rgba(190, 170, 140, 0)
		}
		'confetti' {
			ps.rate = 0
			ps.burst = 50
			ps.looping = false
			ps.duration = 0.1
			ps.lifetime = 2.2
			ps.lifetime_var = 0.5
			ps.speed = 330
			ps.speed_var = 140
			ps.angle = -90
			ps.spread = 55
			ps.gravity = core.vec2(0, 420)
			ps.damping = 0.4
			ps.start_size = 9
			ps.end_size = 9
			ps.size_var = 3
			ps.start_color = rgba(255, 215, 80, 255)
			ps.use_mid_color = true
			ps.mid_color = rgba(255, 215, 80, 255)
			ps.mid_time = 0.8
			ps.end_color = rgba(255, 215, 80, 0)
			ps.spin = 360
			ps.spin_var = 300
			ps.random_angle = true
		}
		'fountain' {
			ps.rate = 90
			ps.lifetime = 1.6
			ps.speed = 330
			ps.speed_var = 40
			ps.angle = -90
			ps.spread = 8
			ps.gravity = core.vec2(0, 600)
			ps.start_size = 6
			ps.end_size = 4
			ps.start_color = rgba(150, 200, 255, 230)
			ps.end_color = rgba(120, 170, 255, 0)
		}
		else {}
	}

	ps.clear()
	ps.restart()
	return true
}
