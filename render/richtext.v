module render

import math
import velo.core

// Rich text for Label (`rich = true`): BBCode-style tags inside one label.
//
//   "Collect [color=#ffd24a]5 coins[/color] to open the [b]gate[/b]!"
//   "[size=32]Big[/size] and small, [u]underlined[/u], [s]struck[/s]"
//
// Tags: [b] bold (drawn heavier), [i] italic (accepted; the font has no italic, so it is only kept for the API),
// [u] underline, [s] strike-through, [color=#rgb | #rrggbb | #rrggbbaa | red | green | ...], [size=N] (pixels, before
// the node's scale). Each closes with [/tag]; an unclosed one runs to the end; an unknown tag or a stray [/x] is
// shown as written; `[[` is a literal `[`.

pub struct RichStyle {
pub:
	color     core.Color
	has_color bool // false: the label's own color
	size      f32  // 0 = the label's size
	bold      bool
	italic    bool
	underline bool
	strike    bool
}

pub struct RichRun {
pub:
	text  string // may hold '\n'
	style RichStyle
}

const named_colors = {
	'white':  core.Color{255, 255, 255, 255}
	'black':  core.Color{0, 0, 0, 255}
	'red':    core.Color{235, 70, 70, 255}
	'green':  core.Color{90, 210, 100, 255}
	'blue':   core.Color{80, 140, 240, 255}
	'yellow': core.Color{250, 220, 70, 255}
	'orange': core.Color{250, 160, 50, 255}
	'purple': core.Color{170, 100, 230, 255}
	'cyan':   core.Color{80, 220, 230, 255}
	'pink':   core.Color{250, 130, 190, 255}
	'gray':   core.Color{150, 150, 150, 255}
	'grey':   core.Color{150, 150, 150, 255}
	'brown':  core.Color{150, 100, 60, 255}
}

// parse_color reads `#rgb`, `#rrggbb`, `#rrggbbaa` or a color name.
pub fn parse_color(s string) ?core.Color {
	t := s.trim_space().to_lower()
	if c := named_colors[t] {
		return c
	}
	if !t.starts_with('#') {
		return none
	}
	h := t[1..]
	if !h.bytes().all(it.is_hex_digit()) {
		return none
	}
	hex := fn (v string) u8 {
		return u8(('0x' + v).int())
	}
	return match h.len {
		3 { core.Color{hex(h[0..1] + h[0..1]), hex(h[1..2] + h[1..2]), hex(h[2..3] + h[2..3]), 255} }
		6 { core.Color{hex(h[0..2]), hex(h[2..4]), hex(h[4..6]), 255} }
		8 { core.Color{hex(h[0..2]), hex(h[2..4]), hex(h[4..6]), hex(h[6..8])} }
		else { none }
	}
}

struct OpenTag {
	name  string
	style RichStyle
}

struct RichParser {
mut:
	runs  []RichRun
	stack []OpenTag
	cur   RichStyle
	buf   string
}

fn (mut p RichParser) flush() {
	if p.buf != '' {
		p.runs << RichRun{p.buf, p.cur}
		p.buf = ''
	}
}

// parse_rich splits BBCode text into styled runs (adjacent text of one style is one run).
pub fn parse_rich(text string) []RichRun {
	mut p := RichParser{}
	mut i := 0
	for i < text.len {
		ch := text[i]
		if ch != `[` {
			p.buf += ch.ascii_str()
			i++
			continue
		}
		if i + 1 < text.len && text[i + 1] == `[` { // [[ = a literal [
			p.buf += '['
			i += 2
			continue
		}
		close := text.index_after(']', i + 1) or {
			p.buf += text[i..]
			break
		}
		tag := text[i + 1..close]
		if tag.starts_with('/') {
			name := tag[1..].to_lower()
			mut idx := -1
			for k := p.stack.len - 1; k >= 0; k-- {
				if p.stack[k].name == name {
					idx = k
					break
				}
			}
			if idx >= 0 {
				p.flush()
				p.cur = p.stack[idx].style // back to what it was before the tag
				p.stack = p.stack[..idx].clone()
				i = close + 1
				continue
			}
		} else {
			name := tag.all_before('=').to_lower()
			arg := if tag.contains('=') { tag.all_after('=') } else { '' }
			if next := apply_tag(p.cur, name, arg) {
				p.flush()
				p.stack << OpenTag{name, p.cur}
				p.cur = next
				i = close + 1
				continue
			}
		}
		p.buf += text[i..close + 1] // not a tag we know: show it as written
		i = close + 1
	}
	p.flush()
	return p.runs
}

fn apply_tag(st RichStyle, name string, arg string) ?RichStyle {
	match name {
		'b' {
			return RichStyle{
				...st
				bold: true
			}
		}
		'i' {
			return RichStyle{
				...st
				italic: true
			}
		}
		'u' {
			return RichStyle{
				...st
				underline: true
			}
		}
		's' {
			return RichStyle{
				...st
				strike: true
			}
		}
		'color' {
			c := parse_color(arg) or { return none }
			return RichStyle{
				...st
				color:     c
				has_color: true
			}
		}
		'size' {
			if arg == '' || !arg.bytes().all(it.is_digit() || it == `.`) {
				return none
			}
			return RichStyle{
				...st
				size: arg.f32()
			}
		}
		else {
			return none
		}
	}
}

// strip_rich: the text without its tags (what a plain Label would have to show).
pub fn strip_rich(text string) string {
	mut out := ''
	for r in parse_rich(text) {
		out += r.text
	}
	return out
}

// ---------- Layout ----------

