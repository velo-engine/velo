module editor

import gg
import time
import engine.core

// Minimal "immediate mode" widget set drawn with gg: the whole UI is redrawn every frame,
// and widgets return interaction results immediately (clicked, value changed, ...).

struct Rect {
	x f32
	y f32
	w f32
	h f32
}

fn (r Rect) has(p core.Vec2) bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

fn (r Rect) shrink(m f32) Rect {
	return Rect{r.x + m, r.y + m, r.w - 2 * m, r.h - 2 * m}
}

fn (r Rect) intersect(o Rect) Rect {
	x0 := if r.x > o.x { r.x } else { o.x }
	y0 := if r.y > o.y { r.y } else { o.y }
	x1 := if r.x + r.w < o.x + o.w { r.x + r.w } else { o.x + o.w }
	y1 := if r.y + r.h < o.y + o.h { r.y + r.h } else { o.y + o.h }
	return Rect{x0, y0, if x1 > x0 { x1 - x0 } else { 0 }, if y1 > y0 { y1 - y0 } else { 0 }}
}

// Color palette (dark, similar to Unity/Cocos).
const c_bg = gg.Color{38, 38, 42, 255}
const c_panel = gg.Color{50, 50, 56, 255}
const c_header = gg.Color{62, 62, 70, 255}
const c_border = gg.Color{24, 24, 28, 255}
const c_text = gg.Color{220, 220, 225, 255}
const c_dim = gg.Color{140, 140, 150, 255}
const c_field = gg.Color{32, 32, 36, 255}
const c_field_focus = gg.Color{20, 20, 24, 255}
const c_button = gg.Color{74, 74, 84, 255}
const c_button_hover = gg.Color{92, 92, 104, 255}
const c_accent = gg.Color{64, 132, 230, 255}
const c_select = gg.Color{44, 93, 160, 255}
const c_prefab = gg.Color{110, 180, 255, 255}
const c_prefab_owned = gg.Color{150, 190, 230, 255}
const c_override = gg.Color{255, 200, 90, 255}
const c_error = gg.Color{255, 110, 100, 255}
const c_ok = gg.Color{130, 210, 130, 255}
const c_play = gg.Color{70, 110, 70, 255}

const font_size = 14
const row_h = f32(22)

// Kind of the input field being edited, to know how to interpret the text on commit.
enum ValueKind {
	raw    // full .scene syntax, e.g. [255, 255, 255, 255]
	number // a number
	text   // a string, no quotes needed
	asset  // path or asset ID
}

enum TargetKind {
	none
	node_name
	node_prop
	comp_field
	prompt
}

// EditTarget — what the input field being edited points to (applied on commit).
struct EditTarget {
	kind  TargetKind
	node  &core.Node = unsafe { nil }
	comp  int
	field string
	part  int = -1 // for Vec2: 0 = x, 1 = y; -1 = the whole value
	value ValueKind
}

struct Ui {
mut:
	ctx &gg.Context = unsafe { nil }
	// mouse (logical coordinates)
	mouse         core.Vec2
	mouse_down    bool
	pressed       bool // left button just pressed this frame
	released      bool
	double        bool
	right_down    bool
	middle_down   bool
	scroll        f32
	last_click_ms i64
	last_click_at core.Vec2
	consumed      bool // a widget has already taken this frame's click
	mods          u32
	// focused input field
	focus      string
	focus_rect Rect
	buf        []rune
	cursor     int
	target     EditTarget
	// overlay (menus, dialogs): widgets on lower layers do not receive the mouse
	layer        int
	overlay      Rect // popup menu area from the previous frame
	overlay_next Rect
	modal        bool
	clip         Rect
	win_w        f32
	win_h        f32
}

fn (mut u Ui) on_mouse_down(button gg.MouseButton) {
	match button {
		.left {
			u.mouse_down = true
			u.pressed = true
			now := time.ticks()
			u.double = now - u.last_click_ms < 350 && u.mouse.distance(u.last_click_at) < 5
			u.last_click_ms = if u.double { 0 } else { now }
			u.last_click_at = u.mouse
		}
		.right {
			u.right_down = true
		}
		.middle {
			u.middle_down = true
		}
		else {}
	}
}

fn (mut u Ui) on_mouse_up(button gg.MouseButton) {
	match button {
		.left {
			u.mouse_down = false
			u.released = true
		}
		.right {
			u.right_down = false
		}
		.middle {
			u.middle_down = false
		}
		else {}
	}
}

fn (mut u Ui) end_frame() {
	u.pressed = false
	u.released = false
	u.double = false
	u.scroll = 0
	u.consumed = false
	u.overlay = u.overlay_next
	u.overlay_next = Rect{}
}

// interactive: whether the mouse is over `r` and widgets on the current layer may receive the mouse.
fn (u &Ui) hover(r Rect) bool {
	if !r.has(u.mouse) || !u.clip.has(u.mouse) {
		return false
	}
	if u.layer == 0 && (u.modal || u.overlay.has(u.mouse)) {
		return false
	}
	return true
}

// click: left button just pressed on `r` (and no widget has taken it yet).
fn (mut u Ui) click(r Rect) bool {
	if u.pressed && !u.consumed && u.hover(r) {
		u.consumed = true
		return true
	}
	return false
}

fn (u &Ui) ctrl() bool {
	return u.mods & (u32(gg.Modifier.ctrl) | u32(gg.Modifier.super)) != 0
}

fn (u &Ui) shift() bool {
	return u.mods & u32(gg.Modifier.shift) != 0
}

fn (u &Ui) alt() bool {
	return u.mods & u32(gg.Modifier.alt) != 0
}

// ---------- Drawing ----------

