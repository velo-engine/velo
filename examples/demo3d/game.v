module main

import math
import rand
import velo.core
import velo.assets
import velo.render
import velo.render3d

// Shared — what the HUD shows about the 3D pass.
@[heap]
struct Shared {
mut:
	r3d &render3d.Renderer3D = unsafe { nil }
}

const stats = &Shared{}

fn set_renderer(r &render3d.Renderer3D) {
	unsafe {
		mut s := stats
		s.r3d = r
	}
}

// ---------- The hero ----------

// HeroController — runs relative to the camera, dashes, kicks up dust, gets knocked back by slimes.
pub struct HeroController {
	core.Component
pub mut:
	speed         f32 = 5
	dash_speed    f32 = 12
	dash_time     f32 = 0.3
	dash_cooldown f32 = 0.7
	turn_speed    f32 = 900 // degrees per second
	arena         f32 = 24  // stays within this distance of the center
	// the run clip covers about this many meters per second at speed 1 (its root motion, removed by in_place)
	clip_speed f32 = 3.6
	velocity   core.Vec3 @[hide]
	dash_left  f32       @[hide]
	cooldown   f32       @[hide]
	idle_time  f32 = -1       @[hide]
	dust_acc   f32       @[hide]
	knock      core.Vec3 @[hide]
	invuln     f32       @[hide]
	// After this many seconds without input the hero runs to the nearest orb by itself (0 = never).
	autopilot  f32 = 5
	idle_input f32 @[hide]
}

// nearest_orb: direction to the closest orb on the ground plane.
fn nearest_orb(s &core.Scene, from core.Vec3) ?core.Vec3 {
	orbs := s.find('World/Orbs')?
	mut best := f32(1e9)
	mut dir := core.Vec3{}
	for o in orbs.children {
		t := o.get_component[render3d.Transform3D]() or { continue }
		mut d := t.position - from
		d.y = 0
		if d.length() < best {
			best = d.length()
			dir = d
		}
	}
	if best > 1e8 {
		return none
	}
	return dir
}

// idle_frame: the moment of the run cycle where the feet are closest together (a standing pose for idling,
// since the model has a single clip).
fn idle_frame(sk &render3d.SkinnedModel3D) f32 {
	m := sk.data
	if m == unsafe { nil } || m.clips.len == 0 {
		return 0
	}
	lf, rf := m.bone_index('LeftFoot'), m.bone_index('RightFoot')
	if lf < 0 || rf < 0 {
		return 0
	}
	mut pose := m.rest_pose()
	mut g := []core.Mat4{}
	mut best, mut best_t := f32(1e9), f32(0)
	c := m.clips[0]
	for f in 0 .. c.frame_count() {
		t := f32(f) / c.fps
		m.sample(0, t, true, mut pose)
		m.globals(pose, mut g)
		d := g[lf].translation_part().distance(g[rf].translation_part())
		if d < best {
			best, best_t = d, t
		}
	}
	return best_t
}

