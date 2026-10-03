import os
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render

fn ui_node(name string, pos core.Vec2, size core.Vec2) &core.Node {
	mut n := core.Node.new(name).with(&render.UITransform{
		size: size
	})
	n.position = pos
	return n
}

fn click_at(mut s core.Scene, p core.Vec2) {
	s.input.mouse = p
	s.input.mouse_press()
	s.update(0.016)
	s.input.end_frame()
	s.input.mouse_release()
	s.update(0.016)
}

fn test_button_click_and_tint() {
	mut s := core.Scene.new('Test')
	mut btn_node := ui_node('Btn', core.vec2(100, 100), core.vec2(80, 40)).with(&render.Panel{
		color: core.rgba(200, 200, 200, 255)
	})
	mut btn := btn_node.add_component(&render.Button{})
	s.add(mut btn_node)
	mut clicks := &[]string{}
	btn.on_click(fn [mut clicks] (mut b render.Button) {
		clicks << b.node.name
	})
	// press outside, release inside: no click
	s.input.mouse = core.vec2(0, 0)
	s.input.mouse_press()
	s.update(0.016)
	s.input.end_frame()
	s.input.mouse = core.vec2(100, 100)
	s.input.mouse_release()
	s.update(0.016)
	s.input.end_frame()
	assert clicks.len == 0
	assert btn.hovered
	// hover tint multiplies the panel's own color
	assert btn_node.get_component[render.Panel]()?.color.r == u8(200 * 225 / 255)

	click_at(mut s, core.vec2(130, 110))
	assert clicks.len == 1
	assert (*clicks)[0] == 'Btn'
	assert btn.clicked

	btn.interactable = false
	s.input.end_frame()
	click_at(mut s, core.vec2(100, 100))
	assert clicks.len == 1
}

fn test_toggle_flips_checkmark() {
	mut s := core.Scene.new('Test')
	mut t :=
		ui_node('Toggle', core.vec2(50, 50), core.vec2(30, 30)).with(&render.Button{}).with(&render.Toggle{})
	mut check := core.Node.new('Checkmark')
	t.add_child(mut check)
	s.add(mut t)
	s.update(0.016)
	assert !check.active
	click_at(mut s, core.vec2(50, 50))
	assert t.get_component[render.Toggle]()?.is_on
	assert check.active
}

fn test_widget_aligns_and_stretches() {
	mut s := core.Scene.new('Test')
	s.view_size = core.vec2(800, 600)
	mut bar := ui_node('Bar', core.Vec2{}, core.vec2(10, 40)).with(&render.Widget{
		align_left:   true
		left:         10
		align_right:  true
		right:        20
		align_bottom: true
		bottom:       5
	})
	s.add(mut bar)
	// child centered in the bar, anchored at its top-left corner
	mut icon := core.Node.new('Icon').with(&render.UITransform{
		size:   core.vec2(20, 20)
		anchor: core.vec2(0, 0)
	}).with(&render.Widget{
		align_center_x: true
		align_center_y: true
	})
	bar.add_child(mut icon)
	s.update(0.016)
	assert bar.get_component[render.UITransform]()?.size == core.vec2(770, 40)
	assert bar.position == core.vec2(10 + 385, 600 - 5 - 20)
	assert icon.position == core.vec2(-10, -10)
}

fn test_vertical_layout_resizes_container() {
	mut s := core.Scene.new('Test')
	mut list := core.Node.new('List').with(&render.UITransform{
		size:   core.vec2(100, 0)
		anchor: core.vec2(0, 0)
	}).with(&render.Layout{
		spacing:     core.vec2(0, 10)
		padding:     5
		child_align: 'center'
	})
	for i in 0 .. 3 {
		mut item := ui_node('Item${i}', core.Vec2{}, core.vec2(50, 20))
		list.add_child(mut item)
	}
	s.add(mut list)
	s.update(0.016)
	assert list.get_component[render.UITransform]()?.size.y == 5 + 20 * 3 + 10 * 2 + 5
	assert list.children[0].position == core.vec2(50, 15)
	assert list.children[2].position == core.vec2(50, 15 + 60)
}

