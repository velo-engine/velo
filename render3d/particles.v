module render3d

import math
import rand
import velo.core

// ---------- Particles ----------

struct Particle3D {
mut:
	pos   core.Vec3
	vel   core.Vec3
	age   f32
	life  f32
	size  f32 // size multiplier (random per particle)
	rot   f32 // degrees
	spin  f32
	shade f32 // 0..1, picks a color between color_start and color_alt
}

// Particles3D — camera-facing sprites emitted from the node (fire, smoke, sparks, magic, dust, weather).
// `preset` fills in the look; any field set in the scene (or code) to something other than its default wins.
pub struct Particles3D {
	core.Component
pub mut:
	preset          string = 'none' @[choices: 'none|fire|smoke|sparkle|magic|dust|explosion|fireflies|portal|snow|rain|heal|embers']
	emitting        bool   = true
	rate            f32    = 20 // particles per second
	burst           int // emitted at once when the component starts (and by `emit`)
	lifetime        f32       = 1
	lifetime_spread f32       = 0.3 // 0..1: random shortening of each particle's life
	speed           f32       = 1
	speed_spread    f32       = 0.3
	direction       core.Vec3 = core.Vec3{0, 1, 0}
	spread          f32       = 25 // degrees around `direction` (180 = every way)
	gravity         core.Vec3
	drag            f32 // velocity lost per second (0..)
	size_start      f32 = 0.3
	size_end        f32
	size_spread     f32        = 0.3
	color_start     core.Color = core.white
	color_alt       core.Color = core.white // each particle starts between color_start and color_alt
	color_end       core.Color = core.rgba(255, 255, 255, 0)
	shape           string     = 'soft' @[choices: 'soft|spark|star|ring|smoke|square']
	emit_shape      string     = 'point' @[choices: 'point|sphere|ring|box|disc']
	radius          f32        = 0.5
	box             core.Vec3  = core.Vec3{1, 1, 1}
	additive        bool       = true
	spin            f32 // degrees per second, random direction
	max_particles   int = 400
	// Move with the node (a torch carried around) instead of staying where they were emitted (a smoke trail).
	local bool
	// Emit from `offset` relative to the node.
	offset    core.Vec3
	particles []Particle3D @[hide]
	acc       f32          @[hide]
	applied   bool         @[hide]
	origin    core.Mat4 = core.Mat4.identity()    @[hide]
}

pub fn (mut p Particles3D) on_load() {
	p.apply_preset()
}

pub fn (mut p Particles3D) start() {
	p.origin = world_matrix(p.node)
	if p.burst > 0 {
		p.emit(p.burst)
	}
}

// emit spawns `n` particles now (explosions, pickups, hits).
pub fn (mut p Particles3D) emit(n int) {
	p.origin = world_matrix(p.node)
	for _ in 0 .. n {
		if p.particles.len >= p.max_particles {
			break
		}
		p.particles << p.new_particle()
	}
}

fn rnd() f32 {
	return rand.f32()
}

fn rnd_sym() f32 {
	return rand.f32() * 2 - 1
}

fn random_unit() core.Vec3 {
	for {
		v := core.vec3(rnd_sym(), rnd_sym(), rnd_sym())
		l := v.length()
		if l > 0.001 && l <= 1 {
			return v.mul(1 / l)
		}
	}
	return core.vec3(0, 1, 0)
}

fn (p &Particles3D) new_particle() Particle3D {
	// position in node space
	mut lp := match p.emit_shape {
		'sphere' {
			random_unit().mul(p.radius * f32(math.cbrt(rnd())))
		}
		'ring' {
			a := rnd() * 2 * math.pi
			core.vec3(f32(math.sin(a)) * p.radius, 0, f32(math.cos(a)) * p.radius)
		}
		'disc' {
			a := rnd() * 2 * math.pi
			r := p.radius * f32(math.sqrt(rnd()))
			core.vec3(f32(math.sin(a)) * r, 0, f32(math.cos(a)) * r)
		}
		'box' {
			core.vec3(rnd_sym() * p.box.x / 2, rnd_sym() * p.box.y / 2, rnd_sym() * p.box.z / 2)
		}
		else {
			core.Vec3{}
		}
	}

	lp = lp + p.offset
	// direction inside the spread cone
	d := p.direction.normalized()
	mut dir := d
	if p.spread > 0 {
		cos_max := f32(math.cos(math.min(p.spread, 180) * math.pi / 180))
		z := cos_max + (1 - cos_max) * rnd()
		a := rnd() * 2 * math.pi
		sr := f32(math.sqrt(math.max(f32(0), 1 - z * z)))
		// basis around d
		up := if math.abs(d.y) < 0.99 { core.vec3(0, 1, 0) } else { core.vec3(1, 0, 0) }
		t := d.cross(up).normalized()
		b := d.cross(t)
		dir = t.mul(sr * f32(math.cos(a))) + b.mul(sr * f32(math.sin(a))) + d.mul(z)
	}
	sp := p.speed * (1 + p.speed_spread * rnd_sym())
	mut pos := lp
	mut vel := dir.mul(sp)
	if !p.local {
		pos = p.origin.transform_point(lp)
		vel = p.origin.transform_dir(vel)
	}
	return Particle3D{
		pos:   pos
		vel:   vel
		life:  p.lifetime * (1 - p.lifetime_spread * rnd())
		size:  1 + p.size_spread * rnd_sym()
		rot:   rnd() * 360
		spin:  p.spin * rnd_sym()
		shade: rnd()
	}
}