pub fn (mut h HeroController) update(dt f32) {
	mut tr := render3d.transform3d(mut h.node)
	mut sk := h.node.get_component[render3d.SkinnedModel3D]() or { return }
	if h.idle_time < 0 && sk.data != unsafe { nil } {
		h.idle_time = idle_frame(sk)
	}
	inp := h.input()
	yaw := camera_yaw(h.scene())
	fwd := core.vec3(f32(math.sin(yaw)), 0, f32(math.cos(yaw)))
	right := core.vec3(-fwd.z, 0, fwd.x)
	mut want := fwd.mul(-inp.axis_y()) + right.mul(inp.axis_x())
	if want.length() > 1 {
		want = want.normalized()
	}
	if want.length() > 0.01 || inp.mouse_down {
		h.idle_input = 0
	} else {
		h.idle_input += dt
	}
	auto := h.autopilot > 0 && h.idle_input > h.autopilot
	if auto {
		if d := nearest_orb(h.scene(), tr.position) {
			want = d.normalized()
			if d.length() > 9 && h.cooldown <= 0 && rand.f32() < 0.02 {
				h.dash_left = h.dash_time
				h.cooldown = h.dash_cooldown * 3
				h.puff(14)
			}
		}
	}
	h.cooldown -= dt
	h.invuln -= dt
	if (inp.was_pressed(.space) || inp.was_pressed(.left_shift)) && h.cooldown <= 0 {
		h.dash_left = h.dash_time
		h.cooldown = h.dash_cooldown
		if want.length() < 0.1 {
			want = tr.forward()
		}
		h.puff(14)
	}
	mut speed := h.speed
	if h.dash_left > 0 {
		h.dash_left -= dt
		speed = h.dash_speed
		if want.length() < 0.1 {
			want = tr.forward()
		}
	}
	if mut trail := child_component[render3d.Trail3D](h.node, 'Trail') {
		trail.emitting = h.dash_left > 0
	}
	target := want.mul(speed)
	k := f32(math.min(f32(1), dt * if h.dash_left > 0 { f32(20) } else { f32(10) }))
	h.velocity = h.velocity.lerp(target, k)
	h.knock = h.knock.mul(f32(math.max(f32(0), 1 - dt * 6)))
	tr.position = tr.position + (h.velocity + h.knock).mul(dt)
	// stay in the arena
	flat := core.vec3(tr.position.x, 0, tr.position.z)
	if flat.length() > h.arena {
		p := flat.normalized().mul(h.arena)
		tr.position.x, tr.position.z = p.x, p.z
	}
	moving := h.velocity.length()
	if moving > 0.3 {
		tr.turn_toward(h.velocity, h.turn_speed * dt)
		sk.speed = moving / h.clip_speed
		sk.playing = true
		// footstep dust
		h.dust_acc += dt * moving
		if h.dust_acc > 1.4 {
			h.dust_acc = 0
			h.puff(2)
		}
	} else {
		// ease into the standing frame of the cycle
		sk.speed = 0
		c := sk.data
		if c != unsafe { nil } && c.clips.len > 0 && h.idle_time >= 0 {
			dur := c.clips[0].duration
			mut d := h.idle_time - (sk.time - dur * f32(int(sk.time / dur)))
			if d > dur / 2 {
				d -= dur
			} else if d < -dur / 2 {
				d += dur
			}
			sk.time += d * f32(math.min(f32(1), dt * 8))
		}
		// breathing
		tr.scale.y = 1 + f32(math.sin(h.scene().time * 2.4)) * 0.008
	}
}

fn (mut h HeroController) puff(n int) {
	if mut dust := child_component[render3d.Particles3D](h.node, 'Dust') {
		dust.emit(n)
	}
}

// hit: knocked back from `from`, flashes, and drops an orb.
pub fn (mut h HeroController) hit(from core.Vec3) {
	if h.invuln > 0 {
		return
	}
	h.invuln = 1
	tr := render3d.transform3d(mut h.node)
	mut d := tr.position - from
	d.y = 0
	h.knock = d.normalized().mul(9)
	if mut sk := h.node.get_component[render3d.SkinnedModel3D]() {
		sk.hit_flash()
	}
	mut st := h.scene().store
	st.set_int('orbs', int(math.max(0, st.get_int('orbs', 0) - 1)))
	h.puff(10)
}

fn child_component[T](n &core.Node, name string) ?&T {
	ch := n.find(name) or { return none }
	return ch.get_component[T]()
}

fn hero(s &core.Scene) ?&core.Node {
	return s.find('World/Hero')
}

fn hero_pos(s &core.Scene) ?core.Vec3 {
	h := hero(s)?
	t := h.get_component[render3d.Transform3D]()?
	return t.position
}

// ---------- Camera ----------

// FollowCamera — a third-person camera behind the target; Q/E or dragging the mouse orbit it.
pub struct FollowCamera {
	core.Component
pub mut:
	target    string = 'World/Hero'
	distance  f32    = 7
	height    f32    = 3
	yaw       f32 // degrees: 0 = looking toward +z
	smoothing f32 = 6
	orbit     f32 = 120 // degrees per second with Q/E
	look      core.Vec3 @[hide]
	last      core.Vec2 @[hide]
	ready     bool      @[hide]
}

fn camera_yaw(s &core.Scene) f32 {
	n := s.find('Camera') or { return 0 }
	c := n.get_component[FollowCamera]() or { return 0 }
	return f32(c.yaw * math.pi / 180)
}

