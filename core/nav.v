module core

import math

// NavGrid — a grid of walkable and blocked cells for path finding (A*) and line of sight. Cells are `cell` world
// units big; `origin` is the world position of the top-left corner. Most games get one from a tile map through the
// NavMap component; build it by hand for anything else:
//
//   mut g := core.NavGrid.new(40, 30, core.vec2(32, 32), core.vec2(0, 0))
//   g.block_rect(100, 60, 64, 32)                       // a wall, in world units
//   path := g.find_path(player_pos, goal) or { return } // world positions, from near `from` to `to`
//
// A path never cuts a corner (a diagonal step needs both neighbors free). `set_cost(c, r, 3)` makes a cell cost
// three times as much to cross (mud, shallow water): paths go around it when that is cheaper.
@[heap]
pub struct NavGrid {
pub:
	columns int
	rows    int
	cell    Vec2
	origin  Vec2
pub mut:
	blocked  []bool
	cost     []f32 // 1 = normal; larger = slower to cross; never below 1
	revision int   // counts changes (a NavAgent repaths when its map changed)
mut:
	inflated     map[int]&NavGrid // clearance -> copy with the obstacles grown by that many cells
	inflated_rev int
}

pub fn NavGrid.new(columns int, rows int, cell Vec2, origin Vec2) &NavGrid {
	n := math.max(columns, 1) * math.max(rows, 1)
	return &NavGrid{
		columns: math.max(columns, 1)
		rows:    math.max(rows, 1)
		cell:    vec2(math.max(cell.x, 0.001), math.max(cell.y, 0.001))
		origin:  origin
		blocked: []bool{len: n}
		cost:    []f32{len: n, init: 1}
	}
}

pub fn (g &NavGrid) in_bounds(col int, row int) bool {
	return col >= 0 && row >= 0 && col < g.columns && row < g.rows
}

// is_blocked: outside the grid counts as blocked.
pub fn (g &NavGrid) is_blocked(col int, row int) bool {
	return !g.in_bounds(col, row) || g.blocked[row * g.columns + col]
}

pub fn (mut g NavGrid) set_blocked(col int, row int, blocked bool) {
	if g.in_bounds(col, row) && g.blocked[row * g.columns + col] != blocked {
		g.blocked[row * g.columns + col] = blocked
		g.revision++
	}
}

pub fn (mut g NavGrid) set_cost(col int, row int, cost f32) {
	if g.in_bounds(col, row) {
		g.cost[row * g.columns + col] = math.max(cost, 1)
		g.revision++
	}
}

// cell_of: the cell under a world point (may be outside the grid).
pub fn (g &NavGrid) cell_of(p Vec2) (int, int) {
	return int(math.floor((p.x - g.origin.x) / g.cell.x)), int(math.floor((p.y - g.origin.y) / g.cell.y))
}

// center_of: the world position of a cell's middle.
pub fn (g &NavGrid) center_of(col int, row int) Vec2 {
	return vec2(g.origin.x + (f32(col) + 0.5) * g.cell.x, g.origin.y + (f32(row) + 0.5) * g.cell.y)
}

// block_rect blocks (or frees) every cell that the world rectangle overlaps.
pub fn (mut g NavGrid) block_rect(x f32, y f32, w f32, h f32) {
	g.set_rect(x, y, w, h, true)
}

pub fn (mut g NavGrid) free_rect(x f32, y f32, w f32, h f32) {
	g.set_rect(x, y, w, h, false)
}

fn (mut g NavGrid) set_rect(x f32, y f32, w f32, h f32, blocked bool) {
	c0, r0 := g.cell_of(vec2(x, y))
	// the far edge belongs to the cell before it when it lands exactly on a cell border
	c1, r1 := g.cell_of(vec2(x + w - 0.0001, y + h - 0.0001))
	for r in math.max(r0, 0) .. math.min(r1 + 1, g.rows) {
		for c in math.max(c0, 0) .. math.min(c1 + 1, g.columns) {
			g.set_blocked(c, r, blocked)
		}
	}
}

// inflate returns a copy where every obstacle is `cells` cells fatter, so a body with a radius can follow a
// path found on it. Cached until the grid changes.
pub fn (mut g NavGrid) inflate(cells int) &NavGrid {
	if cells <= 0 {
		return g
	}
	if g.inflated_rev != g.revision {
		g.inflated.clear()
		g.inflated_rev = g.revision
	}
	if cached := g.inflated[cells] {
		return cached
	}
	mut out := NavGrid.new(g.columns, g.rows, g.cell, g.origin)
	out.cost = g.cost.clone()
	for r in 0 .. g.rows {
		for c in 0 .. g.columns {
			if !g.blocked[r * g.columns + c] {
				continue
			}
			for dr in -cells .. cells + 1 {
				for dc in -cells .. cells + 1 {
					if out.in_bounds(c + dc, r + dr) {
						out.blocked[(r + dr) * g.columns + c + dc] = true
					}
				}
			}
		}
	}
	g.inflated[cells] = out
	return out
}

