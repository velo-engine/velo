module editor

import gg
import math
import engine.core
import engine.assets
import engine.serialize
import engine.render

// ---------- Scene view ----------

// view_matrix: world -> screen. `cam` is the world point at the center of the view.
fn (e &Editor) view_matrix() core.Affine2 {
	center := core.vec2(e.view_rect.x + e.view_rect.w / 2, e.view_rect.y + e.view_rect.h / 2)
	return core.Affine2.trs(center - e.cam.mul(e.zoom), 0, core.vec2(e.zoom, e.zoom))
}

fn (e &Editor) screen_to_world(p core.Vec2) core.Vec2 {
	return e.view_matrix().inverse().apply(p)
}

// frame_all: fits the game screen into the view.
fn (mut e Editor) frame_all() {
	e.cam = core.vec2(f32(e.cfg.game_width) / 2, f32(e.cfg.game_height) / 2)
	vw := if e.view_rect.w > 0 { e.view_rect.w } else { f32(e.cfg.width - 610) }
	vh := if e.view_rect.h > 0 { e.view_rect.h } else { f32(e.cfg.height - 60) }
	zx := (vw - 40) / f32(e.cfg.game_width)
	zy := (vh - 40) / f32(e.cfg.game_height)
	e.zoom = if zx < zy { zx } else { zy }
	if e.zoom <= 0.05 {
		e.zoom = 1
	}
}

fn (mut e Editor) frame_selected() {
	if !e.doc.has_selection() || e.doc.selected == e.doc.scene.root {
		e.frame_all()
		return
	}
	e.cam = e.doc.selected.world_position()
}

fn (e &Editor) current_root() &core.Node {
	return if e.play != unsafe { nil } { e.play.root } else { e.doc.scene.root }
}

fn (mut e Editor) draw_scene_view(r Rect) {
	e.ui.fill(r, gg.Color{28, 28, 32, 255})
	e.ui.set_clip(r)
	view := e.view_matrix()
	e.draw_grid(r, view)
	// game screen frame
	tl := view.apply(core.vec2(0, 0))
	br := view.apply(core.vec2(f32(e.cfg.game_width), f32(e.cfg.game_height)))
	e.ui.ctx.draw_rect_filled(tl.x, tl.y, br.x - tl.x, br.y - tl.y, gg.Color{40, 40, 50, 255})
	e.renderer.draw_tree(e.current_root(), view)
	e.ui.ctx.draw_rect_empty(tl.x, tl.y, br.x - tl.x, br.y - tl.y, gg.Color{200, 200, 210, 120})

	if e.play == unsafe { nil } && e.doc.has_selection() {
		e.draw_selection(e.doc.selected, view)
		if n := e.gizmo_target() {
			e.draw_gizmo(n)
		}
	} else if e.play != unsafe { nil } && e.play_selected != unsafe { nil }
		&& !e.play_selected.destroyed {
		e.draw_selection(e.play_selected, view)
	}
	if e.drag == .asset && e.drag_active && e.ui.hover(r) {
		e.ui.outline(r.shrink(2), c_accent)
	}
	e.ui.reset_clip()

	if e.play != unsafe { nil } {
		e.ui.text(r.x + 10, r.y + 8, 'PLAYING', c_ok)
	}
	e.handle_scene_view_input(r)
}

fn (e &Editor) draw_grid(r Rect, view core.Affine2) {
	mut step := f32(50)
	for step * e.zoom < 24 {
		step *= 2
	}
	for step * e.zoom > 160 {
		step /= 2
	}
	w0 := e.screen_to_world(core.vec2(r.x, r.y))
	w1 := e.screen_to_world(core.vec2(r.x + r.w, r.y + r.h))
	col := gg.Color{255, 255, 255, 14}
	mut x := f32(math.floor(w0.x / step)) * step
	for x <= w1.x {
		p := view.apply(core.vec2(x, 0))
		e.ui.ctx.draw_line(p.x, r.y, p.x, r.y + r.h, col)
		x += step
	}
	mut y := f32(math.floor(w0.y / step)) * step
	for y <= w1.y {
		p := view.apply(core.vec2(0, y))
		e.ui.ctx.draw_line(r.x, p.y, r.x + r.w, p.y, col)
		y += step
	}
}

