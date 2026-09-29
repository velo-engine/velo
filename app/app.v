module app

import gg
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render

pub struct Config {
pub:
	title      string = 'Velo Engine'
	width      int    = 960
	height     int    = 540
	assets_dir string = 'assets'
	scene      string // path (within assets) or asset ID of the startup scene
	background core.Color = core.rgba(30, 30, 40, 255)
	hot_reload bool       = true // always off on Android/iOS
	font_path  string // .ttf used for text; empty = the platform default
	// Set this hook to run code after each time the scene is (re)loaded.
	on_scene_loaded fn (mut a App) = unsafe { nil }
}

// App — game loop: read input -> scene.update(dt) -> draw -> check hot reload.
@[heap]
pub struct App {
pub mut:
	cfg      Config
	ctx      &gg.Context = unsafe { nil }
	db       &assets.AssetDatabase
	registry &serialize.Registry
	loader   &serialize.SceneLoader
	scene    &core.Scene = unsafe { nil }
	input    &core.Input
	renderer &render.Renderer = unsafe { nil }
	scene_id string
mut:
	last_ticks   i64
	reload_timer f32
	fps          f32
	touch_id     u64
	touching     bool
}

// new opens the AssetDatabase and registers built-in components. Call app.register[T]() for the game's components,
// then app.run().
//
// On Android/iOS, assets_dir is ignored: the assets packaged by `velo build android|ios` are used instead.
pub fn new(config Config) !&App {
	cfg := Config{
		...config
		assets_dir: runtime_assets_dir(config.assets_dir)!
		hot_reload: config.hot_reload && !is_mobile() // packaged assets never change
	}
	mut db := assets.open(cfg.assets_dir)!
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut a := &App{
		cfg:      cfg
		db:       db
		registry: reg
		loader:   serialize.new_loader(reg, db)
		input:    &core.Input{}
	}
	println('[velo] ${db.len()} assets in ${db.root}')
	return a
}

// register registers a game component so it can be used in .scene files.
pub fn (mut a App) register[T]() {
	a.registry.register[T]()
}

// load_scene replaces the current scene (calls on_destroy on the old scene, releases assets no longer in use).
pub fn (mut a App) load_scene(key string) ! {
	mut next := a.loader.load_scene(key)!
	next.input = a.input
	next.view_size = a.view_size()
	if a.scene != unsafe { nil } {
		a.scene.unload()
	}
	a.scene = next
	a.scene_id = a.db.resolve(key) or { key }
	if a.cfg.on_scene_loaded != unsafe { nil } {
		a.cfg.on_scene_loaded(mut a)
	}
	println('[velo] loaded scene "${a.db.path_of(a.scene_id) or { key }}" (${a.scene.node_count()} nodes, ${a.db.loaded_count()} assets in memory)')
}

pub fn (mut a App) run() {
	a.ctx = gg.new_context(
		bg_color:     gg.Color{a.cfg.background.r, a.cfg.background.g, a.cfg.background.b, 255}
		width:        a.cfg.width
		height:       a.cfg.height
		window_title: a.cfg.title
		font_path:    if a.cfg.font_path != '' { a.cfg.font_path } else { system_font() }
		init_fn:      on_init
		frame_fn:     on_frame
		event_fn:     on_event
		user_data:    a
	)
	a.ctx.run()
}

fn on_init(mut a App) {
	a.renderer = render.new_renderer(a.ctx, a.db)
	a.load_scene(a.cfg.scene) or {
		eprintln('[velo] scene load error: ${err}')
		exit(1)
	}
	a.last_ticks = time.ticks()
}