// ---------- Line of sight ----------

// line_clear: no blocked cell lies on the straight segment a -> b (every cell the segment touches is checked).
pub fn (g &NavGrid) line_clear(a Vec2, b Vec2) bool {
	mut col, mut row := g.cell_of(a)
	ec, er := g.cell_of(b)
	if g.is_blocked(col, row) {
		return false
	}
	d := b - a
	step_c := if d.x > 0 {
		1
	} else if d.x < 0 {
		-1
	} else {
		0
	}
	step_r := if d.y > 0 {
		1
	} else if d.y < 0 {
		-1
	} else {
		0
	}
	// Amanatides & Woo: how far along the segment (0..1) the next vertical / horizontal cell border is
	mut t_max_x := f32(1e30)
	mut t_max_y := f32(1e30)
	mut t_dx := f32(1e30)
	mut t_dy := f32(1e30)
	if step_c != 0 {
		next := g.origin.x + f32(if step_c > 0 { col + 1 } else { col }) * g.cell.x
		t_max_x = (next - a.x) / d.x
		t_dx = g.cell.x / math.abs(d.x)
	}
	if step_r != 0 {
		next := g.origin.y + f32(if step_r > 0 { row + 1 } else { row }) * g.cell.y
		t_max_y = (next - a.y) / d.y
		t_dy = g.cell.y / math.abs(d.y)
	}
	for col != ec || row != er {
		if t_max_x < t_max_y {
			col += step_c
			t_max_x += t_dx
		} else if t_max_y < t_max_x {
			row += step_r
			t_max_y += t_dy
		} else { // exactly through a corner: both neighbors must be free to pass between them
			if g.is_blocked(col + step_c, row) || g.is_blocked(col, row + step_r) {
				return false
			}
			col += step_c
			row += step_r
			t_max_x += t_dx
			t_max_y += t_dy
		}
		if g.is_blocked(col, row) {
			return false
		}
		if t_max_x > 1.5 && t_max_y > 1.5 {
			break
		}
	}
	return true
}

// can_see: `target` is within `range` of `from`, inside the vision cone (`facing` is a direction, `fov` the full
// opening in degrees; 360 sees all around) and nothing blocks the line.
pub fn (g &NavGrid) can_see(from Vec2, facing Vec2, fov f32, range f32, target Vec2) bool {
	d := target - from
	dist := d.length()
	if dist > range {
		return false
	}
	if dist > 0.0001 && fov < 360 && facing.length() > 0.0001 {
		cos_angle := (d.x * facing.x + d.y * facing.y) / (dist * facing.length())
		if f32(math.acos(math.clamp(cos_angle, -1, 1))) > fov * 0.5 * f32(math.pi) / 180 {
			return false
		}
	}
	return g.line_clear(from, target)
}

// ---------- A* ----------

@[params]
pub struct PathOptions {
pub:
	diagonal  bool = true // 8 directions (never cutting corners); false = 4
	smooth    bool = true // pull the path straight where there is line of sight
	closest   bool // goal blocked or unreachable: walk to the reachable cell nearest to it instead of giving up
	clearance int  // keep this many cells away from obstacles (a body with a radius)
	max_nodes int = 50000 // search limit (cells expanded)
}

struct OpenNode {
	f   f32
	idx int
}

fn heap_push(mut h []OpenNode, n OpenNode) {
	h << n
	mut i := h.len - 1
	for i > 0 {
		p := (i - 1) / 2
		if h[p].f <= h[i].f {
			break
		}
		h[p], h[i] = h[i], h[p]
		i = p
	}
}

fn heap_pop(mut h []OpenNode) OpenNode {
	top := h[0]
	last := h.pop()
	if h.len > 0 {
		h[0] = last
		mut i := 0
		for {
			l, r := 2 * i + 1, 2 * i + 2
			mut m := i
			if l < h.len && h[l].f < h[m].f {
				m = l
			}
			if r < h.len && h[r].f < h[m].f {
				m = r
			}
			if m == i {
				break
			}
			h[m], h[i] = h[i], h[m]
			i = m
		}
	}
	return top
}