fn (e &Editor) draw_selection(n &core.Node, view core.Affine2) {
	m := view.mul(n.world_matrix())
	mut drew := false
	for c in n.components {
		if c is render.Sprite {
			x, y, w, h := c.local_rect()
			if w > 0 && h > 0 {
				e.draw_quad(m, x, y, w, h, c_override)
				drew = true
			}
		}
	}
	if !drew {
		e.draw_quad(m, -12, -12, 24, 24, gg.Color{255, 200, 90, 120})
	}
	p := m.position()
	e.ui.ctx.draw_circle_filled(p.x, p.y, 4, c_override)
}

fn (e &Editor) draw_quad(m core.Affine2, x f32, y f32, w f32, h f32, c gg.Color) {
	a := m.apply(core.vec2(x, y))
	b := m.apply(core.vec2(x + w, y))
	d := m.apply(core.vec2(x + w, y + h))
	f := m.apply(core.vec2(x, y + h))
	e.ui.ctx.draw_line(a.x, a.y, b.x, b.y, c)
	e.ui.ctx.draw_line(b.x, b.y, d.x, d.y, c)
	e.ui.ctx.draw_line(d.x, d.y, f.x, f.y, c)
	e.ui.ctx.draw_line(f.x, f.y, a.x, a.y, c)
}

fn (mut e Editor) handle_scene_view_input(r Rect) {
	if !e.ui.hover(r) {
		return
	}
	// zoom around the cursor
	if e.ui.scroll != 0 {
		before := e.screen_to_world(e.ui.mouse)
		factor := f32(math.pow(1.1, e.ui.scroll))
		e.zoom = clampf(e.zoom * factor, 0.05, 20)
		after := e.screen_to_world(e.ui.mouse)
		e.cam = e.cam + (before - after)
	}
	// pan: right/middle mouse, or Alt + left mouse
	if e.drag == .none && (e.ui.right_down || e.ui.middle_down || (e.ui.pressed && e.ui.alt())) {
		e.drag = .pan
		e.drag_start = e.ui.mouse
		e.drag_offset = e.cam
		e.ui.consumed = true
		return
	}
	if e.play != unsafe { nil } || !e.ui.click(r) {
		return
	}
	// gizmo handles of the selected node take priority over picking
	if n := e.gizmo_target() {
		h := e.gizmo_hit(n, e.ui.mouse)
		if h != .none {
			e.begin_transform_drag(.gizmo, n, h)
			return
		}
	}
	world := e.screen_to_world(e.ui.mouse)
	hit := e.pick(world) or {
		e.doc.selected = unsafe { nil }
		return
	}
	e.doc.select(hit)
	// dragging the node's body moves it freely (Move tool only, so rotating/scaling can't nudge it by accident)
	if hit != e.doc.scene.root && e.tool == .move {
		e.begin_transform_drag(.move_node, hit, .none)
		e.drag_offset = world - hit.world_position()
	}
}

// pick: the topmost node (drawn last) whose sprite contains the point `world`.
// Clicking a child of a prefab instance selects the instance root (like Unity).
fn (mut e Editor) pick(world core.Vec2) ?&core.Node {
	mut hits := []&core.Node{}
	collect_hits(e.doc.scene.root, world, mut hits)
	if hits.len == 0 {
		return none
	}
	mut n := hits.last()
	for n.parent != unsafe { nil } && e.doc.is_prefab_owned(n) {
		n = n.parent
	}
	return n
}

fn collect_hits(n &core.Node, world core.Vec2, mut out []&core.Node) {
	if !n.active {
		return
	}
	local := n.world_matrix().inverse().apply(world)
	for c in n.components {
		if c is render.Sprite {
			x, y, w, h := c.local_rect()
			if w > 0 && h > 0 && local.x >= x && local.x <= x + w && local.y >= y
				&& local.y <= y + h {
				out << n
				break
			}
		}
	}
	for ch in n.children {
		collect_hits(ch, world, mut out)
	}
}

