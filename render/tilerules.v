module render

import velo.core

// TileRules — the text asset (`forest.tilerules`) behind a TileMap's `rules`: auto-tiling terrains and animated
// tiles. (Format and use: see the README, "Tile maps".)
//
//   # comment
//   animate 5 frames=5,6,7,6 fps=6          # the tile 5 plays this frame sequence
//   terrain 1 edges 12 13 14 15 8 9 10 11 4 5 6 7 0 1 2 3          # 16 frames, indexed by the neighbor mask
//   terrain 2 blob  0 1 2 ... (47 frames) join=1 border=empty
//
// `edges` looks at the 4 neighbors: mask = N(1) + E(2) + S(4) + W(8) of the neighbors that belong to the same
// terrain (or one it `join`s). `blob` also looks at the 4 corners (a corner counts only when both of its edges do)
// and has 47 frames, ordered by their canonical mask (see blob_masks). `border=same` (default) treats cells outside
// the map as terrain too, so ground runs off the edge; `border=empty` makes the map edge an edge.

pub struct TileAnim {
pub:
	frames []int
	fps    f32
}

pub struct TerrainRule {
pub:
	id          int
	blob        bool
	frames      []int
	join        []int // other terrain ids that connect to this one
	border_same bool = true
}

pub struct TileRules {
pub mut:
	terrains map[int]TerrainRule
	anims    map[int]TileAnim
}

// neighbor bits, clockwise from north
const bit_n = 1
const bit_ne = 2
const bit_e = 4
const bit_se = 8
const bit_s = 16
const bit_sw = 32
const bit_w = 64
const bit_nw = 128

// canonical_blob drops the corner bits that do not matter: a corner only counts when both of its edges are set.
pub fn canonical_blob(mask int) int {
	mut m := mask
	if m & bit_n == 0 || m & bit_e == 0 {
		m &= ~bit_ne
	}
	if m & bit_e == 0 || m & bit_s == 0 {
		m &= ~bit_se
	}
	if m & bit_s == 0 || m & bit_w == 0 {
		m &= ~bit_sw
	}
	if m & bit_w == 0 || m & bit_n == 0 {
		m &= ~bit_nw
	}
	return m
}

// blob_masks: the 47 distinct canonical masks, ascending. A `blob` terrain lists its frames in this order.
pub fn blob_masks() []int {
	mut seen := map[int]bool{}
	for m in 0 .. 256 {
		seen[canonical_blob(m)] = true
	}
	mut out := seen.keys()
	out.sort()
	return out
}

// edge_mask from the four neighbors' "same terrain" flags.
pub fn edge_mask(n bool, e bool, s bool, w bool) int {
	return (if n {
		1
	} else {
		0
	}) | (if e {
		2
	} else {
		0
	}) | (if s {
		4
	} else {
		0
	}) | (if w {
		8
	} else {
		0
	})
}

// frame_for returns the frame to draw for a neighbor mask: for `edges` the mask is N|E|S|W as 1|2|4|8, for `blob`
// the 8-bit mask (N=1 NE=2 E=4 SE=8 S=16 SW=32 W=64 NW=128).
pub fn (t &TerrainRule) frame_for(mask int) int {
	if t.blob {
		masks := blob_masks()
		c := canonical_blob(mask)
		for i, m in masks {
			if m == c {
				return t.frames[i]
			}
		}
		return t.frames[0]
	}
	return t.frames[mask & 15]
}

pub fn (r &TileRules) joins(a TerrainRule, other int) bool {
	return other == a.id || other in a.join
}

// anim_frame: the frame an animated tile shows at `time` seconds (the tile itself when it has no animation).
pub fn (r &TileRules) anim_frame(tile int, time f32) int {
	a := r.anims[tile] or { return tile }
	if a.frames.len == 0 || a.fps <= 0 {
		return tile
	}
	return a.frames[int(time * a.fps) % a.frames.len]
}

pub fn (r &TileRules) has_anims() bool {
	return r.anims.len > 0
}

// TileRules.parse reads the text format; errors name the line.
pub fn TileRules.parse(text string) !&TileRules {
	mut r := &TileRules{}
	for i, raw in text.split_into_lines() {
		line := raw.all_before('#').trim_space()
		if line == '' {
			continue
		}
		r.parse_line(line) or { return error('line ${i + 1}: ${err}') }
	}
	return r
}

fn parse_ints(s string) ![]int {
	mut out := []int{}
	for p in s.split(',') {
		if p.trim_space() == '' {
			continue
		}
		if !p.trim_space().bytes().all(it.is_digit()) {
			return error('"${p}" is not a frame number')
		}
		out << p.trim_space().int()
	}
	return out
}

