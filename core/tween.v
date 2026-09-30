module core

import math

// Ease — how a tween's progress (0..1 in time) maps to its value. `_in` starts slow, `_out` ends slow.
pub enum Ease {
	linear
	quad_in
	quad_out
	quad_in_out
	cubic_in
	cubic_out
	cubic_in_out
	sine_in
	sine_out
	sine_in_out
	expo_in
	expo_out
	back_in  // pulls back a little before going
	back_out // overshoots a little, then settles
	back_in_out
	elastic_out // springs past the end and wobbles
	bounce_out  // bounces at the end like a dropped ball
}

// apply maps linear progress `t` (0..1) through the easing curve.
pub fn (e Ease) apply(t f32) f32 {
	x := f64(t)
	c1 := 1.70158
	c2 := c1 * 1.525
	c3 := c1 + 1
	v := match e {
		.linear {
			x
		}
		.quad_in {
			x * x
		}
		.quad_out {
			1 - (1 - x) * (1 - x)
		}
		.quad_in_out {
			if x < 0.5 { 2 * x * x } else { 1 - math.pow(-2 * x + 2, 2) / 2 }
		}
		.cubic_in {
			x * x * x
		}
		.cubic_out {
			1 - math.pow(1 - x, 3)
		}
		.cubic_in_out {
			if x < 0.5 { 4 * x * x * x } else { 1 - math.pow(-2 * x + 2, 3) / 2 }
		}
		.sine_in {
			1 - math.cos(x * math.pi / 2)
		}
		.sine_out {
			math.sin(x * math.pi / 2)
		}
		.sine_in_out {
			-(math.cos(math.pi * x) - 1) / 2
		}
		.expo_in {
			if x <= 0 { 0 } else { math.pow(2, 10 * x - 10) }
		}
		.expo_out {
			if x >= 1 { 1 } else { 1 - math.pow(2, -10 * x) }
		}
		.back_in {
			c3 * x * x * x - c1 * x * x
		}
		.back_out {
			1 + c3 * math.pow(x - 1, 3) + c1 * math.pow(x - 1, 2)
		}
		.back_in_out {
			if x < 0.5 {
				(math.pow(2 * x, 2) * ((c2 + 1) * 2 * x - c2)) / 2
			} else {
				(math.pow(2 * x - 2, 2) * ((c2 + 1) * (x * 2 - 2) + c2) + 2) / 2
			}
		}
		.elastic_out {
			if x <= 0 {
				0
			} else if x >= 1 {
				1
			} else {
				math.pow(2, -10 * x) * math.sin((x * 10 - 0.75) * (2 * math.pi / 3)) + 1
			}
		}
		.bounce_out {
			bounce_out(x)
		}
	}

	return f32(v)
}

fn bounce_out(x f64) f64 {
	n1 := 7.5625
	d1 := 2.75
	if x < 1 / d1 {
		return n1 * x * x
	} else if x < 2 / d1 {
		y := x - 1.5 / d1
		return n1 * y * y + 0.75
	} else if x < 2.5 / d1 {
		y := x - 2.25 / d1
		return n1 * y * y + 0.9375
	}
	y := x - 2.625 / d1
	return n1 * y * y + 0.984375
}

pub fn ease_from_str(s string) !Ease {
	$for v in Ease.values {
		if v.name == s {
			return v.value
		}
	}
	return error('unknown ease "${s}"')
}

enum TrackKind {
	position
	rotation
	scale
	value
	call
}

struct Track {
	kind     TrackKind
	duration f32 // its own length: tracks joined with also() can be shorter than their step
	relative bool
	ease     Ease
	target   Vec2 // end value (or the change, when relative); x only for rotation/value
	get      fn () f32  = unsafe { nil } // value: reads the start value when the step starts
	set      fn (v f32) = unsafe { nil } // value: writes it
	on_call  fn ()      = unsafe { nil }
mut:
	from     Vec2
	to       Vec2
	captured bool
}

struct Step {
mut:
	duration f32
	tracks   []Track
}

// Tween — animates a node over time: a sequence of steps (move_to, scale_to, wait, call, ...), each step
// possibly several tracks at once (`also`). It belongs to its node: it runs in the node's update (so it pauses
// with the node and the scene) and stops when the node is destroyed. Start one with `node.tween()`:
//
//   node.tween().move_by(core.vec2(0, -40), 0.3, .quad_out).also().scale_to(core.vec2(1.5, 1.5), 0.3, .back_out)
//       .wait(0.5).call(fn [mut node] () { node.destroy() })
//
// (render.fade_to / render.color_to add color tracks for Sprite, Label and Panel.)
//
// Starting values are read when a step starts, so steps build on each other.
@[heap]
pub struct Tween {
mut:
	node        &Node = unsafe { nil }
	steps       []Step
	join_next   bool
	step        int
	elapsed     f32
	delay_left  f32
	loops       int = 1 // -1 = forever
	loop_index  int
	yoyo        bool
	complete_cb fn () = unsafe { nil }
	paused      bool
	done        bool
}

