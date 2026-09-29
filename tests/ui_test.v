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