// RichPiece — a stretch of one style on one line, `x` from the line's left edge.
pub struct RichPiece {
pub:
	text  string
	x     f32
	width f32
	size  f32 // resolved: never 0
	style RichStyle
}

pub struct RichLine {
pub:
	pieces []RichPiece
	width  f32
	size   f32 // the biggest piece
}

pub struct RichBlock {
pub:
	lines       []RichLine
	scale       f32 // 1, or less when `shrink` made it smaller
	line_height []f32
	width       f32
	height      f32
}

struct RichToken {
	text   string
	style  RichStyle
	size   f32
	breaks int // how many '\n' came before this token (an empty line is two in a row)
}

// space_width: the advance of one space. Measuring ' ' alone (or a trailing space) can give 0 with some fonts, so it is the
// difference a space makes between two letters.
fn space_width(m TextMeasurer, size f32) f32 {
	return m.width('a a', size) - m.width('aa', size)
}

// token_width: a word plus its trailing spaces, each space counted at its real advance.
fn token_width(m TextMeasurer, text string, size f32) f32 {
	word := text.trim_right(' ')
	spaces := text.len - word.len
	return m.width(word, size) + f32(spaces) * space_width(m, size)
}

// tokenize splits runs into words (each with its trailing space) so lines can break between them.
fn tokenize(runs []RichRun, base_size f32, scale f32) []RichToken {
	mut out := []RichToken{}
	mut brk := 0
	for r in runs {
		size := (if r.style.size > 0 { r.style.size } else { base_size }) * scale
		lines := r.text.split('\n')
		for li, line in lines {
			if li > 0 {
				brk++
			}
			mut start := 0
			for k := 0; k <= line.len; k++ {
				if k == line.len || line[k] == ` ` {
					end := if k < line.len { k + 1 } else { k } // keep the space with the word
					if end > start {
						out << RichToken{line[start..end], r.style, size, brk}
						brk = 0
					}
					start = end
				}
			}
		}
	}
	if brk > 0 { // newlines at the very end still make (empty) lines
		out << RichToken{'', RichStyle{}, base_size * scale, brk}
	}
	return out
}

fn same_look(a RichStyle, b RichStyle, sa f32, sb f32) bool {
	return a == b && sa == sb
}

struct RichLayout {
	m TextMeasurer
mut:
	lines  []RichLine
	pieces []RichPiece
	x      f32
	big    f32
}

// finish closes the current line (its width leaves out the last word's trailing space).
fn (mut l RichLayout) finish(base f32) {
	mut w := l.x
	if l.pieces.len > 0 {
		last := l.pieces[l.pieces.len - 1]
		if last.text.ends_with(' ') {
			w -= space_width(l.m, last.size)
		}
	}
	l.lines << RichLine{l.pieces, w, if l.big > 0 { l.big } else { base }}
	l.pieces = []
	l.x = 0
	l.big = 0
}

// layout_rich lays styled runs out in lines: wrapped at `max_width` (0 = never), `spacing` times the biggest
// size on a line apart, every size multiplied by `scale`.
pub fn layout_rich(runs []RichRun, base_size f32, spacing f32, max_width f32, scale f32, m TextMeasurer) RichBlock {
	mut l := RichLayout{
		m: m
	}
	base := base_size * scale
	for t in tokenize(runs, base_size, scale) {
		for _ in 0 .. t.breaks {
			l.finish(base)
		}
		if t.text == '' {
			continue
		}
		visible := m.width(t.text.trim_right(' '), t.size)
		tw := token_width(m, t.text, t.size)
		if max_width > 0 && l.pieces.len > 0 && l.x + visible > max_width {
			l.finish(base)
		}
		// join the previous piece when the look is the same
		if l.pieces.len > 0
			&& same_look(l.pieces[l.pieces.len - 1].style, t.style, l.pieces[l.pieces.len - 1].size, t.size) {
			prev := l.pieces[l.pieces.len - 1]
			joined := prev.text + t.text
			jw := prev.width + tw
			l.pieces[l.pieces.len - 1] = RichPiece{joined, prev.x, jw, t.size, t.style}
			l.x = prev.x + jw
		} else {
			l.pieces << RichPiece{t.text, l.x, tw, t.size, t.style}
			l.x += tw
		}
		if t.size > l.big {
			l.big = t.size
		}
	}
	if l.pieces.len > 0 || l.lines.len == 0 {
		l.finish(base)
	}
	mut heights := []f32{}
	mut total := f32(0)
	mut widest := f32(0)
	for i, ln in l.lines {
		h := ln.size * spacing
		heights << h
		total += if i < l.lines.len - 1 { h } else { ln.size }
		if ln.width > widest {
			widest = ln.width
		}
	}
	return RichBlock{l.lines, scale, heights, widest, total}
}

// layout_rich_fit: layout_rich, shrinking everything (never below `min_size` for the base size) until the block fits
// a `box_w` x `box_h` box (0 = unlimited in that direction).
pub fn layout_rich_fit(runs []RichRun, base_size f32, spacing f32, wrap bool, shrink bool, box_w f32, box_h f32, min_size f32, m TextMeasurer) RichBlock {
	mut scale := f32(1)
	min_scale := if base_size > min_size { min_size / base_size } else { f32(1) }
	for {
		b := layout_rich(runs, base_size, spacing, if wrap { box_w } else { 0 }, scale, m)
		fits_w := box_w <= 0 || b.width <= box_w + 0.001
		fits_h := box_h <= 0 || b.height <= box_h + 0.001
		if !shrink || (fits_w && fits_h) || scale <= min_scale {
			return b
		}
		scale = math.max(scale * 0.94, min_scale)
	}
	return RichBlock{}
}
