module main

import math
import rand
import velo.core
import velo.assets
import velo.render
import velo.audio

// Bob — bobs up and down.
pub struct Bob {
	core.Component
pub mut:
	amplitude f32 = 4
	speed     f32 = 3
	base_y    f32 @[hide]
	phase     f32 @[hide]
}

pub fn (mut b Bob) start() {
	b.base_y = b.node.position.y
	b.phase = b.node.position.x * 0.05
}

pub fn (mut b Bob) update(dt f32) {
	t := f32(b.scene().time)
	b.node.position.y = b.base_y + f32(math.sin(t * b.speed + b.phase)) * b.amplitude
}

// Pickup — when the player touches it: add score, spawn an effect, then pops (tween) and destroys itself.
pub struct Pickup {
	core.Component
pub mut:
	radius f32    = 28
	value  int    = 1
	target string = 'World/Player'
	effect assets.AssetRef[assets.Texture] // image for the sparkle effect
}

pub fn (mut p Pickup) update(dt f32) {
	player := p.scene().find(p.target) or { return }
	me := p.node.world_position()
	reach := p.radius * p.node.world_matrix().scale().x
	if me.distance(player.world_position()) > reach {
		return
	}
	mut sc := p.scene()
	if score_node := sc.find('HUD/Score') {
		if mut board := score_node.get_component[ScoreBoard]() {
			board.add(p.value)
		}
	}
	if log_node := sc.find('HUD/Log') {
		if mut log := log_node.get_component[PickupLog]() {
			log.add('+${p.value}  ${p.node.name}')
		}
	}
	if p.effect.is_set() {
		mut world := sc.find('World') or { sc.root }
		mut fx := make_sparkle(p.effect, me)
		world.add_child(mut fx)
	}
	if sfx_node := sc.find('Audio/Coin') {
		if mut sfx := sfx_node.get_component[audio.AudioSource]() {
			sfx.pitch = if p.value >= 10 { 0.75 } else { 0.95 + rand.f32() * 0.1 } // big coins sound deeper
			sfx.play_one_shot() // overlaps when coins are picked up quickly
		}
	}
	if p.value >= 10 {
		if mut cam := sc.active_camera() {
			cam.shake(6, 0.3) // big coins give a little kick
		}
	}
	// pop: stop counting and bobbing, grow and fade out, then go away
	p.enabled = false
	if mut bob := p.node.get_component[Bob]() {
		bob.enabled = false
	}
	node := p.node
	grow := p.node.scale.mul(1.8)
	render.fade_to(mut p.node, 0, 0.25, .quad_in)
	p.node.tween().scale_to(grow, 0.25, .back_out).call(fn [node] () {
		mut n := unsafe { node }
		n.destroy()
	})
}

// make_sparkle — a "prefab built in code": handy for small effects, type-checked by the compiler.
// A one-shot particle burst that removes its node once the last particle is gone.
fn make_sparkle(tex assets.AssetRef[assets.Texture], at core.Vec2) &core.Node {
	mut n := core.Node.new('Sparkle').with(&render.ParticleSystem{
		texture:      tex
		rate:         0
		burst:        14
		looping:      false
		duration:     0
		lifetime:     0.45
		lifetime_var: 0.15
		speed:        110
		speed_var:    40
		spread:       180
		damping:      3
		start_size:   18
		end_size:     6
		spin:         360
		random_angle: true
		additive:     true
		auto_destroy: true
	})
	n.position = at
	n.z_index = 1 // over the y-sorted World (trees, the player)
	return n
}

// CoinSpawner — creates coins from a prefab at runtime. Press R to scatter more.
pub struct CoinSpawner {
	core.Component
pub mut:
	prefab   assets.AssetRef[assets.SceneAsset]
	count    int       = 8
	area_min core.Vec2 = core.Vec2{50, 50}
	area_max core.Vec2 = core.Vec2{900, 500}
}

pub fn (mut s CoinSpawner) start() {
	s.spawn()
}

pub fn (mut s CoinSpawner) update(dt f32) {
	if s.input().was_pressed(.r) {
		s.spawn()
	}
}

fn (mut s CoinSpawner) spawn() {
	mut sc := s.scene()
	for _ in 0 .. s.count {
		mut coin := sc.instantiate(s.prefab.id, mut s.node) or {
			eprintln('[CoinSpawner] ${err}')
			return
		}
		coin.position = core.vec2(rand.f32_in_range(s.area_min.x, s.area_max.x) or { 0 }, rand.f32_in_range(s.area_min.y,
			s.area_max.y) or { 0 })
	}
}

// ScoreBoard — keeps the score and updates the Label on the same node.
pub struct ScoreBoard {
	core.Component
pub mut:
	prefix string = 'Coin: '
	score  int
}

pub fn (mut b ScoreBoard) start() {
	b.refresh()
}

pub fn (mut b ScoreBoard) add(v int) {
	b.score += v
	b.refresh()
	// a little bounce on every point
	b.node.kill_tweens()
	b.node.scale = core.vec2(1, 1)
	b.node.tween().scale_to(core.vec2(1.3, 1.3), 0.07, .quad_out).scale_to(core.vec2(1, 1), 0.3,
		.back_out)
}

fn (mut b ScoreBoard) refresh() {
	if mut label := b.node.get_component[render.Label]() {
		label.text = '${b.prefix}${b.score}'
	}
}