// finish_drag updates / ends the drag operation (called every frame after drawing).
fn (mut e Editor) finish_drag() {
	match e.drag {
		.none {
			return
		}
		.pan {
			d := e.ui.mouse - e.drag_start
			e.cam = e.drag_offset - d.mul(1 / e.zoom)
			if !e.ui.right_down && !e.ui.middle_down && !e.ui.mouse_down {
				e.drag = .none
			}
			return
		}
		.move_node {
			if e.doc.contains(e.drag_node) && e.ui.mouse_down {
				if !e.drag_active && e.ui.mouse.distance(e.drag_start) > 3 {
					e.drag_active = true
					e.doc.checkpoint() or {}
				}
				if e.drag_active {
					mut n := e.drag_node
					mut p := e.screen_to_world(e.ui.mouse) - e.drag_offset
					if e.ui.shift() {
						p = core.vec2(f32(math.round(p.x / 10) * 10),
							f32(math.round(p.y / 10) * 10))
					}
					n.set_world_position(p)
				}
				return
			}
		}
		.gizmo {
			if e.doc.contains(e.drag_node) && e.ui.mouse_down {
				if !e.drag_active && e.ui.mouse.distance(e.drag_start) > 2 {
					e.drag_active = true
					e.doc.checkpoint() or {}
				}
				if e.drag_active {
					e.apply_gizmo()
				}
				return
			}
		}
		.hier_node, .asset {
			if e.ui.mouse_down {
				if !e.drag_active && e.ui.mouse.distance(e.drag_start) > 4 {
					e.drag_active = true
				}
				return
			}
			if e.drag_active {
				e.drop()
			}
		}
	}

	e.drag = .none
	e.drag_node = unsafe { nil }
	e.drag_active = false
	e.drop_indicator = Rect{}
}

// drop handles a drop: node -> reparent/reorder; asset -> add to the scene (under the node below the cursor or at the position in the scene view).
fn (mut e Editor) drop() {
	target := e.hier_drop_target()
	if e.drag == .hier_node {
		if !e.doc.contains(e.drag_node) {
			return
		}
		mut n := e.drag_node
		if t := target {
			mut parent := t.parent
			e.doc.reparent(mut n, mut parent, t.index) or { e.report(err) }
		}
		return
	}
	// asset
	if e.view_rect.has(e.ui.mouse) && e.modal == .none {
		mut parent := if e.doc.has_selection() && e.doc.selected != e.doc.scene.root {
			e.doc.selected.parent
		} else {
			e.doc.scene.root
		}
		e.add_asset_to_scene(e.drag_asset, mut parent, e.screen_to_world(e.ui.mouse))
	} else if t := target {
		mut parent := t.parent
		e.add_asset_to_scene(e.drag_asset, mut parent, none)
	}
}

fn (mut e Editor) draw_drag_ghost() {
	if !e.drag_active || e.drag !in [.hier_node, .asset] {
		return
	}
	label := if e.drag == .hier_node && e.doc.contains(e.drag_node) {
		e.drag_node.name
	} else {
		e.db.path_of(e.drag_asset) or { '' }
	}
	if e.drop_indicator.w > 0 {
		e.ui.fill(e.drop_indicator, c_accent)
	}
	w := e.ui.text_width(label) + 16
	r := Rect{e.ui.mouse.x + 12, e.ui.mouse.y + 4, w, 20}
	e.ui.fill(r, gg.Color{64, 132, 230, 200})
	e.ui.text_in(r, label, c_text, 8)
}

// ---------- Hierarchy ----------

struct HierRow {
	node  &core.Node
	depth int
	rect  Rect
}

struct DropTarget {
	parent &core.Node
	index  int
}

