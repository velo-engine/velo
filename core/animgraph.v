module core

// AnimGraph — an animation state machine: states (a clip each), parameters the game sets, and transitions that
// fire when their conditions hold. It only decides *which state is playing and for how long*; a component applies
// it (render.Animator to sprite sheet frames, kine2d.Kine2D to skeletal animations). No GPU, so it is testable.
//
// The graph is a text file (`hero.anim`, an asset):
//
//   # comment
//   default = idle
//   state idle  frames=0-3   fps=8  loop
//   state run   frames=4-9   fps=12 loop
//   state jump  frames=10-12 fps=10 once  event=11:land_dust
//   state skel  clip=Run     loop                       # Kine2D: the animation's name in the export
//   idle -> run   when speed > 0.1
//   run  -> idle  when speed <= 0.1
//   any  -> jump  when trigger jump                     # from every state
//   jump -> idle  when finished and grounded            # "finished": a non-looping clip reached its end
//
// state options: frames=a-b (or one number; default: the whole sheet), clip=Name, fps=N, speed=N (time scale),
//   loop | once (default loop), event=<frame>:<name> (fires when the clip passes that frame, any number).
// conditions (joined with `and`): `param > 0.5` (also >= < <= == !=), `grounded` (a bool/number that is not 0),
//   `not grounded`, `trigger jump` (set with trigger(), consumed by the transition that uses it),
//   `finished`, `time >= 0.4` (seconds in the state). Transitions are tried in file order, one per update.

pub struct AnimEvent {
pub:
	frame f32
	name  string
}

pub struct AnimState {
pub mut:
	name   string
	clip   string // skeletal animation name ('' for sprite sheets)
	first  int
	last   int  = -1 // -1 = up to the last frame of the sheet
	fps    f32  = 10
	speed  f32  = 1
	loop   bool = true
	events []AnimEvent
}

enum CondKind {
	compare
	truthy
	falsy
	trigger
	finished
	time
}

struct AnimCond {
	kind  CondKind
	param string
	op    string
	value f32
}

pub struct AnimTransition {
pub:
	from  string // a state name, or 'any'
	to    string
	conds []AnimCond
}

@[heap]
pub struct AnimGraph {
pub mut:
	states      []AnimState
	transitions []AnimTransition
	default     string
mut:
	params       map[string]f32
	triggers     map[string]bool
	current      int = -1
	time         f32 // seconds in the current state (state speed applied)
	finished     bool
	events       []string
	entered      bool // the state changed during the last update
	fresh        bool // just entered: events at frame 0 fire on the next update
	was_finished bool // finished before this update: `finished` conditions wait one update, so the last frame shows
}

// parse reads the text format; errors name the line.
pub fn AnimGraph.parse(text string) !&AnimGraph {
	mut g := &AnimGraph{}
	for i, raw in text.split_into_lines() {
		line := raw.all_before('#').trim_space()
		if line == '' {
			continue
		}
		g.parse_line(line) or { return error('line ${i + 1}: ${err}') }
	}
	if g.states.len == 0 {
		return error('no states')
	}
	if g.default == '' {
		g.default = g.states[0].name
	}
	if g.state_index(g.default) < 0 {
		return error('default state "${g.default}" does not exist')
	}
	for t in g.transitions {
		if t.from != 'any' && g.state_index(t.from) < 0 {
			return error('transition from unknown state "${t.from}"')
		}
		if g.state_index(t.to) < 0 {
			return error('transition to unknown state "${t.to}"')
		}
	}
	return g
}

fn (mut g AnimGraph) parse_line(line string) ! {
	if line.starts_with('default') && line.contains('=') && !line.contains('->') {
		g.default = line.all_after('=').trim_space()
		return
	}
	if line.starts_with('state ') {
		return g.parse_state(line['state '.len..].trim_space())
	}
	if line.contains('->') {
		return g.parse_transition(line)
	}
	return error('cannot read "${line}"')
}

