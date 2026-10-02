module editor

import gg
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render
import velo.audio
import velo.scenedoc

// Scene/prefab editor: Hierarchy + Scene view + Inspector + Assets, with test runs (Play) right inside the editor.
//
//   mut ed := editor.new(assets_dir: 'assets', scene: 'scenes/main.scene')!
//   ed.register[PlayerController]()      // game component, same as app.register
//   ed.run()
//
// The editor must be compiled together with the game's components (V does not load code at runtime),
// so the simplest approach is to give the game program an `--editor` flag (see examples/demo/main.v).
pub struct Config {
pub:
	title       string = 'Velo Editor'
	width       int    = 1440
	height      int    = 860
	assets_dir  string = 'assets'
	scene       string // scene/prefab opened at startup ('' = empty scene)
	game_width  int = 960 // game screen frame drawn in the scene view
	game_height int = 540
}

enum Modal {
	none
	save_as
	make_prefab
	new_node
	confirm_discard
}

// Action waiting for the user to confirm discarding unsaved changes.
enum PendingAction {
	none
	open_asset
	new_doc
}

enum DragKind {
	none
	move_node // dragging a node in the scene view
	pan       // dragging the view
	hier_node // dragging a node in the hierarchy
	asset     // dragging an asset from the Assets panel
	gizmo     // dragging a move/rotate/scale gizmo handle
	paint     // painting tiles on a TileMap (see tilemap.v)
	slice     // dragging a 9-slice border line in the Inspector (see sprite.v)
}

@[heap]
pub struct Editor {
pub mut:
	cfg      Config
	db       &assets.AssetDatabase
	registry &serialize.Registry
	loader   &serialize.SceneLoader
	// Save data while playing: kept in memory for the editor session (the game's real save file is not touched).
	play_store   &core.Store = &core.Store{}
	play_editing bool // last frame, a text field in the game had the keyboard
	doc          &scenedoc.Document = unsafe { nil }
mut:
	ctx      &gg.Context      = unsafe { nil }
	renderer &render.Renderer = unsafe { nil }
	ui       Ui
	// scene view
	view_rect Rect
	cam       core.Vec2
	zoom      f32 = 1
	// drag and drop
	drag           DragKind
	drag_node      &core.Node = unsafe { nil }
	drag_start     core.Vec2
	drag_offset    core.Vec2
	drag_active    bool // dragged past the threshold (avoids recording undo on a plain click)
	drag_asset     string
	drop_indicator Rect
	// transform gizmo (see gizmo.v)
	tool               GizmoTool
	tool_local         bool // move axes follow the node's rotation
	gizmo_handle       GizmoHandle
	gizmo_origin       core.Vec2 // node position on screen when the drag started
	gizmo_ax           core.Vec2 // gizmo axes when the drag started
	gizmo_ay           core.Vec2
	gizmo_start_pos    core.Vec2 // world position
	gizmo_start_local  core.Vec2 // local position (restored on cancel)
	gizmo_start_rot    f32
	gizmo_start_scale  core.Vec2
	gizmo_start_angle  f32 // radians, mouse angle around the node
	gizmo_last_angle   f32
	gizmo_turn         f32 // accumulated rotation (radians)
	gizmo_ratio        f32 = 1 // current scale factor
	gizmo_start_world  core.Affine2 // node's world matrix when the drag started
	gizmo_start_anchor core.Vec2    // Sprite anchor when the drag started
	gizmo_child_world  []core.Vec2  // children kept in place while the anchor moves
	gizmo_child_local  []core.Vec2  // restored on cancel
	gizmo_start_rect   render.Rect  // Size tool: the rectangle (node space) when the drag started
	gizmo_start_size   core.Vec2    // restored on cancel
	gizmo_edge         []int = [0, 0] // Size tool: dragged side per axis (-1 / 0 / 1)
	// tile painting (see tilemap.v)
	tile_tool  TileTool
	tile_brush int
	tile_last  []int // cell painted last during a stroke: [col, row]
	// 9-slice border editing (see sprite.v)
	slice_edge   int       // border being dragged: 0 left, 1 top, 2 right, 3 bottom
	slice_origin core.Vec2 // screen position of the preview frame's top-left corner
	slice_k      f32       // preview scale (screen pixels per texture pixel)
	// panel
	collapsed      map[string]bool // keyed by node path (survives undo)
	hier_rows      []HierRow
	hier_list      Rect
	add_menu_at    core.Vec2
	hier_scroll    f32
	insp_scroll    f32
	asset_scroll   f32
	selected_asset string
	add_menu_open  bool
	// dropdown list (choices, asset picker) — see panels.v
	dd_open   bool
	dd_id     string
	dd_anchor Rect
	dd_labels []string
	dd_values []string
	dd_cur    string
	dd_scroll f32
	dd_node   &core.Node = unsafe { nil }
	dd_comp   int
	dd_field  string
	// number field scrubbing (drag to change the value)
	scrub_id     string
	scrub_x      f32
	scrub_start  f64
	scrub_moved  bool
	scrub_target EditTarget
	// dialogs
	modal         Modal
	modal_message string
	pending       PendingAction
	pending_asset string
	status        string
	status_error  bool
	status_time   i64
	// play mode
	play          &core.Scene = unsafe { nil }
	play_input    &core.Input = unsafe { nil }
	play_selected &core.Node  = unsafe { nil }
	// timing
	last_ticks   i64
	reload_timer f32
}