fn (mut e Editor) draw_hierarchy(r Rect) {
	playing := e.play != unsafe { nil }
	e.ui.fill(r, c_panel)
	head := Rect{r.x, r.y, r.w, 26}
	e.ui.fill(head, c_header)
	e.ui.text_in(head, if playing { 'Hierarchy (playing)' } else { 'Hierarchy' }, c_text, 8)

	// action buttons
	sel := !playing && e.doc.has_selection()
	bw := (r.w - 16 - 4 * 3) / 5
	by := r.y + 30
	mut bx := r.x + 8
	if e.ui.button(Rect{bx, by, bw, 22}, '+ Node', !playing) {
		e.open_modal(.new_node, 'Node')
	}
	bx += bw + 3
	if e.ui.button(Rect{bx, by, bw, 22}, 'Duplicate', sel) {
		e.duplicate_selected()
	}
	bx += bw + 3
	if e.ui.button(Rect{bx, by, bw, 22}, 'Delete', sel) {
		e.delete_selected()
	}
	bx += bw + 3
	if e.ui.button(Rect{bx, by, bw, 22}, 'Up', sel) {
		e.move_selected(-1)
	}
	bx += bw + 3
	if e.ui.button(Rect{bx, by, bw, 22}, 'Down', sel) {
		e.move_selected(1)
	}

	list := Rect{r.x, by + 28, r.w, r.h - (by + 28 - r.y)}
	e.ui.set_clip(list)
	if e.ui.hover(list) && e.ui.scroll != 0 {
		e.hier_scroll = clampf(e.hier_scroll - e.ui.scroll * 30, 0, 1e9)
	}
	mut rows := []HierRow{}
	y := e.layout_rows(e.current_root(), 0, list, list.y + 2 - e.hier_scroll, mut rows)
	e.hier_rows = rows
	e.hier_list = list
	if e.drag_active && e.drag in [.hier_node, .asset] {
		e.update_drop_indicator()
	}
	content_h := y + e.hier_scroll - list.y
	if content_h < list.h {
		e.hier_scroll = 0
	}

	selected := if playing { e.play_selected } else { e.doc.selected }
	for row in rows {
		n := row.node
		rr := row.rect
		if n == selected {
			e.ui.fill(rr, c_select)
		} else if e.ui.hover(rr) {
			e.ui.fill(rr, gg.Color{60, 60, 68, 255})
		}
		tx := rr.x + 6 + f32(row.depth) * 14
		if n.children.len > 0 {
			open := !e.collapsed[e.row_key(n)]
			e.ui.triangle(tx, rr.y + 7, open, c_dim)
			if e.ui.click(Rect{tx - 3, rr.y, 16, rr.h}) {
				e.collapsed[e.row_key(n)] = open
				continue
			}
		}
		color := if !n.active {
			c_dim
		} else if !playing && e.doc.is_instance_root(n) {
			c_prefab
		} else if !playing && e.doc.is_prefab_owned(n) {
			c_prefab_owned
		} else {
			c_text
		}
		e.ui.text_in(Rect{tx + 12, rr.y, rr.w, rr.h}, n.name, color, 0)
		if e.ui.click(rr) {
			if playing {
				e.play_selected = n
			} else {
				e.doc.select(n)
				if e.ui.double {
					e.frame_selected()
				} else if n != e.doc.scene.root {
					e.drag = .hier_node
					e.drag_node = n
					e.drag_start = e.ui.mouse
					e.drag_active = false
				}
			}
		}
	}
	// click on empty space: deselect
	if e.ui.click(list) && !playing {
		e.doc.selected = unsafe { nil }
	}
	e.ui.reset_clip()
}

fn (e &Editor) row_key(n &core.Node) string {
	return if e.play != unsafe { nil } { 'play:' + n.path() } else { e.doc.rel_path(n) }
}

fn (e &Editor) layout_rows(n &core.Node, depth int, list Rect, y0 f32, mut rows []HierRow) f32 {
	if n.destroyed {
		return y0
	}
	rows << HierRow{n, depth, Rect{list.x, y0, list.w, row_h}}
	mut y := y0 + row_h
	if e.collapsed[e.row_key(n)] {
		return y
	}
	for c in n.children {
		y = e.layout_rows(c, depth + 1, list, y, mut rows)
	}
	return y
}

// drop_zone: drop in the top 1/4 of a row = insert before, bottom 1/4 = insert after, middle = make child.
fn (e &Editor) drop_zone(row HierRow) (DropTarget, Rect) {
	n := row.node
	rr := row.rect
	rel := (e.ui.mouse.y - rr.y) / rr.h
	indent := rr.x + 18 + f32(row.depth) * 14
	if n.parent != unsafe { nil } && rel < 0.25 {
		return DropTarget{n.parent, n.child_index()}, Rect{indent, rr.y - 1, rr.w - indent, 2}
	}
	if n.parent != unsafe { nil } && rel > 0.75
		&& (n.children.len == 0 || e.collapsed[e.row_key(n)]) {
		return DropTarget{n.parent, n.child_index() + 1}, Rect{indent, rr.y + rr.h - 1, rr.w - indent, 2}
	}
	return DropTarget{n, -1}, Rect{rr.x + 2, rr.y + rr.h - 2, rr.w - 4, 2}
}

fn (e &Editor) hier_drop_target() ?DropTarget {
	if !e.hier_list.has(e.ui.mouse) || e.play != unsafe { nil } {
		return none
	}
	for row in e.hier_rows {
		if row.rect.has(e.ui.mouse) {
			t, _ := e.drop_zone(row)
			return t
		}
	}
	return DropTarget{e.doc.scene.root, -1}
}

fn (mut e Editor) update_drop_indicator() {
	e.drop_indicator = Rect{}
	for row in e.hier_rows {
		if row.rect.has(e.ui.mouse) && e.hier_list.has(e.ui.mouse) {
			_, r := e.drop_zone(row)
			e.drop_indicator = r
			return
		}
	}
}

// ---------- Assets ----------

