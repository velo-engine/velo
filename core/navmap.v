module core

import math

// NavMap — the walkable grid of a scene, for NavAgents and your own path finding (`scene.nav_map()`).
//
// Next to a TileMap (anything core.SolidTiles) it is built from the map: a cell that holds a solid tile is blocked
// (`solid_tiles` lists the tile frames that block; empty = every non-empty tile) and the grid follows the map's cells,
// position and scale. It is built again when the tiles change. Without a tile map it is an empty grid of
// `columns` x `rows` cells of `cell_size`, top-left at the node, that you fill from code:
//
//   node Level {
//     TileMap { ... }
//     NavMap { solid_tiles = [1, 2, 3] }
//     node Goblin { NavAgent { speed = 90 } }
//   }
//
//   mut agent := goblin.get_component[core.NavAgent]()!
//   agent.move_to(scene.screen_to_world(input.mouse))
//
// The map assumes its node is not rotated (position and scale apply).
@[heap]
pub struct NavMap {
	Component
pub mut:
	solid_tiles []int
	// Only without a tile map:
	columns   int      = 20
	rows      int      = 12
	cell_size Vec2     = Vec2{32, 32}
	grid      &NavGrid = unsafe { nil } @[hide]
	// Called after the grid was built (again): block what the tiles do not know, e.g. standing furniture.
	on_build   fn (mut g NavGrid) = unsafe { nil } @[hide]
	built      int                = -1                @[hide]
	registered bool               @[hide]
}

pub fn (mut n NavMap) on_load() {
	if n.node.scene != unsafe { nil } && !n.registered {
		mut s := n.node.scene
		s.navmaps << n
		n.registered = true
	}
	n.rebuild()
}

pub fn (mut n NavMap) on_destroy() {
	if n.node.scene != unsafe { nil } && n.registered {
		mut s := n.node.scene
		s.navmaps = s.navmaps.filter(voidptr(it) != voidptr(n))
	}
	n.registered = false
}

pub fn (mut n NavMap) update(dt f32) {
	if n.tiles_changed() {
		n.rebuild()
	}
}

// rebuild makes the grid again from the tile map (or an empty one).
pub fn (mut n NavMap) rebuild() {
	m := n.node.world_matrix()
	sc := m.scale()
	sx, sy := f32(math.abs(sc.x)), f32(math.abs(sc.y))
	mut made := false
	for c in n.node.components {
		if c is SolidTiles {
			b := c.solid_bounds()
			cell := c.solid_cell()
			cols := int(math.round(b.size.x / math.max(cell.x, 0.001)))
			rws := int(math.round(b.size.y / math.max(cell.y, 0.001)))
			origin := m.apply(b.pos)
			mut g := NavGrid.new(cols, rws, vec2(cell.x * sx, cell.y * sy), origin)
			for r in c.solid_rects(n.solid_tiles) {
				p := m.apply(r.pos)
				g.block_rect(p.x, p.y, r.size.x * sx, r.size.y * sy)
			}
			n.built = c.solid_revision()
			n.grid = g
			made = true
			break
		}
	}
	if !made {
		wp := n.node.world_position()
		n.grid = NavGrid.new(n.columns, n.rows, vec2(n.cell_size.x * sx, n.cell_size.y * sy), wp)
		n.built = 0
	}
	if n.on_build != unsafe { nil } {
		n.on_build(mut n.grid)
	}
}

// nav_grid: the grid, up to date: built on first use, and again when the tile map changed since (so a path asked
// for right after tm.set() already sees the new wall).
pub fn (mut n NavMap) nav_grid() &NavGrid {
	if n.grid == unsafe { nil } || n.tiles_changed() {
		n.rebuild()
	}
	return n.grid
}

fn (n &NavMap) tiles_changed() bool {
	for c in n.node.components {
		if c is SolidTiles {
			return c.solid_revision() != n.built
		}
	}
	return false
}

// NavAgent — walks its node along a path over the scene's NavMap. `move_to` finds the path and the agent follows it
// at `speed`; it repaths by itself when the map changes (a door opens, a tile is placed).
//
//   agent.move_to(goal)                       // false: no way there
//   if agent.arrived { ... }                  // true for the frame it got there; or set on_arrive
//   agent.sees(player_pos, 90, 200)           // vision cone (fov degrees, range) with walls blocking
pub struct NavAgent {
	Component
pub mut:
	speed     f32  = 120 // world units per second
	diagonal  bool = true
	smooth    bool = true // pull the path straight where it can
	closest   bool = true // goal blocked or unreachable: walk to the nearest reachable point instead of staying
	clearance int  // keep this many cells away from walls
	rotate    bool // turn the node to face where it walks
	// Where it is going, and the path left to walk.
	path      []Vec2 @[hide]
	index     int    @[hide]
	target    Vec2   @[hide]
	moving    bool   @[hide]
	arrived   bool   @[hide] // true for one frame after reaching the end
	facing    Vec2  = Vec2{1, 0}   @[hide] // the last direction it walked
	map_rev   int   = -1    @[hide]
	on_arrive fn () = unsafe { nil }  @[hide]
}

// move_to finds a path to `goal` (world position) and starts walking. false: there is no path (the agent keeps
// doing what it did).
pub fn (mut a NavAgent) move_to(goal Vec2) bool {
	mut nm := a.scene().nav_map() or { return false }
	mut g := nm.nav_grid()
	path := g.find_path(a.node.world_position(), goal, PathOptions{
		diagonal:  a.diagonal
		smooth:    a.smooth
		closest:   a.closest
		clearance: a.clearance
	}) or { return false }
	a.path = path
	a.index = 0
	a.target = goal
	a.moving = path.len > 0
	a.map_rev = g.revision
	a.arrived = false
	return true
}

pub fn (mut a NavAgent) stop() {
	a.moving = false
	a.path = []
}

pub fn (a &NavAgent) is_moving() bool {
	return a.moving
}

pub fn (mut a NavAgent) update(dt f32) {
	a.arrived = false
	if !a.moving {
		return
	}
	if mut nm := a.scene().nav_map() {
		g := nm.nav_grid()
		if g.revision != a.map_rev || nm.built < 0 {
			if !a.move_to(a.target) {
				a.stop()
				return
			}
		}
	}
	mut pos := a.node.world_position()
	mut step := a.speed * dt
	for step > 0 && a.index < a.path.len {
		d := a.path[a.index] - pos
		dist := d.length()
		if dist <= step {
			pos = a.path[a.index]
			step -= dist
			a.index++
		} else {
			dir := d.mul(1 / dist)
			a.facing = dir
			pos = pos + dir.mul(step)
			step = 0
		}
	}
	a.node.set_world_position(pos)
	if a.rotate {
		a.node.rotation = f32(math.atan2(a.facing.y, a.facing.x) * 180.0 / math.pi)
	}
	if a.index >= a.path.len {
		a.moving = false
		a.arrived = true
		if a.on_arrive != unsafe { nil } {
			a.on_arrive()
		}
	}
}

// sees: `target` is within `range`, inside the vision cone around where the agent faces (`fov` degrees; 360 =
// all around) and no wall is between.
pub fn (a &NavAgent) sees(target Vec2, fov f32, range f32) bool {
	nm := a.scene().nav_map() or { return false }
	if nm.grid == unsafe { nil } {
		return false
	}
	return nm.grid.can_see(a.node.world_position(), a.facing, fov, range, target)
}
