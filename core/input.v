module core

// Key codes following the GLFW/sokol standard, so App can translate gg events without importing gg here.
pub enum Key {
	space  = 32
	a      = 65
	d      = 68
	r      = 82
	s      = 83
	w      = 87
	escape = 256
	enter  = 257
	right  = 262
	left   = 263
	down   = 264
	up     = 265
	f1     = 290
}

// Input — keyboard/mouse state for the current frame.
@[heap]
pub struct Input {
mut:
	down     map[int]bool
	pressed  map[int]bool
	released map[int]bool
pub mut:
	mouse      Vec2
	mouse_down bool
	// Per-frame mouse state (reset by end_frame), set through mouse_press / mouse_release / mouse_scroll.
	mouse_pressed  bool
	mouse_released bool
	scroll         Vec2 // wheel delta this frame (y > 0 = wheel up)
}

pub fn (i &Input) is_down(k Key) bool {
	return i.down[int(k)]
}

// was_pressed: true for exactly one frame when the key was just pressed.
pub fn (i &Input) was_pressed(k Key) bool {
	return i.pressed[int(k)]
}

pub fn (i &Input) was_released(k Key) bool {
	return i.released[int(k)]
}

// axis returns -1, 0 or 1.
pub fn (i &Input) axis(negative Key, positive Key) f32 {
	mut v := f32(0)
	if i.is_down(negative) {
		v -= 1
	}
	if i.is_down(positive) {
		v += 1
	}
	return v
}

// axis_x: left/right arrows or A/D.
pub fn (i &Input) axis_x() f32 {
	return clamp1(i.axis(.left, .right) + i.axis(.a, .d))
}

// axis_y: up/down arrows or W/S (y points downward).
pub fn (i &Input) axis_y() f32 {
	return clamp1(i.axis(.up, .down) + i.axis(.w, .s))
}

// The functions below are called by App.

pub fn (mut i Input) key_down(code int) {
	if !i.down[code] {
		i.pressed[code] = true
	}
	i.down[code] = true
}

pub fn (mut i Input) key_up(code int) {
	i.down[code] = false
	i.released[code] = true
}

pub fn (mut i Input) mouse_press() {
	if !i.mouse_down {
		i.mouse_pressed = true
	}
	i.mouse_down = true
}

pub fn (mut i Input) mouse_release() {
	if i.mouse_down {
		i.mouse_released = true
	}
	i.mouse_down = false
}

pub fn (mut i Input) mouse_scroll(dx f32, dy f32) {
	i.scroll = i.scroll + Vec2{dx, dy}
}

pub fn (mut i Input) end_frame() {
	i.pressed.clear()
	i.released.clear()
	i.mouse_pressed = false
	i.mouse_released = false
	i.scroll = Vec2{}
}

fn clamp1(v f32) f32 {
	return if v > 1 {
		1
	} else if v < -1 {
		-1
	} else {
		v
	}
}
