module render

import math
import rand
import velo.core
import velo.assets

// Particle — one live particle. Position/velocity are in world space when the system's `world_space`
// is on (the default), otherwise in the emitting node's space.
pub struct Particle {
pub mut:
	pos        core.Vec2
	vel        core.Vec2
	age        f32
	life       f32
	size_start f32
	size_end   f32
	rotation   f32 // degrees
	spin       f32 // degrees per second
	frame      int
}

// ParticleSystem — emits, moves and draws many small sprites (sparks, smoke, dust, fire, rain...).
// Particles are born at the node (inside `shape`), fly in the `angle` direction +- `spread`,
// fall with `gravity`, and blend from start to end size/color over their lifetime.
//
//   ParticleSystem { texture = @asset("5d9a0c66")  rate = 40  angle = -90  spread = 20  gravity = [0, 200] }
//
// One-shot effects: `rate = 0`, a `burst`, `looping = false` and `auto_destroy = true` (see the demo's Pickup).
pub struct ParticleSystem {
	core.Component
pub mut:
	texture  assets.AssetRef[assets.Texture] // none = plain squares
	playing  bool = true // emitting; `stop()` / `play()`
	looping  bool = true // emit forever; false = stop after `duration` seconds
	duration f32  = 1
	rate     f32  = 20 // particles per second
	burst    int // particles emitted at once when playing starts
	// Live particle cap; emission pauses while it is reached.
	max_particles int = 500
	lifetime      f32 = 1 // seconds
	lifetime_var  f32 // +- random seconds
	speed         f32 = 100
	speed_var     f32
	angle         f32 = -90 // emission direction in degrees (0 = right, -90 = up), rotated with the node
	spread        f32 = 30  // +- degrees around `angle`
	gravity       core.Vec2 // world units / s²
	damping       f32       // fraction of the velocity lost per second (0..1+)
	// Where particles are born, around the node: 'point' | 'circle' (radius = shape_size.x) | 'box' (w, h).
	shape        string = 'point' @[choices: 'point|circle|box']
	shape_size   core.Vec2
	start_size   f32 = 16
	end_size     f32 = 16
	size_var     f32 // +- random size, added to both start and end size
	start_color  core.Color = core.white
	end_color    core.Color = core.Color{255, 255, 255, 0}
	spin         f32 // degrees per second
	spin_var     f32
	random_angle bool // start each particle at a random rotation
	random_frame bool // pick a random frame of a sprite sheet texture (frame 0 otherwise)
	// true: particles stay where they were born when the node moves (trails, smoke).
	// false: they move with the node (an aura).
	world_space  bool = true
	additive     bool // additive blending: overlapping particles brighten (fire, sparks, magic)
	auto_destroy bool // destroy the node once it stopped emitting and every particle died
	particles    []Particle      @[hide]
	elapsed      f32             @[hide] // seconds since playing started
	burst_done   bool            @[hide]
	carry        f32             @[hide] // fractional particles owed by `rate`
	tex          &assets.Texture = unsafe { nil } @[hide]
	loaded       string          @[hide]
}

pub fn (mut ps ParticleSystem) on_load() {
	ps.acquire()
}

pub fn (mut ps ParticleSystem) on_destroy() {
	ps.drop()
}

pub fn (mut ps ParticleSystem) update(dt f32) {
	ps.simulate(dt)
	if ps.playing {
		ps.step_emission(dt)
		if !ps.looping && ps.elapsed >= ps.duration {
			ps.playing = false
		}
	}
	if ps.auto_destroy && ps.is_done() && ps.node != unsafe { nil } {
		ps.node.destroy()
	}
}

// preview runs the effect in the editor (render.Previewable) without touching saved fields:
// it never stops `playing` or destroys the node, and replays one-shot effects once their particles are gone.
pub fn (mut ps ParticleSystem) preview(dt f32) {
	ps.simulate(math.min(dt, f32(0.1)))
	if !ps.playing {
		ps.particles.clear()
		ps.restart()
		return
	}
	if ps.looping || !ps.burst_done || ps.elapsed < ps.duration { // like update: the first step always emits
		ps.step_emission(dt)
	} else {
		ps.elapsed += dt
		if ps.particles.len == 0 && ps.elapsed >= ps.duration + preview_pause {
			ps.restart()
		}
	}
}

const preview_pause = f32(0.5) // seconds between replays of a one-shot effect in the editor