pub fn (mut c FollowCamera) update(dt f32) {
	inp := c.input()
	c.yaw += inp.axis(.e, .q) * c.orbit * dt
	if inp.mouse_down {
		if c.ready {
			c.yaw -= (inp.mouse.x - c.last.x) * 0.3
		}
		c.last = inp.mouse
		c.ready = true
	} else {
		c.ready = false
	}
	n := c.scene().find(c.target) or { return }
	tp := render3d.world_matrix(n).translation_part()
	y := f32(c.yaw * math.pi / 180)
	back := core.vec3(-f32(math.sin(y)), 0, -f32(math.cos(y)))
	want := tp + back.mul(c.distance) + core.vec3(0, c.height, 0)
	mut tr := render3d.transform3d(mut c.node)
	k := f32(math.min(f32(1), dt * c.smoothing))
	if c.look.length() == 0 {
		tr.position = want
		c.look = tp
	}
	tr.position = tr.position.lerp(want, k)
	c.look = c.look.lerp(tp + core.vec3(0, 1.1, 0), f32(math.min(f32(1), dt * c.smoothing * 1.5)))
	// aim: yaw/pitch toward the look point (the camera looks along -z of its node)
	d := c.look - tr.position
	tr.rotation.y = f32(math.atan2(-d.x, -d.z) * 180 / math.pi)
	tr.rotation.x = f32(math.atan2(d.y, math.sqrt(d.x * d.x + d.z * d.z)) * 180 / math.pi)
	tr.rotation.z = 0
}

// ---------- Other characters ----------

// PathRunner — runs around a circle (the golden and shadow echo runners).
pub struct PathRunner {
	core.Component
pub mut:
	radius f32 = 10
	speed  f32 = 6 // meters per second; negative = clockwise
	phase  f32 // starting angle, radians
	angle  f32 @[hide]
}

pub fn (mut p PathRunner) start() {
	p.angle = p.phase
}

pub fn (mut p PathRunner) update(dt f32) {
	p.angle += p.speed / p.radius * dt
	mut tr := render3d.transform3d(mut p.node)
	tr.position = core.vec3(f32(math.sin(p.angle)) * p.radius, 0, f32(math.cos(p.angle)) * p.radius)
	s := if p.speed >= 0 { f32(1) } else { f32(-1) }
	tr.face(core.vec3(f32(math.cos(p.angle)) * s, 0, -f32(math.sin(p.angle)) * s))
}

// SlimeHop — hops with squash and stretch, chases the hero when near, bumps it on contact.
pub struct SlimeHop {
	core.Component
pub mut:
	hop_time  f32 = 0.55
	rest_time f32 = 0.45
	height    f32 = 0.9
	speed     f32 = 2.6
	sight     f32 = 9
	home      core.Vec3 @[hide]
	t         f32       @[hide]
	dir       core.Vec3 @[hide]
	airborne  bool      @[hide]
}

pub fn (mut s SlimeHop) start() {
	s.home = render3d.transform3d(mut s.node).position
	s.t = rand.f32() * s.rest_time
}

pub fn (mut s SlimeHop) update(dt f32) {
	mut tr := render3d.transform3d(mut s.node)
	body_n := s.node.find('Body') or { return }
	mut body := body_n.get_component[render3d.Transform3D]() or { return }
	s.t += dt
	cycle := s.hop_time + s.rest_time
	if s.t >= cycle {
		s.t -= cycle
		// pick the next hop: toward the hero if close, else wander around home
		mut goal := s.home + core.vec3(rand.f32() * 6 - 3, 0, rand.f32() * 6 - 3)
		if hp := hero_pos(s.scene()) {
			if hp.distance(tr.position) < s.sight {
				goal = hp
			}
		}
		s.dir = (goal - tr.position)
		s.dir.y = 0
		s.dir = s.dir.normalized()
	}
	sc := tr.scale.x
	if s.t < s.rest_time {
		// squash before jumping, recover after landing
		k := s.t / s.rest_time
		squash := f32(math.sin(k * math.pi)) * 0.25
		body.scale = core.vec3(0.9 * (1 + squash), 0.9 * (1 - squash), 0.9 * (1 + squash))
		body.position.y = 0.45 * (1 - squash)
		tr.position.y = 0
		if s.airborne {
			s.airborne = false
			if mut dust := child_component[render3d.Particles3D](s.node, 'Dust') {
				dust.emit(10)
			}
		}
	} else {
		s.airborne = true
		k := (s.t - s.rest_time) / s.hop_time
		tr.position = tr.position + s.dir.mul(s.speed * dt)
		tr.position.y = f32(math.sin(k * math.pi)) * s.height
		stretch := f32(math.sin(k * math.pi)) * 0.15
		body.scale = core.vec3(0.9 * (1 - stretch), 0.9 * (1 + stretch), 0.9 * (1 - stretch))
		body.position.y = 0.45
		tr.turn_toward(s.dir, 400 * dt)
	}
	// bump the hero
	if hn := hero(s.scene()) {
		if mut h := hn.get_component[HeroController]() {
			if hp := hero_pos(s.scene()) {
				if hp.distance(core.vec3(tr.position.x, 0, tr.position.z)) < 0.9 * sc
					&& tr.position.y < 0.6 {
					h.hit(tr.position)
				}
			}
		}
	}
}

