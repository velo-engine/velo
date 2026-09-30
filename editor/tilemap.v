module editor

import gg
import math
import velo.core
import velo.render

// Tile painting: while a node with a TileMap is selected, the tile tools edit its cells in the scene view.
// B paint (the brush picked in the Inspector's palette), X erase, G flood fill, I pick a tile from the map.
// Each drag is one undo step; clicking outside the map still selects nodes as usual.
enum TileTool {
	none
	paint
	erase
	fill
	pick
}

const palette_cell = f32(34)

// tile_map: the selected node's TileMap while a tile tool is active (editing only).
fn (e &Editor) tile_map() ?&render.TileMap {
	if e.tile_tool == .none || e.play != unsafe { nil } || !e.doc.has_selection() {
		return none
	}
	return e.doc.selected.get_component[render.TileMap]()
}

fn (mut e Editor) set_tile_tool(t TileTool) {
	if t != .none && e.selected_tile_map() == none {
		e.set_status('select a node with a TileMap to paint tiles', true)
		return
	}
	e.tile_tool = t
	e.set_status(match t {
		.paint { 'paint tiles: drag in the scene view (Esc: back to Move)' }
		.erase { 'erase tiles: drag in the scene view (Esc: back to Move)' }
		.fill { 'fill: click an area of the map (Esc: back to Move)' }
		.pick { 'pick: click a tile of the map to paint with it' }
		.none { 'tile tools off' }
	}, false)
}

fn (e &Editor) selected_tile_map() ?&render.TileMap {
	if e.play != unsafe { nil } || !e.doc.has_selection() {
		return none
	}
	return e.doc.selected.get_component[render.TileMap]()
}

// mouse_cell: the map cell under the mouse (may be outside the map).
fn (e &Editor) mouse_cell(tm &render.TileMap) (int, int) {
	return tm.world_to_cell(e.screen_to_world(e.ui.mouse))
}

// begin_tile_stroke starts a paint drag if the click is on the map; false = let the scene view pick nodes.
fn (mut e Editor) begin_tile_stroke() bool {
	mut tm := e.tile_map() or { return false }
	c, r := e.mouse_cell(tm)
	if !tm.in_bounds(c, r) {
		return false
	}
	e.drag = .paint
	e.drag_node = e.doc.selected
	e.drag_start = e.ui.mouse
	e.drag_active = false // becomes true once the stroke changed a cell (and recorded the undo step)
	e.tile_last = [c, r]
	e.apply_tile_tool(mut tm, c, r)
	return true
}

// continue_tile_stroke paints every cell on the line from the previous cell, so fast drags leave no gaps.
fn (mut e Editor) continue_tile_stroke() {
	if e.tile_tool !in [.paint, .erase] {
		return
	}
	mut tm := e.tile_map() or { return }
	c, r := e.mouse_cell(tm)
	if e.tile_last.len == 2 && c == e.tile_last[0] && r == e.tile_last[1] {
		return
	}
	for p in cell_line(e.tile_last[0], e.tile_last[1], c, r) {
		e.apply_tile_tool(mut tm, p[0], p[1])
	}
	e.tile_last = [c, r]
}

fn (mut e Editor) apply_tile_tool(mut tm render.TileMap, c int, r int) {
	if !tm.in_bounds(c, r) {
		return
	}
	match e.tile_tool {
		.paint, .erase {
			tile := if e.tile_tool == .erase { render.no_tile } else { e.tile_brush }
			if tm.get(c, r) != tile {
				e.tile_checkpoint()
				tm.set(c, r, tile)
			}
		}
		.fill {
			if tm.get(c, r) != e.tile_brush {
				e.tile_checkpoint()
				n := tm.flood_fill(c, r, e.tile_brush)
				e.set_status('filled ${n} cells', false)
			}
		}
		.pick {
			t := tm.get(c, r)
			if t >= 0 {
				e.tile_brush = t
				e.set_tile_tool(.paint)
			} else {
				e.set_tile_tool(.erase)
			}
		}
		.none {}
	}
}

// tile_checkpoint records the undo step right before the stroke's first change.
fn (mut e Editor) tile_checkpoint() {
	if !e.drag_active {
		e.doc.checkpoint() or {}
		e.drag_active = true
	}
}

// cell_line: the cells from (c0, r0) (excluded) to (c1, r1) (included), Bresenham.
fn cell_line(c0 int, r0 int, c1 int, r1 int) [][]int {
	mut out := [][]int{}
	dc := math.abs(c1 - c0)
	dr := -math.abs(r1 - r0)
	sc := if c0 < c1 { 1 } else { -1 }
	sr := if r0 < r1 { 1 } else { -1 }
	mut err := dc + dr
	mut c, mut r := c0, r0
	for c != c1 || r != r1 {
		e2 := 2 * err
		if e2 >= dr {
			err += dr
			c += sc
		}
		if e2 <= dc {
			err += dc
			r += sr
		}
		out << [c, r]
	}
	return out
}