fn (mut g AnimGraph) parse_state(rest string) ! {
	words := rest.fields()
	if words.len == 0 {
		return error('state needs a name')
	}
	mut s := AnimState{
		name: words[0]
	}
	if g.state_index(s.name) >= 0 {
		return error('state "${s.name}" defined twice')
	}
	for w in words[1..] {
		match true {
			w == 'loop' {
				s.loop = true
			}
			w == 'once' {
				s.loop = false
			}
			w.starts_with('frames=') {
				v := w['frames='.len..]
				if v.contains('-') {
					s.first = v.all_before('-').int()
					s.last = v.all_after('-').int()
				} else {
					s.first = v.int()
					s.last = s.first
				}
				if s.first < 0 || (s.last >= 0 && s.last < s.first) {
					return error('bad frames "${v}"')
				}
			}
			w.starts_with('clip=') {
				s.clip = w['clip='.len..]
			}
			w.starts_with('fps=') {
				s.fps = w['fps='.len..].f32()
				if s.fps <= 0 {
					return error('fps must be above 0')
				}
			}
			w.starts_with('speed=') {
				s.speed = w['speed='.len..].f32()
			}
			w.starts_with('event=') {
				f, n := w['event='.len..].split_once(':') or {
					return error('event must be <frame>:<name>')
				}
				s.events << AnimEvent{f.f32(), n}
			}
			else {
				return error('unknown state option "${w}"')
			}
		}
	}
	g.states << s
}

fn (mut g AnimGraph) parse_transition(line string) ! {
	head, cond_text := if line.contains(' when ') {
		line.all_before(' when ').trim_space(), line.all_after(' when ').trim_space()
	} else {
		line.trim_space(), ''
	}
	from, to := head.split_once('->') or { return error('bad transition') }
	mut conds := []AnimCond{}
	if cond_text != '' {
		for part in cond_text.split(' and ') {
			conds << parse_cond(part.trim_space())!
		}
	}
	g.transitions << AnimTransition{from.trim_space(), to.trim_space(), conds}
}

fn parse_cond(s string) !AnimCond {
	w := s.fields()
	match true {
		w.len == 1 && w[0] == 'finished' {
			return AnimCond{
				kind: .finished
			}
		}
		w.len == 2 && w[0] == 'trigger' {
			return AnimCond{
				kind:  .trigger
				param: w[1]
			}
		}
		w.len == 2 && w[0] == 'not' {
			return AnimCond{
				kind:  .falsy
				param: w[1]
			}
		}
		w.len == 1 {
			return AnimCond{
				kind:  .truthy
				param: w[0]
			}
		}
		w.len == 3 && w[1] in ['>', '>=', '<', '<=', '==', '!='] {
			v := match w[2] {
				'true' { f32(1) }
				'false' { f32(0) }
				else { w[2].f32() }
			}

			return AnimCond{
				kind:  if w[0] == 'time' { CondKind.time } else { CondKind.compare }
				param: w[0]
				op:    w[1]
				value: v
			}
		}
		else {
			return error('cannot read condition "${s}"')
		}
	}
}

pub fn (g &AnimGraph) state_index(name string) int {
	for i, s in g.states {
		if s.name == name {
			return i
		}
	}
	return -1
}

// Parameters — set from game code.

pub fn (mut g AnimGraph) set_float(name string, v f32) {
	g.params[name] = v
}

pub fn (mut g AnimGraph) set_int(name string, v int) {
	g.params[name] = f32(v)
}

pub fn (mut g AnimGraph) set_bool(name string, v bool) {
	g.params[name] = if v { f32(1) } else { f32(0) }
}

// trigger arms a one-shot condition; the transition that uses it consumes it.
pub fn (mut g AnimGraph) trigger(name string) {
	g.triggers[name] = true
}

pub fn (mut g AnimGraph) reset_trigger(name string) {
	g.triggers.delete(name)
}

pub fn (g &AnimGraph) get_float(name string) f32 {
	return g.params[name] or { 0 }
}

// State — what is playing.

// current_state: the playing state (the default one before the first update).
pub fn (g &AnimGraph) current_state() &AnimState {
	i := if g.current >= 0 { g.current } else { g.state_index(g.default) }
	return &g.states[i]
}

pub fn (g &AnimGraph) state_name() string {
	return g.current_state().name
}

