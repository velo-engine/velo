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
pub struct TileMap {
	core.Component
pub mut:
	tileset   assets.AssetRef[assets.Texture]
	columns   int = 16 // map size in cells; change it with `resize` so existing tiles keep their place
	rows      int = 10
	tile_size core.Vec2 // cell size in world units; 0 = the tileset's frame size
	anchor    core.Vec2 // (0,0) top-left corner of the map at the node, (0.5,0.5) centered
	color     core.Color = core.white
	tiles     []int // columns * rows frame indices, row by row; -1 = empty (missing entries are empty too)
	tex       &assets.Texture = unsafe { nil } @[hide]
	loaded    string          @[hide]
}

pub const no_tile = -1

pub fn (mut tm TileMap) on_load() {
	tm.acquire()
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

// flood_fill replaces the connected area (4 neighbors) of cells equal to the one at (col, row) with `tile`.
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
		stack << [c + 1, r, c - 1, r, c, r + 1, c, r - 1]
	}
	return n
}

// clear empties every cell.
pub fn (mut tm TileMap) clear() {
	tm.tiles = []int{len: tm.columns * tm.rows, init: no_tile}
}

// resize changes the map size, keeping each tile at its (col, row); cells outside the new size are dropped.
pub fn (mut tm TileMap) resize(columns int, rows int) {
	cols := math.max(columns, 1)
	rs := math.max(rows, 1)
	mut out := []int{len: cols * rs, init: no_tile}
	for r in 0 .. math.min(rs, tm.rows) {
		for c in 0 .. math.min(cols, tm.columns) {
			out[r * cols + c] = tm.get(c, r)
		}
	}
	tm.columns = cols
	tm.rows = rs
	tm.tiles = out
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

// local_rect: the rectangle (x, y, w, h) the whole map covers in node space.
pub fn (tm &TileMap) local_rect() (f32, f32, f32, f32) {
	cs := tm.cell_size()
	w := cs.x * f32(math.max(tm.columns, 0))
	h := cs.y * f32(math.max(tm.rows, 0))
	return -tm.anchor.x * w, -tm.anchor.y * h, w, h
}

// local_to_cell: the (col, row) under a node-space point (may be outside the map, see in_bounds).
pub fn (tm &TileMap) local_to_cell(p core.Vec2) (int, int) {
	x, y, _, _ := tm.local_rect()
	cs := tm.cell_size()
	return int(math.floor((p.x - x) / cs.x)), int(math.floor((p.y - y) / cs.y))
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
	return x + f32(col) * cs.x, y + f32(row) * cs.y, cs.x, cs.y
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
	mut lx0, mut ly0 := f32(1e30), f32(1e30)
	mut lx1, mut ly1 := f32(-1e30), f32(-1e30)
	for p in [core.vec2(cl.x, cl.y), core.vec2(cl.x + cl.w, cl.y),
		core.vec2(cl.x + cl.w, cl.y + cl.h), core.vec2(cl.x, cl.y + cl.h)] {
		q := inv.apply(p)
		lx0, ly0 = math.min(lx0, q.x), math.min(ly0, q.y)
		lx1, ly1 = math.max(lx1, q.x), math.max(ly1, q.y)
	}
	c0, r0 := tm.local_to_cell(core.vec2(lx0, ly0))
	c1, r1 := tm.local_to_cell(core.vec2(lx1, ly1))
	col_from, col_to := math.max(c0, 0), math.min(c1, tm.columns - 1)
	row_from, row_to := math.max(r0, 0), math.min(r1, tm.rows - 1)
	if col_from > col_to || row_from > row_to {
		return
	}
	ox, oy, _, _ := tm.local_rect()
	cs := tm.cell_size()
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
	for row in row_from .. row_to + 1 {
		for c in col_from .. col_to + 1 {
			t := tm.get(c, row)
			if t < 0 || t >= frames {
				continue
			}
			fx, fy, fw, fh := tex.frame_rect(t)
			u0, v0 := f32(fx) / tw + eu, f32(fy) / th + ev
			u1, v1 := f32(fx + fw) / tw - eu, f32(fy + fh) / th - ev
			x := ox + f32(c) * cs.x
			y := oy + f32(row) * cs.y
			a := m.apply(core.vec2(x, y))
			b := m.apply(core.vec2(x + cs.x, y))
			d := m.apply(core.vec2(x + cs.x, y + cs.y))
			e := m.apply(core.vec2(x, y + cs.y))
			sgl.v2f_t2f_c4b(a.x * s, a.y * s, u0, v0, col.r, col.g, col.b, col.a)
			sgl.v2f_t2f_c4b(b.x * s, b.y * s, u1, v0, col.r, col.g, col.b, col.a)
			sgl.v2f_t2f_c4b(d.x * s, d.y * s, u1, v1, col.r, col.g, col.b, col.a)
			sgl.v2f_t2f_c4b(e.x * s, e.y * s, u0, v1, col.r, col.g, col.b, col.a)
		}
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
