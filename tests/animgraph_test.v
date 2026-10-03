module tests

import velo.core

const hero = '
# a hero
default = idle
state idle  frames=0-3  fps=4 loop
state run   frames=4-9  fps=12
state jump  frames=10-12 fps=10 once event=1:land_dust event=2:late
idle -> run   when speed > 0.1
run  -> idle  when speed <= 0.1
any  -> jump  when trigger jump
jump -> idle  when finished and grounded
'

fn step(mut g core.AnimGraph, dt f32) {
	s := g.current_state()
	last := if s.last >= 0 { s.last } else { 9 }
	g.update(dt, f32(last - s.first + 1) / s.fps)
}

fn test_parse_and_defaults() {
	g := core.AnimGraph.parse(hero)!
	assert g.states.len == 3 && g.transitions.len == 4
	assert g.default == 'idle'
	assert g.state_name() == 'idle' // before the first update
	assert g.states[2].loop == false && g.states[2].events.len == 2
	assert g.states[1].first == 4 && g.states[1].last == 9
}

fn test_parse_errors_name_the_line() {
	core.AnimGraph.parse('state a\nstate a') or {
		assert err.msg().contains('line 2')
		return
	}
	assert false
}

fn test_parse_error_cases() {
	for text in ['state a\na -> nope', 'state a fps=0', 'state a frames=5-2', 'state a bogus=1',
		'state a\na -> a when ??? ???', '', 'state a\ndefault = z'] {
		core.AnimGraph.parse(text) or { continue }
		assert false, 'should fail: ${text}'
	}
}

fn test_param_transitions() {
	mut g := core.AnimGraph.parse(hero)!
	step(mut g, 0.016)
	assert g.state_name() == 'idle'
	g.set_float('speed', 0.5)
	step(mut g, 0.016)
	assert g.state_name() == 'run' && g.entered_state()
	step(mut g, 0.016)
	assert !g.entered_state()
	g.set_float('speed', 0)
	step(mut g, 0.016)
	assert g.state_name() == 'idle'
}

fn test_trigger_any_state_finished_and_bool() {
	mut g := core.AnimGraph.parse(hero)!
	step(mut g, 0.016)
	g.trigger('jump')
	step(mut g, 0.016)
	assert g.state_name() == 'jump'
	// the trigger was consumed: it does not fire again from jump (any -> jump excludes the current state anyway)
	g.set_bool('grounded', false)
	for _ in 0 .. 20 {
		step(mut g, 0.05) // the clip is 0.3 s: finished after that
	}
	assert g.is_finished() && g.state_name() == 'jump' // not grounded yet
	g.set_bool('grounded', true)
	step(mut g, 0.016)
	assert g.state_name() == 'idle'
	// triggering from run works too (any)
	g.set_float('speed', 1)
	step(mut g, 0.016)
	assert g.state_name() == 'run'
	g.trigger('jump')
	step(mut g, 0.016)
	assert g.state_name() == 'jump'
}

fn test_events_fire_once_in_order() {
	mut g := core.AnimGraph.parse(hero)!
	g.force('jump')
	mut fired := []string{}
	for _ in 0 .. 12 {
		step(mut g, 0.05)
		fired << g.take_events()
	}
	assert fired == ['land_dust', 'late'] // frame 1 at 0.1 s, frame 2 at 0.2 s, never again after finishing
}

fn test_looping_wraps_and_events_repeat() {
	mut g := core.AnimGraph.parse('state a frames=0-3 fps=4 loop event=2:tick\n')!
	mut ticks := 0
	for _ in 0 .. 40 { // 40 * 0.1 = 4 s = 4 laps of a 1 s clip
		g.update(0.1, 1.0)
		ticks += g.take_events().len
	}
	assert ticks == 4
	assert g.state_time() >= 0 && g.state_time() < 1.0
}

fn test_time_condition_and_state_speed() {
	mut g := core.AnimGraph.parse('state a frames=0-9 fps=10\nstate b\na -> b when time >= 0.5\n')!
	for _ in 0 .. 4 {
		g.update(0.1, 1.0)
	}
	assert g.state_name() == 'a'
	g.update(0.11, 1.0)
	assert g.state_name() == 'b'
	mut h := core.AnimGraph.parse('state a speed=2 once\n')!
	h.update(0.25, 1.0)
	assert h.state_time() == 0.5
}

fn test_event_at_frame_zero_fires_on_entering() {
	mut g := core.AnimGraph.parse('state a event=0:start\nstate b\n')!
	g.update(0.016, 1.0)
	assert g.take_events() == ['start']
	g.update(0.016, 1.0)
	assert g.take_events().len == 0
	g.force('b')
	g.force('a')
	g.update(0.016, 1.0)
	assert g.take_events() == ['start'] // entered again
}