fn (mut u Ui) set_clip(r Rect) {
	u.clip = r
	u.ctx.scissor_rect(int(r.x), int(r.y), int(r.w), int(r.h))
}

fn (mut u Ui) reset_clip() {
	u.set_clip(Rect{0, 0, u.win_w, u.win_h})
}

fn (u &Ui) fill(r Rect, c gg.Color) {
	u.ctx.draw_rect_filled(r.x, r.y, r.w, r.h, c)
}

fn (u &Ui) outline(r Rect, c gg.Color) {
	u.ctx.draw_rect_empty(r.x, r.y, r.w, r.h, c)
}

fn (u &Ui) text(x f32, y f32, s string, c gg.Color) {
	u.ctx.draw_text(int(x), int(y), s, color: c, size: font_size)
}

// text_in: text vertically centered in `r`, with left padding `pad`.
fn (u &Ui) text_in(r Rect, s string, c gg.Color, pad f32) {
	u.ctx.draw_text(int(r.x + pad), int(r.y + r.h / 2), s,
		color:          c
		size:           font_size
		vertical_align: .middle
	)
}

fn (u &Ui) text_center(r Rect, s string, c gg.Color) {
	u.ctx.draw_text(int(r.x + r.w / 2), int(r.y + r.h / 2), s,
		color:          c
		size:           font_size
		align:          .center
		vertical_align: .middle
	)
}

fn (u &Ui) text_width(s string) f32 {
	u.ctx.set_text_cfg(size: font_size)
	return u.ctx.text_width(s)
}

// ---------- Widget ----------

fn (mut u Ui) button(r Rect, label string, enabled bool) bool {
	hov := enabled && u.hover(r)
	u.fill(r, if hov { c_button_hover } else { c_button })
	u.outline(r, c_border)
	u.text_center(r, label, if enabled { c_text } else { c_dim })
	return enabled && u.click(r)
}

// toggle_button: a button with an on state (drawn in the pressed color).
fn (mut u Ui) toggle_button(r Rect, label string, on bool, on_color gg.Color) bool {
	hov := u.hover(r)
	u.fill(r, if on {
		on_color
	} else if hov {
		c_button_hover
	} else {
		c_button
	})
	u.outline(r, c_border)
	u.text_center(r, label, c_text)
	return u.click(r)
}

// checkbox returns true if the user clicked to change the value.
fn (mut u Ui) checkbox(r Rect, value bool, enabled bool) bool {
	box := Rect{r.x, r.y + (r.h - 14) / 2, 14, 14}
	u.fill(box, c_field)
	u.outline(box, if enabled && u.hover(r) { c_accent } else { c_border })
	if value {
		u.fill(box.shrink(3), if enabled { c_accent } else { c_dim })
	}
	return enabled && u.click(r)
}

// triangle: expand/collapse arrow for the hierarchy tree.
fn (u &Ui) triangle(x f32, y f32, open bool, c gg.Color) {
	if open {
		u.ctx.draw_triangle_filled(x, y + 2, x + 8, y + 2, x + 4, y + 7, c)
	} else {
		u.ctx.draw_triangle_filled(x + 2, y, x + 2, y + 8, x + 7, y + 4, c)
	}
}

// ---------- Input fields ----------

fn (mut u Ui) focus_field(id string, r Rect, value string, target EditTarget) {
	u.focus = id
	u.focus_rect = r
	u.buf = value.runes()
	u.cursor = u.buf.len
	u.target = target
}

fn (mut u Ui) unfocus() {
	u.focus = ''
	u.target = EditTarget{}
	u.buf = []
}

// draw_field draws an input field; returns true if the user just clicked it to start editing.
fn (mut u Ui) draw_field(id string, r Rect, shown string, color gg.Color, enabled bool) bool {
	focused := u.focus == id
	if focused {
		u.focus_rect = r // the position may change when scrolling
	}
	u.fill(r, if focused { c_field_focus } else { c_field })
	u.outline(r, if focused {
		c_accent
	} else if enabled && u.hover(r) {
		c_button_hover
	} else {
		c_border
	})
	old := u.clip
	u.set_clip(old.intersect(r.shrink(1)))
	if focused {
		s := u.buf.string()
		u.text_in(r, s, c_text, 5)
		cx := r.x + 5 + u.text_width(u.buf[..u.cursor].string())
		if (time.ticks() / 500) % 2 == 0 {
			u.ctx.draw_line(cx, r.y + 4, cx, r.y + r.h - 4, c_text)
		}
	} else {
		u.text_in(r, shown, if enabled { color } else { c_dim }, 5)
	}
	u.set_clip(old)
	return enabled && !focused && u.click(r)
}

// on_key handles keys while an input field is focused. Returns 'commit', 'cancel' or ''.
fn (mut u Ui) on_key(key gg.KeyCode) string {
	match key {
		.backspace {
			if u.cursor > 0 {
				u.buf.delete(u.cursor - 1)
				u.cursor--
			}
		}
		.delete {
			if u.cursor < u.buf.len {
				u.buf.delete(u.cursor)
			}
		}
		.left {
			if u.cursor > 0 {
				u.cursor--
			}
		}
		.right {
			if u.cursor < u.buf.len {
				u.cursor++
			}
		}
		.home {
			u.cursor = 0
		}
		.end {
			u.cursor = u.buf.len
		}
		.enter, .kp_enter, .tab {
			return 'commit'
		}
		.escape {
			return 'cancel'
		}
		else {}
	}

	if u.ctrl() && key == .a {
		u.cursor = u.buf.len
	}
	return ''
}

fn (mut u Ui) on_char(c u32) {
	if c < 32 || c == 127 || u.ctrl() {
		return
	}
	u.buf.insert(u.cursor, rune(c))
	u.cursor++
}