fn (mut ps ParticleSystem) restart() {
	ps.elapsed = 0
	ps.carry = 0
	ps.burst_done = false
}

// step_emission fires the pending burst, emits `rate` particles for `dt` and advances `elapsed`.
fn (mut ps ParticleSystem) step_emission(dt f32) {
	if !ps.burst_done {
		ps.burst_done = true
		ps.emit(ps.burst)
	}
	ps.carry += ps.rate * dt
	n := int(ps.carry)
	ps.carry -= n
	ps.emit(n)
	ps.elapsed += dt
}

// set_texture changes the particle image at runtime, managing references automatically.
pub fn (mut ps ParticleSystem) set_texture(r assets.AssetRef[assets.Texture]) {
	ps.drop()
	ps.texture = r
	ps.acquire()
}

// play (re)starts emitting from the beginning: fires the `burst` again and resets `duration`.
pub fn (mut ps ParticleSystem) play() {
	ps.playing = true
	ps.restart()
}

// stop stops emitting; live particles finish their lifetime.
pub fn (mut ps ParticleSystem) stop() {
	ps.playing = false
}

// clear removes every live particle at once.
pub fn (mut ps ParticleSystem) clear() {
	ps.particles.clear()
}

// alive: the number of live particles.
pub fn (ps &ParticleSystem) alive() int {
	return ps.particles.len
}

// is_done: not emitting and no particle left.
pub fn (ps &ParticleSystem) is_done() bool {
	return !ps.playing && ps.particles.len == 0
}

// emit spawns `count` particles right now (up to `max_particles`), whether playing or not.
pub fn (mut ps ParticleSystem) emit(count int) {
	n := math.min(count, ps.max_particles - ps.particles.len)
	if n <= 0 {
		return
	}
	m := if ps.world_space && ps.node != unsafe { nil } {
		ps.node.world_matrix()
	} else {
		core.Affine2.identity()
	}
	frames := if ps.random_frame && ps.tex != unsafe { nil } { ps.tex.frame_count() } else { 1 }
	for _ in 0 .. n {
		dir := f64(ps.angle + ps.spread * signed_rand()) * math.pi / 180
		v := core.vec2(f32(math.cos(dir)), f32(math.sin(dir))).mul(ps.speed +
			ps.speed_var * signed_rand())
		p := ps.spawn_point()
		ds := ps.size_var * signed_rand()
		ps.particles << Particle{
			pos:        m.apply(p)
			vel:        direction(m, v)
			life:       math.max(ps.lifetime + ps.lifetime_var * signed_rand(), f32(0.01))
			size_start: math.max(ps.start_size + ds, 0)
			size_end:   math.max(ps.end_size + ds, 0)
			rotation:   if ps.random_angle { rand.f32() * 360 } else { 0 }
			spin:       ps.spin + ps.spin_var * signed_rand()
			frame:      if frames > 1 { rand.intn(frames) or { 0 } } else { 0 }
		}
	}
}

// simulate ages and moves the live particles by `dt` seconds, dropping the dead ones (order is kept).
pub fn (mut ps ParticleSystem) simulate(dt f32) {
	keep := if ps.damping > 0 { math.max(1 - ps.damping * dt, 0) } else { f32(1) }
	mut j := 0
	for i in 0 .. ps.particles.len {
		mut p := ps.particles[i]
		p.age += dt
		if p.age >= p.life {
			continue
		}
		p.vel = (p.vel + ps.gravity.mul(dt)).mul(keep)
		p.pos = p.pos + p.vel.mul(dt)
		p.rotation += p.spin * dt
		ps.particles[j] = p
		j++
	}
	ps.particles.trim(j)
}

fn (ps &ParticleSystem) spawn_point() core.Vec2 {
	match ps.shape {
		'circle' {
			a := rand.f32() * 2 * math.pi
			r := ps.shape_size.x * f32(math.sqrt(rand.f32())) // uniform over the disc
			return core.vec2(f32(math.cos(a)) * r, f32(math.sin(a)) * r)
		}
		'box' {
			return core.vec2(ps.shape_size.x * signed_rand() / 2,
				ps.shape_size.y * signed_rand() / 2)
		}
		else {
			return core.Vec2{}
		}
	}
}

// direction maps a velocity through the node's rotation and flips, keeping its length.
fn direction(m core.Affine2, v core.Vec2) core.Vec2 {
	d := m.apply(v) - m.position()
	return d.normalized().mul(v.length())
}

fn signed_rand() f32 {
	return rand.f32() * 2 - 1
}

