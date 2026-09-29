module editor

import gg
import math
import velo.core
import velo.render

// Sliced / tiled Sprite editing: the Inspector shows the frame with its four 9-slice border lines
// (drag a line to change `border_*`, one undo step per drag), and the scene view draws the same lines
// on the selected sprite as guides. Resize the sprite with the Size tool (U).

const slice_preview_h = f32(150)
const slice_grab = f32(5) // screen pixels around a border line that still grab it
const c_slice = gg.Color{120, 230, 140, 230}
const c_slice_dim = gg.Color{120, 230, 140, 110}

// slice_border: the value of border `edge` (0 left, 1 top, 2 right, 3 bottom).
fn slice_border(sp &render.Sprite, edge int) int {
	return match edge {
		0 { sp.border_left }
		1 { sp.border_top }
		2 { sp.border_right }
		else { sp.border_bottom }
	}
}

fn set_slice_border(mut sp render.Sprite, edge int, v int) {
	match edge {
		0 { sp.border_left = v }
		1 { sp.border_top = v }
		2 { sp.border_right = v }
		else { sp.border_bottom = v }
	}
}

// slice_line_pos: the screen coordinate (x for left/right, y for top/bottom) of a border line in the preview.
fn (e &Editor) slice_line_pos(sp &render.Sprite, edge int) f32 {
	fw, fh := f32(sp.tex.frame_w()), f32(sp.tex.frame_h())
	b := f32(slice_border(sp, edge))
	return match edge {
		0 { e.slice_origin.x + b * e.slice_k }
		1 { e.slice_origin.y + b * e.slice_k }
		2 { e.slice_origin.x + (fw - b) * e.slice_k }
		else { e.slice_origin.y + (fh - b) * e.slice_k }
	}
}

// slice_edge_at: the border line of the preview under the mouse (-1 = none); vertical lines win ties.
fn (e &Editor) slice_edge_at(sp &render.Sprite, img Rect) int {
	m := e.ui.mouse
	if !e.ui.hover(Rect{img.x - slice_grab, img.y - slice_grab, img.w + 2 * slice_grab, img.h +
		2 * slice_grab}) {
		return -1
	}
	mut best := -1
	mut best_d := slice_grab
	for edge in 0 .. 4 {
		d := math.abs(e.slice_line_pos(sp, edge) - if edge % 2 == 0 { m.x } else { m.y })
		if d <= best_d {
			best, best_d = edge, d
		}
	}
	return best
}

// draw_slice_editor: the frame preview with draggable border lines, below the Sprite's fields.
fn (mut e Editor) draw_slice_editor(x f32, y0 f32, w f32, n &core.Node, ro bool) f32 {
	mut y := y0
	sp := n.get_component[render.Sprite]() or { return y }
	if !sp.is_sliced_mode() {
		return y
	}
	if sp.tex == unsafe { nil } {
		e.ui.text_in(Rect{x, y, w, row_h}, 'Assign a texture to edit its 9-slice borders', c_dim, 0)
		return y + row_h + 3
	}
	l, t, r, b := sp.borders()
	e.ui.text_in(Rect{x, y, w, row_h}, 'borders ${l}, ${t}, ${r}, ${b} px · drag the green lines',
		c_dim, 0)
	y += row_h
	fw, fh := f32(sp.tex.frame_w()), f32(sp.tex.frame_h())
	box := Rect{x, y, w, slice_preview_h}
	e.ui.fill(box, c_field)
	e.ui.outline(box, c_border)
	k := math.min((box.w - 16) / fw, (box.h - 16) / fh)
	img := Rect{box.x + (box.w - fw * k) / 2, box.y + (box.h - fh * k) / 2, fw * k, fh * k}
	e.renderer.draw_texture_frame(sp.tex, sp.frame, img.x, img.y, img.w, img.h)
	e.ui.outline(img, gg.Color{255, 255, 255, 40})
	// the drag handler (finish_drag) maps the mouse back through these
	if e.drag != .slice || e.drag_node == n {
		e.slice_origin = core.vec2(img.x, img.y)
		e.slice_k = k
	}
	hot := if e.drag == .slice && e.drag_node == n {
		e.slice_edge
	} else if !ro && e.drag == .none {
		e.slice_edge_at(sp, img)
	} else {
		-1
	}
	for edge in 0 .. 4 {
		p := e.slice_line_pos(sp, edge)
		col := if edge == hot { c_gizmo_hot } else { c_slice }
		th := if edge == hot { f32(2) } else { f32(1) }
		if edge % 2 == 0 {
			e.thick_line(core.vec2(p, box.y + 2), core.vec2(p, box.y + box.h - 2), col, th)
		} else {
			e.thick_line(core.vec2(box.x + 2, p), core.vec2(box.x + box.w - 2, p), col, th)
		}
	}
	if !ro && hot >= 0 && e.drag == .none && e.ui.click(box) {
		e.drag = .slice
		e.drag_node = n
		e.drag_start = e.ui.mouse
		e.drag_active = false // becomes true (and records the undo step) on the first change
		e.slice_edge = hot
	}
	return box.y + box.h + 3
}