// new opens the AssetDatabase and registers the engine's built-in components.
pub fn new(cfg Config) !&Editor {
	mut db := assets.open(cfg.assets_dir)!
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	audio.register_builtins(mut reg)
	return &Editor{
		cfg:        cfg
		db:         db
		registry:   reg
		loader:     serialize.new_loader(reg, db)
		play_input: &core.Input{}
	}
}

// register registers a game component so the editor can create/edit/save it.
pub fn (mut e Editor) register[T]() {
	e.registry.register[T]()
}

pub fn (mut e Editor) run() {
	e.ctx = gg.new_context(
		bg_color:     c_bg
		width:        e.cfg.width
		height:       e.cfg.height
		window_title: e.cfg.title
		init_fn:      on_init
		frame_fn:     on_frame
		event_fn:     on_event
		cleanup_fn:   on_cleanup
		user_data:    e
	)
	e.ui.ctx = e.ctx
	e.ctx.run()
}

fn on_init(mut e Editor) {
	e.renderer = render.new_renderer(e.ctx, e.db)
	e.renderer.show_shapes = true
	audio.start() // sounds play while playing the scene
	if e.cfg.scene != '' {
		e.open_doc(e.cfg.scene)
	}
	if e.doc == unsafe { nil } {
		e.doc = scenedoc.new_empty(mut e.loader, 'Scene')
	}
	e.frame_all()
	e.last_ticks = time.ticks()
}

fn on_cleanup(mut _ Editor) {
	audio.shutdown()
}

// ---------- Loop ----------

fn on_frame(mut e Editor) {
	now := time.ticks()
	mut dt := f32(now - e.last_ticks) / 1000.0
	e.last_ticks = now
	if dt > 0.1 {
		dt = 0.1
	}
	size := gg.window_size()
	e.ui.win_w = f32(size.width)
	e.ui.win_h = f32(size.height)

	// Clicking outside the field being edited = commit the value, BEFORE any other widget handles the click.
	if e.ui.pressed && e.ui.focus != '' && !e.ui.focus_rect.has(e.ui.mouse) {
		e.commit_edit()
	}

	if e.play != unsafe { nil } {
		e.play.update(dt)
		e.play_editing = e.play_input.text_editing // a text field has the keys: Esc goes to it, not Stop
		e.play_input.end_frame()
		e.change_play_scene()
		audio.pump()
	} else if e.doc != unsafe { nil } {
		preview_tree(mut e.doc.scene.root, dt)
		// the scene is not updated while editing: advance its clocks so shader effects (TIME) animate
		e.doc.scene.time += dt
		e.doc.scene.real_time += dt
	}

	e.ctx.begin()
	e.ui.layer = 0
	e.ui.modal = e.modal != .none
	e.ui.reset_clip()
	e.layout_and_draw()
	e.ui.reset_clip()
	e.ctx.end()

	e.finish_drag()
	e.ui.end_frame()

	e.reload_timer += dt
	if e.reload_timer >= 0.5 {
		e.reload_timer = 0
		e.poll_assets()
	}
}

