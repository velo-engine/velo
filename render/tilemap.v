module render

import gg
import math
import sokol.sgl
import velo.core
import velo.assets

// TileMap — a grid of tiles cut from one tileset, drawn in a single draw call (only the visible cells).
// The tileset is an ordinary sprite sheet: its .meta `frame_width`/`frame_height` give the tile size and
// a tile is a frame index (left -> right, top -> bottom), -1 = empty cell. `tiles` is row-major.
//
//   TileMap { tileset = @asset("e71a0c3d")  columns = 4  rows = 2  tiles = [0, 1, 1, 2, 4, 5, 5, 6] }
//
// The node's position is the map's top-left corner (anchor [0, 0]); paint it in the editor's Inspector.
//
// `layout` picks how the cells sit on the map (a cell is always `tile_size` big: the box its tile is drawn in):
//   orthogonal  square grid (default)
//   isometric   diamond grid; col runs down-right, row down-left; drawn back to front
//   staggered   isometric diamonds in offset rows: odd rows are shifted half a tile right
//               (stagger_odd = false: the even rows)
//   hex_pointy  pointy-top hexagons in offset rows (rows touch at 3/4 of the tile height)
//   hex_flat    flat-top hexagons in offset columns (odd columns shifted half a tile down)
// For the hex layouts `hex_side` is the length of the edge parallel to the stagger axis (0 = half the tile).
pub struct TileMap {
	core.Component
pub mut:
	tileset     assets.AssetRef[assets.Texture]
	columns     int = 16 // map size in cells; change it with `resize` so existing tiles keep their place
	rows        int = 10
	tile_size   core.Vec2 // cell size in world units; 0 = the tileset's frame size
	anchor      core.Vec2 // (0,0) top-left corner of the map at the node, (0.5,0.5) centered
	color       core.Color = core.white
	layout      string     = 'orthogonal' @[choices: 'orthogonal|isometric|staggered|hex_pointy|hex_flat']
	stagger_odd bool       = true // staggered and hex layouts: shift the odd rows / columns (false: the even ones)
	hex_side    f32   // hex layouts: edge length along the stagger axis, 0 = half the tile
	tiles       []int // columns * rows frame indices, row by row; -1 = empty (missing entries are empty too)
	// Auto-tiling and animated tiles (see tilemap_terrain.v): a `.tilerules` asset, and per cell a terrain id of it
	// (0 = none) whose frame the rules pick from the neighbors.
	rules        assets.AssetRef[assets.TextAsset]
	terrain      []int
	tex          &assets.Texture = unsafe { nil } @[hide]
	loaded       string          @[hide]
	rule_set     &TileRules = unsafe { nil }      @[hide]
	rules_hash   u64             @[hide]
	rules_failed bool            @[hide]
	// Counts changes of the cells; a TileMapCollider rebuilds its boxes when it differs from what it built.
	revision int @[hide]
}

pub const no_tile = -1

// TileLayout — the parsed `layout` of a TileMap.
pub enum TileLayout {
	orthogonal
	isometric
	staggered
	hex_pointy
	hex_flat
}

// tile_layout: the map's `layout` (an unknown name means orthogonal).
pub fn (tm &TileMap) tile_layout() TileLayout {
	return match tm.layout {
		'isometric' { TileLayout.isometric }
		'staggered' { TileLayout.staggered }
		'hex_pointy' { TileLayout.hex_pointy }
		'hex_flat' { TileLayout.hex_flat }
		else { TileLayout.orthogonal }
	}
}

pub fn (mut tm TileMap) on_load() {
	tm.acquire()
	tm.load_rules()
}

pub fn (mut tm TileMap) on_destroy() {
	tm.drop()
}

// set_tileset changes the tileset at runtime, managing references automatically.
pub fn (mut tm TileMap) set_tileset(r assets.AssetRef[assets.Texture]) {
	tm.drop()
	tm.tileset = r
	tm.acquire()
}

// ---------- Cells ----------

// in_bounds: true if (col, row) is a cell of the map.
pub fn (tm &TileMap) in_bounds(col int, row int) bool {
	return col >= 0 && row >= 0 && col < tm.columns && row < tm.rows
}