pub fn (mut p Particles3D) update(dt f32) {
	p.origin = world_matrix(p.node)
	if p.emitting && p.rate > 0 {
		p.acc += p.rate * dt
		for p.acc >= 1 {
			p.acc -= 1
			if p.particles.len < p.max_particles {
				p.particles << p.new_particle()
			}
		}
	}
	damp := f32(math.max(f32(0), 1 - p.drag * dt))
	mut j := 0
	for i in 0 .. p.particles.len {
		mut q := p.particles[i]
		q.age += dt
		if q.age >= q.life {
			continue
		}
		q.vel = (q.vel + p.gravity.mul(dt)).mul(damp)
		q.pos = q.pos + q.vel.mul(dt)
		q.rot += q.spin * dt
		p.particles[j] = q
		j++
	}
	p.particles.trim(j)
}

pub fn (p &Particles3D) count() int {
	return p.particles.len
}

// ---------- Presets ----------

// preset_particles: the look of a named preset (fields at their defaults stay untouched by `apply_preset`).
pub fn preset_particles(name string) ?Particles3D {
	return match name {
		'fire' {
			Particles3D{
				rate:        60
				lifetime:    0.9
				speed:       1.2
				spread:      12
				emit_shape:  'disc'
				radius:      0.18
				size_start:  0.55
				size_end:    0.05
				color_start: core.rgba(255, 210, 90, 255)
				color_alt:   core.rgba(255, 120, 30, 255)
				color_end:   core.rgba(200, 30, 10, 0)
				gravity:     core.vec3(0, 0.8, 0)
				spin:        90
			}
		}
		'smoke' {
			Particles3D{
				rate:        12
				lifetime:    2.5
				speed:       0.8
				spread:      15
				size_start:  0.4
				size_end:    1.6
				shape:       'smoke'
				additive:    false
				color_start: core.rgba(90, 90, 95, 150)
				color_alt:   core.rgba(60, 60, 65, 150)
				color_end:   core.rgba(140, 140, 150, 0)
				drag:        0.5
				spin:        40
			}
		}
		'sparkle' {
			Particles3D{
				rate:        25
				lifetime:    0.8
				speed:       0.6
				spread:      180
				emit_shape:  'sphere'
				radius:      0.4
				size_start:  0.25
				size_end:    0
				shape:       'star'
				color_start: core.rgba(255, 250, 200, 255)
				color_alt:   core.rgba(255, 220, 90, 255)
				color_end:   core.rgba(255, 200, 60, 0)
				spin:        180
			}
		}
		'magic' {
			Particles3D{
				rate:        50
				lifetime:    1.4
				speed:       0.5
				spread:      30
				emit_shape:  'ring'
				radius:      0.7
				size_start:  0.22
				size_end:    0
				shape:       'spark'
				color_start: core.rgba(120, 200, 255, 255)
				color_alt:   core.rgba(200, 120, 255, 255)
				color_end:   core.rgba(80, 60, 255, 0)
				gravity:     core.vec3(0, 0.6, 0)
			}
		}
		'dust' {
			Particles3D{
				rate:        0
				lifetime:    0.7
				speed:       0.8
				spread:      70
				size_start:  0.25
				size_end:    0.7
				shape:       'smoke'
				additive:    false
				color_start: core.rgba(190, 170, 140, 150)
				color_alt:   core.rgba(160, 140, 110, 150)
				color_end:   core.rgba(200, 185, 160, 0)
				drag:        3
				gravity:     core.vec3(0, -0.5, 0)
			}
		}
		'explosion' {
			Particles3D{
				rate:          0
				burst:         80
				emitting:      false
				lifetime:      0.9
				speed:         6
				speed_spread:  0.6
				spread:        180
				size_start:    0.6
				size_end:      0.05
				shape:         'spark'
				color_start:   core.rgba(255, 230, 140, 255)
				color_alt:     core.rgba(255, 110, 30, 255)
				color_end:     core.rgba(120, 20, 0, 0)
				drag:          2.5
				gravity:       core.vec3(0, -4, 0)
				max_particles: 200
			}
		}
		'fireflies' {
			Particles3D{
				rate:        6
				lifetime:    5
				speed:       0.3
				spread:      180
				emit_shape:  'box'
				box:         core.vec3(16, 2, 16)
				offset:      core.vec3(0, 1.2, 0)
				size_start:  0.12
				size_end:    0.12
				shape:       'spark'
				color_start: core.rgba(210, 255, 120, 255)
				color_alt:   core.rgba(255, 240, 120, 255)
				color_end:   core.rgba(160, 255, 80, 0)
			}
		}
		'portal' {
			Particles3D{
				rate:        70
				lifetime:    1.2
				speed:       0.2
				spread:      180
				emit_shape:  'ring'
				radius:      1.1
				size_start:  0.2
				size_end:    0
				shape:       'spark'
				color_start: core.rgba(255, 120, 230, 255)
				color_alt:   core.rgba(140, 90, 255, 255)
				color_end:   core.rgba(60, 40, 200, 0)
				gravity:     core.vec3(0, 1.2, 0)
				local:       true
			}
		}
		'snow' {
			Particles3D{
				rate:          40
				lifetime:      6
				speed:         0.4
				spread:        20
				direction:     core.vec3(0, -1, 0)
				emit_shape:    'box'
				box:           core.vec3(30, 0.5, 30)
				offset:        core.vec3(0, 10, 0)
				size_start:    0.08
				size_end:      0.08
				additive:      false
				color_start:   core.rgba(255, 255, 255, 230)
				color_alt:     core.rgba(230, 240, 255, 230)
				color_end:     core.rgba(255, 255, 255, 0)
				gravity:       core.vec3(0, -0.6, 0)
				max_particles: 600
			}
		}
		'rain' {
			Particles3D{
				rate:          300
				lifetime:      0.8
				speed:         14
				spread:        2
				direction:     core.vec3(0.1, -1, 0)
				emit_shape:    'box'
				box:           core.vec3(30, 0.5, 30)
				offset:        core.vec3(0, 10, 0)
				size_start:    0.05
				size_end:      0.05
				shape:         'square'
				additive:      false
				color_start:   core.rgba(170, 190, 230, 170)
				color_alt:     core.rgba(150, 170, 210, 170)
				color_end:     core.rgba(170, 190, 230, 0)
				max_particles: 1200
			}
		}
		'heal' {
			Particles3D{
				rate:        30
				lifetime:    1.2
				speed:       1
				spread:      10
				emit_shape:  'disc'
				radius:      0.6
				size_start:  0.25
				size_end:    0
				shape:       'star'
				color_start: core.rgba(150, 255, 160, 255)
				color_alt:   core.rgba(230, 255, 140, 255)
				color_end:   core.rgba(60, 255, 120, 0)
			}
		}
		'embers' {
			Particles3D{
				rate:        14
				lifetime:    2
				speed:       1.4
				spread:      25
				emit_shape:  'disc'
				radius:      0.25
				size_start:  0.08
				size_end:    0
				shape:       'spark'
				color_start: core.rgba(255, 200, 80, 255)
				color_alt:   core.rgba(255, 120, 40, 255)
				color_end:   core.rgba(255, 60, 0, 0)
				gravity:     core.vec3(0, 0.3, 0)
				drag:        0.4
			}
		}
		else {
			none
		}
	}
}

