module core

// Timer — runs a function after a delay, once or repeatedly. Like tweens, timers belong to a node: they count
// down in the node's update (scaled time, paused with the scene and while the node is inactive) and are
// dropped with the node. Timers due in the same frame run in the order they were made.
//
//   node.after(2, fn [mut node] () { node.destroy() })
//   spawn := node.every(0.5, fn [mut spawner] () { spawner.spawn() })
//   spawn.cancel()
@[heap]
pub struct Timer {
mut:
	left     f32
	interval f32
	repeat   bool
	cb       fn () = unsafe { nil }
	done     bool
}

// cancel stops the timer (safe to call from its own callback, or after it has fired).
pub fn (mut t Timer) cancel() {
	t.done = true
}

pub fn (t &Timer) is_pending() bool {
	return !t.done
}

// time_left: seconds until it fires next.
pub fn (t &Timer) time_left() f32 {
	return if t.done { 0 } else { t.left }
}

// after runs `f` once, `seconds` from now.
pub fn (mut n Node) after(seconds f32, f fn ()) &Timer {
	t := &Timer{
		left: seconds
		cb:   f
	}
	n.timers << t
	return t
}

// every runs `f` every `seconds` (the first time `seconds` from now) until cancelled.
pub fn (mut n Node) every(seconds f32, f fn ()) &Timer {
	t := &Timer{
		left:     seconds
		interval: seconds
		repeat:   true
		cb:       f
	}
	n.timers << t
	return t
}

// cancel_timers cancels every timer of the node.
pub fn (mut n Node) cancel_timers() {
	for mut t in n.timers {
		t.done = true
	}
}

fn (mut n Node) tick_timers(dt f32) {
	if n.timers.len == 0 {
		return
	}
	count := n.timers.len
	for i in 0 .. count {
		mut t := n.timers[i]
		if t.done {
			continue
		}
		t.left -= dt
		// a long frame can owe several calls of a repeating timer (capped, so a tiny interval cannot hang)
		mut calls := 0
		for t.left <= 0 && !t.done && !n.destroyed && calls < 10 {
			calls++
			if t.repeat && t.interval > 0 {
				t.left += t.interval
			} else {
				t.done = true
			}
			t.cb()
		}
		if calls >= 10 && t.left < 0 {
			t.left = t.interval
		}
	}
	n.timers = n.timers.filter(!it.done)
}

// after runs `f` once, `seconds` from now (a timer on the scene root).
pub fn (mut s Scene) after(seconds f32, f fn ()) &Timer {
	return s.root.after(seconds, f)
}

// every runs `f` every `seconds` (a timer on the scene root).
pub fn (mut s Scene) every(seconds f32, f fn ()) &Timer {
	return s.root.every(seconds, f)
}