fn on_frame(mut a App) {
	now := time.ticks()
	mut dt := f32(now - a.last_ticks) / 1000.0
	a.last_ticks = now
	if dt > 0.1 {
		dt = 0.1 // avoid a big "jump" after dragging the window / debugging
	}
	if dt > 0 {
		a.fps = a.fps * 0.95 + (1.0 / dt) * 0.05
	}

	if a.input.was_pressed(.f1) {
		a.renderer.debug = !a.renderer.debug
	}
	a.scene.view_size = a.view_size()
	a.scene.update(dt)
	a.input.end_frame()

	a.ctx.begin()
	a.renderer.draw_scene(a.scene)
	if a.renderer.debug {
		a.ctx.draw_text(a.cfg.width - 10, 10,
			'FPS ${int(a.fps)} | node ${a.scene.node_count()} | asset ${a.db.loaded_count()}/${a.db.len()} | draw ${a.renderer.draw_calls}',
			size:  16
			color: gg.Color{255, 255, 0, 255}
			align: .right
		)
	}
	a.ctx.end()

	for ev in a.db.drain_events() {
		a.renderer.on_asset_event(ev)
	}
	if a.cfg.hot_reload {
		a.reload_timer += dt
		if a.reload_timer >= 0.5 {
			a.reload_timer = 0
			a.check_hot_reload()
		}
	}
}

// view_size: the window size in world units (the configured size until the window exists).
fn (a &App) view_size() core.Vec2 {
	if a.ctx == unsafe { nil } {
		return core.vec2(a.cfg.width, a.cfg.height)
	}
	sz := gg.window_size()
	return core.vec2(sz.width, sz.height)
}

// check_hot_reload: texture changed -> draw the new image; scene/prefab changed -> reload the current scene.
fn (mut a App) check_hot_reload() {
	events := a.db.poll_changes()
	mut reload := false
	used := a.db.dependencies_deep(a.scene_id)
	for ev in events {
		a.renderer.on_asset_event(ev)
		if ev.kind == .unloaded {
			continue
		}
		println('[hot-reload] ${ev.kind}: ${ev.path}')
		if ev.kind == .modified && (ev.id == a.scene_id || ev.id in used) {
			if e := a.db.entry(ev.id) {
				if e.kind == .scene {
					reload = true
				}
			}
		}
	}
	if reload {
		a.load_scene(a.scene_id) or {
			eprintln('[hot-reload] keeping the old scene due to error: ${err}')
		}
	}
}

fn on_event(e &gg.Event, mut a App) {
	match e.typ {
		.key_down {
			a.input.key_down(int(e.key_code))
			if e.key_code == .escape {
				a.ctx.quit()
			}
		}
		.key_up {
			a.input.key_up(int(e.key_code))
		}
		.mouse_move {
			a.input.mouse = core.vec2(e.mouse_x, e.mouse_y) // gg already divides by the dpi scale
		}
		.mouse_down {
			if e.mouse_button == .left {
				a.input.mouse_press()
			}
		}
		.mouse_up {
			if e.mouse_button == .left {
				a.input.mouse_release()
			}
		}
		.mouse_scroll {
			a.input.mouse_scroll(e.scroll_x, e.scroll_y)
		}
		.touches_began, .touches_moved, .touches_ended, .touches_cancelled {
			a.on_touch(e)
		}
		else {}
	}
}

// on_touch: on touch screens the first finger down acts as the left mouse button until it is lifted.
fn (mut a App) on_touch(e &gg.Event) {
	scale := if a.ctx.scale > 0 { a.ctx.scale } else { f32(1) }
	for i in 0 .. e.num_touches {
		t := e.touches[i]
		if !a.touching && e.typ == .touches_began && t.changed {
			a.touching = true
			a.touch_id = t.identifier
			a.input.mouse = core.vec2(t.pos_x / scale, t.pos_y / scale)
			a.input.mouse_press()
		} else if a.touching && t.identifier == a.touch_id {
			a.input.mouse = core.vec2(t.pos_x / scale, t.pos_y / scale)
			if t.changed && e.typ in [.touches_ended, .touches_cancelled] {
				a.touching = false
				a.input.mouse_release()
			}
		}
	}
}