// preview_tree animates the edited scene's render.Previewable components (particles) while not playing.
fn preview_tree(mut n core.Node, dt f32) {
	if !n.active {
		return
	}
	for mut c in n.components {
		if c.enabled && mut c is render.Previewable {
			c.preview(dt)
		}
	}
	for mut ch in n.children {
		preview_tree(mut ch, dt)
	}
}

fn (mut e Editor) layout_and_draw() {
	w := e.ui.win_w
	h := e.ui.win_h
	toolbar_h := f32(36)
	status_h := f32(24)
	left_w := f32(270)
	right_w := f32(340)
	body_y := toolbar_h
	body_h := h - toolbar_h - status_h
	hier_h := f32(int(body_h * 0.58))

	e.view_rect = Rect{left_w, body_y, w - left_w - right_w, body_h}
	e.draw_scene_view(e.view_rect)
	e.draw_hierarchy(Rect{0, body_y, left_w, hier_h})
	e.draw_assets(Rect{0, body_y + hier_h, left_w, body_h - hier_h})
	e.draw_inspector(Rect{w - right_w, body_y, right_w, body_h})
	e.draw_toolbar(Rect{0, 0, w, toolbar_h})
	e.draw_status(Rect{0, h - status_h, w, status_h})
	e.draw_drag_ghost()
	e.draw_add_component_menu()
	e.draw_dropdown()
	e.draw_modal()
}

fn (mut e Editor) poll_assets() {
	events, rebuilt := e.doc.poll()
	for ev in events {
		e.renderer.on_asset_event(ev)
		if ev.kind in [.unloaded, .removed] {
			mut m := audio.mixer()
			m.forget(ev.id)
		}
		if ev.kind != .unloaded {
			println('[editor] ${ev.kind}: ${ev.path}')
		}
	}
	if rebuilt {
		e.ui.unfocus()
		e.set_status('reloaded because the file changed on disk', false)
	}
}

// ---------- Events ----------

fn on_event(ev &gg.Event, mut e Editor) {
	e.ui.mods = ev.modifiers
	match ev.typ {
		.mouse_move {
			e.ui.mouse = core.vec2(ev.mouse_x, ev.mouse_y) // gg already divides by the dpi scale
			if e.play != unsafe { nil } {
				e.play_input.mouse = e.screen_to_world(e.ui.mouse)
			}
		}
		.mouse_down {
			e.ui.on_mouse_down(ev.mouse_button)
			if e.play != unsafe { nil } && e.view_rect.has(e.ui.mouse) && ev.mouse_button == .left {
				e.play_input.mouse_press()
			}
		}
		.mouse_up {
			e.ui.on_mouse_up(ev.mouse_button)
			if e.play != unsafe { nil } && ev.mouse_button == .left {
				e.play_input.mouse_release()
			}
		}
		.mouse_scroll {
			e.ui.scroll += ev.scroll_y
			if e.play != unsafe { nil } && e.view_rect.has(e.ui.mouse) {
				e.play_input.mouse_scroll(ev.scroll_x, ev.scroll_y)
			}
		}
		.char {
			if e.ui.focus != '' {
				e.ui.on_char(ev.char_code)
			} else if e.play != unsafe { nil } {
				e.play_input.type_char(ev.char_code)
			}
		}
		.key_down {
			if ev.key_repeat && e.play != unsafe { nil } && e.ui.focus == '' {
				e.play_input.key_repeat(int(ev.key_code))
			} else {
				e.on_key_down(ev.key_code)
			}
		}
		.key_up {
			if e.play != unsafe { nil } {
				e.play_input.key_up(int(ev.key_code))
			}
		}
		else {}
	}
}

