module editor

import gg
import math
import velo.core
import velo.render

// Transform gizmos for the scene view: Move (W), Rotate (E), Scale (R), Anchor (Y).
//
//   Move:   drag the red/green arrow to move along one axis, the square to move freely.
//   Rotate: drag the ring.
//   Scale:  drag the red/green box to scale one axis, the center box to scale uniformly.
//   Anchor: drag the pivot circle to move the Sprite's anchor, or click one of the 9 dots on the
//           sprite's edges. The sprite and the children stay where they are: the node's position is
//           adjusted so only the pivot (used by rotate/scale) moves. Snaps to the dots when close.
//
// Shift snaps (move: 10px, rotate: 15°, scale: 0.1, anchor: 0.1). Esc while dragging cancels.
// Move axes follow the node's rotation in Local mode, the world axes in Global mode;
// scale axes are always local. Handles keep a constant size on screen whatever the zoom.

enum GizmoTool {
	move
	rotate
	scale
	anchor
}

enum GizmoHandle {
	none
	move_x
	move_y
	move_xy
	rotate
	scale_x
	scale_y
	scale_xy
	anchor        // the pivot circle (Anchor tool)
	anchor_preset // one of the 9 dots on the sprite's edges
}

const gizmo_len = f32(72) // axis length (screen pixels)
const gizmo_ring = f32(62) // rotate ring radius
const gizmo_grab = f32(7) // pick tolerance around a handle
const gizmo_square = f32(22) // move-both-axes square, drawn in the +x/+y quadrant
const gizmo_box = f32(6) // half size of the scale boxes
const gizmo_pivot = f32(8) // radius of the anchor pivot circle
const anchor_presets = [f32(0), 0.5, 1]

const c_axis_x = gg.Color{230, 80, 80, 255}
const c_axis_y = gg.Color{90, 200, 90, 255}
const c_axis_xy = gg.Color{90, 150, 240, 255}
const c_gizmo_hot = gg.Color{255, 220, 90, 255}

fn dot(a core.Vec2, b core.Vec2) f32 {
	return a.x * b.x + a.y * b.y
}

fn snap_to(v f32, step f32) f32 {
	return f32(math.round(v / step)) * step
}

// gizmo_axes: unit x/y axis directions on screen (the view has no rotation, so screen = world directions).
fn (e &Editor) gizmo_axes(n &core.Node) (core.Vec2, core.Vec2) {
	deg := if e.tool == .scale || e.tool_local { n.world_matrix().rotation_deg() } else { f32(0) }
	r := f64(deg) * math.pi / 180.0
	cs := f32(math.cos(r))
	sn := f32(math.sin(r))
	return core.vec2(cs, sn), core.vec2(-sn, cs)
}

fn (e &Editor) gizmo_center(n &core.Node) core.Vec2 {
	return e.view_matrix().apply(n.world_position())
}

// gizmo_target: the node the gizmo is shown for (none while playing or when the root is selected).
fn (e &Editor) gizmo_target() ?&core.Node {
	if e.play != unsafe { nil } || !e.doc.has_selection() || e.doc.selected == e.doc.scene.root {
		return none
	}
	return e.doc.selected
}

// gizmo_hit: the handle of `n`'s gizmo under the screen point `m`.
fn (e &Editor) gizmo_hit(n &core.Node, m core.Vec2) GizmoHandle {
	c := e.gizmo_center(n)
	ax, ay := e.gizmo_axes(n)
	d := m - c
	s := dot(d, ax) // coordinates along the gizmo axes
	t := dot(d, ay)
	on_x := s >= -gizmo_grab && s <= gizmo_len + gizmo_grab && math.abs(t) <= gizmo_grab
	on_y := t >= -gizmo_grab && t <= gizmo_len + gizmo_grab && math.abs(s) <= gizmo_grab
	match e.tool {
		.move {
			if s >= 0 && s <= gizmo_square && t >= 0 && t <= gizmo_square {
				return .move_xy
			}
			if on_x {
				return .move_x
			}
			if on_y {
				return .move_y
			}
		}
		.rotate {
			if math.abs(d.length() - gizmo_ring) <= gizmo_grab {
				return .rotate
			}
		}
		.scale {
			if math.abs(s) <= gizmo_box + 2 && math.abs(t) <= gizmo_box + 2 {
				return .scale_xy
			}
			if on_x {
				return .scale_x
			}
			if on_y {
				return .scale_y
			}
		}
		.anchor {
			sp := n.get_component[render.Sprite]() or { return .none }
			if sp.display_size().x <= 0 || sp.display_size().y <= 0 {
				return .none
			}
			if d.length() <= gizmo_pivot + 3 {
				return .anchor
			}
			if _ := e.anchor_preset_at(n, m) {
				return .anchor_preset
			}
		}
	}

	return .none
}