// draw_tile_overlay draws the map's grid and the cell under the mouse (with the brush previewed in it).
fn (mut e Editor) draw_tile_overlay(view core.Affine2) {
	tm := e.tile_map() or { return }
	m := view.mul(tm.node.world_matrix())
	x, y, w, h := tm.local_rect()
	cs := tm.cell_size()
	cell_px := math.min(cs.x * m.scale().x, cs.y * m.scale().y)
	if cell_px >= 6 {
		col := gg.Color{255, 255, 255, 40}
		for c in 1 .. tm.columns {
			a := m.apply(core.vec2(x + f32(c) * cs.x, y))
			b := m.apply(core.vec2(x + f32(c) * cs.x, y + h))
			e.ui.ctx.draw_line(a.x, a.y, b.x, b.y, col)
		}
		for r in 1 .. tm.rows {
			a := m.apply(core.vec2(x, y + f32(r) * cs.y))
			b := m.apply(core.vec2(x + w, y + f32(r) * cs.y))
			e.ui.ctx.draw_line(a.x, a.y, b.x, b.y, col)
		}
	}
	e.draw_quad(m, x, y, w, h, gg.Color{120, 200, 255, 200})
	if !e.ui.hover(e.view_rect) || e.drag == .pan {
		return
	}
	c, r := e.mouse_cell(tm)
	if !tm.in_bounds(c, r) {
		return
	}
	cx, cy, cw, ch := tm.cell_local_rect(c, r)
	if e.tile_tool == .paint && tm.tex != unsafe { nil } && m.b == 0 && m.c == 0 {
		p := m.apply(core.vec2(cx, cy))
		q := m.apply(core.vec2(cx + cw, cy + ch))
		e.renderer.draw_texture_frame(tm.tex, e.tile_brush, math.min(p.x, q.x), math.min(p.y, q.y),
			math.abs(q.x - p.x), math.abs(q.y - p.y))
	}
	color := match e.tile_tool {
		.erase { c_error }
		.pick { c_ok }
		else { c_override }
	}

	e.draw_quad(m, cx, cy, cw, ch, color)
}

// draw_tile_palette: tool buttons + the tileset's tiles, below the TileMap's fields in the Inspector.
fn (mut e Editor) draw_tile_palette(x f32, y0 f32, w f32, n &core.Node, ro bool) f32 {
	mut y := y0
	mut tm := n.get_component[render.TileMap]() or { return y }
	if !ro {
		bw := (w - 9) / 4
		for i, t in [TileTool.paint, .erase, .fill, .pick] {
			label := match t {
				.paint { 'Paint B' }
				.erase { 'Erase X' }
				.fill { 'Fill G' }
				else { 'Pick I' }
			}

			active := e.tile_tool == t && voidptr(e.doc.selected) == voidptr(n)
			if e.ui.toggle_button(Rect{x + f32(i) * (bw + 3), y, bw, row_h}, label, active,
				c_select)
			{
				e.set_tile_tool(if active { TileTool.none } else { t })
			}
		}
		y += row_h + 4
	}
	tex := tm.tex
	if tex == unsafe { nil } {
		e.ui.text_in(Rect{x, y, w, row_h}, 'Assign a tileset (a sprite sheet image)', c_dim, 0)
		return y + row_h + 3
	}
	frames := tex.frame_count()
	if frames <= 1 {
		e.ui.text_in(Rect{x, y, w, row_h}, 'Tip: set frame_width/frame_height in its .meta', c_dim,
			0)
		y += row_h
	}
	painted := tm.count()
	e.ui.text_in(Rect{x, y, w, row_h},
		'brush ${e.tile_brush}  ·  ${frames} tiles  ·  ${painted}/${tm.columns * tm.rows} cells painted',
		c_dim, 0)
	if !ro && e.ui.button(Rect{x + w - 50, y, 50, row_h}, 'Clear', painted > 0) {
		e.doc.checkpoint() or {}
		tm.clear()
	}
	y += row_h + 4
	// the sheet's own column count when it fits, so the palette looks like the tileset image
	fw, fh := f32(tex.frame_w()), f32(tex.frame_h())
	sheet_cols := math.max(tex.width / math.max(tex.frame_w(), 1), 1)
	fit := math.max(int(w / (palette_cell + 2)), 1)
	cols := if sheet_cols <= fit { sheet_cols } else { fit }
	scale := palette_cell / math.max(fw, fh)
	dw, dh := fw * scale, fh * scale
	for i in 0 .. frames {
		cr :=
			Rect{x + f32(i % cols) * (palette_cell + 2), y + f32(i / cols) * (palette_cell + 2), palette_cell, palette_cell}
		if cr.y + cr.h < e.ui.clip.y || cr.y > e.ui.clip.y + e.ui.clip.h {
			continue
		}
		e.ui.fill(cr, c_field)
		e.renderer.draw_texture_frame(tex, i, cr.x + (palette_cell - dw) / 2, cr.y +
			(palette_cell - dh) / 2, dw, dh)
		if i == e.tile_brush {
			e.ui.outline(cr, c_override)
			e.ui.outline(cr.shrink(1), c_override)
		} else if e.ui.hover(cr) {
			e.ui.outline(cr, c_accent)
		}
		if !ro && e.ui.click(cr) {
			e.tile_brush = i
			if e.tile_tool in [.none, .erase, .pick] || voidptr(e.doc.selected) != voidptr(n) {
				e.set_tile_tool(.paint)
			}
		}
	}
	rows := (frames + cols - 1) / cols
	return y + f32(rows) * (palette_cell + 2) + 3
}
