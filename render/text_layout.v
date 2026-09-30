module render

// TextMeasurer — measures the width of one line of text at a font size, in node units. The renderer measures
// with the real font; tests use a fixed width per character. (An interface rather than a closure: closures
// created every frame are unsafe in V 0.5.2 web builds.)
pub interface TextMeasurer {
	width(s string, size f32) f32
}

// wrap_lines splits `text` into the lines to draw: at each '\n', and (when max_width > 0) before a word
// that would pass max_width. A word longer than a whole line is cut between characters. Spaces where a
// line breaks are dropped.
pub fn wrap_lines(text string, max_width f32, size f32, m TextMeasurer) []string {
	mut out := []string{}
	for para in text.split('\n') {
		if max_width <= 0 || m.width(para, size) <= max_width {
			out << para
			continue
		}
		mut line := ''
		for word in para.split(' ') {
			candidate := if line == '' { word } else { line + ' ' + word }
			if m.width(candidate, size) <= max_width {
				line = candidate
				continue
			}
			if line != '' {
				out << line
				line = ''
			}
			if m.width(word, size) <= max_width {
				line = word
				continue
			}
			// the word alone is too wide: cut it (also how text without spaces, e.g. CJK, wraps)
			mut piece := ''
			for r in word.runes() {
				next := piece + r.str()
				if piece != '' && m.width(next, size) > max_width {
					out << piece
					piece = r.str()
				} else {
					piece = next
				}
			}
			line = piece
		}
		out << line
	}
	return out
}

// TextBlock — laid out text: its lines, the font size they fit at, and the line height.
pub struct TextBlock {
pub:
	lines       []string
	size        f32
	line_height f32
}

// height of the block: the last line counts as one font size, the others as a line height.
pub fn (b TextBlock) height() f32 {
	if b.lines.len == 0 {
		return 0
	}
	return (b.lines.len - 1) * b.line_height + b.size
}

// layout_text wraps `text` to `box_w` (when `wrap`), and with `shrink` lowers the font size (down to
// `min_size`) until the block fits `box_w` x `box_h`. A zero box size means unlimited in that direction.
pub fn layout_text(text string, size f32, spacing f32, wrap bool, shrink bool, box_w f32, box_h f32, min_size f32, m TextMeasurer) TextBlock {
	mut s := size
	for {
		lines := wrap_lines(text, if wrap { box_w } else { 0 }, s, m)
		block := TextBlock{
			lines:       lines
			size:        s
			line_height: s * spacing
		}
		if !shrink || s <= min_size || fits(block, box_w, box_h, m) {
			return block
		}
		s = if s - 1 < min_size { min_size } else { s - 1 }
	}
	return TextBlock{}
}

fn fits(b TextBlock, w f32, h f32, m TextMeasurer) bool {
	if h > 0 && b.height() > h {
		return false
	}
	if w > 0 {
		for l in b.lines {
			if m.width(l, b.size) > w {
				return false
			}
		}
	}
	return true
}