fn (mut e Editor) on_key_down(key gg.KeyCode) {
	// The focused input field receives keys first.
	if e.ui.focus != '' {
		match e.ui.on_key(key) {
			'commit' { e.commit_edit() }
			'cancel' { e.ui.unfocus() }
			else {}
		}

		if !e.ui.ctrl() {
			return
		}
	}
	if e.modal != .none {
		if key == .escape {
			e.close_modal()
		}
		return
	}
	if e.play != unsafe { nil } {
		if (key == .escape && !e.play_editing) || (e.ui.ctrl() && key == .p) {
			e.stop_play()
			return
		}
		e.play_input.key_down(int(key))
		return
	}
	if e.ui.ctrl() {
		match key {
			.s {
				if e.ui.shift() {
					e.ask_save_as()
				} else {
					e.save()
				}
			}
			.z {
				if e.ui.shift() {
					e.redo()
				} else {
					e.undo()
				}
			}
			.y {
				e.redo()
			}
			.d {
				e.duplicate_selected()
			}
			.n {
				e.request(.new_doc, '')
			}
			.p {
				e.start_play()
			}
			else {}
		}

		return
	}
	match key {
		.delete, .backspace {
			e.delete_selected()
		}
		.f {
			e.frame_selected()
		}
		.escape {
			if e.cancel_transform_drag() {
			} else if e.tile_tool != .none {
				e.set_tile_tool(.none)
			} else {
				e.add_menu_open = false
				e.dd_open = false
			}
		}
		.b {
			e.set_tile_tool(.paint)
		}
		.x {
			e.set_tile_tool(.erase)
		}
		.g {
			e.set_tile_tool(.fill)
		}
		.i {
			e.set_tile_tool(.pick)
		}
		.w {
			e.set_tool(.move)
		}
		.e {
			e.set_tool(.rotate)
		}
		.r {
			e.set_tool(.scale)
		}
		.y {
			e.set_tool(.anchor)
		}
		.u {
			e.set_tool(.size)
		}
		.t {
			e.tool_local = !e.tool_local
			e.set_status(if e.tool_local { 'local axes' } else { 'global axes' }, false)
		}
		.left, .right, .up, .down {
			e.nudge(key)
		}
		else {}
	}
}

// ---------- Actions ----------

fn (mut e Editor) set_status(msg string, is_error bool) {
	e.status = msg
	e.status_error = is_error
	e.status_time = time.ticks()
	if is_error {
		eprintln('[editor] ${msg}')
	}
}

fn (mut e Editor) report(err IError) {
	e.set_status(err.msg(), true)
}

fn (mut e Editor) open_doc(key string) {
	mut next := scenedoc.open(mut e.loader, key) or {
		e.report(err)
		return
	}
	if e.doc != unsafe { nil } {
		e.doc.close()
	}
	e.doc = next
	e.ui.unfocus()
	e.collapsed.clear()
	e.hier_scroll = 0
	e.insp_scroll = 0
	e.frame_all()
	e.set_status('opened ${next.path}', false)
}

// request runs an action that discards unsaved changes — asks first if the document is "dirty".
fn (mut e Editor) request(action PendingAction, asset string) {
	if e.play != unsafe { nil } {
		e.stop_play()
	}
	e.pending = action
	e.pending_asset = asset
	if e.doc.dirty {
		e.modal = .confirm_discard
		e.modal_message = '"${e.doc.path}" has unsaved changes.'
		return
	}
	e.run_pending()
}