fn (t &Tween) add(dur f32, track Track) &Tween {
	tr := Track{
		...track
		duration: dur
	}
	mut m := unsafe { t }
	if m.join_next && m.steps.len > 0 {
		mut last := &m.steps[m.steps.len - 1]
		last.tracks << tr
		if dur > last.duration {
			last.duration = dur
		}
	} else {
		m.steps << Step{
			duration: dur
			tracks:   [tr]
		}
	}
	m.join_next = false
	return t
}

// also makes the next step run at the same time as the previous one instead of after it.
pub fn (t &Tween) also() &Tween {
	mut m := unsafe { t }
	m.join_next = true
	return t
}

// move_to moves the node to `p` (local position) over `duration` seconds.
pub fn (t &Tween) move_to(p Vec2, duration f32, ease Ease) &Tween {
	return t.add(duration, Track{ kind: .position, target: p, ease: ease })
}

// move_by moves the node by `d` from where it is when the step starts.
pub fn (t &Tween) move_by(d Vec2, duration f32, ease Ease) &Tween {
	return t.add(duration, Track{ kind: .position, target: d, ease: ease, relative: true })
}

// rotate_to turns the node to `deg` degrees.
pub fn (t &Tween) rotate_to(deg f32, duration f32, ease Ease) &Tween {
	return t.add(duration, Track{ kind: .rotation, target: vec2(deg, 0), ease: ease })
}

// rotate_by turns the node by `deg` degrees (e.g. 360 = one full turn).
pub fn (t &Tween) rotate_by(deg f32, duration f32, ease Ease) &Tween {
	return t.add(duration, Track{
		kind:     .rotation
		target:   vec2(deg, 0)
		ease:     ease
		relative: true
	})
}

// scale_to scales the node to `s`.
pub fn (t &Tween) scale_to(s Vec2, duration f32, ease Ease) &Tween {
	return t.add(duration, Track{ kind: .scale, target: s, ease: ease })
}

// value animates anything: `set` receives values from what `get` returns when the step starts to `to`.
//   node.tween().value(fn [bar] () f32 { return bar.progress }, fn [mut bar] (v f32) { bar.progress = v }, 1, 0.5, .quad_out)
pub fn (t &Tween) value(get fn () f32, set fn (v f32), to f32, duration f32, ease Ease) &Tween {
	return t.add(duration, Track{
		kind:   .value
		target: vec2(to, 0)
		ease:   ease
		get:    get
		set:    set
	})
}

// progress calls `set` with 0..1 (eased) over `duration`, for effects that compute their own values.
pub fn (t &Tween) progress(set fn (v f32), duration f32, ease Ease) &Tween {
	return t.add(duration, Track{
		kind:   .value
		target: vec2(1, 0)
		ease:   ease
		get:    fn () f32 {
			return 0
		}
		set:    set
	})
}

// wait adds a pause before the next step.
pub fn (t &Tween) wait(seconds f32) &Tween {
	mut m := unsafe { t }
	m.steps << Step{
		duration: seconds
	}
	m.join_next = false
	return t
}

// call runs `f` when the sequence gets there (it may destroy the node).
pub fn (t &Tween) call(f fn ()) &Tween {
	return t.add(0, Track{ kind: .call, on_call: f })
}

// delay waits before the first step.
pub fn (t &Tween) delay(seconds f32) &Tween {
	mut m := unsafe { t }
	m.delay_left = seconds
	return t
}

// repeat plays the whole sequence `times` times (-1 = forever); with `yoyo` every other pass plays backwards.
// Without yoyo each pass starts again from the values the first pass started from.
pub fn (t &Tween) repeat(times int, yoyo bool) &Tween {
	mut m := unsafe { t }
	m.loops = times
	m.yoyo = yoyo
	return t
}

// on_complete runs `f` once the tween has finished (not when it is killed).
pub fn (t &Tween) on_complete(f fn ()) &Tween {
	mut m := unsafe { t }
	m.complete_cb = f
	return t
}

// kill stops the tween where it is.
pub fn (mut t Tween) kill() {
	t.done = true
}