// apply_preset copies the preset's look into every field still at its default value.
pub fn (mut p Particles3D) apply_preset() {
	if p.applied || p.preset == '' || p.preset == 'none' {
		return
	}
	p.applied = true
	pre := preset_particles(p.preset) or { return }
	def := Particles3D{}
	$for f in Particles3D.fields {
		$if f.typ is f32 {
			if p.$(f.name) == def.$(f.name) {
				p.$(f.name) = pre.$(f.name)
			}
		} $else $if f.typ is int {
			if p.$(f.name) == def.$(f.name) {
				p.$(f.name) = pre.$(f.name)
			}
		} $else $if f.typ is bool {
			if p.$(f.name) == def.$(f.name) {
				p.$(f.name) = pre.$(f.name)
			}
		} $else $if f.typ is string {
			if f.name != 'preset' && p.$(f.name) == def.$(f.name) {
				p.$(f.name) = pre.$(f.name)
			}
		} $else $if f.typ is core.Vec3 {
			if p.$(f.name) == def.$(f.name) {
				p.$(f.name) = pre.$(f.name)
			}
		} $else $if f.typ is core.Color {
			if p.$(f.name) == def.$(f.name) {
				p.$(f.name) = pre.$(f.name)
			}
		}
	}
	p.applied = true
}

// ---------- Trail ----------

struct TrailPoint {
	pos core.Vec3
	age f32
}

// Trail3D — a glowing ribbon left behind the node as it moves (dashes, swords, magic missiles).
pub struct Trail3D {
	core.Component
pub mut:
	duration     f32        = 0.4 // seconds a point stays
	width        f32        = 0.35
	color        core.Color = core.rgba(120, 200, 255, 220)
	color_end    core.Color = core.rgba(120, 80, 255, 0)
	offset       core.Vec3 // emit point relative to the node
	min_distance f32  = 0.05
	additive     bool = true
	emitting     bool = true
	points       []TrailPoint @[hide]
}

pub fn (mut t Trail3D) update(dt f32) {
	mut j := 0
	for i in 0 .. t.points.len {
		q := TrailPoint{t.points[i].pos, t.points[i].age + dt}
		if q.age < t.duration {
			t.points[j] = q
			j++
		}
	}
	t.points.trim(j)
	if !t.emitting {
		return
	}
	p := world_matrix(t.node).transform_point(t.offset)
	if t.points.len == 0 || t.points.last().pos.distance(p) >= t.min_distance {
		t.points << TrailPoint{p, 0}
	}
}
