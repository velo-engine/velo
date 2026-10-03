module render

import math
import velo.core

// UINav — keyboard / gamepad navigation for the Buttons of a menu: the arrows, the d-pad or the left stick move a focus
// ring to the nearest Button in that direction, Enter / Space / gamepad A presses it, Escape / B cancels.
// It manages the Buttons below its own node, or, when there are none there, below its parent. So either put it on the
// UI root, or (so the ring draws on top of everything) on an empty last child of it:
//
//   node UI { Canvas { }  ...buttons...  node Nav { UINav { } } }
//
// A dialog with its own UINav inside the dialog's node keeps navigation inside the dialog (disable the other UINav).
//
// It uses the input actions `ui_up`, `ui_down`, `ui_left`, `ui_right`, `ui_accept` and `ui_cancel`, and binds them to the
// arrows, the d-pad, the left stick, Enter/Space/A and Esc/B unless the game bound them first (`input.bind`). The mouse
// moves the focus too (`follow_mouse`), so a pointer and a gamepad can share one menu. A focused Button is tinted like a
// hovered one and has a ring around it. Read `focused_node()`, change it with `focus(node)`, poll `cancelled`.
pub struct UINav {
	core.Component
pub mut:
	wrap         bool       = true // past the last Button in a direction, go to the far side
	follow_mouse bool       = true // hovering a Button with the mouse focuses it
	auto_focus   bool       = true // a first direction press focuses the top-left Button
	ring_color   core.Color = core.rgba(255, 215, 80, 255)
	ring_width   f32        = 3
	ring_pad     f32        = 3
	repeat_delay f32        = 0.4 // seconds holding a direction before it repeats
	repeat_rate  f32        = 0.12
	cancelled    bool       @[hide] // true for the frame cancel (Esc / B) was pressed
	on_cancel    fn ()      = unsafe { nil }      @[hide]
	focused      &core.Node = unsafe { nil } @[hide]
	hold_dir     int        = -1        @[hide]
	hold_time    f32        @[hide]
	last_mouse   core.Vec2  @[hide]
}

struct NavCand {
	node   &core.Node
	center core.Vec2 // screen space
}

const nav_dirs = ['ui_up', 'ui_down', 'ui_left', 'ui_right']

pub fn (mut n UINav) on_load() {
	mut input := n.input()
	defaults := {
		'ui_up':     ['key:up', 'axis:left_y-', 'pad:dpad_up']
		'ui_down':   ['key:down', 'axis:left_y+', 'pad:dpad_down']
		'ui_left':   ['key:left', 'axis:left_x-', 'pad:dpad_left']
		'ui_right':  ['key:right', 'axis:left_x+', 'pad:dpad_right']
		'ui_accept': ['key:enter', 'key:space', 'pad:a']
		'ui_cancel': ['key:escape', 'pad:b']
	}
	for name, binds in defaults {
		if input.bindings_of(name).len == 0 {
			for b in binds {
				bind := core.parse_binding(b) or { continue }
				input.add_binding(name, bind)
			}
		}
	}
	n.last_mouse = input.mouse
}

// focus gives the focus to the Button on `target` (false: it has none, or it is not usable now).
pub fn (mut n UINav) focus(target &core.Node) bool {
	for c in n.candidates() {
		if voidptr(c.node) == voidptr(target) {
			n.set_focus(c.node)
			return true
		}
	}
	return false
}

pub fn (mut n UINav) clear_focus() {
	n.set_focus(unsafe { nil })
}

// focused_node: the node with the focus (none when nothing is focused).
pub fn (n &UINav) focused_node() ?&core.Node {
	if n.focused == unsafe { nil } {
		return none
	}
	return n.focused
}

fn (mut n UINav) set_focus(target &core.Node) {
	if n.focused != unsafe { nil } {
		if mut b := n.focused.get_component[Button]() {
			b.focused = false
		}
	}
	n.focused = unsafe { target }
	if target != unsafe { nil } {
		if mut b := target.get_component[Button]() {
			b.focused = true
		}
	}
}

// scope_root: the node whose Buttons are managed: this one, or its parent when this one has none below it.
fn (n &UINav) scope_root() &core.Node {
	if n.node.parent != unsafe { nil } && !has_button(n.node) {
		return n.node.parent
	}
	return n.node
}

fn has_button(node &core.Node) bool {
	if node.get_component[Button]() != none {
		return true
	}
	for ch in node.children {
		if has_button(ch) {
			return true
		}
	}
	return false
}

// candidates: the Buttons that can take the focus now, with where they are on screen.
fn (n &UINav) candidates() []NavCand {
	mut out := []NavCand{}
	collect_nav(n.scope_root(), mut out)
	return out
}

fn collect_nav(node &core.Node, mut out []NavCand) {
	if !node.active || node.destroyed {
		return
	}
	if b := node.get_component[Button]() {
		if b.enabled && b.interactable {
			if r := node_rect(node) {
				c := node.screen_matrix().apply(core.vec2(r.x + r.w / 2, r.y + r.h / 2))
				out << NavCand{node, c}
			}
		}
	}
	for ch in node.children {
		collect_nav(ch, mut out)
	}
}

