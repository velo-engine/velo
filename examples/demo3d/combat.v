module main

import math
import rand
import velo.core
import velo.render3d

// ---------- Health ----------

// Health — hit points: flashes and is knocked back when hit, shows a bar over enemies, and on death bursts,
// disappears and comes back at its starting point after `respawn` seconds. The hero's health goes to the saved
// data (`hp`, `max_hp`) for the HUD.
pub struct Health {
	core.Component
pub mut:
	max        int    = 3
	team       string = 'enemy' @[choices: 'hero|enemy']
	respawn    f32    = 6
	bar_height f32    = 1.5 // where the bar floats, in node units
	hp         int                    @[hide]
	invuln     f32                    @[hide] // seconds of immunity after a hit
	flash      f32                    @[hide]
	knock      core.Vec3              @[hide]
	home       core.Vec3              @[hide]
	base       map[voidptr]core.Color @[hide]
	bar        &core.Node = unsafe { nil }             @[hide]
	fill       &core.Node = unsafe { nil }             @[hide]
}

pub fn (mut h Health) start() {
	h.hp = h.max
	h.home = render3d.transform3d(mut h.node).position
	if h.team == 'hero' {
		h.publish()
	} else {
		h.make_bar()
	}
}

fn (h &Health) publish() {
	mut st := h.scene().store
	st.set_int('hp', h.hp)
	st.set_int('max_hp', h.max)
}

pub fn (h &Health) alive() bool {
	return h.hp > 0 && h.node.active
}

pub fn (h &Health) position() core.Vec3 {
	return render3d.world_matrix(h.node).translation_part()
}

// damage takes `n` hit points from a hit coming from `from`, pushing the node away with `knock` m/s.
// false = no effect (dead, or still immune from the last hit).
pub fn (mut h Health) damage(n int, from core.Vec3, knock f32) bool {
	if h.hp <= 0 || h.invuln > 0 || !h.node.active {
		return false
	}
	h.hp -= n
	h.invuln = if h.team == 'hero' { f32(1) } else { f32(0.15) }
	h.flash = 1
	mut d := h.position() - from
	d.y = 0
	push := d.normalized().mul(knock)
	if mut hc := h.node.get_component[HeroController]() {
		hc.knock = push
	} else {
		h.knock = push
	}
	if mut sk := h.node.get_component[render3d.SkinnedModel3D]() {
		sk.hit_flash()
	}
	if h.team == 'hero' {
		h.publish()
	}
	if h.hp <= 0 {
		h.die()
	}
	return true
}

pub fn (mut h Health) heal(n int) {
	if h.hp <= 0 || h.hp >= h.max {
		return
	}
	h.hp = int(math.min(h.max, h.hp + n))
	if h.team == 'hero' {
		h.publish()
	}
}

fn (mut h Health) die() {
	p := h.position()
	mut world := h.scene().find('World') or { return }
	if h.team == 'hero' {
		burst_colored(mut world, p + core.vec3(0, 1, 0), core.rgba(140, 200, 255, 255), core.rgba(90,
			120, 255, 255), 90)
		mut st := h.scene().store
		st.set_int('orbs', 0)
	} else {
		burst_colored(mut world, p + core.vec3(0, 0.6, 0), core.rgba(255, 240, 170, 255), core.rgba(255,
			120, 40, 255), 70)
		mut st := h.scene().store
		st.set_int('kills', st.get_int('kills', 0) + 1)
	}
	mut n := h.node
	n.active = false
	mut sc := h.scene()
	delay := if h.team == 'hero' { f32(2) } else { h.respawn }
	sc.after(delay, fn [mut n] () {
		mut hh := n.get_component[Health]() or { return }
		hh.revive()
	})
}

fn (mut h Health) revive() {
	mut tr := render3d.transform3d(mut h.node)
	tr.position = h.home
	h.hp = h.max
	h.knock = core.Vec3{}
	h.invuln = 1
	h.node.active = true
	if mut hc := h.node.get_component[HeroController]() {
		hc.knock = core.Vec3{}
		hc.velocity = core.Vec3{}
	}
	if h.team == 'hero' {
		h.publish()
	}
	if mut world := h.scene().find('World') {
		burst_colored(mut world, h.home + core.vec3(0, 0.5, 0), core.rgba(160, 255, 200, 255), core.rgba(90,
			200, 255, 255), 40)
	}
}