// get: the tile at (col, row), -1 when empty or outside the map.
pub fn (tm &TileMap) get(col int, row int) int {
	if !tm.in_bounds(col, row) {
		return no_tile
	}
	i := row * tm.columns + col
	return if i < tm.tiles.len { tm.tiles[i] } else { no_tile }
}

// set puts `tile` (-1 = erase) at (col, row); outside the map it does nothing. Returns true if the cell changed.
pub fn (mut tm TileMap) set(col int, row int, tile int) bool {
	t := if tile < 0 { no_tile } else { tile }
	if !tm.in_bounds(col, row) || tm.get(col, row) == t {
		return false
	}
	tm.normalize()
	tm.tiles[row * tm.columns + col] = t
	tm.revision++
	return true
}

// fill_rect sets every cell between the two corners (inclusive, clipped to the map).
pub fn (mut tm TileMap) fill_rect(col0 int, row0 int, col1 int, row1 int, tile int) {
	for r in math.max(math.min(row0, row1), 0) .. math.min(math.max(row0, row1) + 1, tm.rows) {
		for c in math.max(math.min(col0, col1), 0) .. math.min(math.max(col0, col1) + 1, tm.columns) {
			tm.set(c, r, tile)
		}
	}
}

// flood_fill replaces the connected area (cells sharing an edge, see `neighbors`) of cells equal to the one at
// (col, row) with `tile`.
// Returns the number of cells changed.
pub fn (mut tm TileMap) flood_fill(col int, row int, tile int) int {
	target := tm.get(col, row)
	if !tm.in_bounds(col, row) || target == (if tile < 0 {
		no_tile
	} else {
		tile
	}) {
		return 0
	}
	mut stack := [col, row]
	mut n := 0
	for stack.len > 0 {
		r := stack.pop()
		c := stack.pop()
		if tm.get(c, r) != target || !tm.in_bounds(c, r) {
			continue
		}
		tm.set(c, r, tile)
		n++
		for nb in tm.neighbors(c, r) {
			stack << nb[0]
			stack << nb[1]
		}
	}
	return n
}

// shifted: true when row (pointy / staggered) or column (flat) `i` sits half a tile off.
fn (tm &TileMap) shifted(i int) bool {
	return (i & 1 == 1) == tm.stagger_odd
}

// neighbors: the cells sharing an edge with (col, row), as [col, row] pairs (they may lie outside the map):
// 4 for orthogonal, isometric and staggered, 6 for the hex layouts.
pub fn (tm &TileMap) neighbors(col int, row int) [][]int {
	match tm.tile_layout() {
		.orthogonal, .isometric {
			return [[col + 1, row], [col - 1, row], [col, row + 1],
				[col, row - 1]]
		}
		.staggered, .hex_pointy {
			d := if tm.shifted(row) { 1 } else { -1 } // the rows above and below touch columns col and col + d
			mut out := [[col, row - 1], [col + d, row - 1], [col, row + 1],
				[col + d, row + 1]]
			if tm.tile_layout() == .hex_pointy {
				out << [col + 1, row]
				out << [col - 1, row]
			}
			return out
		}
		.hex_flat {
			d := if tm.shifted(col) { 1 } else { -1 }
			return [[col, row - 1], [col, row + 1], [col - 1, row],
				[col - 1, row + d], [col + 1, row], [col + 1, row + d]]
		}
	}
}

// clear empties every cell.
pub fn (mut tm TileMap) clear() {
	tm.tiles = []int{len: tm.columns * tm.rows, init: no_tile}
	tm.terrain = []int{len: tm.columns * tm.rows}
	tm.revision++
}