// pick: the candidate to move to from `cur` in direction `dir` (a unit vector in screen space).
fn (n &UINav) pick(cands []NavCand, cur core.Vec2, cur_node &core.Node, dir core.Vec2) ?&core.Node {
	mut best := unsafe { &core.Node(nil) }
	mut best_score := f32(1e30)
	mut far := unsafe { &core.Node(nil) }
	mut far_score := f32(1e30)
	for c in cands {
		if voidptr(c.node) == voidptr(cur_node) {
			continue
		}
		v := c.center - cur
		along := v.x * dir.x + v.y * dir.y
		perp := f32(math.abs(v.x * dir.y - v.y * dir.x))
		if along > 0.5 {
			score := along + 2 * perp // straight ahead beats a near diagonal
			if score < best_score {
				best_score = score
				best = c.node
			}
		} else {
			wrap_score := along + 2 * perp // the most "behind" one, lined up with us
			if wrap_score < far_score {
				far_score = wrap_score
				far = c.node
			}
		}
	}
	if best != unsafe { nil } {
		return best
	}
	if n.wrap && far != unsafe { nil } {
		return far
	}
	return none
}

fn nav_vec(i int) core.Vec2 {
	return match i {
		0 { core.vec2(0, -1) }
		1 { core.vec2(0, 1) }
		2 { core.vec2(-1, 0) }
		else { core.vec2(1, 0) }
	}
}

pub fn (mut n UINav) update(dt f32) {
	n.cancelled = false
	input := n.input()
	cands := n.candidates()
	// a focus that is gone (destroyed, hidden, disabled) is dropped
	if n.focused != unsafe { nil } && !cands.any(voidptr(it.node) == voidptr(n.focused)) {
		n.set_focus(unsafe { nil })
	}
	// the mouse focuses what it moves over
	if n.follow_mouse && input.mouse != n.last_mouse {
		for c in cands.reverse() { // later nodes draw on top
			if hit_test(c.node, input.mouse) {
				n.set_focus(c.node)
				break
			}
		}
	}
	n.last_mouse = input.mouse
	// directions: a press moves once; holding repeats after a delay
	mut moved := -1
	for i, name in nav_dirs {
		if input.action_pressed(name) {
			moved = i
			n.hold_dir = i
			n.hold_time = 0
		}
	}
	if moved < 0 && n.hold_dir >= 0 {
		if input.action_down(nav_dirs[n.hold_dir]) {
			n.hold_time += dt
			if n.hold_time >= n.repeat_delay {
				n.hold_time -= n.repeat_rate
				moved = n.hold_dir
			}
		} else {
			n.hold_dir = -1
		}
	}
	if moved >= 0 {
		if n.focused == unsafe { nil } {
			if n.auto_focus && cands.len > 0 {
				n.set_focus(top_left(cands))
			}
		} else {
			cur := cands.filter(voidptr(it.node) == voidptr(n.focused))
			if cur.len > 0 {
				if next := n.pick(cands, cur[0].center, n.focused, nav_vec(moved)) {
					n.set_focus(next)
				}
			}
		}
	}
	if input.action_pressed('ui_accept') && n.focused != unsafe { nil } {
		if mut b := n.focused.get_component[Button]() {
			b.press()
		}
	}
	if input.action_pressed('ui_cancel') {
		n.cancelled = true
		if n.on_cancel != unsafe { nil } {
			n.on_cancel()
		}
	}
}

fn top_left(cands []NavCand) &core.Node {
	mut best := cands[0]
	for c in cands {
		if c.center.y < best.center.y - 0.5
			|| (math.abs(c.center.y - best.center.y) <= 0.5 && c.center.x < best.center.x) {
			best = c
		}
	}
	return best.node
}

// meshes draws the focus ring (render.MeshDrawable): four bars around the focused Button.
pub fn (n &UINav) meshes() []TexturedMesh {
	if n.focused == unsafe { nil } || n.node == unsafe { nil } {
		return []
	}
	r := node_rect(n.focused) or { return [] }
	fm := n.focused.world_matrix()
	inv := n.node.world_matrix().inverse()
	pts := [inv.apply(fm.apply(core.vec2(r.x, r.y))), inv.apply(fm.apply(core.vec2(r.x + r.w, r.y))),
		inv.apply(fm.apply(core.vec2(r.x + r.w, r.y + r.h))),
		inv.apply(fm.apply(core.vec2(r.x, r.y + r.h)))]
	centroid := (pts[0] + pts[1] + pts[2] + pts[3]).mul(0.25)
	mut positions := []f32{}
	mut indices := []int{}
	for i in 0 .. 4 {
		a := pts[i]
		b := pts[(i + 1) % 4]
		edge := (b - a).normalized()
		mut out := core.vec2(-edge.y, edge.x)
		mid := (a + b).mul(0.5) - centroid
		if mid.x * out.x + mid.y * out.y < 0 {
			out = out.mul(-1) // point away from the middle
		}
		in_d := n.ring_pad
		out_d := n.ring_pad + n.ring_width
		ext := out_d // run past the ends so the corners are filled
		p0 := a - edge.mul(ext)
		p1 := b + edge.mul(ext)
		base := positions.len / 2
		for q in [p0 + out.mul(in_d), p1 + out.mul(in_d), p1 + out.mul(out_d), p0 + out.mul(out_d)] {
			positions << q.x
			positions << q.y
		}
		indices << [base, base + 1, base + 2, base, base + 2, base + 3]
	}
	return [
		TexturedMesh{
			positions: positions
			indices:   indices
			color:     n.ring_color
		},
	]
}
