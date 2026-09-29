module main

import math
import rand
import velo.core
import velo.assets
import velo.render

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

// Pickup — when the player touches it: add score, spawn an effect, then destroy itself.
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
		for i in 0 .. 6 {
			mut fx := make_sparkle(p.effect, me, f32(i) * 60)
			world.add_child(mut fx)
		}
	}
	p.node.destroy()
}

// make_sparkle — a "prefab built in code": handy for small effects, type-checked by the compiler.
fn make_sparkle(tex assets.AssetRef[assets.Texture], at core.Vec2, angle f32) &core.Node {
	mut n := core.Node.new('Sparkle')
		.with(&render.Sprite{ texture: tex, size: core.vec2(18, 18) })
		.with(&FadeAway{ duration: 0.5, direction: angle })
	n.position = at
	return n
}

// FadeAway — flies outward, fades out, then destroys itself.
pub struct FadeAway {
	core.Component
pub mut:
	duration  f32 = 0.5
	direction f32 // degrees
	distance  f32 = 40
	t         f32       @[hide]
	origin    core.Vec2 @[hide]
}

pub fn (mut f FadeAway) start() {
	f.origin = f.node.position
}

pub fn (mut f FadeAway) update(dt f32) {
	f.t += dt
	k := if f.duration > 0 { f.t / f.duration } else { 1 }
	if k >= 1 {
		f.node.destroy()
		return
	}
	rad := f.direction * math.pi / 180
	f.node.position = f.origin + core.vec2(f32(math.cos(rad)), f32(math.sin(rad))).mul(f.distance * k)
	f.node.rotation += 360 * dt
	if mut s := f.node.get_component[render.Sprite]() {
		s.color.a = u8(255 * (1 - k))
	}
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
		coin.position = core.vec2(rand.f32_in_range(s.area_min.x, s.area_max.x) or { 0 },
			rand.f32_in_range(s.area_min.y, s.area_max.y) or { 0 })
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
}

fn (mut b ScoreBoard) refresh() {
	if mut label := b.node.get_component[render.Label]() {
		label.text = '${b.prefix}${b.score}'
	}
}