// resize changes the map size, keeping each tile at its (col, row); cells outside the new size are dropped.
pub fn (mut tm TileMap) resize(columns int, rows int) {
	cols := math.max(columns, 1)
	rs := math.max(rows, 1)
	mut out := []int{len: cols * rs, init: no_tile}
	mut terr := []int{len: cols * rs}
	for r in 0 .. math.min(rs, tm.rows) {
		for c in 0 .. math.min(cols, tm.columns) {
			out[r * cols + c] = tm.get(c, r)
			terr[r * cols + c] = tm.terrain_at(c, r)
		}
	}
	tm.columns = cols
	tm.rows = rs
	tm.tiles = out
	tm.terrain = terr
	tm.revision++
	tm.refresh_terrain()
}

// count: the number of non-empty cells.
pub fn (tm &TileMap) count() int {
	mut n := 0
	for r in 0 .. tm.rows {
		for c in 0 .. tm.columns {
			if tm.get(c, r) >= 0 {
				n++
			}
		}
	}
	return n
}

// normalize makes `tiles` exactly columns * rows long (a hand-written or truncated list is padded with -1).
fn (mut tm TileMap) normalize() {
	want := math.max(tm.columns, 0) * math.max(tm.rows, 0)
	if tm.tiles.len > want {
		tm.tiles.trim(want)
	}
	for tm.tiles.len < want {
		tm.tiles << no_tile
	}
}

// ---------- Geometry ----------

// cell_size: the size of one cell in node space (tile_size, or the tileset's frame size, or 16x16 without one).
pub fn (tm &TileMap) cell_size() core.Vec2 {
	if tm.tile_size.x > 0 && tm.tile_size.y > 0 {
		return tm.tile_size
	}
	if tm.tex != unsafe { nil } && tm.tex.frame_w() > 0 && tm.tex.frame_h() > 0 {
		return core.vec2(tm.tex.frame_w(), tm.tex.frame_h())
	}
	return core.vec2(16, 16)
}

// hex_edge: the hex layouts' edge length along the stagger axis.
fn (tm &TileMap) hex_edge(cs core.Vec2) f32 {
	if tm.hex_side > 0 {
		return tm.hex_side
	}
	return if tm.tile_layout() == .hex_flat { cs.x / 2 } else { cs.y / 2 }
}

// step: the distance between neighboring cells along x and y (the layout's lattice spacing).
fn (tm &TileMap) step(cs core.Vec2) (f32, f32) {
	match tm.tile_layout() {
		.orthogonal {
			return cs.x, cs.y
		}
		.isometric {
			return cs.x / 2, cs.y / 2
		}
		.staggered {
			return cs.x, cs.y / 2
		}
		.hex_pointy {
			return cs.x, (cs.y + tm.hex_edge(cs)) / 2
		}
		.hex_flat {
			return (cs.x + tm.hex_edge(cs)) / 2, cs.y
		}
	}
}

// local_rect: the rectangle (x, y, w, h) the whole map covers in node space.
pub fn (tm &TileMap) local_rect() (f32, f32, f32, f32) {
	cs := tm.cell_size()
	cols := f32(math.max(tm.columns, 0))
	rs := f32(math.max(tm.rows, 0))
	sx, sy := tm.step(cs)
	mut w := f32(0)
	mut h := f32(0)
	if cols > 0 && rs > 0 {
		match tm.tile_layout() {
			.orthogonal {
				w, h = cols * cs.x, rs * cs.y
			}
			.isometric {
				w, h = (cols + rs) * sx, (cols + rs) * sy
			}
			.staggered {
				w, h = cols * cs.x + cs.x / 2, (rs - 1) * sy + cs.y
			}
			.hex_pointy {
				w, h = cols * cs.x + cs.x / 2, (rs - 1) * sy + cs.y
			}
			.hex_flat {
				w, h = (cols - 1) * sx + cs.x, rs * cs.y + cs.y / 2
			}
		}
	}
	return -tm.anchor.x * w, -tm.anchor.y * h, w, h
}

