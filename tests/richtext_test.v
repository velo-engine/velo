import velo.core
import velo.render

// every character is half the font size wide
struct Half {}

fn (h Half) width(s string, size f32) f32 {
	return f32(s.runes().len) * size * 0.5
}

fn texts(runs []render.RichRun) []string {
	return runs.map(it.text)
}

fn test_plain_text_is_one_run() {
	r := render.parse_rich('hello world')
	assert r.len == 1 && r[0].text == 'hello world' && r[0].style == render.RichStyle{}
	assert render.parse_rich('').len == 0
}

fn test_tags_style_the_text_between_them() {
	r := render.parse_rich('a [b]bold[/b] [u]under[/u][s]x[/s] z')
	assert texts(r) == ['a ', 'bold', ' ', 'under', 'x', ' z']
	assert r[1].style.bold && !r[1].style.underline
	assert r[3].style.underline && r[4].style.strike
	assert r[5].style == render.RichStyle{} // back to plain
	assert render.strip_rich('a [b]bold[/b] z') == 'a bold z'
}

fn test_colors_and_sizes() {
	r :=
		render.parse_rich('[color=#f00]a[/color][color=#00ff80]b[/color][color=#11223344]c[/color][color=blue]d[/color][size=32]e[/size]')
	assert r[0].style.color == core.rgba(255, 0, 0, 255) && r[0].style.has_color
	assert r[1].style.color == core.rgba(0, 255, 128, 255)
	assert r[2].style.color == core.rgba(0x11, 0x22, 0x33, 0x44)
	assert r[3].style.has_color && r[3].style.color.b > r[3].style.color.r
	assert r[4].style.size == 32
	assert render.parse_color('#zzz') == none && render.parse_color('nope') == none
	assert render.parse_color('RED')? == render.parse_color('red')?
}

fn test_nesting_restores_the_outer_style() {
	r := render.parse_rich('[b]x[color=red]y[/color]z[/b]w')
	assert texts(r) == ['x', 'y', 'z', 'w']
	assert r[1].style.bold && r[1].style.has_color // inside both
	assert r[2].style.bold && !r[2].style.has_color // only bold again
	assert !r[3].style.bold // nothing
	// closing the outer one also ends the inner one
	r2 := render.parse_rich('[b][u]x[/b]y')
	assert r2[0].style.bold && r2[0].style.underline && !r2[1].style.bold && !r2[1].style.underline
}

fn test_unknown_and_stray_tags_stay_as_written() {
	assert render.strip_rich('a [wobble]b[/wobble] c') == 'a [wobble]b[/wobble] c'
	assert render.strip_rich('x [/b] y') == 'x [/b] y' // a closing tag nothing opened
	assert render.strip_rich('[color=nope]x') == '[color=nope]x' // an unusable argument
	assert render.strip_rich('[size=big]x') == '[size=big]x'
	assert render.strip_rich('open [b bracket') == 'open [b bracket' // never closed
	assert render.strip_rich('[[b]] stays') == '[b]] stays' // [[ is a literal [
	r := render.parse_rich('[b]no end')
	assert r.len == 1 && r[0].style.bold // an unclosed tag runs to the end
}

fn test_layout_one_line_pieces_and_positions() {
	runs := render.parse_rich('ab [b]cd[/b] ef')
	b := render.layout_rich(runs, 20, 1.25, 0, 1, Half{})
	assert b.lines.len == 1
	l := b.lines[0]
	assert l.pieces.map(it.text) == ['ab ', 'cd', ' ef']
	assert l.pieces[0].x == 0 && l.pieces[1].x == 30 && l.pieces[2].x == 50 // 10 px per character
	assert l.width == 80 // 'ab cd ef' = 8 chars
	assert b.height == 20 && b.width == 80
}

fn test_layout_mixed_sizes_wrap_and_newlines() {
	// 'big' is 30 px big (15 px per character): 45 wide
	runs := render.parse_rich('aa [size=30]big[/size] cc dd')
	one := render.layout_rich(runs, 20, 1.0, 0, 1, Half{})
	assert one.lines.len == 1 && one.lines[0].size == 30 // the line is as tall as its biggest piece
	// wrapping at 90: 'aa big' = 30 + 45 = 75 fits, ' cc' would be 75 + 30 = 105 > 90
	w := render.layout_rich(runs, 20, 1.0, 90, 1, Half{})
	assert w.lines.len == 2
	assert w.lines[0].pieces.map(it.text).join('') == 'aa big '
	assert w.lines[1].pieces.map(it.text).join('') == 'cc dd'
	assert w.lines[0].width == 75 // the trailing space is not counted
	assert w.line_height[0] == 30 && w.height == 30 + 20
	// explicit newlines
	n := render.layout_rich(render.parse_rich('one\ntwo\n\nfour'), 10, 1.5, 0, 1, Half{})
	assert n.lines.len == 4 && n.lines[2].pieces.len == 0
	assert n.line_height.len == 4 && n.line_height[0] == 15
}

fn test_shrink_fits_the_box() {
	runs := render.parse_rich('[b]hello[/b] [size=40]wide[/size] text')
	free := render.layout_rich_fit(runs, 20, 1.25, false, false, 0, 0, 6, Half{})
	fit := render.layout_rich_fit(runs, 20, 1.25, false, true, 120, 0, 6, Half{})
	assert free.width > 120
	assert fit.width <= 120.01 && fit.scale < 1
	assert fit.lines[0].pieces[0].size < free.lines[0].pieces[0].size // every size shrank together
	// never below the minimum base size
	tiny := render.layout_rich_fit(runs, 20, 1.25, false, true, 5, 0, 12, Half{})
	assert tiny.lines[0].pieces[0].size >= 11.9
}

// a measurer like gg's with some fonts: a space only counts between letters, never alone or at the end
struct NoTrailingSpace {}

fn (h NoTrailingSpace) width(s string, size f32) f32 {
	t := s.trim_space()
	return f32(t.runes().len) * size * 0.5
}

fn test_trailing_spaces_still_take_room() {
	// 'a a' = 3 characters trimmed = 15 at size 10... but a real space is wider than 0: the layout must not rely on
	// measuring the space on its own. With this measurer a space between words measures as the difference of
	// 'a a' and 'aa' = (3 - 2) * 5 = 5.
	runs := render.parse_rich('aa [color=red]bb[/color] cc')
	b := render.layout_rich(runs, 10, 1.0, 0, 1, NoTrailingSpace{})
	l := b.lines[0]
	assert l.pieces.map(it.text) == ['aa ', 'bb', ' cc']
	assert l.pieces[0].width == 15 // 'aa' (10) + one space (5)
	assert l.pieces[1].x == 15 && l.pieces[2].x == 25 // the space after 'aa' is not lost
	assert l.width == 25 + 5 + 10 // the last piece: ' cc' = a space + 'cc'
}