fn test_scroll_view_wheel_is_clamped_and_clips_hits() {
	mut s := core.Scene.new('Test')
	mut view := ui_node('View', core.vec2(0, 0), core.vec2(100, 100)).with(&render.ScrollView{
		wheel_speed: 30
	})
	view.get_component[render.UITransform]()?.anchor = core.vec2(0, 0)
	mut content := core.Node.new('Content').with(&render.UITransform{
		size:   core.vec2(100, 300)
		anchor: core.vec2(0, 0)
	})
	view.add_child(mut content)
	mut far := ui_node('Far', core.vec2(50, 250), core.vec2(100, 20))
	content.add_child(mut far)
	s.add(mut view)

	// item below the viewport cannot be hit
	assert !render.hit_test(far, core.vec2(50, 250))
	s.input.mouse = core.vec2(50, 50)
	s.input.mouse_scroll(0, -3) // wheel down: content moves up
	s.update(0.016)
	s.input.end_frame()
	assert content.position.y == -90
	for _ in 0 .. 10 {
		s.input.mouse_scroll(0, -3)
		s.update(0.016)
		s.input.end_frame()
	}
	assert content.position.y == -200 // 300 content - 100 viewport
	assert render.hit_test(far, core.vec2(50, 50))
	mut sv := view.get_component[render.ScrollView]()?
	sv.scroll_to_top()
	assert content.position.y == 0
}

fn test_scroll_view_drag_cancels_button() {
	mut s := core.Scene.new('Test')
	mut view := ui_node('View', core.vec2(50, 50), core.vec2(100, 100)).with(&render.ScrollView{
		elastic: false
		inertia: false
	})
	mut content := ui_node('Content', core.vec2(0, 0), core.vec2(100, 400))
	mut b := ui_node('B', core.vec2(0, 0), core.vec2(100, 40))
	mut btn := b.add_component(&render.Button{})
	content.add_child(mut b)
	view.add_child(mut content)
	s.add(mut view)
	s.update(0.016)
	start_y := content.position.y

	s.input.mouse = core.vec2(50, 50)
	s.input.mouse_press()
	s.update(0.016)
	s.input.end_frame()
	assert btn.pressed
	s.input.mouse = core.vec2(50, 20)
	s.update(0.016)
	s.input.end_frame()
	s.input.mouse_release()
	s.update(0.016)
	assert !btn.clicked
	assert content.position.y == start_y - 30
}