// state_time: seconds into the current state's clip (speed applied).
pub fn (g &AnimGraph) state_time() f32 {
	return g.time
}

pub fn (g &AnimGraph) is_finished() bool {
	return g.finished
}

// entered_state: the state changed in the last update (a component restarts its clip then).
pub fn (g &AnimGraph) entered_state() bool {
	return g.entered
}

// take_events returns (and clears) the event names fired since the last call, in order.
pub fn (mut g AnimGraph) take_events() []string {
	out := g.events.clone()
	g.events.clear()
	return out
}

// adopt_state carries the parameters, armed triggers and playing state of `old` over to this graph (after the
// graph file was edited while the game runs). The state is kept when it still exists, with its time.
pub fn (mut g AnimGraph) adopt_state(old &AnimGraph) {
	g.params = old.params.clone()
	g.triggers = old.triggers.clone()
	if old.current >= 0 {
		i := g.state_index(old.states[old.current].name)
		if i >= 0 {
			g.current = i
			g.time = old.time
			g.finished = old.finished
		}
	}
}

// force switches state at once, whatever the transitions say (a respawn, a cutscene).
pub fn (mut g AnimGraph) force(name string) bool {
	i := g.state_index(name)
	if i < 0 {
		return false
	}
	g.enter(i)
	return true
}

fn (mut g AnimGraph) enter(i int) {
	g.current = i
	g.time = 0
	g.finished = false
	g.entered = true
	g.fresh = true
}

// update advances the machine by dt. `duration` is the length in seconds of the current state's clip at speed 1
// (the component knows it: frames / fps for a sprite sheet, the animation length for Kine2D).
pub fn (mut g AnimGraph) update(dt f32, duration f32) {
	g.entered = false
	if g.current < 0 {
		g.enter(g.state_index(g.default))
	}
	s := g.states[g.current]
	was_fresh := g.fresh
	g.was_finished = g.finished
	g.fresh = false
	prev := g.time
	if !g.finished {
		g.time += dt * s.speed
		mut wrapped := false
		if duration > 0 {
			if s.loop {
				if g.time >= duration {
					g.time -= duration * f32(int(g.time / duration))
					wrapped = true
				}
			} else if g.time >= duration {
				g.time = duration
				g.finished = true
			}
		}
		g.fire_events(s, prev, g.time, wrapped, was_fresh)
	}
	g.try_transition()
}

fn (mut g AnimGraph) fire_events(s AnimState, prev f32, now f32, wrapped bool, fresh bool) {
	for ev in s.events {
		t := ev.frame / s.fps
		hit := if wrapped {
			t > prev || t <= now // the end of the clip, then the start of the next lap
		} else {
			t > prev && t <= now
		}
		// an event at frame 0 fires on the first update after the state was entered
		if hit || (fresh && t == 0) {
			g.events << ev.name
		}
	}
}

fn (mut g AnimGraph) try_transition() {
	cur := g.states[g.current].name
	for t in g.transitions {
		if t.from != cur && !(t.from == 'any' && t.to != cur) {
			continue
		}
		if !g.conds_hold(t.conds) {
			continue
		}
		for c in t.conds {
			if c.kind == .trigger {
				g.triggers.delete(c.param)
			}
		}
		g.enter(g.state_index(t.to))
		return
	}
}

fn (g &AnimGraph) conds_hold(conds []AnimCond) bool {
	for c in conds {
		ok := match c.kind {
			.finished { g.finished && g.was_finished }
			.trigger { g.triggers[c.param] or { false } }
			.truthy { g.get_float(c.param) != 0 }
			.falsy { g.get_float(c.param) == 0 }
			.time { compare_f(g.time, c.op, c.value) }
			.compare { compare_f(g.get_float(c.param), c.op, c.value) }
		}

		if !ok {
			return false
		}
	}
	return true
}

fn compare_f(a f32, op string, b f32) bool {
	return match op {
		'>' { a > b }
		'>=' { a >= b }
		'<' { a < b }
		'<=' { a <= b }
		'==' { a == b }
		else { a != b }
	}
}