fn (mut e Editor) run_pending() {
	match e.pending {
		.open_asset {
			e.open_doc(e.pending_asset)
		}
		.new_doc {
			e.doc.close()
			e.doc = scenedoc.new_empty(mut e.loader, 'Scene')
			e.frame_all()
			e.set_status('new scene — Ctrl+Shift+S to save', false)
		}
		.none {}
	}

	e.pending = .none
}

fn (mut e Editor) save() {
	if e.doc.path == '' {
		e.ask_save_as()
		return
	}
	e.commit_edit()
	e.doc.save() or {
		e.report(err)
		return
	}
	e.set_status('saved ${e.doc.path}', false)
}

fn (mut e Editor) ask_save_as() {
	e.open_modal(.save_as, if e.doc.path == '' { 'scenes/new.scene' } else { e.doc.path })
}

fn (mut e Editor) undo() {
	e.commit_edit()
	e.doc.undo() or {
		e.report(err)
		return
	}
	e.set_status('undo', false)
}

fn (mut e Editor) redo() {
	e.commit_edit()
	e.doc.redo() or {
		e.report(err)
		return
	}
	e.set_status('redo', false)
}

fn (mut e Editor) add_node() {
	mut parent := if e.doc.has_selection() { e.doc.selected } else { e.doc.scene.root }
	e.doc.add_node(mut parent, 'Node') or {
		e.report(err)
		return
	}
	e.collapsed.delete(e.doc.rel_path(parent))
}

fn (mut e Editor) duplicate_selected() {
	if !e.doc.has_selection() {
		return
	}
	e.doc.duplicate(e.doc.selected) or { e.report(err) }
}

fn (mut e Editor) delete_selected() {
	if !e.doc.has_selection() {
		return
	}
	mut n := e.doc.selected
	e.doc.delete(mut n) or { e.report(err) }
}

fn (mut e Editor) move_selected(delta int) {
	if !e.doc.has_selection() {
		return
	}
	mut n := e.doc.selected
	e.doc.move_sibling(mut n, delta) or { e.report(err) }
}

fn (mut e Editor) nudge(key gg.KeyCode) {
	if !e.doc.has_selection() || voidptr(e.doc.selected) == voidptr(e.doc.scene.root) {
		return
	}
	step := f32(if e.ui.shift() { 10 } else { 1 })
	d := match key {
		.left { core.vec2(-step, 0) }
		.right { core.vec2(step, 0) }
		.up { core.vec2(0, -step) }
		else { core.vec2(0, step) }
	}

	mut n := e.doc.selected
	e.doc.set_node_prop(mut n, 'position', serialize.vec2_value(n.position + d), true) or {
		e.report(err)
	}
}

// add_asset_to_scene: prefab -> instance; texture -> new node with a Sprite. `at` is the world position (if any).
fn (mut e Editor) add_asset_to_scene(id string, mut parent core.Node, at ?core.Vec2) {
	entry := e.db.entry(id) or { return }
	depth := e.doc.undo_depth()
	mut n := unsafe { &core.Node(nil) }
	match entry.kind {
		.scene {
			n = e.doc.instantiate_prefab(id, mut parent) or {
				e.report(err)
				return
			}
		}
		.texture {
			name := entry.path.all_after_last('/').all_before_last('.')
			n = e.doc.add_node(mut parent, name) or {
				e.report(err)
				return
			}
			e.doc.add_component(mut n, 'Sprite') or {
				e.report(err)
				return
			}
			e.doc.set_field(mut n, 0, 'texture', serialize.Value(id)) or {
				e.report(err)
				return
			}
		}
		else {
			e.set_status('cannot add ${entry.kind} to the scene', true)
			return
		}
	}

	if p := at {
		n.set_world_position(p)
	}
	e.doc.collapse_undo(depth) // add node + assign texture/position = one undo step
	e.collapsed.delete(e.doc.rel_path(parent))
	e.set_status('added ${entry.path}', false)
}

