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

pub enum TouchPhase {
	began      // went down this frame
	moved      // moved this frame
	stationary // down, did not move this frame
	ended      // lifted this frame (still listed until end_frame)
	cancelled  // taken away by the system this frame (still listed until end_frame)
}

// Touch — one finger on the screen (or the mouse, see Input.pointers).
pub struct Touch {
pub mut:
	id    u64
	pos   Vec2 // current position, world units
	start Vec2 // where it went down
	phase TouchPhase
}

struct PendingTouchEnd {
	id        u64
	pos       Vec2
	cancelled bool
}

pub fn (t Touch) is_up() bool {
	return t.phase in [.ended, .cancelled]
}

// The id of the mouse in Input.pointers.
pub const mouse_pointer_id = u64(0xffff_ffff_ffff_ffff)

// Input — keyboard/mouse/touch state for the current frame.
@[heap]
pub struct Input {
mut:
	down     map[int]bool
	pressed  map[int]bool
	released map[int]bool
	// The touch that drives the mouse fields (the first finger down), see touch_begin.
	mouse_touch u64
	mouse_start Vec2
	// A release that arrived in the same frame as its press is applied next frame, so the press is
	// seen for one frame (synthetic clicks and very quick taps would otherwise be lost).
	release_pending bool
	ends_pending    []PendingTouchEnd
pub mut:
	mouse      Vec2
	mouse_down bool
	// Per-frame mouse state (reset by end_frame), set through mouse_press / mouse_release / mouse_scroll.
	mouse_pressed  bool
	mouse_released bool
	scroll         Vec2 // wheel delta this frame (y > 0 = wheel up)
	// Fingers currently down, plus the ones lifted this frame. Set through touch_begin / touch_move / touch_end.
	touches []Touch
	// True while the mouse fields are emulated by a touch, so mouse-only code keeps working on touch screens.
	mouse_from_touch bool
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
		i.mouse_start = i.mouse
	}
	i.mouse_down = true
}

pub fn (mut i Input) mouse_release() {
	if i.mouse_down && i.mouse_pressed {
		i.release_pending = true // pressed this frame: release next frame
		return
	}
	if i.mouse_down {
		i.mouse_released = true
	}
	i.mouse_down = false
}

pub fn (mut i Input) mouse_scroll(dx f32, dy f32) {
	i.scroll = i.scroll + Vec2{dx, dy}
}

// touch returns the finger with this id, if it is down or was lifted this frame.
pub fn (i &Input) touch(id u64) ?Touch {
	for t in i.touches {
		if t.id == id {
			return t
		}
	}
	return none
}

// pointers: every finger plus the mouse while its left button is down (id mouse_pointer_id), without
// counting a touch twice. Code written against pointers works the same with a mouse and with several fingers.
pub fn (i &Input) pointers() []Touch {
	mut out := i.touches.clone()
	if !i.mouse_from_touch && (i.mouse_down || i.mouse_released) {
		phase := if i.mouse_released {
			TouchPhase.ended
		} else if i.mouse_pressed {
			TouchPhase.began
		} else {
			TouchPhase.moved
		}
		out << Touch{mouse_pointer_id, i.mouse, i.mouse_start, phase}
	}
	return out
}

// pointer returns the pointer with this id (see pointers).
pub fn (i &Input) pointer(id u64) ?Touch {
	if id == mouse_pointer_id {
		for p in i.pointers() {
			if p.id == id {
				return p
			}
		}
		return none
	}
	return i.touch(id)
}

pub fn (mut i Input) end_frame() {
	i.pressed.clear()
	i.released.clear()
	i.mouse_pressed = false
	i.mouse_released = false
	i.scroll = Vec2{}
	i.touches = i.touches.filter(!it.is_up())
	for mut t in i.touches {
		t.phase = .stationary
	}
	if !i.mouse_down {
		i.mouse_from_touch = false
	}
	// Releases that came in the same frame as their press happen now, at the start of the next frame.
	if i.release_pending {
		i.release_pending = false
		i.mouse_release()
	}
	ends := i.ends_pending.clone()
	i.ends_pending.clear()
	for e in ends {
		i.touch_end(e.id, e.pos, e.cancelled)
	}
}

// touch_begin: a finger went down. The first finger down also acts as the left mouse button until it is lifted.
pub fn (mut i Input) touch_begin(id u64, pos Vec2) {
	i.touches = i.touches.filter(it.id != id)
	i.touches << Touch{id, pos, pos, .began}
	if !i.mouse_down {
		i.mouse_touch = id
		i.mouse_from_touch = true
		i.mouse = pos
		i.mouse_press()
	}
}

pub fn (mut i Input) touch_move(id u64, pos Vec2) {
	for mut t in i.touches {
		if t.id == id && !t.is_up() {
			t.pos = pos
			if t.phase == .stationary {
				t.phase = .moved
			}
		}
	}
	if i.mouse_from_touch && i.mouse_touch == id {
		i.mouse = pos
	}
}

// touch_end: a finger was lifted (or cancelled by the system). It stays in `touches` until end_frame.
pub fn (mut i Input) touch_end(id u64, pos Vec2, cancelled bool) {
	for t in i.touches {
		if t.id == id && t.phase == .began {
			// went down this frame: keep it down for this frame, lift it next frame
			i.ends_pending << PendingTouchEnd{id, pos, cancelled}
			for mut tt in i.touches {
				if tt.id == id {
					tt.pos = pos
				}
			}
			return
		}
	}
	for mut t in i.touches {
		if t.id == id {
			t.pos = pos
			t.phase = if cancelled { TouchPhase.cancelled } else { TouchPhase.ended }
		}
	}
	if i.mouse_from_touch && i.mouse_touch == id && i.mouse_down {
		i.mouse = pos
		i.mouse_release()
	}
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
