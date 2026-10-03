module tests

import velo.core

fn test_key_action() {
	mut i := core.Input{}
	i.bind('jump', 'key:space', 'pad:a')
	assert !i.action_down('jump')
	i.key_down(int(core.Key.space))
	assert i.action_pressed('jump') && i.action_down('jump')
	i.end_frame()
	assert !i.action_pressed('jump') && i.action_down('jump')
	i.key_up(int(core.Key.space))
	assert i.action_released('jump') && !i.action_down('jump')
	i.end_frame()
	assert !i.action_released('jump')
}

fn test_gamepad_button_and_any_pad() {
	mut i := core.Input{}
	i.bind('jump', 'pad:a')
	i.gamepad_button(1, .a, true) // not connected: ignored
	assert !i.action_down('jump')
	i.gamepad_connect(1, true)
	i.gamepad_button(1, .a, true)
	assert i.action_pressed('jump')
	i.end_frame()
	assert i.action_down('jump') && !i.action_pressed('jump')
	i.bind('p0_only', 'pad:a@0')
	assert !i.action_down('p0_only')
}

fn test_axis_deadzone_and_press() {
	mut i := core.Input{}
	i.bind('left', 'axis:left_x-', 'key:a')
	i.bind('right', 'axis:left_x+', 'key:d')
	i.gamepad_connect(0, true)
	i.gamepad_axis_set(0, .left_x, 0.1)
	assert i.action_axis('left', 'right') == 0
	i.gamepad_axis_set(0, .left_x, -1)
	assert i.action_axis('left', 'right') == -1
	assert i.action_pressed('left')
	i.end_frame()
	assert i.action_down('left') && !i.action_pressed('left')
	i.gamepad_axis_set(0, .left_x, 0)
	assert i.action_released('left')
	i.gamepad_axis_set(0, .left_x, 0.6) // analog, between deadzone and full
	v := i.action_value('right')
	assert v > 0.4 && v < 0.6
}

fn test_vec2_is_clamped() {
	mut i := core.Input{}
	i.bind('l', 'key:left')
	i.bind('r', 'key:right')
	i.bind('u', 'key:up')
	i.bind('d', 'key:down')
	i.key_down(int(core.Key.right))
	i.key_down(int(core.Key.down))
	v := i.action_vec2('l', 'r', 'u', 'd')
	assert v.length() < 1.001 && v.x > 0 && v.y > 0
}

fn test_text_roundtrip_and_errors() {
	mut i := core.Input{}
	i.bind('jump', 'key:space', 'pad:a@1')
	i.bind('left', 'axis:left_x-', 'key:3')
	text := i.actions_to_text()
	mut j := core.Input{}
	assert j.load_actions(text).len == 0
	assert j.actions_to_text() == text
	errs := j.load_actions('fire = key:nosuchkey\nbad line\njump = pad:b\n')
	assert errs.len == 2
	assert j.bindings_of('jump').len == 1 // the good line applied, the failed one kept the old bindings
	assert j.bindings_of('left').len == 2
}

fn test_any_binding_input_for_rebind() {
	mut i := core.Input{}
	assert i.any_binding_input() == none
	i.key_down(int(core.Key.f))
	b := i.any_binding_input() or { panic('none') }
	i.add_binding('fire', b)
	assert i.actions_to_text() == 'fire = key:f\n'
}