fn (mut e Editor) start_play() {
	if e.play != unsafe { nil } {
		return
	}
	e.commit_edit()
	mut s := e.doc.play_scene() or {
		e.report(err)
		return
	}
	e.play_input = &core.Input{}
	e.setup_play_scene(mut s)
	e.play = s
	e.play_selected = unsafe { nil }
	e.add_menu_open = false
	e.set_status('playing — Esc or the Stop button to return to editing (changes made while playing are not saved)',
		false)
}

fn (mut e Editor) setup_play_scene(mut s core.Scene) {
	s.input = e.play_input
	s.view_size = core.vec2(e.cfg.game_width, e.cfg.game_height)
	s.store = e.play_store
	if s.key == '' {
		s.key = e.doc.asset_id
	}
}

// change_play_scene carries out change_scene while playing (at once, without the fade). Reloading the
// scene being edited plays its current state, unsaved changes included.
fn (mut e Editor) change_play_scene() {
	key := e.play.next_scene
	if key == '' {
		return
	}
	e.play.next_scene = ''
	id := e.db.resolve(key) or { key }
	mut next := if id == e.doc.asset_id && id != '' {
		e.doc.play_scene() or {
			e.report(err)
			return
		}
	} else {
		e.loader.load_scene(key) or {
			e.report(err)
			return
		}
	}
	next.key = id
	e.setup_play_scene(mut next)
	next.take_persistent(mut e.play)
	e.play.unload()
	e.play = next
	e.play_selected = unsafe { nil }
	e.set_status('playing ${e.db.path_of(id) or { key }}', false)
}

fn (mut e Editor) stop_play() {
	if e.play == unsafe { nil } {
		return
	}
	e.play.unload()
	mut m := audio.mixer()
	m.stop_all() // one-shots and music started from code
	audio.pump()
	e.play = unsafe { nil }
	e.play_selected = unsafe { nil }
	e.set_status('stopped', false)
}

// ---------- Input fields: committing values ----------

fn (mut e Editor) commit_edit() {
	if e.ui.focus == '' {
		return
	}
	t := e.ui.target
	text := e.ui.buf.string()
	e.ui.unfocus()
	if t.kind == .prompt {
		e.confirm_modal(text)
		return
	}
	if t.kind == .none || !e.doc.contains(t.node) {
		return
	}
	e.apply_edit(t, text) or { e.report(err) }
}

fn (mut e Editor) apply_edit(t EditTarget, text string) ! {
	mut n := t.node
	if t.kind == .node_name {
		e.doc.rename(mut n, text)!
		return
	}
	// current value (to merge when only x or y of a Vec2 is edited)
	current := if t.kind == .node_prop {
		node_prop_value(n, t.field)
	} else {
		tname := core.short_type_name(n.components[t.comp].type_name())
		ct := e.registry.get(tname) or { return error('${tname} is not registered') }
		ct.dump(n.components[t.comp])[t.field] or { return error('no field ${t.field}') }
	}
	mut v := match t.value {
		.text { serialize.Value(text) }
		.asset { serialize.Value(text.trim_space()) }
		.number { serialize.Value(parse_number(text)!) }
		.raw { serialize.parse_value_text(text)! }
	}

	if t.part >= 0 {
		mut arr := current as []serialize.Value
		mut parts := arr.clone()
		parts[t.part] = v
		v = serialize.Value(parts)
	}
	if v.to_text() == current.to_text() {
		return
	}
	if t.kind == .node_prop {
		e.doc.set_node_prop(mut n, t.field, v, true)!
	} else if t.field in ['columns', 'rows'] && n.components[t.comp] is render.TileMap {
		// resizing a TileMap keeps every tile at its cell instead of shifting the row-major list
		size := int(v.as_f64()!)
		if size < 1 {
			return error('${t.field} must be at least 1')
		}
		e.doc.checkpoint()!
		mut c := n.components[t.comp]
		if mut c is render.TileMap {
			if t.field == 'columns' {
				c.resize(size, c.rows)
			} else {
				c.resize(c.columns, size)
			}
		}
	} else {
		e.doc.set_field(mut n, t.comp, t.field, v)!
	}
}

