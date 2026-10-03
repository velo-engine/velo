module core

// Input actions: the game asks for "jump" or "move_left", not for a key, so bindings can be changed at run time
// (a settings screen), saved, and shared by keyboard and gamepad.
//
//   input.bind('jump', 'key:space', 'pad:a')
//   input.bind('move_left', 'key:a', 'key:left', 'axis:left_x-', 'pad:dpad_left')
//   if input.action_pressed('jump') { ... }
//   dx := input.action_axis('move_left', 'move_right')     // -1..1, analog on a stick

pub enum GamepadButton {
	a
	b
	x
	y
	left_shoulder
	right_shoulder
	back
	start
	left_stick
	right_stick
	dpad_up
	dpad_down
	dpad_left
	dpad_right
}

pub enum GamepadAxis {
	left_x // -1 left .. 1 right
	left_y // -1 up .. 1 down (like the screen)
	right_x
	right_y
	left_trigger // 0..1
	right_trigger
}

pub const max_gamepads = 4

// Stick values smaller than this count as 0 (rescaled so the output still reaches 1).
pub const gamepad_deadzone = f32(0.2)

// An axis binding counts as "down" for the action once it is pushed past this.
const axis_press_threshold = f32(0.5)

struct GamepadState {
mut:
	connected bool
	down      map[int]bool
	pressed   map[int]bool
	released  map[int]bool
	axes      map[int]f32
}

enum BindingKind {
	key
	pad_button
	pad_axis
}

// Binding — one physical input that triggers an action.
pub struct Binding {
pub:
	kind BindingKind
	code int
	sign int // pad_axis: +1 or -1, the direction that counts
	pad  int = -1 // gamepad index, -1 = any
}

// parse_binding reads "key:space", "pad:a", "axis:left_x-", "axis:right_y+"; a pad name may be followed by
// "@1" to only listen to the second gamepad ("pad:a@1").
pub fn parse_binding(s string) !Binding {
	kind, rest0 := s.trim_space().split_once(':') or { return error('binding "${s}": expected kind:name') }
	mut rest := rest0
	mut pad := -1
	if rest.contains('@') {
		name, idx := rest.split_once('@') or { '', '' }
		pad = idx.int()
		rest = name
	}
	match kind {
		'key' {
			k := key_from_name(rest) or { return error('binding "${s}": unknown key') }
			return Binding{
				kind: .key
				code: int(k)
			}
		}
		'pad' {
			b := button_from_name(rest) or { return error('binding "${s}": unknown button') }
			return Binding{
				kind: .pad_button
				code: int(b)
				pad:  pad
			}
		}
		'axis' {
			if !rest.ends_with('+') && !rest.ends_with('-') {
				return error('binding "${s}": axis needs a + or - direction')
			}
			a := axis_from_name(rest[..rest.len - 1]) or { return error('binding "${s}": unknown axis') }
			return Binding{
				kind: .pad_axis
				code: int(a)
				sign: if rest.ends_with('-') { -1 } else { 1 }
				pad:  pad
			}
		}
		else {
			return error('binding "${s}": kind must be key, pad or axis')
		}
	}
}

pub fn (b Binding) str() string {
	at := if b.pad >= 0 { '@${b.pad}' } else { '' }
	return match b.kind {
		.key { 'key:${unsafe { Key(b.code) }}' }
		.pad_button { 'pad:${unsafe { GamepadButton(b.code) }}${at}' }
		.pad_axis { 'axis:${unsafe { GamepadAxis(b.code) }}${if b.sign < 0 { '-' } else { '+' }}${at}' }
	}
}

fn key_from_name(name string) ?Key {
	n := if name.len == 1 && name[0] >= `0` && name[0] <= `9` { '_${name}' } else { name }
	$for v in Key.values {
		if v.name == n {
			return v.value
		}
	}
	return none
}

fn button_from_name(name string) ?GamepadButton {
	$for v in GamepadButton.values {
		if v.name == name {
			return v.value
		}
	}
	return none
}

fn axis_from_name(name string) ?GamepadAxis {
	$for v in GamepadAxis.values {
		if v.name == name {
			return v.value
		}
	}
	return none
}

// ActionMap — action name -> bindings. Owned by Input (input.actions).
pub struct ActionMap {
mut:
	bindings map[string][]Binding
	// action value last frame (for axis bindings, which have no press event of their own)
	prev map[string]bool
}