// ---------- Drawing ----------

fn (e &Editor) draw_gizmo(n &core.Node) {
	hot := if e.drag == .gizmo {
		e.gizmo_handle
	} else if e.drag == .none && e.ui.hover(e.view_rect) {
		e.gizmo_hit(n, e.ui.mouse)
	} else {
		GizmoHandle.none
	}
	c := e.gizmo_center(n)
	ax, ay := e.gizmo_axes(n)
	col := fn [hot] (h GizmoHandle, base gg.Color) gg.Color {
		return if hot == h { c_gizmo_hot } else { base }
	}
	match e.tool {
		.move {
			// both-axes square
			sq := [c, c + ax.mul(gizmo_square), c + ax.mul(gizmo_square) + ay.mul(gizmo_square),
				c + ay.mul(gizmo_square)]
			fill_c := if hot == .move_xy {
				gg.Color{255, 220, 90, 110}
			} else {
				gg.Color{90, 150, 240, 70}
			}
			e.ui.ctx.draw_triangle_filled(sq[0].x, sq[0].y, sq[1].x, sq[1].y, sq[2].x, sq[2].y,
				fill_c)
			e.ui.ctx.draw_triangle_filled(sq[0].x, sq[0].y, sq[2].x, sq[2].y, sq[3].x, sq[3].y,
				fill_c)
			e.draw_polyline(sq, true, col(.move_xy, c_axis_xy), 1)
			e.draw_arrow(c, ax, ay, col(.move_x, c_axis_x))
			e.draw_arrow(c, ay, ax.mul(-1), col(.move_y, c_axis_y))
		}
		.rotate {
			e.draw_polyline(circle_points(c, gizmo_ring, 64), true, col(.rotate, c_axis_xy), if hot == .rotate {
				3
			} else {
				2
			})
			// current orientation of the node's x axis
			e.thick_line(c, c + ax.mul(gizmo_ring), c_axis_x, 2)
			if e.drag == .gizmo && e.drag_active {
				start_dir := core.vec2(f32(math.cos(f64(e.gizmo_start_angle))),
					f32(math.sin(f64(e.gizmo_start_angle))))
				e.ui.ctx.draw_line(c.x, c.y, c.x + start_dir.x * gizmo_ring, c.y +
					start_dir.y * gizmo_ring, gg.Color{255, 255, 255, 90})
			}
		}
		.scale {
			for h in [GizmoHandle.scale_x, .scale_y] {
				dir := if h == .scale_x { ax } else { ay }
				mut len := gizmo_len
				if e.drag == .gizmo && e.drag_active && e.gizmo_handle in [h, .scale_xy] {
					len *= e.gizmo_ratio // stretch the handle while scaling
				}
				hc := col(h, if h == .scale_x { c_axis_x } else { c_axis_y })
				tip := c + dir.mul(len)
				e.thick_line(c, tip, hc, 2)
				e.draw_box(tip, ax, ay, gizmo_box, hc)
			}
			e.draw_box(c, ax, ay, gizmo_box, col(.scale_xy, c_text))
		}
		.anchor {
			e.draw_anchor_gizmo(n, c, hot)
		}
	}

	e.ui.ctx.draw_circle_filled(c.x, c.y, 3, c_override)
	if e.drag == .gizmo && e.drag_active {
		e.draw_gizmo_readout(n)
	}
}