fn parse_number(text string) !f64 {
	v := serialize.parse_value_text(text.trim_space()) or {
		return error('"${text}" is not a number')
	}
	if v is f64 {
		return v
	}
	return error('"${text}" is not a number')
}

fn node_prop_value(n &core.Node, prop string) serialize.Value {
	return match prop {
		'position' { serialize.vec2_value(n.position) }
		'rotation' { serialize.Value(f64(n.rotation)) }
		'z_index' { serialize.Value(f64(n.z_index)) }
		'y_sort' { serialize.Value(n.y_sort) }
		'unscaled_time' { serialize.Value(n.unscaled_time) }
		'persistent' { serialize.Value(n.persistent) }
		'scale' { serialize.vec2_value(n.scale) }
		else { serialize.Value(n.active) }
	}
}

// ---------- Dialogs ----------

fn (mut e Editor) open_modal(kind Modal, initial string) {
	e.commit_edit()
	e.modal = kind
	e.ui.focus_field('prompt', Rect{}, initial, EditTarget{
		kind: .prompt
	})
}

fn (mut e Editor) close_modal() {
	e.modal = .none
	if e.ui.target.kind == .prompt {
		e.ui.unfocus()
	}
}

fn (mut e Editor) confirm_modal(text string) {
	kind := e.modal
	e.modal = .none
	match kind {
		.save_as {
			e.doc.save_as(text) or {
				e.report(err)
				return
			}
			e.set_status('saved ${e.doc.path}', false)
		}
		.make_prefab {
			if !e.doc.has_selection() {
				return
			}
			mut n := e.doc.selected
			e.doc.make_prefab(mut n, text) or {
				e.report(err)
				return
			}
			e.set_status('created prefab ${e.db.path_of(n.prefab_id) or { text }}', false)
		}
		.new_node {
			depth := e.doc.undo_depth()
			e.add_node()
			if e.doc.has_selection() && text.trim_space() != '' {
				mut n := e.doc.selected
				e.doc.rename(mut n, text) or { e.report(err) }
			}
			e.doc.collapse_undo(depth)
		}
		.confirm_discard {
			e.run_pending()
		}
		.none {}
	}
}

fn (mut e Editor) draw_modal() {
	if e.modal == .none {
		return
	}
	e.ui.layer = 1
	e.ui.reset_clip()
	e.ui.fill(Rect{0, 0, e.ui.win_w, e.ui.win_h}, gg.Color{0, 0, 0, 120})
	title := match e.modal {
		.save_as { 'Save scene as (path within the assets directory)' }
		.make_prefab { 'Create prefab from the selected node (new file path)' }
		.new_node { 'New node name' }
		.confirm_discard { e.modal_message }
		.none { '' }
	}

	has_input := e.modal != .confirm_discard
	r := Rect{(e.ui.win_w - 460) / 2, (e.ui.win_h - 130) / 2, 460, 130}
	e.ui.fill(r, c_panel)
	e.ui.outline(r, c_accent)
	e.ui.text(r.x + 14, r.y + 14, title, c_text)
	if has_input {
		field := Rect{r.x + 14, r.y + 44, r.w - 28, 26}
		if e.ui.focus != 'prompt' {
			e.ui.focus_field('prompt', field, '', EditTarget{ kind: .prompt })
		}
		e.ui.draw_field('prompt', field, '', c_text, true)
	} else {
		e.ui.text(r.x + 14, r.y + 50, 'Discard these changes?', c_dim)
	}
	ok_label := if has_input { 'OK' } else { 'Discard' }
	if e.ui.button(Rect{r.x + r.w - 214, r.y + r.h - 40, 100, 26}, ok_label, true) {
		if has_input {
			e.commit_edit() // -> confirm_modal
		} else {
			e.confirm_modal('')
		}
	}
	if e.ui.button(Rect{r.x + r.w - 108, r.y + r.h - 40, 94, 26}, 'Cancel', true) {
		e.close_modal()
	}
	e.ui.layer = 0
}