pub fn (mut t Tween) pause() {
	t.paused = true
}

pub fn (mut t Tween) resume() {
	t.paused = false
}

// is_playing: not finished nor killed (a paused tween counts as playing).
pub fn (t &Tween) is_playing() bool {
	return !t.done
}

// finish jumps to the end: every step is applied at its end value (the `call`s run), then on_complete.
// Tweens that repeat forever end their current pass.
pub fn (mut t Tween) finish() {
	if t.done {
		return
	}
	if t.loops < 0 {
		t.loops = t.loop_index + 1
	}
	t.paused = false
	t.delay_left = 0
	t.advance(f32(1e9))
}

// advance moves the tween `dt` seconds forward.
fn (mut t Tween) advance(dt_in f32) {
	if t.done || t.paused || t.node == unsafe { nil } {
		return
	}
	mut dt := dt_in
	if t.delay_left > 0 {
		t.delay_left -= dt
		if t.delay_left > 0 {
			return
		}
		dt = -t.delay_left
		t.delay_left = 0
	}
	mut empty_passes := 0
	for !t.done && !t.node.destroyed {
		if t.step >= t.steps.len {
			t.loop_index++
			if t.loops >= 0 && t.loop_index >= t.loops {
				t.done = true
				if t.complete_cb != unsafe { nil } {
					t.complete_cb()
				}
				return
			}
			t.step = 0
			empty_passes++
			if empty_passes > 1 || t.steps.len == 0 {
				return
			}
			continue
		}
		backwards := t.yoyo && t.loop_index % 2 == 1
		idx := if backwards { t.steps.len - 1 - t.step } else { t.step }
		if t.elapsed == 0 {
			t.start_step(idx)
		}
		dur := t.steps[idx].duration
		remaining := dur - t.elapsed
		if dt < remaining {
			t.elapsed += dt
			t.apply(idx, t.elapsed, backwards)
			return
		}
		if remaining > 0 {
			empty_passes = 0
		}
		dt -= remaining
		t.apply(idx, dur, backwards)
		t.fire_calls(idx)
		t.step++
		t.elapsed = 0
	}
}

// start_step reads the starting values (first pass only: later passes replay the same values).
fn (mut t Tween) start_step(idx int) {
	mut n := t.node
	for mut tr in t.steps[idx].tracks {
		if tr.captured {
			continue
		}
		tr.captured = true
		match tr.kind {
			.position { tr.from = n.position }
			.rotation { tr.from = vec2(n.rotation, 0) }
			.scale { tr.from = n.scale }
			.value { tr.from = vec2(if tr.get != unsafe { nil } { tr.get() } else { 0 }, 0) }
			.call {}
		}

		tr.to = if tr.relative { tr.from + tr.target } else { tr.target }
	}
}

// apply sets every track of step `idx` to where it is `elapsed` seconds into the step (backwards: from its end).
fn (mut t Tween) apply(idx int, elapsed f32, backwards bool) {
	mut n := t.node
	at := if backwards { t.steps[idx].duration - elapsed } else { elapsed }
	for tr in t.steps[idx].tracks {
		if tr.kind == .call {
			continue
		}
		u := if tr.duration <= 0 || at >= tr.duration {
			f32(1)
		} else if at <= 0 {
			f32(0)
		} else {
			at / tr.duration
		}
		k := tr.ease.apply(u)
		v := tr.from + (tr.to - tr.from).mul(k)
		match tr.kind {
			.position { n.position = v }
			.rotation { n.rotation = v.x }
			.scale { n.scale = v }
			.value { tr.set(v.x) }
			.call {}
		}
	}
}

fn (mut t Tween) fire_calls(idx int) {
	for tr in t.steps[idx].tracks {
		if tr.kind == .call && tr.on_call != unsafe { nil } && !t.node.destroyed {
			tr.on_call()
		}
	}
}

// ---------- Node ----------

// tween starts a new tween on the node (it begins with the node's next update). Several can run at once.
pub fn (mut n Node) tween() &Tween {
	t := &Tween{
		node: n
	}
	n.tweens << t
	return t
}

// kill_tweens stops every tween of the node (not of its children).
pub fn (mut n Node) kill_tweens() {
	for mut t in n.tweens {
		t.done = true
	}
}

fn (mut n Node) tick_tweens(dt f32) {
	if n.tweens.len == 0 {
		return
	}
	count := n.tweens.len
	for i in 0 .. count {
		mut t := n.tweens[i]
		t.advance(dt)
	}
	n.tweens = n.tweens.filter(!it.done)
}