fn (e &Editor) draw_anchor_gizmo(n &core.Node, c core.Vec2, hot GizmoHandle) {
	sp := n.get_component[render.Sprite]() or {
		e.ui.text(c.x + 10, c.y + 6, 'no Sprite: nothing to anchor', c_dim)
		return
	}
	if sp.display_size().x <= 0 || sp.display_size().y <= 0 {
		e.ui.text(c.x + 10, c.y + 6, 'Sprite has no size', c_dim)
		return
	}
	hot_preset := if hot == .anchor_preset {
		e.anchor_preset_at(n, e.ui.mouse) or { core.vec2(-1, -1) }
	} else {
		core.vec2(-1, -1)
	}
	for py in anchor_presets {
		for px in anchor_presets {
			p := e.anchor_point_screen(n, sp, core.vec2(px, py))
			if px == hot_preset.x && py == hot_preset.y {
				e.ui.ctx.draw_circle_filled(p.x, p.y, 5, c_gizmo_hot)
			} else {
				e.ui.ctx.draw_circle_filled(p.x, p.y, 3.5, gg.Color{20, 20, 24, 220})
				e.ui.ctx.draw_circle_empty(p.x, p.y, 3.5, c_axis_xy)
			}
		}
	}
	pc := if hot == .anchor { c_gizmo_hot } else { c_axis_xy }
	e.draw_polyline(circle_points(c, gizmo_pivot, 24), true, pc, 2)
	e.thick_line(c - core.vec2(gizmo_pivot + 5, 0), c + core.vec2(gizmo_pivot + 5, 0), pc, 1)
	e.thick_line(c - core.vec2(0, gizmo_pivot + 5), c + core.vec2(0, gizmo_pivot + 5), pc, 1)
	if hot in [.anchor, .anchor_preset] && e.drag == .none {
		e.ui.text(e.ui.mouse.x + 14, e.ui.mouse.y + 12, e.anchor_label(n), c_text)
	}
}

// draw_gizmo_readout: the edited value next to the cursor while dragging.
fn (e &Editor) draw_gizmo_readout(n &core.Node) {
	label := match e.gizmo_handle {
		.move_x, .move_y, .move_xy { 'position ${fmt_f(n.position.x)}, ${fmt_f(n.position.y)}' }
		.rotate { 'rotation ${fmt_f(n.rotation)}°' }
		.scale_x, .scale_y, .scale_xy { 'scale ${fmt_f(n.scale.x)}, ${fmt_f(n.scale.y)}' }
		.anchor, .anchor_preset { e.anchor_label(n) }
		.none { '' }
	}

	w := e.ui.text_width(label) + 12
	r := Rect{e.ui.mouse.x + 16, e.ui.mouse.y + 14, w, 20}
	e.ui.fill(r, gg.Color{0, 0, 0, 170})
	e.ui.text_in(r, label, c_text, 6)
}

fn (e &Editor) anchor_label(n &core.Node) string {
	sp := n.get_component[render.Sprite]() or { return '' }
	return 'anchor ${fmt_f(sp.anchor.x)}, ${fmt_f(sp.anchor.y)}'
}

// anchor_point_screen: where the anchor value `a` lies on screen (the sprite's rect doesn't depend on
// the anchor once drawn: its corner is at -anchor * size in node space).
fn (e &Editor) anchor_point_screen(n &core.Node, sp &render.Sprite, a core.Vec2) core.Vec2 {
	local := (a - sp.anchor) * sp.display_size()
	return e.view_matrix().mul(n.world_matrix()).apply(local)
}

// anchor_preset_at: the preset anchor (0 / 0.5 / 1 on each axis) whose dot is under the screen point `m`.
fn (e &Editor) anchor_preset_at(n &core.Node, m core.Vec2) ?core.Vec2 {
	sp := n.get_component[render.Sprite]() or { return none }
	for py in anchor_presets {
		for px in anchor_presets {
			a := core.vec2(px, py)
			if e.anchor_point_screen(n, sp, a).distance(m) <= gizmo_grab {
				return a
			}
		}
	}
	return none
}

fn fmt_f(v f32) string {
	s := '${v:.2f}'
	return s.trim_right('0').trim_right('.')
}

fn circle_points(c core.Vec2, radius f32, segments int) []core.Vec2 {
	mut pts := []core.Vec2{cap: segments}
	for i in 0 .. segments {
		a := f64(i) / f64(segments) * 2 * math.pi
		pts << c + core.vec2(f32(math.cos(a)), f32(math.sin(a))).mul(radius)
	}
	return pts
}

fn (e &Editor) thick_line(a core.Vec2, b core.Vec2, c gg.Color, thickness f32) {
	e.ui.ctx.draw_line_with_config(a.x, a.y, b.x, b.y, gg.PenConfig{
		color:     c
		thickness: thickness
	})
}

fn (e &Editor) draw_polyline(pts []core.Vec2, closed bool, c gg.Color, thickness f32) {
	for i in 0 .. pts.len - 1 {
		e.thick_line(pts[i], pts[i + 1], c, thickness)
	}
	if closed && pts.len > 2 {
		e.thick_line(pts.last(), pts[0], c, thickness)
	}
}

