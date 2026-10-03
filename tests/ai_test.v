import math
import velo.core

fn near(a f32, b f32) bool {
	return math.abs(a - b) < 0.01
}

fn open_grid(cols int, rows int) &core.NavGrid {
	return core.NavGrid.new(cols, rows, core.vec2(10, 10), core.vec2(0, 0))
}

// ---------- NavGrid and A* ----------

fn test_cells_and_rects() {
	mut g := open_grid(10, 5)
	c, r := g.cell_of(core.vec2(25, 31))
	assert c == 2 && r == 3
	assert g.center_of(2, 3) == core.vec2(25, 35)
	g.block_rect(20, 10, 20, 10) // exactly cells (2..3, 1)
	assert g.is_blocked(2, 1) && g.is_blocked(3, 1) && !g.is_blocked(4, 1) && !g.is_blocked(2, 2)
	assert g.is_blocked(-1, 0) && g.is_blocked(0, 5) // outside = blocked
	g.free_rect(20, 10, 10, 10)
	assert !g.is_blocked(2, 1) && g.is_blocked(3, 1)
}

fn test_straight_path_in_the_open() {
	mut g := open_grid(20, 20)
	from, to := core.vec2(5, 5), core.vec2(185, 5)
	p := g.find_path(from, to)?
	assert p.last() == to // the exact goal, not its cell's center
	assert near(core.path_length(from, p), 180)
	assert p.len <= 2 // smoothed to a line
	raw := g.find_path(from, to, smooth: false)?
	assert raw.len == 18 // one waypoint per cell
}

fn test_path_goes_around_a_wall_and_never_cuts_corners() {
	mut g := open_grid(10, 10)
	g.block_rect(50, 0, 10, 80) // a wall at column 5, rows 0..7, open at the bottom
	from, to := core.vec2(25, 5), core.vec2(85, 5)
	p := g.find_path(from, to)?
	assert core.path_length(from, p) > 120 // it must go down and around
	// every straight piece of the smoothed path is really clear
	mut prev := from
	for w in p {
		assert g.line_clear(prev, w)
		prev = w
	}
	// no diagonal squeeze between two blocked corners
	mut h := open_grid(4, 4)
	h.set_blocked(1, 0, true)
	h.set_blocked(0, 1, true) // (0,0) can only leave through the corner it may not cut
	assert h.find_path(core.vec2(5, 5), core.vec2(35, 35)) == none
	assert h.find_path(core.vec2(5, 5), core.vec2(15, 15), diagonal: true, smooth: false) == none
}

fn test_unreachable_blocked_goal_and_closest() {
	mut g := open_grid(10, 10)
	g.block_rect(60, 0, 10, 100) // a full wall: the right side is cut off
	assert g.find_path(core.vec2(5, 5), core.vec2(95, 5)) == none
	p := g.find_path(core.vec2(5, 5), core.vec2(95, 5), closest: true)?
	assert p.last().x < 60 && p.last().x > 40 // as close as it can get, on the near side
	g2 := open_grid(10, 10)
	mut gg := g2
	gg.set_blocked(5, 5, true)
	assert gg.find_path(core.vec2(5, 5), core.vec2(55, 55)) == none // the goal cell itself is blocked
	near_p := gg.find_path(core.vec2(5, 5), core.vec2(55, 55), closest: true)?
	assert near_p.len > 0
	assert gg.find_path(core.vec2(-50, 5), core.vec2(55, 55)) == none // start outside
	assert gg.find_path(core.vec2(5, 5), core.vec2(5, 5))? == [
		core.vec2(5, 5),
	] // already there
}

fn test_costs_make_paths_prefer_cheap_ground() {
	mut g := open_grid(10, 3)
	for c in 3 .. 7 { // a mud strip across the middle row, 5 times as costly
		g.set_cost(c, 1, 5)
	}
	from, to := core.vec2(5, 15), core.vec2(95, 15)
	p := g.find_path(from, to, smooth: false)?
	assert p.any(it.y < 10 || it.y > 20) // it left the middle row to avoid the mud
	assert g.cost[1 * 10 + 4] == 5
	g.set_cost(4, 1, 0.2) // never below 1
	assert g.cost[1 * 10 + 4] == 1
}

fn test_four_way_movement_and_clearance() {
	mut g := open_grid(10, 10)
	p := g.find_path(core.vec2(5, 5), core.vec2(55, 55), diagonal: false, smooth: false)?
	assert p.len == 10 // Manhattan: 5 + 5 steps
	mut w := open_grid(10, 5)
	w.block_rect(50, 0, 10, 20) // a wall, with a 3 cell gap at the bottom (rows 2..4)
	gap := w.find_path(core.vec2(5, 25), core.vec2(95, 25))?
	assert gap.len > 0
	// a body that needs 2 cells of clearance does not fit through the 3 cell gap beside the 2-cell stub...
	w2 := open_grid(10, 5)
	mut m := w2
	m.block_rect(50, 0, 10, 40) // only the last row is open
	assert m.find_path(core.vec2(5, 45), core.vec2(95, 45)) != none
	assert m.find_path(core.vec2(5, 45), core.vec2(95, 45), clearance: 1) == none // the lane is 1 cell wide
}

