module render

import velo.core
import velo.assets

// TextInput — a one-line text field (names, chat, codes). Needs a UITransform (its box); add a Panel for the
// background. Click or tap it to type: arrows, Home/End, Backspace/Delete edit, Enter submits, Esc or a click
// elsewhere stops editing. Phones and browsers show their on-screen keyboard while it is focused.
//
//   node Name {
//     UITransform { size = [260, 40] }
//     Panel { color = [0, 0, 0, 140]  radius = 6 }
//     TextInput { placeholder = "Your name"  max_length = 16 }
//   }
//
// Poll `changed` (the text changed this frame) and `submitted` (Enter was pressed this frame), or read `text`.
pub struct TextInput {
	core.Component
pub mut:
	text              string
	placeholder       string
	size              int        = 20
	color             core.Color = core.white
	placeholder_color core.Color = core.rgba(255, 255, 255, 110)
	caret_color       core.Color = core.rgba(255, 255, 255, 230)
	font              assets.AssetRef[assets.Font]
	max_length        int // characters; 0 = no limit
	password          bool
	padding           f32  = 8
	blur_on_submit    bool = true // Enter also stops editing
	focused           bool         @[hide]
	changed           bool         @[hide]
	submitted         bool         @[hide]
	caret             int          @[hide] // position in characters (runes)
	blink             f32          @[hide]
	scroll            f32          @[hide] // horizontal scroll of the text, node units (kept by the renderer)
	font_data         &assets.Font = unsafe { nil } @[hide]
}

pub fn (mut t TextInput) on_load() {
	t.font_data = load_font(t.node, t.font)
	t.caret = t.text.runes().len
}

pub fn (mut t TextInput) on_destroy() {
	t.blur()
	t.font_data = release_font(t.node, t.font_data)
}

// focus starts editing (the caret goes to the end).
pub fn (mut t TextInput) focus() {
	if t.focused {
		return
	}
	t.focused = true
	t.caret = t.text.runes().len
	t.blink = 0
}

// blur stops editing.
pub fn (mut t TextInput) blur() {
	if !t.focused {
		return
	}
	t.focused = false
}

pub fn (mut t TextInput) update(dt f32) {
	t.changed = false
	t.submitted = false
	input := t.input()
	for p in input.pointers() {
		if p.phase == .began {
			if ui_hit(t.node, p.pos) {
				t.focus()
			} else {
				t.blur()
			}
		}
	}
	if !t.focused {
		return
	}
	mut input_mut := t.node.scene.input
	input_mut.text_editing = true // set every frame while focused (Input.end_frame clears it)
	t.blink += t.scene().unscaled_dt
	mut runes := t.text.runes()
	t.caret = if t.caret < 0 {
		0
	} else if t.caret > runes.len {
		runes.len
	} else {
		t.caret
	}
	before := t.text
	if input.text != '' {
		for r in input.text.runes() {
			if t.max_length > 0 && runes.len >= t.max_length {
				break
			}
			runes.insert(t.caret, r)
			t.caret++
		}
	}
	if input.was_typed(.backspace) && t.caret > 0 {
		runes.delete(t.caret - 1)
		t.caret--
	}
	if input.was_typed(.delete) && t.caret < runes.len {
		runes.delete(t.caret)
	}
	if input.was_typed(.left) && t.caret > 0 {
		t.caret--
	}
	if input.was_typed(.right) && t.caret < runes.len {
		t.caret++
	}
	if input.was_pressed(.home) {
		t.caret = 0
	}
	if input.was_pressed(.end) {
		t.caret = runes.len
	}
	t.text = runes.string()
	if t.text != before || input.text != '' || input.was_typed(.left) || input.was_typed(.right) {
		t.blink = 0 // keep the caret visible while typing
	}
	t.changed = t.text != before
	if input.was_pressed(.enter) {
		t.submitted = true
		if t.blur_on_submit {
			t.blur()
		}
	}
	if input.was_pressed(.escape) {
		t.blur()
	}
}

// shown: what is drawn (dots for a password).
pub fn (t &TextInput) shown() string {
	return if t.password { '*'.repeat(t.text.runes().len) } else { t.text }
}

// caret_visible: blinking twice a second while focused.
pub fn (t &TextInput) caret_visible() bool {
	return t.focused && int(t.blink * 2) % 2 == 0
}

// update_scroll keeps the caret inside the box: `caret_x` is its offset from the start of the text and
// `inner` the width available (both node units). Returns the scroll to draw with.
pub fn (mut t TextInput) update_scroll(caret_x f32, text_w f32, inner f32) f32 {
	if caret_x - t.scroll > inner {
		t.scroll = caret_x - inner
	}
	if caret_x < t.scroll {
		t.scroll = caret_x
	}
	// no empty space on the right while the text is longer than the box
	max_scroll := if text_w > inner { text_w - inner } else { f32(0) }
	if t.scroll > max_scroll {
		t.scroll = max_scroll
	}
	if t.scroll < 0 {
		t.scroll = 0
	}
	return t.scroll
}
