import os
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render

// Every character is 10 units wide at size 20 (scales with the size).
struct Mono {}

fn (m Mono) width(s string, size f32) f32 {
	return f32(s.runes().len) * size / 2
}

fn test_wrap_lines() {
	m := Mono{}
	assert render.wrap_lines('hello world', 0, 20, m) == ['hello world']
	assert render.wrap_lines('hello big world', 100, 20, m) == ['hello big', 'world']
	assert render.wrap_lines('one\ntwo three', 1000, 20, m) == ['one', 'two three']
	assert render.wrap_lines('abcdefghijklmnop', 50, 20, m) == ['abcde', 'fghij', 'klmno', 'p']
	assert render.wrap_lines('xin chào thế giới', 80, 20, m) == ['xin chào', 'thế giới']
	assert render.wrap_lines('', 50, 20, m) == ['']
}

fn test_layout_shrinks_to_fit() {
	m := Mono{}
	b := render.layout_text('a long title', 20, 1.25, false, true, 60, 0, 6, m)
	assert b.lines == ['a long title'] && b.size == 10 // 12 characters * 5 = 60
	w := render.layout_text('one two three four', 20, 1.25, true, true, 100, 40, 6, m)
	assert w.height() <= 40 && w.lines.len >= 2
	assert render.layout_text('x', 20, 1.25, true, true, 100, 100, 6, m).size == 20 // fits: unchanged
}

fn field(name string, pos core.Vec2) (&core.Node, &render.TextInput) {
	mut n := core.Node.new(name).with(&render.UITransform{
		size: core.vec2(200, 40)
	})
	n.position = pos
	t := n.add_component(&render.TextInput{
		max_length: 8
	})
	return n, t
}

fn frame(mut s core.Scene) {
	s.update(0.016)
	s.input.end_frame()
}

fn click(mut s core.Scene, p core.Vec2) {
	s.input.mouse = p
	s.input.mouse_press()
	frame(mut s)
	s.input.mouse_release()
	frame(mut s)
}

fn press(mut s core.Scene, k core.Key) {
	s.input.key_down(int(k))
	s.update(0.016)
	s.input.end_frame()
	s.input.key_up(int(k))
}

fn typ(mut s core.Scene, text string) {
	for r in text.runes() {
		s.input.type_char(u32(r))
	}
	frame(mut s)
}

fn test_text_input_editing() {
	mut s := core.Scene.new('Test')
	mut a, mut ta := field('A', core.vec2(150, 50))
	mut b, mut tb := field('B', core.vec2(150, 150))
	s.add(mut a)
	s.add(mut b)
	typ(mut s, 'ignored') // nothing focused
	assert ta.text == ''
	click(mut s, core.vec2(150, 50))
	assert ta.focused && !tb.focused
	s.input.mouse = core.vec2(0, 0)
	s.input.type_char(u32(`V`))
	s.update(0.016)
	assert s.input.text_editing // set while a field is focused (App shows the phone keyboard)
	assert ta.changed
	s.input.end_frame()
	typ(mut s, 'iệt Nam!!') // stops at max_length 8
	assert ta.text == 'Việt Nam'
	press(mut s, .backspace)
	press(mut s, .home)
	press(mut s, .delete)
	assert ta.text == 'iệt Na' && ta.caret == 0
	press(mut s, .right)
	typ(mut s, '-')
	assert ta.text == 'i-ệt Na'
	press(mut s, .end)
	assert ta.caret == 7
	click(mut s, core.vec2(150, 150)) // another field takes over
	assert !ta.focused && tb.focused
	typ(mut s, 'ok')
	press(mut s, .enter)
	assert tb.text == 'ok' && !tb.focused
	assert ta.text == 'i-ệt Na'
	tb.password = true
	assert tb.shown() == '**'
}

fn test_text_input_scroll_keeps_caret_visible() {
	mut t := render.TextInput{}
	assert t.update_scroll(50, 50, 100) == 0
	assert t.update_scroll(250, 300, 100) == 150 // caret past the right edge
	assert t.update_scroll(20, 300, 100) == 20 // caret left of the view
	assert t.update_scroll(20, 60, 100) == 0 // text shorter than the box again
}

fn button(name string, pos core.Vec2) (&core.Node, &render.Button) {
	mut n := core.Node.new(name).with(&render.UITransform{
		size: core.vec2(100, 40)
	})
	n.position = pos
	b := n.add_component(&render.Button{})
	return n, b
}

fn clicked_after(mut s core.Scene, p core.Vec2, b &render.Button) bool {
	s.input.mouse = p
	s.input.mouse_press()
	frame(mut s)
	s.input.mouse_release()
	s.update(0.016)
	c := b.clicked
	s.input.end_frame()
	return c
}

fn test_only_the_topmost_ui_gets_the_click() {
	mut s := core.Scene.new('Test')
	mut under, bu := button('Under', core.vec2(100, 100))
	mut over, bo := button('Over', core.vec2(120, 100)) // drawn later = on top
	s.add(mut under)
	s.add(mut over)
	assert clicked_after(mut s, core.vec2(110, 100), bo) // where both overlap
	assert !bu.clicked
	assert clicked_after(mut s, core.vec2(60, 100), bu) // only Under there
	// a dialog panel over both blocks them
	mut dialog := core.Node.new('Dialog').with(&render.UITransform{
		size: core.vec2(400, 300)
	}).with(&render.Panel{})
	dialog.position = core.vec2(100, 100)
	s.add(mut dialog)
	assert !clicked_after(mut s, core.vec2(110, 100), bo)
	assert render.pointer_over_ui(s, core.vec2(110, 100))
	assert !render.pointer_over_ui(s, core.vec2(900, 900))
	// z_index decides, not tree order
	dialog.z_index = -1
	assert clicked_after(mut s, core.vec2(110, 100), bo)
	// a panel that lets clicks through
	dialog.z_index = 0
	dialog.get_component[render.Panel]()?.block_input = false
	assert clicked_after(mut s, core.vec2(110, 100), bo)
}

fn test_font_asset_and_label_font() {
	dir := os.join_path(os.temp_dir(), 'velo_text_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'title.ttf'), 'not really a font')!
	// a .ttf imported by an older version was "unknown": it becomes a font
	os.write_file(os.join_path(dir, 'old.otf'), 'x')!
	os.write_file(os.join_path(dir, 'old.otf.meta'), 'id: 0a0b0c0d\nkind: unknown\nversion: 1\n')!
	mut db := assets.open(dir)!
	id := db.id_of('title.ttf')?
	assert db.entry(id)?.kind == .font
	assert db.entry('0a0b0c0d')?.kind == .font
	assert os.read_file(os.join_path(dir, 'old.otf.meta'))!.contains('kind: font')
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut l := serialize.new_loader(reg, db)
	mut root := l.instantiate_source('node Main {
  node Title { Label { text = "Hi"  font = @asset("${id}")  wrap = true  shadow_color = [0, 0, 0, 200]  outline_width = 2 } }
  node Name { UITransform { size = [200, 40] }  TextInput { placeholder = "Name"  password = true } }
}',
		'main.scene')!
	mut s := l.new_scene(mut root)
	label := root.find('Title')?.get_component[render.Label]()?
	assert label.wrap && label.shadow_color.a == 200 && label.outline_width == 2
	assert label.font_data != unsafe { nil } && db.entry(id)?.refs == 1
	assert root.find('Name')?.get_component[render.TextInput]()?.password
	s.unload()
	assert db.entry(id)?.refs == 0
}