// find_path searches the shortest route from `from` to `to` (world positions) and returns the waypoints, the
// first one is the first place to walk to (not `from` itself) and the last is `to` (or, with `closest`, where the
// search ended). `none`: no route. A start inside an obstacle is allowed (it walks out of it).
pub fn (mut g NavGrid) find_path(from Vec2, to Vec2, opts PathOptions) ?[]Vec2 {
	grid := g.inflate(opts.clearance)
	sc, sr := grid.cell_of(from)
	mut gc, mut gr := grid.cell_of(to)
	if !grid.in_bounds(sc, sr) {
		return none
	}
	if !grid.in_bounds(gc, gr) && !opts.closest {
		return none
	}
	gc = int(math.clamp(gc, 0, grid.columns - 1))
	gr = int(math.clamp(gr, 0, grid.rows - 1))
	start := sr * grid.columns + sc
	goal := gr * grid.columns + gc
	if start == goal {
		return [to]
	}
	if grid.blocked[goal] && !opts.closest {
		return none
	}
	n := grid.columns * grid.rows
	mut gscore := []f32{len: n, init: 1e30}
	mut came := []int{len: n, init: -1}
	mut closed := []bool{len: n}
	mut open := []OpenNode{}
	gscore[start] = 0
	heap_push(mut open, OpenNode{grid.heuristic(sc, sr, gc, gr, opts.diagonal), start})
	mut best := start // the closest cell to the goal seen (for `closest`)
	mut best_h := grid.heuristic(sc, sr, gc, gr, opts.diagonal)
	mut expanded := 0
	mut found := false
	for open.len > 0 && expanded < opts.max_nodes {
		cur := heap_pop(mut open)
		if closed[cur.idx] {
			continue
		}
		closed[cur.idx] = true
		expanded++
		if cur.idx == goal {
			found = true
			break
		}
		cc, cr := cur.idx % grid.columns, cur.idx / grid.columns
		h := grid.heuristic(cc, cr, gc, gr, opts.diagonal)
		if h < best_h {
			best_h = h
			best = cur.idx
		}
		for dr in -1 .. 2 {
			for dc in -1 .. 2 {
				if dr == 0 && dc == 0 {
					continue
				}
				diag := dr != 0 && dc != 0
				if diag && !opts.diagonal {
					continue
				}
				nc, nr := cc + dc, cr + dr
				if !grid.in_bounds(nc, nr) || grid.blocked[nr * grid.columns + nc] {
					continue
				}
				if diag && (grid.is_blocked(cc + dc, cr) || grid.is_blocked(cc, cr + dr)) {
					continue // no corner cutting
				}
				ni := nr * grid.columns + nc
				if closed[ni] {
					continue
				}
				step := if diag { f32(1.41421356) } else { f32(1) }
				ng := gscore[cur.idx] + step * grid.cost[ni]
				if ng < gscore[ni] {
					gscore[ni] = ng
					came[ni] = cur.idx
					heap_push(mut open, OpenNode{ng + grid.heuristic(nc, nr, gc, gr, opts.diagonal), ni})
				}
			}
		}
	}
	end := if found {
		goal
	} else if opts.closest && best != start {
		best
	} else {
		return none
	}
	mut cells := []int{}
	mut i := end
	for i != -1 {
		cells << i
		i = came[i]
	}
	cells = cells.reverse() // start first (reverse() returns a copy)
	mut pts := []Vec2{}
	for k, ci in cells {
		if k == 0 {
			continue // where we already are
		}
		pts << grid.center_of(ci % grid.columns, ci / grid.columns)
	}
	if found {
		if pts.len > 0 {
			pts[pts.len - 1] = to // the exact goal, not its cell's center
		} else {
			pts << to
		}
	}
	if opts.smooth && pts.len > 2 {
		pts = grid.smooth_path(from, pts)
	}
	return pts
}

fn (g &NavGrid) heuristic(c0 int, r0 int, c1 int, r1 int, diagonal bool) f32 {
	dx := f32(math.abs(c1 - c0))
	dy := f32(math.abs(r1 - r0))
	if diagonal {
		return (dx + dy) + (1.41421356 - 2) * math.min(dx, dy) // octile
	}
	return dx + dy
}

// smooth_path drops waypoints that a straight line can skip (string pulling): from each anchor it goes to the
// farthest waypoint it can see.
fn (g &NavGrid) smooth_path(from Vec2, pts []Vec2) []Vec2 {
	mut out := []Vec2{}
	mut anchor := from
	mut i := 0
	for i < pts.len {
		mut far := i
		for k := pts.len - 1; k > i; k-- {
			if g.line_clear(anchor, pts[k]) {
				far = k
				break
			}
		}
		out << pts[far]
		anchor = pts[far]
		i = far + 1
	}
	return out
}

// path_length: the length of a path starting at `from`.
pub fn path_length(from Vec2, path []Vec2) f32 {
	mut total := f32(0)
	mut prev := from
	for p in path {
		total += (p - prev).length()
		prev = p
	}
	return total
}