// bind replaces the bindings of an action. Panics on a malformed binding string (a typo in code, not user data);
// use ActionMap.load for text that comes from a file.
pub fn (mut i Input) bind(action string, bindings ...string) {
	mut list := []Binding{}
	for s in bindings {
		list << parse_binding(s) or { panic(err) }
	}
	i.actions.bindings[action] = list
}

// add_binding adds one binding to an action (keeps the others); used by "press a key to rebind" screens.
pub fn (mut i Input) add_binding(action string, b Binding) {
	i.actions.bindings[action] << b
}

pub fn (mut i Input) clear_binding(action string) {
	i.actions.bindings[action] = []Binding{}
}

pub fn (i &Input) bindings_of(action string) []Binding {
	return i.actions.bindings[action].clone()
}

// action_value: 0..1, how hard the action is pressed (keys and buttons give 0 or 1, sticks and triggers analog).
pub fn (i &Input) action_value(action string) f32 {
	mut v := f32(0)
	for b in i.actions.bindings[action] {
		x := match b.kind {
			.key {
				if i.down[b.code] { f32(1) } else { f32(0) }
			}
			.pad_button {
				i.pad_any(b.pad, fn [b] (p &GamepadState) f32 {
					return if p.down[b.code] { f32(1) } else { f32(0) }
				})
			}
			.pad_axis {
				i.pad_any(b.pad, fn [b] (p &GamepadState) f32 {
					a := apply_deadzone(p.axes[b.code])
					return if a * f32(b.sign) > 0 { a * f32(b.sign) } else { f32(0) }
				})
			}
		}
		if x > v {
			v = x
		}
	}
	return v
}

// pad_any: the largest value of f over the gamepad `pad`, or over all connected ones for -1.
fn (i &Input) pad_any(pad int, f fn (&GamepadState) f32) f32 {
	mut v := f32(0)
	for n in 0 .. max_gamepads {
		if (pad >= 0 && pad != n) || !i.pads[n].connected {
			continue
		}
		x := f(&i.pads[n])
		if x > v {
			v = x
		}
	}
	return v
}

pub fn (i &Input) action_down(action string) bool {
	return i.action_value(action) >= axis_press_threshold
}

// action_pressed: true for exactly one frame when the action went down.
pub fn (i &Input) action_pressed(action string) bool {
	if i.action_event(action, true) {
		return true
	}
	return i.action_value(action) >= axis_press_threshold && !i.actions.prev[action] && i.has_axis(action)
}

// action_released: true for exactly one frame when the action went up.
pub fn (i &Input) action_released(action string) bool {
	if i.action_event(action, false) {
		return true
	}
	return i.action_value(action) < axis_press_threshold && i.actions.prev[action] && i.has_axis(action)
}

fn (i &Input) has_axis(action string) bool {
	for b in i.actions.bindings[action] {
		if b.kind == .pad_axis {
			return true
		}
	}
	return false
}

// action_event: a key or button binding of the action was pressed (or released) this frame.
fn (i &Input) action_event(action string, press bool) bool {
	for b in i.actions.bindings[action] {
		match b.kind {
			.key {
				hit := if press { i.pressed[b.code] } else { i.released[b.code] }
				if hit {
					return true
				}
			}
			.pad_button {
				for n in 0 .. max_gamepads {
					if (b.pad >= 0 && b.pad != n) || !i.pads[n].connected {
						continue
					}
					hit := if press { i.pads[n].pressed[b.code] } else { i.pads[n].released[b.code] }
					if hit {
						return true
					}
				}
			}
			.pad_axis {}
		}
	}
	return false
}

// action_axis: positive - negative, in -1..1.
pub fn (i &Input) action_axis(negative string, positive string) f32 {
	return clamp1(i.action_value(positive) - i.action_value(negative))
}

// action_vec2: a movement vector from four actions, clamped to length 1 (so diagonals are not faster).
pub fn (i &Input) action_vec2(left string, right string, up string, down string) Vec2 {
	v := Vec2{i.action_axis(left, right), i.action_axis(up, down)}
	l := v.length()
	return if l > 1 { v.mul(1 / l) } else { v }
}