fn (mut e Editor) draw_assets(r Rect) {
	e.ui.fill(r, c_panel)
	e.ui.ctx.draw_line(r.x, r.y, r.x + r.w, r.y, c_border)
	head := Rect{r.x, r.y, r.w, 26}
	e.ui.fill(head, c_header)
	e.ui.text_in(head, 'Assets', c_text, 8)

	editing := e.play == unsafe { nil }
	sel := e.db.entry(e.selected_asset) or { unsafe { nil } }
	can_open := sel != unsafe { nil } && sel.kind == .scene
	can_add := sel != unsafe { nil } && sel.kind in [.scene, .texture]
	by := r.y + 30
	bw := (r.w - 19) / 2
	if e.ui.button(Rect{r.x + 8, by, bw, 22}, 'Open', editing && can_open) {
		e.request(.open_asset, e.selected_asset)
	}
	if e.ui.button(Rect{r.x + 11 + bw, by, bw, 22}, 'Add to scene', editing && can_add) {
		mut parent := if e.doc.has_selection() { e.doc.selected } else { e.doc.scene.root }
		e.add_asset_to_scene(e.selected_asset, mut parent, none)
	}

	list := Rect{r.x, by + 28, r.w, r.h - (by + 28 - r.y)}
	e.ui.set_clip(list)
	if e.ui.hover(list) && e.ui.scroll != 0 {
		e.asset_scroll = clampf(e.asset_scroll - e.ui.scroll * 30, 0, 1e9)
	}
	mut y := list.y + 2 - e.asset_scroll
	for a in e.db.all() {
		rr := Rect{list.x, y, list.w, row_h}
		y += row_h
		if rr.y + rr.h < list.y || rr.y > list.y + list.h {
			continue
		}
		is_sel := a.id == e.selected_asset
		if is_sel {
			e.ui.fill(rr, c_select)
		} else if e.ui.hover(rr) {
			e.ui.fill(rr, gg.Color{60, 60, 68, 255})
		}
		tag, tag_color := match a.kind {
			.scene { 'scene', c_prefab }
			.texture { 'image', c_ok }
			.audio { 'audio', c_override }
			.text { 'text', c_dim }
			.unknown { '?', c_dim }
		}

		e.ui.text_in(Rect{rr.x + 8, rr.y, 40, rr.h}, tag, tag_color, 0)
		is_open := a.id == e.doc.asset_id
		e.ui.text_in(Rect{rr.x + 50, rr.y, rr.w - 50, rr.h}, a.path, if is_open {
			c_override
		} else {
			c_text
		}, 0)
		if e.ui.click(rr) {
			e.selected_asset = a.id
			if e.ui.double && a.kind == .scene && editing {
				e.request(.open_asset, a.id)
			} else if editing && a.kind in [.scene, .texture] {
				e.drag = .asset
				e.drag_asset = a.id
				e.drag_start = e.ui.mouse
				e.drag_active = false
			}
		}
	}
	if y + e.asset_scroll - list.y < list.h {
		e.asset_scroll = 0
	}
	e.ui.reset_clip()
}

// ---------- Inspector ----------

const label_w = f32(104)