// ---------- Toolbar and status bar ----------

fn (mut e Editor) draw_toolbar(r Rect) {
	playing := e.play != unsafe { nil }
	e.ui.fill(r, if playing { c_play } else { c_header })
	e.ui.ctx.draw_line(r.x, r.y + r.h - 1, r.x + r.w, r.y + r.h - 1, c_border)
	mut x := r.x + 8
	y := r.y + 5
	h := r.h - 10
	editing := !playing
	if e.ui.button(Rect{x, y, 54, h}, 'New', editing) {
		e.request(.new_doc, '')
	}
	x += 58
	if e.ui.button(Rect{x, y, 54, h}, 'Save', editing) {
		e.save()
	}
	x += 58
	if e.ui.button(Rect{x, y, 90, h}, 'Save as…', editing) {
		e.ask_save_as()
	}
	x += 104
	if e.ui.button(Rect{x, y, 80, h}, 'Undo', editing && e.doc.can_undo()) {
		e.undo()
	}
	x += 84
	if e.ui.button(Rect{x, y, 70, h}, 'Redo', editing && e.doc.can_redo()) {
		e.redo()
	}
	x += 88
	if e.ui.toggle_button(Rect{x, y, 80, h}, if playing { '■ Stop' } else { '▶ Play' },
		playing, c_ok)
	{
		if playing {
			e.stop_play()
		} else {
			e.start_play()
		}
	}
	x += 96
	for t in [GizmoTool.move, .rotate, .scale, .anchor, .size] {
		label, key, bw := match t {
			.move { 'Move', 'W', f32(64) }
			.rotate { 'Rotate', 'E', f32(72) }
			.scale { 'Scale', 'R', f32(64) }
			.anchor { 'Anchor', 'Y', f32(74) }
			.size { 'Size', 'U', f32(60) }
		}

		if e.ui.toggle_button(Rect{x, y, bw, h}, '${label} ${key}', e.tool == t, c_select) {
			e.set_tool(t)
		}
		x += bw + 4
	}
	if e.ui.toggle_button(Rect{x, y, 70, h}, if e.tool_local { 'Local T' } else { 'Global T' },
		e.tool_local, c_select)
	{
		e.tool_local = !e.tool_local
	}
	x += 86
	e.ui.text_in(Rect{x, r.y, 300, r.h}, e.doc.title(),
		if e.doc.dirty { c_override } else { c_text }, 0)
	hint := 'Shift snap · Esc cancel · Ctrl+Z/Y · Ctrl+D dup · F frame'
	e.ui.ctx.draw_text(int(r.x + r.w - 10), int(r.y + r.h / 2), hint,
		color:          c_dim
		size:           12
		align:          .right
		vertical_align: .middle
	)
}

fn (mut e Editor) draw_status(r Rect) {
	e.ui.fill(r, c_header)
	if e.status != '' && time.ticks() - e.status_time < 8000 {
		e.ui.text_in(r, e.status, if e.status_error { c_error } else { c_ok }, 8)
	}
	info := '${e.db.len()} assets · ${e.db.loaded_count()} loaded · zoom ${int(e.zoom * 100)}%'
	e.ui.ctx.draw_text(int(r.x + r.w - 10), int(r.y + r.h / 2), info,
		color:          c_dim
		size:           12
		align:          .right
		vertical_align: .middle
	)
}