// cell_origin: the top-left corner of the cell's tile box, relative to the map's top-left corner.
fn (tm &TileMap) cell_origin(col int, row int, cs core.Vec2) (f32, f32) {
	sx, sy := tm.step(cs)
	match tm.tile_layout() {
		.orthogonal {
			return f32(col) * cs.x, f32(row) * cs.y
		}
		.isometric {
			return f32(tm.rows - 1 + col - row) * sx, f32(col + row) * sy
		}
		.staggered, .hex_pointy {
			dx := if tm.shifted(row) { cs.x / 2 } else { f32(0) }
			return f32(col) * cs.x + dx, f32(row) * sy
		}
		.hex_flat {
			dy := if tm.shifted(col) { cs.y / 2 } else { f32(0) }
			return f32(col) * sx, f32(row) * cs.y + dy
		}
	}
}

// tile_outline: the cell's outline inside its tile box (w x h): the box, a diamond or a hexagon.
fn (tm &TileMap) tile_outline(cs core.Vec2) []core.Vec2 {
	w, h := cs.x, cs.y
	match tm.tile_layout() {
		.orthogonal {
			return [core.vec2(0, 0), core.vec2(w, 0), core.vec2(w, h),
				core.vec2(0, h)]
		}
		.isometric, .staggered {
			return [core.vec2(w / 2, 0), core.vec2(w, h / 2),
				core.vec2(w / 2, h), core.vec2(0, h / 2)]
		}
		.hex_pointy {
			a := (h - tm.hex_edge(cs)) / 2
			return [core.vec2(w / 2, 0), core.vec2(w, a), core.vec2(w, h - a),
				core.vec2(w / 2, h), core.vec2(0, h - a), core.vec2(0, a)]
		}
		.hex_flat {
			a := (w - tm.hex_edge(cs)) / 2
			return [core.vec2(a, 0), core.vec2(w - a, 0), core.vec2(w, h / 2),
				core.vec2(w - a, h), core.vec2(a, h), core.vec2(0, h / 2)]
		}
	}
}

// cell_polygon: the outline of a cell in node space (4 corners, or 6 for a hex), clockwise on screen.
pub fn (tm &TileMap) cell_polygon(col int, row int) []core.Vec2 {
	x, y, _, _ := tm.cell_local_rect(col, row)
	return tm.tile_outline(tm.cell_size()).map(core.vec2(x + it.x, y + it.y))
}

// inside_convex: true if `p` lies in the convex polygon `poly` (edges count as inside).
fn inside_convex(poly []core.Vec2, p core.Vec2) bool {
	mut pos := false
	mut neg := false
	for i, a in poly {
		b := poly[(i + 1) % poly.len]
		cr := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
		if cr > 0 {
			pos = true
		} else if cr < 0 {
			neg = true
		}
	}
	return !(pos && neg)
}

// local_to_cell: the (col, row) under a node-space point (may be outside the map, see in_bounds).
pub fn (tm &TileMap) local_to_cell(p core.Vec2) (int, int) {
	x, y, _, _ := tm.local_rect()
	cs := tm.cell_size()
	rx, ry := p.x - x, p.y - y
	lay := tm.tile_layout()
	if lay == .orthogonal {
		return int(math.floor(rx / cs.x)), int(math.floor(ry / cs.y))
	}
	sx, sy := tm.step(cs)
	if lay == .isometric {
		a := rx / sx - f32(tm.rows) // col - row at the cell's center
		b := ry / sy - 1 // col + row
		return int(math.floor((a + b) / 2 + 0.5)), int(math.floor((b - a) / 2 + 0.5))
	}
	// offset layouts: test the few cells around the point, each against its outline
	outline := tm.tile_outline(cs)
	cg := int(math.floor(rx / sx))
	rg := int(math.floor(ry / sy))
	mut best_c, mut best_r := cg, rg
	mut best_d := f32(1e30)
	for r in rg - 2 .. rg + 2 {
		for c in cg - 2 .. cg + 2 {
			ox, oy := tm.cell_origin(c, r, cs)
			q := core.vec2(rx - ox, ry - oy)
			if inside_convex(outline, q) {
				return c, r
			}
			d := (q - core.vec2(cs.x / 2, cs.y / 2)).length()
			if d < best_d {
				best_c, best_r, best_d = c, r, d
			}
		}
	}
	return best_c, best_r
}