fn (mut r TileRules) parse_line(line string) ! {
	w := line.fields()
	match w[0] {
		'animate' {
			if w.len < 3 {
				return error('animate <tile> frames=a,b,c fps=N')
			}
			tile := w[1].int()
			mut frames := []int{}
			mut fps := f32(8)
			for opt in w[2..] {
				if opt.starts_with('frames=') {
					frames = parse_ints(opt['frames='.len..])!
				} else if opt.starts_with('fps=') {
					fps = opt['fps='.len..].f32()
				} else {
					return error('unknown option "${opt}"')
				}
			}
			if frames.len == 0 || fps <= 0 {
				return error('animate needs frames= and a fps above 0')
			}
			r.anims[tile] = TileAnim{frames, fps}
		}
		'terrain' {
			if w.len < 4 || w[2] !in ['edges', 'blob'] {
				return error('terrain <id> edges|blob <frames...>')
			}
			id := w[1].int()
			if id <= 0 {
				return error('terrain ids start at 1')
			}
			blob := w[2] == 'blob'
			mut frames := []int{}
			mut join := []int{}
			mut border_same := true
			for tok in w[3..] {
				if tok.starts_with('join=') {
					join = parse_ints(tok['join='.len..])!
				} else if tok.starts_with('border=') {
					b := tok['border='.len..]
					if b !in ['same', 'empty'] {
						return error('border must be same or empty')
					}
					border_same = b == 'same'
				} else {
					frames << parse_ints(tok)!
				}
			}
			want := if blob { 47 } else { 16 }
			if frames.len != want {
				return error('terrain ${id} ${w[2]} needs ${want} frames, got ${frames.len}')
			}
			if id in r.terrains {
				return error('terrain ${id} defined twice')
			}
			r.terrains[id] = TerrainRule{
				id:          id
				blob:        blob
				frames:      frames
				join:        join
				border_same: border_same
			}
		}
		else {
			return error('cannot read "${line}"')
		}
	}
}

// ---------- Solid boxes ----------

// TileBox — a rectangle of cells (col, row, cols x rows) merged from neighboring solid tiles.
pub struct TileBox {
pub:
	col  int
	row  int
	cols int
	rows int
}

// solid_boxes merges the cells whose tile is solid into as few rectangles as it can (for colliders): runs along
// each row first, then runs with the same extent in the rows below. `solid` lists the solid tile frames; empty
// means every non-empty tile. Orthogonal maps only (others give none).
pub fn (tm &TileMap) solid_boxes(solid []int) []TileBox {
	if tm.tile_layout() != .orthogonal {
		return []
	}
	is_solid := fn [tm, solid] (c int, r int) bool {
		t := tm.get(c, r)
		return t >= 0 && (solid.len == 0 || t in solid)
	}
	mut used := []bool{len: tm.columns * tm.rows}
	mut out := []TileBox{}
	for r in 0 .. tm.rows {
		for c in 0 .. tm.columns {
			if used[r * tm.columns + c] || !is_solid(c, r) {
				continue
			}
			mut w := 1
			for c + w < tm.columns && !used[r * tm.columns + c + w] && is_solid(c + w, r) {
				w++
			}
			mut h := 1
			for r + h < tm.rows {
				mut full := true
				for k in 0 .. w {
					if used[(r + h) * tm.columns + c + k] || !is_solid(c + k, r + h) {
						full = false
						break
					}
				}
				if !full {
					break
				}
				h++
			}
			for dr in 0 .. h {
				for dc in 0 .. w {
					used[(r + dr) * tm.columns + c + dc] = true
				}
			}
			out << TileBox{c, r, w, h}
		}
	}
	return out
}

// box_rect: the box as a rectangle in the map node's space (x, y, w, h).
pub fn (tm &TileMap) box_rect(b TileBox) (f32, f32, f32, f32) {
	x, y, cw, ch := tm.cell_local_rect(b.col, b.row)
	return x, y, cw * f32(b.cols), ch * f32(b.rows)
}

// solid_rects: the merged solid boxes as rectangles in the map node's space (core.SolidTiles).
pub fn (tm &TileMap) solid_rects(solid []int) []core.SolidRect {
	mut out := []core.SolidRect{}
	for b in tm.solid_boxes(solid) {
		x, y, w, h := tm.box_rect(b)
		out << core.SolidRect{core.vec2(x, y), core.vec2(w, h)}
	}
	return out
}

// solid_revision: changes whenever a cell does (core.SolidTiles).
pub fn (tm &TileMap) solid_revision() int {
	return tm.revision
}

// solid_bounds: the whole map in the node's space (core.SolidTiles).
pub fn (tm &TileMap) solid_bounds() core.SolidRect {
	x, y, w, h := tm.local_rect()
	return core.SolidRect{core.vec2(x, y), core.vec2(w, h)}
}

// solid_cell: one cell's size (core.SolidTiles).
pub fn (tm &TileMap) solid_cell() core.Vec2 {
	return tm.cell_size()
}