fn test_line_of_sight_and_vision_cone() {
	mut g := open_grid(10, 10)
	g.block_rect(50, 40, 10, 20) // a pillar
	assert g.line_clear(core.vec2(5, 5), core.vec2(95, 5))
	assert !g.line_clear(core.vec2(5, 50), core.vec2(95, 50))
	assert g.line_clear(core.vec2(5, 5), core.vec2(95, 5)) // along the top
	assert !g.line_clear(core.vec2(5, 5), core.vec2(95, 95)) // the diagonal runs through the pillar
	assert g.line_clear(core.vec2(5, 95), core.vec2(95, 75)) // well below it
	// can_see: range, cone and walls
	eye := core.vec2(5, 5)
	assert g.can_see(eye, core.vec2(1, 0), 90, 200, core.vec2(85, 15))
	assert !g.can_see(eye, core.vec2(1, 0), 90, 50, core.vec2(85, 15)) // out of range
	assert !g.can_see(eye, core.vec2(-1, 0), 90, 200, core.vec2(85, 15)) // behind
	assert g.can_see(eye, core.vec2(-1, 0), 360, 200, core.vec2(85, 15)) // all around
	assert !g.can_see(core.vec2(5, 50), core.vec2(1, 0), 120, 200, core.vec2(95, 50)) // the pillar
}

// ---------- Steering ----------

fn test_seek_flee_arrive() {
	mut a := core.SteerAgent{
		max_speed: 100
		max_force: 1000
	}
	f := a.seek(core.vec2(100, 0))
	assert f.x > 0 && near(f.y, 0)
	assert a.flee(core.vec2(100, 0)).x < 0
	mut b := core.SteerAgent{
		pos:       core.vec2(0, 0)
		max_speed: 100
		max_force: 1000
	}
	for _ in 0 .. 600 { // arrives and rests on the target
		b.apply(b.arrive(core.vec2(200, 0), 80), 1.0 / 60.0)
	}
	assert math.abs(b.pos.x - 200) < 2 && b.vel.length() < 5
	// far from the target it goes at full speed, inside the radius it slows
	far := core.SteerAgent{
		max_speed: 100
		max_force: 1e6
	}
	assert near(far.arrive(core.vec2(1000, 0), 80).length(), 100)
	assert far.arrive(core.vec2(20, 0), 80).length() < 30
}

fn test_pursue_leads_the_target_and_evade_runs_from_it() {
	a := core.SteerAgent{
		max_speed: 100
		max_force: 1e6
	}
	// the target is 100 units ahead moving up: pursue aims above the target, seek aims straight at it
	p := a.pursue(core.vec2(100, 0), core.vec2(0, -50))
	assert p.y < -1
	e := a.evade(core.vec2(100, 0), core.vec2(0, -50))
	assert e.x < 0
}

fn test_separate_align_cohere_and_avoid() {
	a := core.SteerAgent{
		pos:       core.vec2(0, 0)
		max_speed: 100
		max_force: 1e6
	}
	assert a.separate([core.vec2(10, 0)], 30).x < 0 // pushed away from a close neighbor
	assert a.separate([core.vec2(100, 0)], 30) == core.Vec2{} // too far
	assert a.align([core.vec2(0, 50), core.vec2(0, 50)]).y > 0
	assert a.cohere([core.vec2(100, 0), core.vec2(100, 100)]).x > 0
	mut m := core.SteerAgent{
		pos:       core.vec2(0, 0)
		vel:       core.vec2(100, 0)
		max_speed: 100
		max_force: 1e6
	}
	assert m.avoid([core.Circle{core.vec2(60, 0), 20}], 100).length() > 0 // a rock ahead
	assert m.avoid([core.Circle{core.vec2(60, 300), 20}], 100) == core.Vec2{} // not in the way
	// wander keeps moving and changes direction gradually
	mut w := core.SteerAgent{
		vel:       core.vec2(50, 0)
		max_speed: 50
		max_force: 500
	}
	for _ in 0 .. 120 {
		w.apply(w.wander(1.0 / 60.0, 40, 20, 4), 1.0 / 60.0)
	}
	assert w.vel.length() > 20
}

fn test_follow_path_advances_and_arrives() {
	path := [core.vec2(100, 0), core.vec2(100, 100)]
	mut a := core.SteerAgent{
		max_speed: 200
		max_force: 2000
	}
	mut i := 0
	for _ in 0 .. 900 {
		a.apply(a.follow_path(path, mut &i, 8, 40), 1.0 / 60.0)
	}
	assert i == 1 && (a.pos - core.vec2(100, 100)).length() < 4
}

// ---------- Behavior trees and FSM ----------