// draw_arrow: a shaft from `c` along `dir` with a triangular head (`side` = perpendicular).
fn (e &Editor) draw_arrow(c core.Vec2, dir core.Vec2, side core.Vec2, col gg.Color) {
	base := c + dir.mul(gizmo_len - 12)
	tip := c + dir.mul(gizmo_len + 2)
	e.thick_line(c, base, col, 2)
	l := base + side.mul(6)
	r := base - side.mul(6)
	e.ui.ctx.draw_triangle_filled(tip.x, tip.y, l.x, l.y, r.x, r.y, col)
}

fn (e &Editor) draw_box(p core.Vec2, ax core.Vec2, ay core.Vec2, half f32, col gg.Color) {
	a := p - ax.mul(half) - ay.mul(half)
	b := p + ax.mul(half) - ay.mul(half)
	c := p + ax.mul(half) + ay.mul(half)
	d := p - ax.mul(half) + ay.mul(half)
	e.ui.ctx.draw_triangle_filled(a.x, a.y, b.x, b.y, c.x, c.y, col)
	e.ui.ctx.draw_triangle_filled(a.x, a.y, c.x, c.y, d.x, d.y, col)
}

// ---------- Dragging ----------

// begin_transform_drag remembers the node's transform so the drag can be applied relative to it (or cancelled).
fn (mut e Editor) begin_transform_drag(kind DragKind, n &core.Node, handle GizmoHandle) {
	e.drag = kind
	e.drag_node = n
	e.drag_start = e.ui.mouse
	e.drag_active = false
	e.gizmo_handle = handle
	e.gizmo_start_pos = n.world_position()
	e.gizmo_start_local = n.position
	e.gizmo_start_rot = n.rotation
	e.gizmo_start_scale = n.scale
	e.gizmo_start_world = n.world_matrix()
	e.gizmo_start_anchor = if sp := n.get_component[render.Sprite]() {
		sp.anchor
	} else {
		core.vec2(0.5, 0.5)
	}
	e.gizmo_child_world = n.children.map(it.world_position())
	e.gizmo_child_local = n.children.map(it.position)
	e.gizmo_origin = e.gizmo_center(n)
	e.gizmo_ax, e.gizmo_ay = e.gizmo_axes(n)
	d := e.ui.mouse - e.gizmo_origin
	e.gizmo_start_angle = f32(math.atan2(d.y, d.x))
	e.gizmo_last_angle = e.gizmo_start_angle
	e.gizmo_turn = 0
	e.gizmo_ratio = 1
}

// apply_gizmo sets the dragged node's transform from the current mouse position.
fn (mut e Editor) apply_gizmo() {
	mut n := e.drag_node
	m := e.ui.mouse
	snap := e.ui.shift()
	match e.gizmo_handle {
		.move_x, .move_y, .move_xy {
			d := (m - e.drag_start).mul(1 / e.zoom) // world delta (the view only scales)
			mut p := e.gizmo_start_pos
			if e.gizmo_handle == .move_xy {
				p = p + d
				if snap {
					p = core.vec2(snap_to(p.x, 10), snap_to(p.y, 10))
				}
			} else {
				axis := if e.gizmo_handle == .move_x { e.gizmo_ax } else { e.gizmo_ay }
				mut k := dot(d, axis)
				if snap {
					k = snap_to(k, 10)
				}
				p = p + axis.mul(k)
			}
			n.set_world_position(p)
		}
		.rotate {
			d := m - e.gizmo_origin
			if d.length() < 2 {
				return
			}
			a := f32(math.atan2(d.y, d.x))
			// accumulate the angle so crossing ±180° doesn't make the value jump by 360°
			mut step := a - e.gizmo_last_angle
			if step > math.pi {
				step -= 2 * math.pi
			} else if step < -math.pi {
				step += 2 * math.pi
			}
			e.gizmo_turn += step
			e.gizmo_last_angle = a
			mut deg := e.gizmo_start_rot + e.gizmo_turn * 180 / math.pi
			if snap {
				deg = snap_to(deg, 15)
			}
			n.rotation = deg
		}
		.scale_x, .scale_y {
			axis := if e.gizmo_handle == .scale_x { e.gizmo_ax } else { e.gizmo_ay }
			v0 := dot(e.drag_start - e.gizmo_origin, axis)
			v1 := dot(m - e.gizmo_origin, axis)
			e.gizmo_ratio = if math.abs(v0) < 1 { 1 } else { v1 / v0 }
			mut s := e.gizmo_start_scale
			if e.gizmo_handle == .scale_x {
				s = core.vec2(scale_value(s.x * e.gizmo_ratio, snap), s.y)
			} else {
				s = core.vec2(s.x, scale_value(s.y * e.gizmo_ratio, snap))
			}
			n.scale = s
		}
		.scale_xy {
			d := m - e.drag_start
			e.gizmo_ratio = f32(math.max(0.01, 1 + (d.x - d.y) / 100))
			s := e.gizmo_start_scale
			n.scale = core.vec2(scale_value(s.x * e.gizmo_ratio, snap),
				scale_value(s.y * e.gizmo_ratio, snap))
		}
		.anchor {
			mut sp := n.get_component[render.Sprite]() or { return }
			sz := sp.display_size()
			if sz.x <= 0 || sz.y <= 0 {
				return
			}
			// the mouse in the node's space as it was when the drag started (origin = old pivot)
			q := e.gizmo_start_world.inverse().apply(e.screen_to_world(m))
			mut a := core.vec2(e.gizmo_start_anchor.x + q.x / sz.x, e.gizmo_start_anchor.y +
				q.y / sz.y)
			if snap {
				a = core.vec2(snap_to(a.x, 0.1), snap_to(a.y, 0.1))
			} else {
				// magnet: stick to the corner/edge/center dots when close to them
				to_screen := e.view_matrix().mul(e.gizmo_start_world)
				for py in anchor_presets {
					for px in anchor_presets {
						p := core.vec2(px, py)
						if to_screen.apply((p - e.gizmo_start_anchor) * sz).distance(m) <= gizmo_grab {
							a = p
						}
					}
				}
			}
			e.set_anchor_keep_visual(mut n, mut sp, a)
		}
		.anchor_preset, .none {}
	}
}