// visible_cells: the cells whose tile box touches the node-space rectangle (x0, y0)-(x1, y1), as
// row * columns + col, in drawing order (back to front: rows top to bottom, isometric diagonals).
pub fn (tm &TileMap) visible_cells(x0 f32, y0 f32, x1 f32, y1 f32) []int {
	mut sc := &CellScratch{}
	tm.visible_cells_into(mut sc, x0, y0, x1, y1)
	return sc.cells
}

// CellScratch — the buffer visible_cells_into fills; the renderer keeps one so drawing a map does not allocate.
@[heap]
struct CellScratch {
mut:
	cells []int
}

// visible_cells_into puts the visible cells (see visible_cells) in `sc.cells`, reusing its memory.
fn (tm &TileMap) visible_cells_into(mut sc CellScratch, x0 f32, y0 f32, x1 f32, y1 f32) {
	sc.cells.clear()
	ox, oy, _, _ := tm.local_rect()
	cs := tm.cell_size()
	sx, sy := tm.step(cs)
	rx0, ry0, rx1, ry1 := x0 - ox, y0 - oy, x1 - ox, y1 - oy
	cols, rows := tm.columns, tm.rows
	match tm.tile_layout() {
		.orthogonal {
			r_from, r_to := math.max(int(math.floor(ry0 / cs.y)), 0), math.min(int(math.ceil(ry1 / cs.y)) - 1,
				rows - 1)
			c_from, c_to := math.max(int(math.floor(rx0 / cs.x)), 0), math.min(int(math.ceil(rx1 / cs.x)) - 1,
				cols - 1)
			for r in r_from .. r_to + 1 {
				for c in c_from .. c_to + 1 {
					sc.cells << r * cols + c
				}
			}
		}
		.isometric {
			// diagonal s = col + row sits at y = s * sy; d = col - row at x = (rows - 1 + d) * sx
			s_lo := math.max(int(math.floor((ry0 - cs.y) / sy)) + 1, 0)
			s_hi := math.min(int(math.ceil(ry1 / sy)) - 1, cols + rows - 2)
			d_lo := int(math.floor((rx0 - cs.x) / sx)) + 1 - (rows - 1)
			d_hi := int(math.ceil(rx1 / sx)) - 1 - (rows - 1)
			for s in s_lo .. s_hi + 1 {
				c_lo := math.max(math.max(s - rows + 1, 0), int(math.ceil(f32(s + d_lo) / 2)))
				c_hi := math.min(math.min(s, cols - 1), int(math.floor(f32(s + d_hi) / 2)))
				for c in c_lo .. c_hi + 1 {
					r := s - c
					d := c - r
					if r >= 0 && r < rows && d >= d_lo && d <= d_hi {
						sc.cells << r * cols + c
					}
				}
			}
		}
		else {
			flat := tm.tile_layout() == .hex_flat
			r_lo := if flat {
				int(math.ceil((ry0 - cs.y * 1.5) / cs.y))
			} else {
				int(math.ceil((ry0 - cs.y) / sy))
			}
			r_hi := if flat { int(math.floor(ry1 / cs.y)) } else { int(math.floor(ry1 / sy)) }
			c_lo := if flat {
				int(math.ceil((rx0 - cs.x) / sx))
			} else {
				int(math.ceil((rx0 - cs.x * 1.5) / cs.x))
			}
			c_hi := if flat { int(math.floor(rx1 / sx)) } else { int(math.floor(rx1 / cs.x)) }
			for r in math.max(r_lo, 0) .. math.min(r_hi + 1, rows) {
				for c in math.max(c_lo, 0) .. math.min(c_hi + 1, cols) {
					x, y := tm.cell_origin(c, r, cs)
					if x < rx1 && x + cs.x > rx0 && y < ry1 && y + cs.y > ry0 {
						sc.cells << r * cols + c
					}
				}
			}
		}
	}
}

// world_to_cell: the (col, row) under a world point, e.g. the player's feet.
pub fn (tm &TileMap) world_to_cell(p core.Vec2) (int, int) {
	return tm.local_to_cell(tm.node.world_matrix().inverse().apply(p))
}