// make_bar builds a small 3D health bar (a dark back and a colored fill) over the node.
fn (mut h Health) make_bar() {
	mut bar := core.Node.new('HpBar')
	bar.add_component(&render3d.Transform3D{
		position: core.vec3(0, h.bar_height, 0)
	})
	mut back := core.Node.new('Back')
	back.add_component(&render3d.Transform3D{
		scale: core.vec3(1, 0.13, 0.03)
	})
	back.add_component(&render3d.MeshRenderer3D{
		mesh:  'cube'
		color: core.rgba(20, 20, 30, 200)
		blend: 'alpha'
		unlit: true
	})
	mut fill := core.Node.new('Fill')
	fill.add_component(&render3d.Transform3D{
		position: core.vec3(0, 0, 0.02)
		scale:    core.vec3(0.94, 0.09, 0.03)
	})
	fill.add_component(&render3d.MeshRenderer3D{
		mesh:  'cube'
		color: core.rgba(120, 230, 90, 255)
		unlit: true
	})
	bar.add_child(mut back)
	bar.add_child(mut fill)
	h.node.add_child(mut bar)
	bar.active = false
	h.bar = bar
	h.fill = fill
}

pub fn (mut h Health) update(dt f32) {
	h.invuln -= dt
	// knockback for nodes that have no controller of their own
	if h.knock.length() > 0.01 {
		mut tr := render3d.transform3d(mut h.node)
		tr.position = tr.position + h.knock.mul(dt)
		h.knock = h.knock.mul(f32(math.max(f32(0), 1 - dt * 7)))
	}
	h.update_flash(dt)
	h.update_bar()
}

// update_flash whitens every mesh of the node for a moment after a hit.
fn (mut h Health) update_flash(dt f32) {
	if h.flash <= 0 && h.base.len == 0 {
		return
	}
	h.flash = f32(math.max(f32(0), h.flash - dt * 5))
	mut stack := [h.node]
	for stack.len > 0 {
		n := stack.pop()
		for ch in n.children {
			if voidptr(ch) != voidptr(h.bar) {
				stack << ch
			}
		}
		mut m := n.get_component[render3d.MeshRenderer3D]() or { continue }
		key := voidptr(m)
		if key !in h.base {
			h.base[key] = m.emissive
		}
		b := h.base[key] or { m.emissive }
		k := h.flash
		m.emissive = core.rgba(u8(f32(b.r) + (255 - f32(b.r)) * k), u8(f32(b.g) +
			(255 - f32(b.g)) * k), u8(f32(b.b) + (255 - f32(b.b)) * k), 255)
	}
	if h.flash <= 0 {
		h.base.clear()
	}
}

fn (mut h Health) update_bar() {
	if h.bar == unsafe { nil } {
		return
	}
	mut bar := h.bar
	bar.active = h.hp < h.max && h.hp > 0
	if !bar.active {
		return
	}
	f := f32(h.hp) / f32(h.max)
	mut ft := h.fill.get_component[render3d.Transform3D]() or { return }
	ft.scale.x = 0.94 * f
	ft.position.x = -0.47 * (1 - f)
	if mut m := h.fill.get_component[render3d.MeshRenderer3D]() {
		m.color = if f > 0.5 {
			core.rgba(120, 230, 90, 255)
		} else if f > 0.25 {
			core.rgba(240, 200, 60, 255)
		} else {
			core.rgba(240, 70, 60, 255)
		}
	}
	// face the camera: undo the node's own yaw, then turn like the camera
	own := render3d.transform3d(mut h.node).rotation.y
	mut bt := bar.get_component[render3d.Transform3D]() or { return }
	bt.rotation.y = f32(camera_yaw(h.scene()) * 180 / math.pi) - own
}

// healths: every living Health of `team` in the world.
fn healths(s &core.Scene, team string) []&Health {
	mut out := []&Health{}
	root := s.find('World') or { return out }
	mut stack := [root]
	for stack.len > 0 {
		n := stack.pop()
		if !n.active {
			continue
		}
		for h in n.get_components[Health]() {
			if h.team == team && h.hp > 0 {
				out << h
			}
		}
		for ch in n.children {
			stack << ch
		}
	}
	return out
}