// set_anchor_keep_visual changes the Sprite's anchor and moves the node so the sprite and the children
// stay in place: only the pivot moves. Relative to the state saved by begin_transform_drag.
fn (mut e Editor) set_anchor_keep_visual(mut n core.Node, mut sp render.Sprite, a core.Vec2) {
	n.set_world_position(e.gizmo_start_world.apply((a - e.gizmo_start_anchor) * sp.display_size()))
	sp.anchor = a
	for i, mut ch in n.children {
		if i < e.gizmo_child_world.len {
			ch.set_world_position(e.gizmo_child_world[i])
		}
	}
}

// click_anchor_preset: clicking one of the 9 dots moves the anchor there (one undo step).
fn (mut e Editor) click_anchor_preset(mut n core.Node) {
	a := e.anchor_preset_at(n, e.ui.mouse) or { return }
	mut sp := n.get_component[render.Sprite]() or { return }
	e.begin_transform_drag(.none, n, .none)
	e.drag_node = unsafe { nil }
	e.doc.checkpoint() or {
		e.report(err)
		return
	}
	e.set_anchor_keep_visual(mut n, mut sp, a)
	e.set_status(e.anchor_label(n), false)
}

// scale_value snaps to 0.1 steps (Shift) and keeps the scale away from 0 (a zero scale can't be inverted).
fn scale_value(v f32, snap bool) f32 {
	mut s := if snap { snap_to(v, 0.1) } else { v }
	if math.abs(s) < 0.01 {
		s = if v < 0 { f32(-0.01) } else { f32(0.01) }
	}
	return s
}

// cancel_transform_drag restores the transform from before the drag (Esc).
fn (mut e Editor) cancel_transform_drag() bool {
	if e.drag !in [.gizmo, .move_node] {
		return false
	}
	if e.drag_active && e.doc.contains(e.drag_node) {
		mut n := e.drag_node
		n.position = e.gizmo_start_local
		n.rotation = e.gizmo_start_rot
		n.scale = e.gizmo_start_scale
		if e.gizmo_handle == .anchor {
			if mut sp := n.get_component[render.Sprite]() {
				sp.anchor = e.gizmo_start_anchor
			}
			for i, mut ch in n.children {
				if i < e.gizmo_child_local.len {
					ch.position = e.gizmo_child_local[i]
				}
			}
		}
		e.set_status('cancelled', false)
	}
	e.drag = .none
	e.drag_node = unsafe { nil }
	e.drag_active = false
	return true
}

fn (mut e Editor) set_tool(t GizmoTool) {
	e.tool = t
	e.set_status('${t} tool', false)
}