fn (mut e Editor) draw_inspector(r Rect) {
	e.ui.fill(r, c_panel)
	e.ui.ctx.draw_line(r.x, r.y, r.x, r.y + r.h, c_border)
	head := Rect{r.x, r.y, r.w, 26}
	e.ui.fill(head, c_header)
	e.ui.text_in(head, 'Inspector', c_text, 8)

	body := Rect{r.x, r.y + 26, r.w, r.h - 26}
	e.ui.set_clip(body)
	if e.ui.hover(body) && e.ui.scroll != 0 {
		e.insp_scroll = clampf(e.insp_scroll - e.ui.scroll * 30, 0, 1e9)
	}
	mut y := body.y + 8 - e.insp_scroll
	x := body.x + 10
	w := body.w - 20

	playing := e.play != unsafe { nil }
	mut n := if playing { e.play_selected } else { e.doc.selected }
	if n == unsafe { nil } || n.destroyed || (!playing && !e.doc.contains(n)) {
		e.ui.text(x, y, 'Select a node in the Hierarchy or Scene.', c_dim)
		y += 24
		e.ui.text(x, y, 'Drag assets into Scene/Hierarchy to add them.', c_dim)
		y += 24
		e.ui.text(x, y, 'Right/middle mouse: pan view · wheel: zoom', c_dim)
		y += 20
		e.ui.text(x, y, 'W move · E rotate · R scale · T local/global axes', c_dim)
		y += 20
		e.ui.text(x, y, 'Shift while dragging: snap · Esc: cancel the drag', c_dim)
		e.ui.reset_clip()
		return
	}
	ro := playing // read-only while playing
	id := '${voidptr(n)}'

	// ---- Node ----
	e.ui.text_in(Rect{x, y, label_w, row_h}, 'Name', c_dim, 0)
	owned := !ro && e.doc.is_prefab_owned(n)
	if e.ui.draw_field('${id}/name', Rect{x + label_w, y, w - label_w - 70, row_h}, n.name, c_text,

		!ro && !owned)
	{
		e.begin_edit('${id}/name', n.name, EditTarget{ kind: .node_name, node: n })
	}
	if e.ui.checkbox(Rect{x + w - 64, y, 64, row_h}, n.active, !ro) {
		toggled := !n.active
		e.doc.set_node_prop(mut n, 'active', serialize.Value(toggled), true) or { e.report(err) }
	}
	e.ui.text_in(Rect{x + w - 46, y, 46, row_h}, 'active', if !ro
		&& e.doc.node_prop_overridden(n, 'active') {
		c_override
	} else {
		c_dim
	}, 0)
	y += row_h + 6

	if !ro {
		if e.doc.is_instance_root(n) {
			path := e.db.path_of(n.prefab_id) or { n.prefab_id }
			e.ui.text_in(Rect{x, y, w, row_h}, 'Prefab: ${path}', c_prefab, 0)
			y += row_h
			bw := (w - 6) / 3
			if e.ui.button(Rect{x, y, bw, row_h}, 'Open prefab', true) {
				e.request(.open_asset, n.prefab_id)
			}
			if e.ui.button(Rect{x + bw + 3, y, bw, row_h}, 'Select file', true) {
				e.selected_asset = n.prefab_id
			}
			if e.ui.button(Rect{x + 2 * (bw + 3), y, bw, row_h}, 'Unpack prefab', true) {
				e.doc.unpack(mut n) or { e.report(err) }
			}
			y += row_h + 6
		} else if owned {
			e.ui.text_in(Rect{x, y, w, row_h}, 'Owned by the source prefab (values only)',
				c_prefab_owned, 0)
			y += row_h + 6
		}
		if n != e.doc.scene.root && !owned {
			if e.ui.button(Rect{x, y, w, row_h}, 'Create prefab from this node…', true) {
				e.open_modal(.make_prefab, 'prefabs/${n.name.to_lower().replace(' ', '_')}.scene')
			}
			y += row_h + 6
		}
	}

	// ---- Transform ----
	y = e.section(Rect{x - 10, y, w + 20, row_h}, 'Transform', '', false)
	y = e.vec2_row(x, y, w, id, n, -1, 'position', serialize.vec2_value(n.position), ro)
	y = e.number_row(x, y, w, id, n, -1, 'rotation', serialize.Value(f64(n.rotation)), ro)
	y = e.vec2_row(x, y, w, id, n, -1, 'scale', serialize.vec2_value(n.scale), ro)
	y += 6

	// ---- Component ----
	for ci in 0 .. n.components.len {
		c := n.components[ci]
		tname := core.short_type_name(c.type_name())
		t := e.registry.get(tname) or {
			y = e.section(Rect{x - 10, y, w + 20, row_h}, tname, '', false)
			e.ui.text_in(Rect{x, y, w, row_h}, 'not registered with the Registry', c_error, 0)
			y += row_h + 6
			continue
		}
		in_prefab := !ro && e.doc.component_in_prefab(n, tname)
		added := !ro && !in_prefab && e.doc.reference_of(n) != none
		title := if added { '${tname}  (+ override)' } else { tname }
		removable := !ro && !in_prefab
		hy := y
		y = e.section(Rect{x - 10, y, w + 20, row_h}, title, 'x', removable)
		if removable && e.ui.click(Rect{x + w - 14, hy, 24, row_h}) {
			e.doc.remove_component(mut n, ci) or { e.report(err) }
			break
		}
		values := t.dump(c)
		for f in t.fields {
			v := values[f.name] or { continue }
			y = e.field_row(x, y, w, id, n, ci, f, v, ro)
		}
		y += 6
	}

	if !ro {
		br := Rect{x, y + 4, w, row_h + 2}
		if e.ui.button(br, '+ Add component', true) {
			e.add_menu_open = !e.add_menu_open
			e.add_menu_at = core.vec2(br.x, br.y + br.h)
		}
		y += row_h + 12
	}
	content_h := y + e.insp_scroll - body.y
	if content_h < body.h {
		e.insp_scroll = 0
	}
	e.ui.reset_clip()
}