fn test_ui_components_load_from_scene_text() {
	dir := os.join_path(os.temp_dir(), 'velo_ui_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	db := assets.open(dir)!
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut l := serialize.new_loader(reg, db)
	n := l.instantiate_source('
node Menu {
  UITransform { size = [300, 200] }
  Panel { color = [30, 30, 40, 230]  radius = 8  border_width = 2 }
  Widget { align_center_x = true  align_center_y = true }
  node Bar { UITransform { size = [200, 16] }  ProgressBar { progress = 0.25  direction = "vertical" } }
  node Play {
    UITransform { size = [160, 44] }
    Button { hover_color = [255, 0, 0, 255] }
    Label { text = "Play"  align = "center"  valign = "middle" }
  }
  node List { UITransform { size = [100, 100] }  ScrollView { horizontal = true  vertical = false } }
  node Grid { UITransform { }  Layout { kind = "grid"  columns = 3 } }
}',
		'menu.scene')!
	assert n.get_component[render.Panel]()?.radius == 8
	assert n.find('Bar')?.get_component[render.ProgressBar]()?.progress == 0.25
	assert n.find('Play')?.get_component[render.Button]()?.hover_color == core.rgba(255, 0, 0, 255)
	assert n.find('Play')?.get_component[render.Label]()?.valign == 'middle'
	assert n.find('List')?.get_component[render.ScrollView]()?.horizontal
	assert n.find('Grid')?.get_component[render.Layout]()?.columns == 3
}

fn test_touches_track_fingers_and_emulate_mouse_with_the_first() {
	mut i := core.Input{}
	i.touch_begin(7, core.vec2(10, 10))
	i.touch_begin(9, core.vec2(50, 50))
	assert i.touches.len == 2
	assert i.mouse_down && i.mouse_pressed && i.mouse_from_touch
	assert i.mouse == core.vec2(10, 10)
	assert i.pointers().len == 2 // the emulated mouse is not counted twice
	i.end_frame()
	assert i.touch(9)?.phase == .stationary
	i.touch_move(9, core.vec2(60, 50))
	assert i.touch(9)?.phase == .moved
	assert i.mouse == core.vec2(10, 10) // only the first finger moves the mouse
	i.touch_end(7, core.vec2(12, 10), false)
	assert i.mouse_released && !i.mouse_down
	assert i.touch(7)?.phase == .ended
	i.end_frame()
	assert i.touches.len == 1
	assert !i.mouse_from_touch
	assert i.touch(7) == none
}

fn test_mouse_is_a_pointer() {
	mut i := core.Input{}
	assert i.pointers().len == 0
	i.mouse = core.vec2(5, 5)
	i.mouse_press()
	assert i.pointer(core.mouse_pointer_id)?.phase == .began
	i.end_frame()
	i.mouse = core.vec2(8, 5)
	assert i.pointer(core.mouse_pointer_id)?.pos == core.vec2(8, 5)
	assert i.pointer(core.mouse_pointer_id)?.start == core.vec2(5, 5)
	i.mouse_release()
	assert i.pointer(core.mouse_pointer_id)?.phase == .ended
	i.end_frame()
	assert i.pointers().len == 0
}

fn test_button_tapped_by_second_finger() {
	mut s := core.Scene.new('Test')
	mut btn_node := ui_node('Btn', core.vec2(300, 100), core.vec2(80, 40))
	btn := btn_node.add_component(&render.Button{})
	s.add(mut btn_node)
	s.input.touch_begin(1, core.vec2(20, 20)) // first finger elsewhere (it drives the mouse)
	s.update(0.016)
	s.input.end_frame()
	s.input.touch_begin(2, core.vec2(300, 100))
	s.update(0.016)
	s.input.end_frame()
	assert btn.pressed
	s.input.touch_end(2, core.vec2(305, 100), false)
	s.update(0.016)
	assert btn.clicked
	s.input.end_frame()
	s.update(0.016)
	assert !btn.clicked
}

fn test_joystick_follows_its_finger() {
	mut s := core.Scene.new('Test')
	mut stick := ui_node('Stick', core.vec2(100, 400), core.vec2(200, 200))
	j := stick.add_component(&render.Joystick{
		radius: 50
	})
	mut base := core.Node.new('Base')
	mut knob := core.Node.new('Knob')
	base.add_child(mut knob)
	stick.add_child(mut base)
	s.add(mut stick)
	s.update(0.016)
	s.input.touch_begin(3, core.vec2(500, 100)) // outside: ignored
	s.input.touch_begin(4, core.vec2(120, 410)) // floating: the base lands under the thumb
	s.update(0.016)
	s.input.end_frame()
	assert j.held
	assert base.position == core.vec2(20, 10)
	s.input.touch_move(4, core.vec2(145, 410))
	s.update(0.016)
	s.input.end_frame()
	assert knob.position == core.vec2(25, 0)
	assert j.value == core.vec2(0.5, 0)
	s.input.touch_move(4, core.vec2(120, 510)) // past the radius: clamped
	s.update(0.016)
	s.input.end_frame()
	assert knob.position == core.vec2(0, 50)
	assert j.value == core.vec2(0, 1)
	s.input.touch_end(4, core.vec2(120, 510), false)
	s.update(0.016)
	assert !j.held
	assert j.value == core.Vec2{}
	assert base.position == core.Vec2{}
	assert knob.position == core.Vec2{}
}

fn test_widget_safe_area() {
	mut s := core.Scene.new('Test')
	s.view_size = core.vec2(800, 400)
	s.safe_insets = core.Insets{
		left:   40
		top:    10
		right:  30
		bottom: 20
	}
	mut safe := ui_node('Safe', core.Vec2{}, core.vec2(100, 50)).with(&render.Widget{
		align_left:   true
		align_right:  true
		align_bottom: true
		bottom:       5
	})
	mut full := ui_node('Full', core.Vec2{}, core.vec2(100, 50)).with(&render.Widget{
		align_left:  true
		align_right: true
		align_top:   true
		safe_area:   false
	})
	s.add(mut safe)
	s.add(mut full)
	s.update(0.016)
	assert safe.get_component[render.UITransform]()?.size.x == 800 - 40 - 30
	assert safe.position == core.vec2(40 + 365, 400 - 20 - 5 - 25)
	assert full.get_component[render.UITransform]()?.size.x == 800
	assert full.position == core.vec2(400, 25)
	// a Widget inside a UITransform follows the parent, not the screen
	mut child := ui_node('Child', core.Vec2{}, core.vec2(10, 10)).with(&render.Widget{
		align_left: true
	})
	safe.add_child(mut child)
	s.update(0.016)
	assert child.position.x == -365 + 5
}

fn test_press_and_release_in_one_frame_is_still_a_click() {
	mut s := core.Scene.new('Test')
	mut btn_node := ui_node('Btn', core.vec2(100, 100), core.vec2(80, 40))
	btn := btn_node.add_component(&render.Button{})
	s.add(mut btn_node)
	// mouse: both events arrive before the frame runs (synthetic clicks, very fast clicks)
	s.input.mouse = core.vec2(100, 100)
	s.input.mouse_press()
	s.input.mouse_release()
	assert s.input.mouse_down // the release waits for the next frame
	s.update(0.016)
	s.input.end_frame()
	assert !btn.clicked
	s.update(0.016)
	assert btn.clicked
	s.input.end_frame()
	assert !s.input.mouse_down
	// touch: a tap that begins and ends within one frame
	s.input.touch_begin(5, core.vec2(100, 100))
	s.input.touch_end(5, core.vec2(100, 100), false)
	assert s.input.touch(5)?.phase == .began
	s.update(0.016)
	s.input.end_frame()
	assert s.input.touch(5)?.phase == .ended
	s.update(0.016)
	assert btn.clicked
	s.input.end_frame()
	assert s.input.touches.len == 0
	assert !s.input.mouse_down
}

// ---------- Data binding to the saved data ----------

fn bound_scene() (&core.Scene, &core.Node) {
	mut s := core.Scene.new('t')
	s.store = core.Store.from_text('') or { panic(err) }
	mut root := core.Node.new('UI')
	s.add(mut root)
	return s, root
}

fn test_label_follows_a_store_value() {
	mut s, mut root := bound_scene()
	mut lbl := root.add_component(&render.Label{
		text:        'fallback'
		bind:        'coins'
		bind_format: 'Coins: {}'
	})
	s.update(0.016)
	assert lbl.text == 'fallback' // the key does not exist yet
	s.store.set_int('coins', 7)
	s.update(0.016)
	assert lbl.text == 'Coins: 7'
	s.store.set_f64('coins', 2.5)
	s.update(0.016)
	assert lbl.text == 'Coins: 2.5'
	s.store.set_bool('coins', true)
	s.update(0.016)
	assert lbl.text == 'Coins: true'
	s.store.set_string('coins', 'many')
	s.update(0.016)
	assert lbl.text == 'Coins: many'
	lbl.bind_format = ''
	s.update(0.016)
	assert lbl.text == 'many' // no format: the value alone
}

fn test_store_display_and_number() {
	mut st := core.Store.from_text('')!
	st.set_f64('a', 3.0)
	st.set_f64('b', 0.125)
	st.set_int('c', -4)
	assert st.get_display('a')? == '3' && st.get_display('b')? == '0.125'
		&& st.get_display('c')? == '-4'
	assert st.get_display('missing') == none
	assert st.get_number('c')? == -4.0 && st.get_number('b')? == 0.125
	st.set_string('d', 'x')
	assert st.get_number('d') == none
}

fn test_progress_bar_binds_value_over_max() {
	mut s, mut root := bound_scene()
	mut bar := root.add_component(&render.ProgressBar{
		bind:         'hp'
		bind_max_key: 'max_hp'
	})
	s.update(0.016)
	assert bar.progress == 0.5 // no value: left alone
	s.store.set_int('hp', 30)
	s.store.set_int('max_hp', 120)
	s.update(0.016)
	assert bar.progress == 0.25
	s.store.set_int('hp', 500) // clamped
	s.update(0.016)
	assert bar.progress == 1
	mut fixed := root.add_component(&render.ProgressBar{
		bind:     'ammo'
		bind_max: 8
	})
	s.store.set_int('ammo', 2)
	s.update(0.016)
	assert fixed.progress == 0.25
}

fn test_toggle_binds_both_ways() {
	mut s, mut root := bound_scene()
	mut t := root.add_component(&render.Toggle{
		bind:  'music'
		is_on: true
	})
	s.update(0.016)
	assert t.is_on && !s.store.has('music') // untouched until a click
	s.store.set_bool('music', false)
	s.update(0.016)
	assert !t.is_on // the stored value wins
	mut btn := root.add_component(&render.Button{})
	btn.clicked = true // a click this frame (set by hand: Button.update would clear it)
	t.update(0.016)
	assert t.is_on && t.changed && s.store.get_bool('music', false) // a click wrote it back
}

// ---------- UINav: keyboard / gamepad navigation ----------

@[heap]
struct Presses {
mut:
	names []string
}

fn nav_menu() (&core.Scene, &render.UINav, &Presses) {
	mut s := core.Scene.new('t')
	mut ui := core.Node.new('UI')
	mut log := &Presses{}
	// a 2 x 2 grid of buttons:   A B
	//                            C D
	for name, pos in {
		'A': core.vec2(100, 100)
		'B': core.vec2(300, 100)
		'C': core.vec2(100, 200)
		'D': core.vec2(300, 200)
	} {
		mut n := core.Node.new(name)
		n.position = pos
		n.add_component(&render.UITransform{
			size: core.vec2(80, 40)
		})
		n.add_component(&render.Panel{
			color: core.white
		})
		mut b := n.add_component(&render.Button{})
		b.on_click(fn [mut log, name] (mut btn render.Button) {
			log.names << name
		})
		ui.add_child(mut n)
	}
	mut nav_node := core.Node.new('Nav')
	nav := nav_node.add_component(&render.UINav{})
	ui.add_child(mut nav_node)
	s.add(mut ui)
	return s, nav, log
}

fn tap(mut s core.Scene, k core.Key) {
	s.input.key_down(int(k))
	s.update(0.016)
	s.input.key_up(int(k))
	s.input.end_frame()
}

fn focus_name(nav &render.UINav) string {
	n := nav.focused_node() or { return '' }
	return n.name
}

fn test_arrows_move_the_focus_and_the_first_press_focuses_the_top_left() {
	mut s, nav, _ := nav_menu()
	s.update(0.016)
	assert focus_name(nav) == '' // nothing focused until the player uses the keys
	tap(mut s, .down)
	assert focus_name(nav) == 'A'
	tap(mut s, .right)
	assert focus_name(nav) == 'B'
	tap(mut s, .down)
	assert focus_name(nav) == 'D'
	tap(mut s, .left)
	assert focus_name(nav) == 'C'
	tap(mut s, .up)
	assert focus_name(nav) == 'A'
}

fn test_wrap_and_no_wrap() {
	mut s, mut nav, _ := nav_menu()
	tap(mut s, .down) // A
	tap(mut s, .up) // past the top: wraps to the bottom of the same column
	assert focus_name(nav) == 'C'
	tap(mut s, .left) // past the left edge: wraps to the right side of the same row
	assert focus_name(nav) == 'D'
	nav.wrap = false
	tap(mut s, .right)
	assert focus_name(nav) == 'D' // stays
	tap(mut s, .down)
	assert focus_name(nav) == 'D'
}

fn test_accept_presses_and_cancel_reports() {
	mut s, mut nav, log := nav_menu()
	mut cancelled := &Presses{}
	nav.on_cancel = fn [mut cancelled] () {
		cancelled.names << 'cancel'
	}
	tap(mut s, .enter) // nothing focused: nothing to press
	assert log.names.len == 0
	tap(mut s, .down) // A
	tap(mut s, .right) // B
	tap(mut s, .space)
	s.update(0.016) // the Button handles the press in its next update
	assert log.names == ['B']
	tap(mut s, .enter)
	s.update(0.016)
	assert log.names == ['B', 'B']
	tap(mut s, .escape)
	assert cancelled.names == ['cancel']
	assert nav.cancelled
	s.update(0.016)
	assert !nav.cancelled // only for the frame it happened
}

fn test_disabled_buttons_are_skipped_and_the_focus_tints() {
	mut s, nav, _ := nav_menu()
	mut b := s.find('UI/B')?.get_component[render.Button]()?
	b.interactable = false
	tap(mut s, .down) // A
	tap(mut s, .right) // B is disabled: the nearest in that direction is D (down-right)
	assert focus_name(nav) == 'D'
	a_panel := s.find('UI/A')?.get_component[render.Panel]()?
	d_panel := s.find('UI/D')?.get_component[render.Panel]()?
	s.update(0.016)
	assert d_panel.color.r < 255 // the focused button is tinted like a hovered one
	assert a_panel.color.r == 255
	// a focused button that gets disabled loses the focus
	mut d := s.find('UI/D')?.get_component[render.Button]()?
	d.interactable = false
	s.update(0.016)
	assert focus_name(nav) == ''
}

fn test_holding_a_direction_repeats() {
	mut s, nav, _ := nav_menu()
	tap(mut s, .down) // A
	s.input.key_down(int(core.Key.right))
	s.update(0.016) // pressed: B
	assert focus_name(nav) == 'B'
	s.input.end_frame()
	for _ in 0 .. 10 { // held 0.16 s: still before the repeat delay
		s.update(0.016)
		s.input.end_frame()
	}
	assert focus_name(nav) == 'B'
	for _ in 0 .. 40 { // past the delay: it repeats, wrapping A -> B -> A ...
		s.update(0.016)
		s.input.end_frame()
	}
	assert nav.hold_dir == 3
	assert focus_name(nav) in ['A', 'B']
	s.input.key_up(int(core.Key.right))
	s.update(0.016)
	assert nav.hold_dir == -1
}

fn test_mouse_focuses_what_it_hovers_and_game_bindings_win() {
	mut s, nav, _ := nav_menu()
	s.input.mouse = core.vec2(300, 100) // over B
	s.update(0.016)
	assert focus_name(nav) == 'B'
	// the game's own binding for ui_up is kept; the defaults are only added when there is none
	mut s2 := core.Scene.new('t2')
	s2.input.bind('ui_up', 'key:w')
	mut n := core.Node.new('Nav')
	n.add_component(&render.UINav{})
	s2.add(mut n)
	assert s2.input.bindings_of('ui_up').len == 1
	assert s2.input.bindings_of('ui_down').len == 3 // key + stick + d-pad defaults
}

fn test_gamepad_dpad_and_the_ring_mesh() {
	mut s, nav, log := nav_menu()
	s.input.gamepad_connect(0, true)
	s.input.gamepad_button(0, .dpad_down, true)
	s.update(0.016)
	assert focus_name(nav) == 'A'
	s.input.gamepad_button(0, .dpad_down, false)
	s.input.end_frame()
	s.input.gamepad_button(0, .a, true)
	s.update(0.016)
	s.input.gamepad_button(0, .a, false)
	s.input.end_frame()
	s.update(0.016)
	assert log.names == ['A']
	// the focus ring: four bars around the focused button, none without focus
	ms := nav.meshes()
	assert ms.len == 1 && ms[0].indices.len == 4 * 6 && ms[0].positions.len == 4 * 4 * 2
	mut nav2 := nav
	nav2.clear_focus()
	assert nav2.meshes().len == 0
	assert nav2.focus(s.find('UI/C')?)
	assert focus_name(nav2) == 'C'
	assert !nav2.focus(s.find('UI')?) // no Button there
}