// any_binding_input returns what the player is pressing right now as a Binding (key, gamepad button or a stick
// pushed far), for a "press something to rebind" screen; none when nothing is pressed this frame.
pub fn (i &Input) any_binding_input() ?Binding {
	for code, p in i.pressed {
		if p {
			return Binding{
				kind: .key
				code: code
			}
		}
	}
	for n in 0 .. max_gamepads {
		if !i.pads[n].connected {
			continue
		}
		for code, p in i.pads[n].pressed {
			if p {
				return Binding{
					kind: .pad_button
					code: code
				}
			}
		}
		for code, a in i.pads[n].axes {
			if code < int(GamepadAxis.left_trigger) && (a > 0.7 || a < -0.7) {
				return Binding{
					kind: .pad_axis
					code: code
					sign: if a < 0 { -1 } else { 1 }
				}
			}
		}
	}
	return none
}

// actions_to_text writes every action as `name = binding, binding` (sorted), for the save file or a config.
pub fn (i &Input) actions_to_text() string {
	mut names := i.actions.bindings.keys()
	names.sort()
	mut out := ''
	for n in names {
		out += '${n} = ${i.actions.bindings[n].map(it.str()).join(', ')}\n'
	}
	return out
}

// load_actions reads the actions_to_text format. A line that fails to parse is skipped and reported in the
// returned error list; the other actions are still applied (a hand-edited config should not break the game).
pub fn (mut i Input) load_actions(text string) []string {
	mut errors := []string{}
	for line in text.split_into_lines() {
		l := line.trim_space()
		if l == '' || l.starts_with('#') {
			continue
		}
		name, rest := l.split_once('=') or {
			errors << 'missing "=": ${l}'
			continue
		}
		mut list := []Binding{}
		mut ok := true
		for part in rest.split(',') {
			if part.trim_space() == '' {
				continue
			}
			list << parse_binding(part) or {
				errors << err.msg()
				ok = false
				break
			}
		}
		if ok {
			i.actions.bindings[name.trim_space()] = list
		}
	}
	return errors
}

fn apply_deadzone(v f32) f32 {
	a := if v < 0 { -v } else { v }
	if a < gamepad_deadzone {
		return 0
	}
	r := (a - gamepad_deadzone) / (1 - gamepad_deadzone)
	return if v < 0 { -r } else { r }
}

// The functions below are called by the gamepad backend (App) — and by tests.

pub fn (mut i Input) gamepad_connect(pad int, connected bool) {
	if pad < 0 || pad >= max_gamepads {
		return
	}
	i.pads[pad].connected = connected
	if !connected {
		i.pads[pad] = GamepadState{}
	}
}

pub fn (mut i Input) gamepad_button(pad int, b GamepadButton, down bool) {
	if pad < 0 || pad >= max_gamepads {
		return
	}
	code := int(b)
	if down && !i.pads[pad].down[code] {
		i.pads[pad].pressed[code] = true
	} else if !down && i.pads[pad].down[code] {
		i.pads[pad].released[code] = true
	}
	i.pads[pad].down[code] = down
}

pub fn (mut i Input) gamepad_axis_set(pad int, a GamepadAxis, v f32) {
	if pad < 0 || pad >= max_gamepads {
		return
	}
	i.pads[pad].axes[int(a)] = v
}

pub fn (i &Input) gamepad_is_connected(pad int) bool {
	return pad >= 0 && pad < max_gamepads && i.pads[pad].connected
}

pub fn (i &Input) gamepad_is_down(pad int, b GamepadButton) bool {
	return pad >= 0 && pad < max_gamepads && i.pads[pad].down[int(b)]
}

pub fn (i &Input) gamepad_was_pressed(pad int, b GamepadButton) bool {
	return pad >= 0 && pad < max_gamepads && i.pads[pad].pressed[int(b)]
}

// gamepad_axis: the stick/trigger value after the dead zone, -1..1.
pub fn (i &Input) gamepad_axis(pad int, a GamepadAxis) f32 {
	if pad < 0 || pad >= max_gamepads {
		return 0
	}
	return apply_deadzone(i.pads[pad].axes[int(a)])
}

// end_gamepad_frame clears the per-frame press/release flags and remembers the action state (called by end_frame).
fn (mut i Input) end_actions_frame() {
	for n in 0 .. max_gamepads {
		i.pads[n].pressed.clear()
		i.pads[n].released.clear()
	}
	for name, _ in i.actions.bindings {
		i.actions.prev[name] = i.action_value(name) >= axis_press_threshold
	}
}