// section draws a group's header bar and returns the next y.
fn (mut e Editor) section(r Rect, title string, action string, action_enabled bool) f32 {
	e.ui.fill(r, c_header)
	e.ui.text_in(r, title, if title.contains('override') { c_override } else { c_text }, 10)
	if action != '' && action_enabled {
		ar := Rect{r.x + r.w - 24, r.y, 24, r.h}
		e.ui.text_center(ar, action, if e.ui.hover(ar) { c_error } else { c_dim })
	}
	return r.y + r.h + 4
}

fn (mut e Editor) begin_edit(id string, value string, target EditTarget) {
	e.commit_edit()
	e.ui.focus_field(id, e.ui.focus_rect, value, target)
}

fn (mut e Editor) prop_label(x f32, y f32, name string, overridden bool) {
	if overridden {
		e.ui.fill(Rect{x - 8, y + 3, 3, row_h - 6}, c_override)
	}
	e.ui.text_in(Rect{x, y, label_w, row_h}, name, if overridden { c_override } else { c_dim }, 0)
}

fn (mut e Editor) is_overridden(n &core.Node, comp int, field string, ro bool) bool {
	if ro {
		return false
	}
	return if comp < 0 {
		e.doc.node_prop_overridden(n, field)
	} else {
		e.doc.field_overridden(n, comp, field)
	}
}

fn target_for(n &core.Node, comp int, field string, part int, kind ValueKind) EditTarget {
	return EditTarget{
		kind:  if comp < 0 { .node_prop } else { .comp_field }
		node:  n
		comp:  comp
		field: field
		part:  part
		value: kind
	}
}

fn (mut e Editor) vec2_row(x f32, y f32, w f32, id string, n &core.Node, comp int, field string, v serialize.Value, ro bool) f32 {
	e.prop_label(x, y, field, e.is_overridden(n, comp, field, ro))
	parts := v as []serialize.Value
	fw := (w - label_w - 4) / 2
	for i in 0 .. 2 {
		fr := Rect{x + label_w + f32(i) * (fw + 4), y, fw, row_h}
		fid := '${id}/${comp}/${field}/${i}'
		shown := parts[i].to_text()
		axis := if i == 0 { 'x ' } else { 'y ' }
		if e.ui.draw_field(fid, fr, axis + shown, c_text, !ro) {
			e.begin_edit(fid, shown, target_for(n, comp, field, i, .number))
		}
	}
	return y + row_h + 3
}

fn (mut e Editor) number_row(x f32, y f32, w f32, id string, n &core.Node, comp int, field string, v serialize.Value, ro bool) f32 {
	e.prop_label(x, y, field, e.is_overridden(n, comp, field, ro))
	fid := '${id}/${comp}/${field}'
	shown := v.to_text()
	if e.ui.draw_field(fid, Rect{x + label_w, y, w - label_w, row_h}, shown, c_text, !ro) {
		e.begin_edit(fid, shown, target_for(n, comp, field, -1, .number))
	}
	return y + row_h + 3
}

fn (mut e Editor) field_row(x f32, y f32, w f32, id string, n &core.Node, comp int, f serialize.FieldInfo, v serialize.Value, ro bool) f32 {
	mut nn := unsafe { n }
	match v {
		bool {
			e.prop_label(x, y, f.name, e.is_overridden(n, comp, f.name, ro))
			if e.ui.checkbox(Rect{x + label_w, y, 40, row_h}, v, !ro) {
				toggled := !v
				e.doc.set_field(mut nn, comp, f.name, serialize.Value(toggled)) or { e.report(err) }
			}
			return y + row_h + 3
		}
		f64 {
			return e.number_row(x, y, w, id, n, comp, f.name, v, ro)
		}
		string {
			e.prop_label(x, y, f.name, e.is_overridden(n, comp, f.name, ro))
			fid := '${id}/${comp}/${f.name}'
			if e.ui.draw_field(fid, Rect{x + label_w, y, w - label_w, row_h}, v, c_text, !ro) {
				e.begin_edit(fid, v, target_for(n, comp, f.name, -1, .text))
			}
			return y + row_h + 3
		}
		serialize.AssetId {
			return e.asset_row(x, y, w, id, n, comp, f, v.id, ro)
		}
		[]serialize.Value {
			if v.len == 2 {
				return e.vec2_row(x, y, w, id, n, comp, f.name, v, ro)
			}
			e.prop_label(x, y, f.name, e.is_overridden(n, comp, f.name, ro))
			fid := '${id}/${comp}/${f.name}'
			shown := serialize.Value(v).to_text()
			mut fw := w - label_w
			if v.len == 4 {
				// color preview swatch
				nums := serialize.Value(v).as_number_list() or { [0.0, 0, 0, 0] }
				sw := Rect{x + w - 22, y + 2, 22, row_h - 4}
				e.ui.fill(sw, gg.Color{u8(nums[0]), u8(nums[1]), u8(nums[2]), 255})
				e.ui.outline(sw, c_border)
				fw -= 26
			}
			if e.ui.draw_field(fid, Rect{x + label_w, y, fw, row_h}, shown, c_text, !ro) {
				e.begin_edit(fid, shown, target_for(n, comp, f.name, -1, .raw))
			}
			return y + row_h + 3
		}
	}
}