// drag_slice_border sets the dragged border from the mouse (called every frame while dragging).
fn (mut e Editor) drag_slice_border() {
	mut n := e.drag_node
	mut sp := n.get_component[render.Sprite]() or { return }
	if sp.tex == unsafe { nil } || e.slice_k <= 0 {
		return
	}
	fw, fh := sp.tex.frame_w(), sp.tex.frame_h()
	edge := e.slice_edge
	m := e.ui.mouse
	px := int(math.round((if edge % 2 == 0 { m.x - e.slice_origin.x } else { m.y - e.slice_origin.y }) / e.slice_k))
	// each border stops at the opposite one, so they never cross
	v := match edge {
		0 { clampi(px, 0, fw - sp.border_right) }
		1 { clampi(px, 0, fh - sp.border_bottom) }
		2 { clampi(fw - px, 0, fw - sp.border_left) }
		else { clampi(fh - px, 0, fh - sp.border_top) }
	}

	if v == slice_border(sp, edge) {
		return
	}
	if !e.drag_active {
		e.doc.checkpoint() or {}
		e.drag_active = true
	}
	set_slice_border(mut sp, edge, v)
	e.set_status(['border_left', 'border_top', 'border_right', 'border_bottom'][edge] + ' = ${v}',
		false)
}

// draw_slice_guides: the selected sliced/tiled sprite's border lines in the scene view.
fn (e &Editor) draw_slice_guides(n &core.Node, view core.Affine2) {
	sp := n.get_component[render.Sprite]() or { return }
	if !sp.enabled || !sp.is_sliced_mode() || sp.tex == unsafe { nil } {
		return
	}
	l, t, r, b := sp.borders()
	if l + t + r + b == 0 {
		return
	}
	m := view.mul(n.world_matrix())
	x, y, w, h := sp.local_rect()
	gl, gt, gr, gb := sp.slice_lines()
	mut lines := [][]f32{}
	if l > 0 {
		lines << [gl, y, gl, y + h]
	}
	if r > 0 {
		lines << [gr, y, gr, y + h]
	}
	if t > 0 {
		lines << [x, gt, x + w, gt]
	}
	if b > 0 {
		lines << [x, gb, x + w, gb]
	}
	for ln in lines {
		// flips mirror the pieces, so mirror the guides the same way
		p := m.apply(flip_point(sp, x, y, w, h, core.vec2(ln[0], ln[1])))
		q := m.apply(flip_point(sp, x, y, w, h, core.vec2(ln[2], ln[3])))
		e.ui.ctx.draw_line(p.x, p.y, q.x, q.y, c_slice_dim)
	}
}

fn flip_point(sp &render.Sprite, x f32, y f32, w f32, h f32, p core.Vec2) core.Vec2 {
	return core.vec2(if sp.flip_x { 2 * x + w - p.x } else { p.x }, if sp.flip_y {
		2 * y + h - p.y
	} else {
		p.y
	})
}

fn clampi(v int, lo int, hi int) int {
	return if v < lo {
		lo
	} else if v > hi {
		hi
	} else {
		v
	}
}
