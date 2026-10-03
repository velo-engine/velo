module tests

import velo.core
import velo.render

fn test_log_levels_and_ring() {
	mut l := &core.Log{
		echo:        false
		max_entries: 3
	}
	l.write(.debug, 'hidden') // below min_level (info)
	for i in 0 .. 5 {
		l.write(.info, 'm${i}')
	}
	l.write(.error, 'boom')
	t := l.tail(10)
	assert t.len == 3
	assert t[0].text == 'm3' && t[2].text == 'boom' && t[2].level == .error
	assert l.tail(1)[0].text == 'boom'
	assert core.log_level_from_str('WARN')? == .warn
	assert core.log_level_from_str('nope') == none
}

fn test_profiler_scopes_and_history() {
	mut p := &core.Profiler{}
	p.begin('x')
	p.end('x') // disabled: nothing recorded
	p.new_frame(16)
	assert p.frame_history().len == 0
	p.enabled = true
	for _ in 0 .. 3 {
		p.begin('work')
		mut n := 0
		for i in 0 .. 2_000_000 {
			n += i % 7
		}
		assert n > 0
		p.end('work')
		p.new_frame(10)
	}
	assert p.frame_history().len == 3
	assert p.scope_ms('work') > 0
	assert p.top(5)[0].name == 'work'
	for _ in 0 .. 130 {
		p.new_frame(10)
	}
	assert p.frame_history().len == 120 // a ring
	p.reset()
	assert p.top(5).len == 0
}

struct Ticker {
	core.Component
pub mut:
	n int
}

fn (mut t Ticker) update(dt f32) {
	t.n++
}

fn test_profiler_times_components() {
	mut s := core.Scene.new('t')
	s.profiler.enabled = true
	mut n := core.Node.new('N')
	s.add(mut n)
	n.add_component(&Ticker{})
	n.add_component(&render.Sprite{})
	s.update(0.016)
	s.profiler.new_frame(16)
	assert s.profiler.scope_ms('update:Ticker') > 0
	assert n.get_component[Ticker]()?.n == 1
}

fn test_console_commands_and_editing() {
	mut c := &core.Console{}
	mut l := core.logger()
	l.echo = false
	l.clear()
	c.register('add', 'add a b', fn (args []string) string {
		return '${args[0].int() + args[1].int()}'
	})
	c.register('addx', 'second', fn (args []string) string {
		return ''
	})
	assert c.execute('add 2 3') == '5'
	assert core.logger().tail(1)[0].text == '5'
	assert c.execute('  nope ').contains('unknown command')
	assert c.execute('') == ''
	// typing
	c.open = true
	c.type_text('ad')
	c.complete() // two matches: no change
	assert c.line == 'ad'
	c.input_char(u32(`d`))
	c.input_char(u32(`\n`)) // control character ignored
	assert c.line == 'add'
	c.line = 'add 4 4'
	assert c.key(.enter)
	assert c.line == ''
	assert core.logger().tail(2)[0].text == '> add 4 4'
	assert core.logger().tail(1)[0].text == '8'
	assert c.key(.up) && c.line == 'add 4 4' // history
	assert c.key(.down) && c.line == ''
	c.type_text('xé')
	assert c.key(.backspace) && c.line == 'x' // removes a whole character
	assert !c.key(.a) // not an editing key
	assert c.key(.escape) && !c.open
	l.echo = true
}