// DroneHover — circles around where it started, bobbing and tilting into its turn.
pub struct DroneHover {
	core.Component
pub mut:
	radius f32 = 3
	speed  f32 = 0.6 // radians per second
	bob    f32 = 0.3
	center core.Vec3 @[hide]
	a      f32       @[hide]
}

pub fn (mut d DroneHover) start() {
	d.center = render3d.transform3d(mut d.node).position
	d.a = rand.f32() * 6
}

pub fn (mut d DroneHover) update(dt f32) {
	d.a += d.speed * dt
	mut tr := render3d.transform3d(mut d.node)
	t := f32(d.scene().time)
	tr.position = d.center + core.vec3(f32(math.sin(d.a)) * d.radius, f32(math.sin(t * 2.1 +
		d.a)) * d.bob, f32(math.cos(d.a)) * d.radius)
	s := if d.speed >= 0 { f32(1) } else { f32(-1) }
	tr.face(core.vec3(f32(math.cos(d.a)) * s, 0, -f32(math.sin(d.a)) * s))
	tr.rotation.z = -18 * s
}

// GolemWalk — paces back and forth, swinging arms and legs.
pub struct GolemWalk {
	core.Component
pub mut:
	distance f32 = 8
	speed    f32 = 1.3
	swing    f32 = 28 // degrees
	start_p  core.Vec3 @[hide]
	t        f32       @[hide]
	dir      f32 = 1       @[hide]
	moved    f32       @[hide]
	steps    f32       @[hide]
}

pub fn (mut g GolemWalk) start() {
	g.start_p = render3d.transform3d(mut g.node).position
}

fn set_swing(n &core.Node, path string, deg f32) {
	ch := n.find(path) or { return }
	mut t := ch.get_component[render3d.Transform3D]() or { return }
	t.rotation.x = deg
}

pub fn (mut g GolemWalk) update(dt f32) {
	mut tr := render3d.transform3d(mut g.node)
	g.t += dt
	g.moved += g.speed * dt
	if g.moved >= g.distance {
		g.moved = 0
		g.dir = -g.dir
	}
	tr.position = tr.position + core.vec3(0, 0, g.dir * g.speed * dt)
	tr.turn_toward(core.vec3(0, 0, g.dir), 180 * dt)
	ph := g.t * g.speed * 2.6
	sw := f32(math.sin(ph)) * g.swing
	set_swing(g.node, 'Hips/LegL', sw)
	set_swing(g.node, 'Hips/LegR', -sw)
	set_swing(g.node, 'Hips/Torso/ArmL', -sw * 0.8)
	set_swing(g.node, 'Hips/Torso/ArmR', sw * 0.8)
	if hips_n := g.node.find('Hips') {
		if mut hips := hips_n.get_component[render3d.Transform3D]() {
			hips.position.y = 1.15 + f32(math.abs(math.cos(ph))) * 0.08
		}
	}
	// a thud at each footfall
	steps := f32(int(ph / math.pi))
	if steps != g.steps {
		g.steps = steps
		if mut dust := child_component[render3d.Particles3D](g.node, 'Dust') {
			dust.emit(6)
		}
	}
}

// ---------- Orbs ----------

// OrbPickup — collected when the hero touches it: score, a burst of sparks, and it moves somewhere else.
pub struct OrbPickup {
	core.Component
pub mut:
	radius f32 = 1
	value  int = 1
	armed  f32 = 0.5 @[hide]   // seconds before it can be picked (spawners place it during the first frame)
}

pub fn (mut o OrbPickup) update(dt f32) {
	if o.armed > 0 {
		o.armed -= dt
		return
	}
	hp := hero_pos(o.scene()) or { return }
	mut tr := render3d.transform3d(mut o.node)
	p := tr.position
	if core.vec3(p.x, 0, p.z).distance(core.vec3(hp.x, 0, hp.z)) > o.radius {
		return
	}
	mut st := o.scene().store
	st.set_int('orbs', st.get_int('orbs', 0) + o.value)
	burst(mut o.node.parent, p)
	// respawn elsewhere
	a := rand.f32() * 2 * math.pi
	r := 3 + rand.f32() * 13
	tr.position = core.vec3(f32(math.sin(a)) * r, tr.position.y, f32(math.cos(a)) * r)
	if mut b := o.node.get_component[Bob3D]() {
		b.base = tr.position.y
	}
}