// tile_at: the tile under a world point (-1 when empty or outside the map).
pub fn (tm &TileMap) tile_at(p core.Vec2) int {
	c, r := tm.world_to_cell(p)
	return tm.get(c, r)
}

// cell_local_rect: the node-space rectangle (x, y, w, h) of a cell.
pub fn (tm &TileMap) cell_local_rect(col int, row int) (f32, f32, f32, f32) {
	x, y, _, _ := tm.local_rect()
	cs := tm.cell_size()
	cx, cy := tm.cell_origin(col, row, cs)
	return x + cx, y + cy, cs.x, cs.y
}

// cell_center: the world position of a cell's center (to place objects on the grid).
pub fn (tm &TileMap) cell_center(col int, row int) core.Vec2 {
	x, y, w, h := tm.cell_local_rect(col, row)
	return tm.node.world_matrix().apply(core.vec2(x + w / 2, y + h / 2))
}

// debug_outline: the map's border, so an empty map (or one without a tileset) is visible and clickable in the editor.
pub fn (tm &TileMap) debug_outline() []core.Vec2 {
	x, y, w, h := tm.local_rect()
	return [core.vec2(x, y), core.vec2(x + w, y), core.vec2(x + w, y + h),
		core.vec2(x, y + h)]
}

pub fn (tm &TileMap) debug_color() core.Color {
	return core.rgba(120, 200, 255, 110)
}

// ---------- Drawing ----------

// draw_tilemap draws the cells that intersect the clip area, as textured quads in one batch.
fn (mut r Renderer) draw_tilemap(tm &TileMap, m core.Affine2) {
	tex := tm.tex
	if tex == unsafe { nil } || tex.width <= 0 || tex.height <= 0 || tm.columns <= 0 || tm.rows <= 0 {
		return
	}
	img := r.image_for(tex) or { return }
	if !img.simg_ok {
		return
	}
	// visible cell range: the clip rectangle brought back into node space
	inv := m.inverse()
	cl := r.clip
	p0 := inv.apply(core.vec2(cl.x, cl.y))
	p1 := inv.apply(core.vec2(cl.x + cl.w, cl.y))
	p2 := inv.apply(core.vec2(cl.x + cl.w, cl.y + cl.h))
	p3 := inv.apply(core.vec2(cl.x, cl.y + cl.h))
	mut sc := r.cell_scratch
	tm.visible_cells_into(mut sc, min4(p0.x, p1.x, p2.x, p3.x), min4(p0.y, p1.y, p2.y, p3.y), max4(p0.x,
		p1.x, p2.x, p3.x), max4(p0.y, p1.y, p2.y, p3.y))
	if sc.cells.len == 0 {
		return
	}
	cs := tm.cell_size()
	ox, oy, _, _ := tm.local_rect()
	frames := tex.frame_count()
	tw, th := f32(tex.width), f32(tex.height)
	// pull UVs a hair inside each frame so neighbouring tiles in the sheet never bleed into seams
	eu, ev := f32(0.01) / tw, f32(0.01) / th
	s := r.ctx.scale
	col := tm.color
	sgl.load_pipeline(r.ctx.pipeline.alpha)
	sgl.enable_texture()
	sgl.texture(img.simg, img.ssmp)
	sgl.begin_quads()
	for i in sc.cells {
		c, row := i % tm.columns, i / tm.columns
		t0 := tm.get(c, row)
		if t0 < 0 {
			continue
		}
		t := tm.display_tile(t0)
		if t >= frames {
			continue
		}
		fx, fy, fw, fh := tex.frame_rect(t)
		u0, v0 := f32(fx) / tw + eu, f32(fy) / th + ev
		u1, v1 := f32(fx + fw) / tw - eu, f32(fy + fh) / th - ev
		cx, cy := tm.cell_origin(c, row, cs)
		x, y := ox + cx, oy + cy
		a := m.apply(core.vec2(x, y))
		b := m.apply(core.vec2(x + cs.x, y))
		d := m.apply(core.vec2(x + cs.x, y + cs.y))
		e := m.apply(core.vec2(x, y + cs.y))
		sgl.v2f_t2f_c4b(a.x * s, a.y * s, u0, v0, col.r, col.g, col.b, col.a)
		sgl.v2f_t2f_c4b(b.x * s, b.y * s, u1, v0, col.r, col.g, col.b, col.a)
		sgl.v2f_t2f_c4b(d.x * s, d.y * s, u1, v1, col.r, col.g, col.b, col.a)
		sgl.v2f_t2f_c4b(e.x * s, e.y * s, u0, v1, col.r, col.g, col.b, col.a)
	}
	sgl.end()
	sgl.disable_texture()
	r.draw_calls++
}

