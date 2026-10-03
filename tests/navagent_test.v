import math
import velo.core
import velo.render

@[heap]
struct Flag {
mut:
	hit int
}

fn near(a core.Vec2, b core.Vec2, eps f32) bool {
	return math.abs(a.x - b.x) < eps && math.abs(a.y - b.y) < eps
}

// A 10 x 6 map of 10 unit cells at (100, 50); a wall of tile 1 on column 5, rows 0..3 (open below).
fn level() (&core.Scene, &core.Node, &render.TileMap, &core.NavMap) {
	mut s := core.Scene.new('t')
	mut lvl := core.Node.new('Level')
	lvl.position = core.vec2(100, 50)
	mut tm := lvl.add_component(&render.TileMap{
		columns:   10
		rows:      6
		tile_size: core.vec2(10, 10)
	})
	tm.clear()
	for r in 0 .. 4 {
		tm.set(5, r, 1)
	}
	mut nm := lvl.add_component(&core.NavMap{})
	s.add(mut lvl)
	return s, lvl, tm, nm
}

fn agent_at(mut s core.Scene, x f32, y f32) (&core.Node, &core.NavAgent) {
	mut n := core.Node.new('Goblin')
	n.position = core.vec2(x, y)
	mut a := n.add_component(&core.NavAgent{
		speed: 100
	})
	s.add(mut n)
	return n, a
}

fn test_navmap_follows_the_tile_map() {
	_, _, mut tm, mut nm := level()
	g := nm.nav_grid()
	assert g.columns == 10 && g.rows == 6 && g.origin == core.vec2(100, 50)
		&& g.cell == core.vec2(10, 10)
	assert g.is_blocked(5, 0) && g.is_blocked(5, 3) && !g.is_blocked(5, 4) && !g.is_blocked(0, 0)
	// only some tiles block
	tm.set(2, 2, 7)
	nm.solid_tiles = [1]
	nm.rebuild()
	assert !nm.grid.is_blocked(2, 2) && nm.grid.is_blocked(5, 1)
	nm.solid_tiles = []
	nm.rebuild()
	assert nm.grid.is_blocked(2, 2)
}

fn test_agent_walks_around_the_wall_and_arrives() {
	mut s, _, _, _ := level()
	n, mut a := agent_at(mut s, 125, 55) // left of the wall, top row
	mut f := &Flag{}
	a.on_arrive = fn [mut f] () {
		f.hit++
	}
	goal := core.vec2(175, 55) // the same row, right of the wall
	assert a.move_to(goal)
	assert a.is_moving() && a.path.len >= 2 // not a straight line: it has to go under the wall
	mut min_y_seen := f32(0)
	for _ in 0 .. 600 {
		s.update(1.0 / 60.0)
		min_y_seen = math.max(min_y_seen, n.position.y)
		if !a.is_moving() {
			break
		}
	}
	assert near(n.position, goal, 0.5) && f.hit == 1
	assert min_y_seen > 90 // it went down to the open rows (y >= 90) and came back
}

fn test_arrived_flag_is_one_frame() {
	mut s, _, _, _ := level()
	n, mut a := agent_at(mut s, 105, 105)
	assert a.move_to(core.vec2(115, 105))
	mut frames_arrived := 0
	for _ in 0 .. 30 {
		s.update(1.0 / 60.0)
		if a.arrived {
			frames_arrived++
		}
	}
	assert frames_arrived == 1
	assert near(n.position, core.vec2(115, 105), 0.01)
}

fn test_agent_repaths_when_the_map_changes() {
	mut s, _, mut tm, _ := level()
	n, mut a := agent_at(mut s, 125, 105) // bottom area
	assert a.move_to(core.vec2(175, 105))
	s.update(1.0 / 60.0)
	// wall off the passage under the wall: column 5 all the way down; no route is left
	tm.set(5, 4, 1)
	tm.set(5, 5, 1)
	for _ in 0 .. 300 {
		s.update(1.0 / 60.0)
	}
	// the repath found no way through; `closest` makes it walk to the nearest reachable spot, then stop
	assert !a.is_moving()
	assert n.position.x > 135 && n.position.x < 150 // right up to the wall, never across
	// open it again and send it
	tm.set(5, 5, -1)
	assert a.move_to(core.vec2(175, 105))
	for _ in 0 .. 300 {
		s.update(1.0 / 60.0)
	}
	assert near(n.position, core.vec2(175, 105), 0.5)
}

fn test_manual_grid_and_on_build_and_no_map() {
	mut s := core.Scene.new('t')
	mut lvl := core.Node.new('Level')
	lvl.position = core.vec2(0, 0)
	mut nm := lvl.add_component(&core.NavMap{
		columns:   8
		rows:      4
		cell_size: core.vec2(10, 10)
	})
	nm.on_build = fn (mut g core.NavGrid) {
		g.block_rect(40, 0, 10, 30) // standing furniture
	}
	s.add(mut lvl)
	assert nm.grid.columns == 8 && nm.grid.is_blocked(4, 2) && !nm.grid.is_blocked(4, 3)
	// a scene without any NavMap: move_to says no
	mut s2 := core.Scene.new('t2')
	_, mut a := agent_at(mut s2, 5, 5)
	assert !a.move_to(core.vec2(50, 5))
	assert !a.sees(core.vec2(50, 5), 90, 100)
}

fn test_agent_sees_through_the_scene_map() {
	mut s, _, _, _ := level()
	_, mut a := agent_at(mut s, 125, 55)
	assert a.sees(core.vec2(140, 55), 90, 100) // same side, open
	assert !a.sees(core.vec2(175, 55), 90, 100) // the wall between
	assert !a.sees(core.vec2(140, 55), 90, 5) // out of range
}