// meshes is what the renderer draws (MeshDrawable): one quad per particle, in one draw call.
pub fn (ps &ParticleSystem) meshes() []TexturedMesh {
	if ps.particles.len == 0 {
		return []
	}
	// World-space particles are brought back into node space; the renderer then applies the node matrix.
	to_node := if ps.world_space && ps.node != unsafe { nil } {
		ps.node.world_matrix().inverse()
	} else {
		core.Affine2.identity()
	}
	tex := if ps.tex != unsafe { nil } && ps.tex.width > 0 && ps.tex.height > 0 {
		ps.tex
	} else {
		&assets.Texture(unsafe { nil })
	}
	textured := tex != unsafe { nil }
	n := ps.particles.len
	mut positions := []f32{cap: n * 8}
	mut uvs := []f32{cap: if textured { n * 8 } else { 0 }}
	mut colors := []core.Color{cap: n * 4}
	mut indices := []int{cap: n * 6}
	for i, p in ps.particles {
		k := p.age / p.life
		h := (p.size_start + (p.size_end - p.size_start) * k) / 2
		col := lerp_color(ps.start_color, ps.end_color, k)
		quad := core.Affine2.trs(p.pos, p.rotation, core.vec2(h, h))
		for c in [core.vec2(-1, -1), core.vec2(1, -1), core.vec2(1, 1),
			core.vec2(-1, 1)] {
			q := to_node.apply(quad.apply(c))
			positions << q.x
			positions << q.y
			colors << col
		}
		if textured {
			fx, fy, fw, fh := ps.tex.frame_rect(p.frame)
			u0, v0 := f32(fx) / ps.tex.width, f32(fy) / ps.tex.height
			u1, v1 := f32(fx + fw) / ps.tex.width, f32(fy + fh) / ps.tex.height
			uvs << [u0, v0, u1, v0, u1, v1, u0, v1]
		}
		b := i * 4
		indices << [b, b + 1, b + 2, b, b + 2, b + 3]
	}
	return [
		TexturedMesh{
			texture:   tex
			positions: positions
			uvs:       uvs
			indices:   indices
			colors:    colors
			additive:  ps.additive
		},
	]
}

// debug_outline shows the emission shape in debug mode (F1) and in the editor, where particles do not run.
pub fn (ps &ParticleSystem) debug_outline() []core.Vec2 {
	match ps.shape {
		'circle' {
			r := math.max(ps.shape_size.x, 1)
			return []core.Vec2{len: 24, init: core.vec2(f32(math.cos(f64(index) * math.pi / 12)) * r,
				f32(math.sin(f64(index) * math.pi / 12)) * r)}
		}
		'box' {
			w, h := ps.shape_size.x / 2, ps.shape_size.y / 2
			return [core.vec2(-w, -h), core.vec2(w, -h), core.vec2(w, h),
				core.vec2(-w, h)]
		}
		else {
			return [core.vec2(0, -4), core.vec2(4, 0), core.vec2(0, 4),
				core.vec2(-4, 0)]
		}
	}
}

pub fn (ps &ParticleSystem) debug_color() core.Color {
	return core.rgba(255, 150, 40, 200)
}

fn lerp_color(a core.Color, b core.Color, t f32) core.Color {
	return core.Color{lerp_u8(a.r, b.r, t), lerp_u8(a.g, b.g, t), lerp_u8(a.b, b.b, t), lerp_u8(a.a,
		b.a, t)}
}

fn lerp_u8(a u8, b u8, t f32) u8 {
	return u8(f32(a) + (f32(b) - f32(a)) * t + 0.5)
}

fn (mut ps ParticleSystem) acquire() {
	if !ps.texture.is_set() || ps.node == unsafe { nil } || ps.node.scene == unsafe { nil } {
		return
	}
	mut db := ps.node.scene.assets
	if db == unsafe { nil } || ps.loaded == ps.texture.id {
		return
	}
	ps.tex = db.get(ps.texture) or {
		eprintln('[ParticleSystem] ${ps.node.path()}: ${err}')
		return
	}
	ps.loaded = ps.texture.id
}

fn (mut ps ParticleSystem) drop() {
	if ps.loaded == '' || ps.node == unsafe { nil } || ps.node.scene == unsafe { nil } {
		return
	}
	mut db := ps.node.scene.assets
	if db != unsafe { nil } {
		db.release(ps.loaded)
	}
	ps.loaded = ''
	ps.tex = unsafe { nil }
}