// burst: a one-shot spark explosion at `p` that removes itself.
fn burst(mut parent core.Node, p core.Vec3) {
	mut n := core.Node.new('Burst')
	n.add_component(&render3d.Transform3D{
		position: p
	})
	n.add_component(&render3d.Particles3D{
		preset:      'explosion'
		speed:       4
		size_start:  0.35
		color_start: core.rgba(255, 240, 160, 255)
		color_alt:   core.rgba(255, 190, 60, 255)
		gravity:     core.vec3(0, -2, 0)
		burst:       60
	})
	n.add_component(&render3d.PointLight3D{
		color:     core.rgba(255, 200, 90, 255)
		intensity: 3
		range:     5
	})
	parent.add_child(mut n)
	n.after(0.15, fn [mut n] () {
		if mut l := n.get_component[render3d.PointLight3D]() {
			l.enabled = false
		}
	})
	n.after(1.2, fn [mut n] () {
		n.destroy()
	})
}

// OrbSpawner — places `count` orbs from the prefab at random spots within `radius`.
pub struct OrbSpawner {
	core.Component
pub mut:
	prefab assets.AssetRef[assets.SceneAsset]
	count  int = 8
	radius f32 = 14
}

pub fn (mut s OrbSpawner) start() {
	for _ in 0 .. s.count {
		mut sc := s.scene()
		mut orb := sc.instantiate(s.prefab.id, mut s.node) or {
			eprintln(err)
			return
		}
		a := rand.f32() * 2 * math.pi
		r := 3 + rand.f32() * (s.radius - 3)
		mut t := render3d.transform3d(mut orb)
		t.position = core.vec3(f32(math.sin(a)) * r, 1, f32(math.cos(a)) * r)
	}
}

// ---------- Small helpers ----------

// Bob3D — bobs the node up and down.
pub struct Bob3D {
	core.Component
pub mut:
	amplitude f32 = 0.2
	speed     f32 = 2
	base      f32 @[hide]
	phase     f32 @[hide]
}

pub fn (mut b Bob3D) start() {
	t := render3d.transform3d(mut b.node)
	b.base = t.position.y
	b.phase = rand.f32() * 6
}

pub fn (mut b Bob3D) update(dt f32) {
	mut t := render3d.transform3d(mut b.node)
	t.position.y = b.base + f32(math.sin(b.scene().time * b.speed + b.phase)) * b.amplitude
}

// Spin3D — turns the node at `speed` degrees per second around each axis.
pub struct Spin3D {
	core.Component
pub mut:
	speed core.Vec3 = core.Vec3{0, 90, 0}
}

pub fn (mut s Spin3D) update(dt f32) {
	mut t := render3d.transform3d(mut s.node)
	t.rotation = t.rotation + s.speed.mul(dt)
}

// Pulse3D — pulses the glow (emissive, point light) of the node and its children.
pub struct Pulse3D {
	core.Component
pub mut:
	min   f32 = 0.5
	max   f32 = 1
	speed f32 = 2
	base  map[voidptr]core.Color @[hide]
	light f32 = -1                    @[hide]
}

pub fn (mut p Pulse3D) update(dt f32) {
	k := p.min + (p.max - p.min) * (0.5 + 0.5 * f32(math.sin(p.scene().time * p.speed)))
	mut nodes := [p.node]
	nodes << p.node.children
	for n in nodes {
		if mut m := n.get_component[render3d.MeshRenderer3D]() {
			key := voidptr(m)
			if key !in p.base {
				p.base[key] = m.emissive
			}
			b := p.base[key] or { m.emissive }
			m.emissive = core.rgba(u8(math.min(f32(255), f32(b.r) * k)), u8(math.min(f32(255),
				f32(b.g) * k)), u8(math.min(f32(255), f32(b.b) * k)), 255)
		}
	}
	if mut l := p.node.get_component[render3d.PointLight3D]() {
		if p.light < 0 {
			p.light = l.intensity
		}
		l.intensity = p.light * k
	}
}

// StatsLabel — FPS and what the 3D pass drew.
pub struct StatsLabel {
	core.Component
pub mut:
	fps   f32 @[hide]
	timer f32 @[hide]
}

pub fn (mut s StatsLabel) update(dt f32) {
	if dt > 0 {
		s.fps = s.fps * 0.9 + 0.1 / s.scene().unscaled_dt
	}
	s.timer -= dt
	if s.timer > 0 {
		return
	}
	s.timer = 0.25
	mut l := s.node.get_component[render.Label]() or { return }
	r := stats.r3d
	if r == unsafe { nil } {
		return
	}
	l.text = '${int(s.fps)} fps   3D: ${r.draw_calls} draws, ${r.triangles / 1000}k triangles'
}