// draw_texture_frame draws one frame of `t` into the screen rectangle (x, y, w, h) — used by the editor's tile palette.
pub fn (mut r Renderer) draw_texture_frame(t &assets.Texture, frame int, x f32, y f32, w f32, h f32) {
	img := r.image_for(t) or { return }
	fx, fy, fw, fh := t.frame_rect(frame)
	r.ctx.draw_image_with_config(
		img_id:    img.id
		img_rect:  gg.Rect{x, y, w, h}
		part_rect: gg.Rect{fx, fy, fw, fh}
	)
}

// draw_tile_ghost draws one tile of the map's tileset into the map-local rect (x, y, w, h) under `m`,
// tinted by `c`; same path as draw_tilemap, so it works under rotation and matches the real tile exactly.
pub fn (mut r Renderer) draw_tile_ghost(tm &TileMap, m core.Affine2, tile int, x f32, y f32, w f32, h f32, c gg.Color) {
	tex := tm.tex
	if tex == unsafe { nil } || tex.width <= 0 || tex.height <= 0 || tile < 0
		|| tile >= tex.frame_count() {
		return
	}
	img := r.image_for(tex) or { return }
	if !img.simg_ok {
		return
	}
	tw, th := f32(tex.width), f32(tex.height)
	eu, ev := f32(0.01) / tw, f32(0.01) / th
	fx, fy, fw, fh := tex.frame_rect(tile)
	u0, v0 := f32(fx) / tw + eu, f32(fy) / th + ev
	u1, v1 := f32(fx + fw) / tw - eu, f32(fy + fh) / th - ev
	s := r.ctx.scale
	a := m.apply(core.vec2(x, y))
	b := m.apply(core.vec2(x + w, y))
	d := m.apply(core.vec2(x + w, y + h))
	e := m.apply(core.vec2(x, y + h))
	sgl.load_pipeline(r.ctx.pipeline.alpha)
	sgl.enable_texture()
	sgl.texture(img.simg, img.ssmp)
	sgl.begin_quads()
	sgl.v2f_t2f_c4b(a.x * s, a.y * s, u0, v0, c.r, c.g, c.b, c.a)
	sgl.v2f_t2f_c4b(b.x * s, b.y * s, u1, v0, c.r, c.g, c.b, c.a)
	sgl.v2f_t2f_c4b(d.x * s, d.y * s, u1, v1, c.r, c.g, c.b, c.a)
	sgl.v2f_t2f_c4b(e.x * s, e.y * s, u0, v1, c.r, c.g, c.b, c.a)
	sgl.end()
	sgl.disable_texture()
}

// ---------- Assets ----------

fn (mut tm TileMap) acquire() {
	if !tm.tileset.is_set() || tm.node == unsafe { nil } || tm.node.scene == unsafe { nil } {
		return
	}
	mut db := tm.node.scene.assets
	if db == unsafe { nil } || tm.loaded == tm.tileset.id {
		return
	}
	tm.tex = db.get(tm.tileset) or {
		eprintln('[TileMap] ${tm.node.path()}: ${err}')
		return
	}
	tm.loaded = tm.tileset.id
}

fn (mut tm TileMap) drop() {
	if tm.loaded == '' || tm.node == unsafe { nil } || tm.node.scene == unsafe { nil } {
		return
	}
	mut db := tm.node.scene.assets
	if db != unsafe { nil } {
		db.release(tm.loaded)
	}
	tm.loaded = ''
	tm.tex = unsafe { nil }
}