// burst_colored: a one-shot spark explosion at `p` that removes itself.
fn burst_colored(mut parent core.Node, p core.Vec3, c0 core.Color, c1 core.Color, count int) {
	mut n := core.Node.new('Burst')
	n.add_component(&render3d.Transform3D{
		position: p
	})
	n.add_component(&render3d.Particles3D{
		preset:      'explosion'
		speed:       4.5
		size_start:  0.4
		color_start: c0
		color_alt:   c1
		color_end:   core.rgba(c1.r / 2, c1.g / 2, c1.b / 2, 0)
		gravity:     core.vec3(0, -3, 0)
		burst:       count
	})
	n.add_component(&render3d.PointLight3D{
		color:     c1
		intensity: 3
		range:     6
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

// ---------- Projectiles ----------

// Projectile — a glowing bolt that flies straight and explodes on the first target of the other team.
pub struct Projectile {
	core.Component
pub mut:
	velocity core.Vec3
	team     string     = 'hero'
	damage   int        = 2
	radius   f32        = 0.7
	life     f32        = 2.5
	color    core.Color = core.rgba(140, 200, 255, 255)
	done     bool @[hide]
}

pub fn (mut p Projectile) update(dt f32) {
	if p.done {
		return
	}
	mut tr := render3d.transform3d(mut p.node)
	tr.position = tr.position + p.velocity.mul(dt)
	p.life -= dt
	target := if p.team == 'hero' { 'enemy' } else { 'hero' }
	for mut h in healths(p.scene(), target) {
		hp := h.position() + core.vec3(0, 0.8, 0)
		if hp.distance(tr.position) < p.radius + 0.4 {
			h.damage(p.damage, tr.position - p.velocity.normalized(), 7)
			p.explode()
			return
		}
	}
	if p.life <= 0 || tr.position.y < 0.05 {
		p.explode()
	}
}

fn (mut p Projectile) explode() {
	p.done = true
	pos := render3d.transform3d(mut p.node).position
	mut parent := p.node.parent
	c := p.color
	burst_colored(mut parent, pos, core.rgba(255, 255, 255, 255), c, 40)
	p.node.destroy()
}

// spawn_bolt fires a bolt from `from` toward `dir`.
fn spawn_bolt(mut world core.Node, from core.Vec3, dir core.Vec3, team string, speed f32, damage int, color core.Color) {
	mut n := core.Node.new('Bolt')
	n.add_component(&render3d.Transform3D{
		position: from
		scale:    core.vec3(0.28, 0.28, 0.28)
	})
	n.add_component(&render3d.MeshRenderer3D{
		mesh:     'sphere'
		color:    core.rgba(255, 255, 255, 255)
		emissive: color
		unlit:    true
	})
	n.add_component(&Projectile{
		velocity: dir.normalized().mul(speed)
		team:     team
		damage:   damage
		color:    color
	})
	n.add_component(&render3d.PointLight3D{
		color:     color
		intensity: 2
		range:     4
	})
	n.add_component(&render3d.Trail3D{
		width:     0.35
		duration:  0.25
		color:     core.rgba(color.r, color.g, color.b, 230)
		color_end: core.rgba(color.r / 2, color.g / 2, color.b, 0)
	})
	n.add_component(&render3d.Particles3D{
		rate:        60
		lifetime:    0.4
		speed:       0.4
		spread:      180
		size_start:  0.25
		size_end:    0
		shape:       'spark'
		color_start: core.rgba(255, 255, 255, 255)
		color_alt:   color
		color_end:   core.rgba(color.r, color.g, color.b, 0)
	})
	world.add_child(mut n)
}

// ---------- Hero attacks ----------

// HeroCombat — J or a mouse click: a sword slash in front of the hero; K: a magic bolt.
// On autopilot the hero fights by itself.
pub struct HeroCombat {
	core.Component
pub mut:
	slash_damage   int = 1
	slash_range    f32 = 2.4
	slash_arc      f32 = 120 // degrees in front
	slash_cooldown f32 = 0.4
	bolt_damage    int = 2
	bolt_speed     f32 = 16
	bolt_cooldown  f32 = 0.7
	slash_cd       f32       @[hide]
	bolt_cd        f32       @[hide]
	swing          f32 = -1       @[hide]    // 0..1 while the slash plays
	swing_dir      f32 = 1       @[hide]
	click_at       core.Vec2 @[hide]
}

pub fn (mut c HeroCombat) start() {
	// the sword's swing: a pivot at chest height, a blade tip that leaves a trail
	mut pivot := core.Node.new('Slash')
	pivot.add_component(&render3d.Transform3D{
		position: core.vec3(0, 1.0, 0)
	})
	mut tip := core.Node.new('Tip')
	tip.add_component(&render3d.Transform3D{
		position: core.vec3(0, 0, 1.5)
	})
	tip.add_component(&render3d.Trail3D{
		width:        0.7
		duration:     0.18
		color:        core.rgba(220, 245, 255, 240)
		color_end:    core.rgba(90, 160, 255, 0)
		emitting:     false
		min_distance: 0.02
	})
	pivot.add_child(mut tip)
	c.node.add_child(mut pivot)
}

pub fn (mut c HeroCombat) update(dt f32) {
	c.slash_cd -= dt
	c.bolt_cd -= dt
	inp := c.input()
	// a click (not a camera drag) slashes
	if inp.mouse_pressed {
		c.click_at = inp.mouse
	}
	clicked := inp.mouse_released && inp.mouse.distance(c.click_at) < 6
	mut want_slash := inp.was_pressed(.j) || clicked
	mut want_bolt := inp.was_pressed(.k)
	mut aim := core.Vec3{}
	if hc := c.node.get_component[HeroController]() {
		if hc.autopilot > 0 && hc.idle_input > hc.autopilot {
			want_slash, want_bolt, aim = c.auto_fight()
		}
	}
	if want_slash && c.slash_cd <= 0 {
		c.slash()
	}
	if want_bolt && c.bolt_cd <= 0 {
		c.bolt(aim)
	}
	c.animate_swing(dt)
}

// auto_fight: slash what is close in front, shoot what is a bit further.
fn (c &HeroCombat) auto_fight() (bool, bool, core.Vec3) {
	tr := c.node.get_component[render3d.Transform3D]() or { return false, false, core.Vec3{} }
	for h in healths(c.scene(), 'enemy') {
		mut d := h.position() - tr.position
		d.y = 0
		dist := d.length()
		if dist < c.slash_range * 0.9 {
			return true, false, d
		}
		if dist < 11 && rand.f32() < 0.03 {
			return false, true, d
		}
	}
	return false, false, core.Vec3{}
}

fn (mut c HeroCombat) slash() {
	c.slash_cd = c.slash_cooldown
	c.swing = 0
	c.swing_dir = -c.swing_dir
	tr := render3d.transform3d(mut c.node)
	fwd := tr.forward()
	pos := tr.position
	// a short lunge
	if mut hc := c.node.get_component[HeroController]() {
		hc.velocity = hc.velocity + fwd.mul(4)
	}
	cos_arc := f32(math.cos(c.slash_arc / 2 * math.pi / 180))
	mut world := c.scene().find('World') or { return }
	for mut h in healths(c.scene(), 'enemy') {
		mut d := h.position() - pos
		d.y = 0
		dist := d.length()
		if dist > c.slash_range || (dist > 0.3 && d.normalized().dot(fwd) < cos_arc) {
			continue
		}
		if h.damage(c.slash_damage, pos, 7) {
			hit := h.position() + core.vec3(0, 0.8, 0)
			burst_colored(mut world, hit, core.rgba(255, 255, 230, 255), core.rgba(255, 200, 90,
				255), 18)
		}
	}
}

fn (mut c HeroCombat) bolt(aim core.Vec3) {
	c.bolt_cd = c.bolt_cooldown
	mut tr := render3d.transform3d(mut c.node)
	mut dir := if aim.length() > 0.1 { aim.normalized() } else { tr.forward() }
	dir.y = 0
	tr.face(dir)
	from := tr.position + dir.mul(0.8) + core.vec3(0, 1.1, 0)
	mut world := c.scene().find('World') or { return }
	spawn_bolt(mut world, from, dir, 'hero', c.bolt_speed, c.bolt_damage, core.rgba(120, 190, 255,
		255))
}

// animate_swing sweeps the blade tip across the front of the hero.
fn (mut c HeroCombat) animate_swing(dt f32) {
	pivot := c.node.find('Slash') or { return }
	tip := pivot.find('Tip') or { return }
	mut trail := tip.get_component[render3d.Trail3D]() or { return }
	mut pt := pivot.get_component[render3d.Transform3D]() or { return }
	if c.swing < 0 {
		trail.emitting = false
		return
	}
	c.swing += dt / 0.18
	if c.swing >= 1 {
		c.swing = -1
		trail.emitting = false
		return
	}
	trail.emitting = true
	k := c.swing * c.swing * (3 - 2 * c.swing)
	pt.rotation.y = (-75 + 150 * k) * c.swing_dir
	pt.rotation.z = 20 * c.swing_dir
}

// ---------- Enemy attacks ----------

// GolemSlam — when the hero comes close the golem stops, raises its arms (the rune glows) and slams the ground.
pub struct GolemSlam {
	core.Component
pub mut:
	range    f32 = 3
	damage   int = 2
	windup   f32 = 0.7
	cooldown f32 = 2.5
	t        f32 = -1 @[hide]    // time into the attack, -1 = idle
	cd       f32 @[hide]
}

pub fn (mut g GolemSlam) update(dt f32) {
	g.cd -= dt
	mut walk := g.node.get_component[GolemWalk]() or { return }
	hp := hero_pos(g.scene()) or { return }
	mut tr := render3d.transform3d(mut g.node)
	if g.t < 0 {
		if g.cd <= 0 && hp.distance(tr.position) < g.range {
			g.t = 0
			walk.paused = true
		}
		return
	}
	g.t += dt
	tr.turn_toward(hp - tr.position, 240 * dt)
	if g.t < g.windup {
		// raise both arms
		k := g.t / g.windup
		set_swing(g.node, 'Hips/Torso/ArmL', -160 * k)
		set_swing(g.node, 'Hips/Torso/ArmR', -160 * k)
		return
	}
	if g.t - dt < g.windup {
		// slam
		set_swing(g.node, 'Hips/Torso/ArmL', 20)
		set_swing(g.node, 'Hips/Torso/ArmR', 20)
		if mut dust := child_component[render3d.Particles3D](g.node, 'Dust') {
			dust.emit(30)
		}
		mut world := g.scene().find('World') or { return }
		front := tr.position + tr.forward().mul(1.2)
		burst_colored(mut world, front + core.vec3(0, 0.2, 0), core.rgba(255, 210, 140, 255), core.rgba(200,
			120, 60, 255), 35)
		if hn := hero(g.scene()) {
			if mut h := hn.get_component[Health]() {
				if hp.distance(front) < 2.4 {
					h.damage(g.damage, tr.position, 12)
				}
			}
		}
	}
	if g.t > g.windup + 0.5 {
		g.t = -1
		g.cd = g.cooldown
		walk.paused = false
	}
}

// DroneGun — shoots a red bolt at the hero now and then when it is in range.
pub struct DroneGun {
	core.Component
pub mut:
	range    f32 = 10
	interval f32 = 3.5
	speed    f32 = 9
	damage   int = 1
	t        f32 @[hide]
}

pub fn (mut d DroneGun) start() {
	d.t = rand.f32() * d.interval
}

pub fn (mut d DroneGun) update(dt f32) {
	d.t -= dt
	if d.t > 0 {
		return
	}
	d.t = d.interval
	hn := hero(d.scene()) or { return }
	if !hn.active {
		return
	}
	hp := hero_pos(d.scene()) or { return }
	from := render3d.world_matrix(d.node).translation_part()
	if from.distance(hp) > d.range {
		return
	}
	mut world := d.scene().find('World') or { return }
	spawn_bolt(mut world, from, hp + core.vec3(0, 0.9, 0) - from, 'enemy', d.speed, d.damage, core.rgba(255,
		90, 70, 255))
}

// HealZone — heals the hero standing on it.
pub struct HealZone {
	core.Component
pub mut:
	radius f32 = 1.5
	rate   f32 = 1 // hit points per second
	acc    f32 @[hide]
}

pub fn (mut z HealZone) update(dt f32) {
	hn := hero(z.scene()) or { return }
	mut h := hn.get_component[Health]() or { return }
	hp := hero_pos(z.scene()) or { return }
	p := render3d.world_matrix(z.node).translation_part()
	if core.vec3(hp.x, 0, hp.z).distance(core.vec3(p.x, 0, p.z)) > z.radius || h.hp >= h.max {
		z.acc = 0
		return
	}
	z.acc += z.rate * dt
	if z.acc >= 1 {
		z.acc -= 1
		h.heal(1)
		if mut parts := z.node.get_component[render3d.Particles3D]() {
			parts.emit(12)
		}
	}
}