fn (mut e Editor) asset_row(x f32, y f32, w f32, id string, n &core.Node, comp int, f serialize.FieldInfo, asset_id string, ro bool) f32 {
	mut nn := unsafe { n }
	e.prop_label(x, y, f.name, e.is_overridden(n, comp, f.name, ro))
	fid := '${id}/${comp}/${f.name}'
	shown := if asset_id == '' {
		'(empty)'
	} else {
		e.db.path_of(asset_id) or { '${asset_id} (not found!)' }
	}
	color := if asset_id != '' && e.db.entry(asset_id) == none { c_error } else { c_text }
	fw := w - label_w - 48
	if e.ui.draw_field(fid, Rect{x + label_w, y, fw, row_h}, shown, color, !ro) {
		editable := e.db.path_of(asset_id) or { asset_id }
		e.begin_edit(fid, editable, target_for(n, comp, f.name, -1, .asset))
	}
	// assign the asset selected in the Assets panel (if the kind matches)
	sel_kind := if ent := e.db.entry(e.selected_asset) { ent.kind } else { assets.AssetKind.unknown }
	can_assign := !ro && sel_kind == f.asset_kind && e.selected_asset != asset_id
	if e.ui.button(Rect{x + w - 44, y, 44, row_h}, 'Assign', can_assign) {
		e.doc.set_field(mut nn, comp, f.name, serialize.Value(e.selected_asset)) or {
			e.report(err)
		}
	}
	return y + row_h + 3
}

// ---------- Add component menu ----------

fn (mut e Editor) draw_add_component_menu() {
	if !e.add_menu_open || e.play != unsafe { nil } || !e.doc.has_selection() || e.modal != .none {
		e.add_menu_open = false
		return
	}
	mut n := e.doc.selected
	mut names := []string{}
	for name in e.registry.names() {
		if _ := n.component_by_type_name(name) {
			continue
		}
		names << name
	}
	w := f32(220)
	h := f32(names.len) * row_h + 8
	mut x := e.add_menu_at.x
	if x + w > e.ui.win_w {
		x = e.ui.win_w - w - 4
	}
	mut y := e.add_menu_at.y
	if y + h > e.ui.win_h {
		y = e.add_menu_at.y - h - row_h - 2
	}
	r := Rect{x, y, w, if names.len == 0 { row_h + 8 } else { h }}
	e.ui.overlay_next = r
	e.ui.layer = 1
	e.ui.reset_clip()
	e.ui.fill(r, c_header)
	e.ui.outline(r, c_accent)
	if names.len == 0 {
		e.ui.text_in(Rect{r.x, r.y + 4, r.w, row_h}, 'all components already added', c_dim, 10)
	}
	for i, name in names {
		rr := Rect{r.x + 4, r.y + 4 + f32(i) * row_h, r.w - 8, row_h}
		if e.ui.hover(rr) {
			e.ui.fill(rr, c_select)
		}
		e.ui.text_in(rr, name, c_text, 8)
		if e.ui.click(rr) {
			e.doc.add_component(mut n, name) or { e.report(err) }
			e.add_menu_open = false
		}
	}
	// click outside: close the menu (the "+ Add component" button handles its own toggle)
	if e.ui.pressed && !e.ui.consumed && !r.has(e.ui.mouse) {
		e.add_menu_open = false
	}
	e.ui.layer = 0
}

fn clampf(v f32, lo f32, hi f32) f32 {
	return if v < lo {
		lo
	} else if v > hi {
		hi
	} else {
		v
	}
}