fn test_sequence_selector_and_running() {
	mut bb := core.Blackboard{}
	mut ticks := 0
	mut seq := core.bt_sequence([
		core.bt_cond(fn (mut bb core.Blackboard) bool {
			return bb.get_bool('go')
		}),
		core.bt_action(fn [mut ticks] (mut bb core.Blackboard, dt f32) core.BtStatus {
			ticks++
			return if ticks < 3 { core.BtStatus.running } else { core.BtStatus.success }
		}),
	])
	assert seq.tick(mut bb, 0.1) == .failure // the condition is false
	bb.set_bool('go', true)
	assert seq.tick(mut bb, 0.1) == .running
	assert seq.tick(mut bb, 0.1) == .running // remembers it is on the action
	assert seq.tick(mut bb, 0.1) == .success
	// selector: the first child that does not fail
	mut sel := core.bt_selector([
		core.bt_cond(fn (mut bb core.Blackboard) bool {
			return bb.get_bool('a')
		}),
		core.bt_action(fn (mut bb core.Blackboard, dt f32) core.BtStatus {
			bb.set_f32('fallback', bb.get_f32('fallback') + 1)
			return .success
		}),
	])
	assert sel.tick(mut bb, 0) == .success && bb.get_f32('fallback') == 1
	bb.set_bool('a', true)
	assert sel.tick(mut bb, 0) == .success && bb.get_f32('fallback') == 1 // the first child won
}

fn test_selector_interrupt_and_decorators() {
	mut bb := core.Blackboard{}
	mut sel := core.bt_selector([
		core.bt_reactive_sequence([
			core.bt_cond(fn (mut bb core.Blackboard) bool {
				return bb.get_bool('alarm')
			}),
			core.bt_action(fn (mut bb core.Blackboard, dt f32) core.BtStatus {
				bb.set_string('doing', 'flee')
				return .running
			}),
		]),
		core.bt_action(fn (mut bb core.Blackboard, dt f32) core.BtStatus {
			bb.set_string('doing', 'patrol')
			return .running
		}),
	])
	sel.tick(mut bb, 0.1)
	assert bb.get_string('doing') == 'patrol'
	bb.set_bool('alarm', true) // a higher priority child interrupts the running one
	sel.tick(mut bb, 0.1)
	assert bb.get_string('doing') == 'flee'
	bb.set_bool('alarm', false)
	sel.tick(mut bb, 0.1)
	assert bb.get_string('doing') == 'patrol'
	// inverter, succeeder, wait, repeat
	mut inv := core.bt_inverter(core.bt_cond(fn (mut bb core.Blackboard) bool {
		return false
	}))
	assert inv.tick(mut bb, 0) == .success
	mut ok := core.bt_succeeder(core.bt_cond(fn (mut bb core.Blackboard) bool {
		return false
	}))
	assert ok.tick(mut bb, 0) == .success
	mut w := core.bt_wait(0.25)
	assert w.tick(mut bb, 0.1) == .running && w.tick(mut bb, 0.1) == .running
	assert w.tick(mut bb, 0.1) == .success // 0.3 >= 0.25
	assert w.tick(mut bb, 0.1) == .running // starts over
	mut counter := &Counter{}
	mut rep := core.bt_repeat(3, core.bt_action(fn [mut counter] (mut bb core.Blackboard, dt f32) core.BtStatus {
		counter.n++
		return .success
	}))
	assert rep.tick(mut bb, 0) == .running && rep.tick(mut bb, 0) == .running
	assert rep.tick(mut bb, 0) == .success && counter.n == 3
}

fn test_behavior_tree_component_ticks_with_the_scene() {
	mut s := core.Scene.new('t')
	mut n := core.Node.new('AI')
	mut bt := n.add_component(&core.BehaviorTree{})
	s.add(mut n)
	bt.set_tree(core.bt_action(fn (mut bb core.Blackboard, dt f32) core.BtStatus {
		bb.set_f32('t', bb.get_f32('t') + dt)
		return .running
	}))
	s.update(0.1)
	s.update(0.1)
	assert near(bt.blackboard.get_f32('t'), 0.2) && bt.status == .running
}

@[heap]
struct Counter {
mut:
	n int
}

@[heap]
struct Log {
mut:
	lines []string
}

fn test_fsm_enter_exit_update() {
	mut log := &Log{}
	mut f := core.Fsm{}
	f.add('idle', core.FsmState{
		enter: fn [mut log] () {
			log.lines << 'enter idle'
		}
		exit:  fn [mut log] () {
			log.lines << 'exit idle'
		}
	})
	f.add('chase', core.FsmState{
		enter: fn [mut log] () {
			log.lines << 'enter chase'
		}
	})
	assert !f.go('nope')
	assert f.go('idle') && f.go('chase')
	assert log.lines == ['enter idle', 'exit idle', 'enter chase']
	f.update(0.5)
	f.update(0.25)
	assert near(f.time, 0.75)
	f.go('idle')
	assert f.time == 0
}
