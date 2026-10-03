module app

import gg
import sokol.sapp
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render
import velo.audio

pub struct Config {
pub:
	title string = 'Velo Engine'
	// Design resolution: the screen size the game is made for, in screen units. `scale_mode` fits it to the
	// real window / phone screen (see core.ScaleMode): expand (default), fit, fill, width, height or none.
	width      int    = 960
	height     int    = 540
	scale_mode string = 'expand'
	// Desktop window size at startup, in points; 0 = the design resolution.
	window_width  int
	window_height int
	assets_dir    string = 'assets'
	scene         string // path (within assets) or asset ID of the startup scene
	background    core.Color = core.rgba(30, 30, 40, 255)
	hot_reload    bool       = true // always off on Android/iOS
	font_path     string // .ttf used for text; empty = the platform default
	// Language used when neither the saved choice nor the system language has a table in `locales/` (see core.Locale).
	language string = 'en'
	// The developer tools: F1 overlay, F2 profiler, ` console (see core.Console). Turn off for the shipped game.
	debug_tools bool = true
	// Names the save data folder (see open_store); '' = made from the title. Keep it once the game ships.
	app_id string
	// Where to save the player's data instead of the platform's usual place (desktop and phones).
	save_file string
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
	// Where the game is drawn in the window this frame (see core.fit_screen).
	fit core.ScreenFit
	// The safe area insets in window points, refreshed twice a second (the scene gets them in screen units).
	safe_insets core.Insets
	// The player's saved data, given to every scene (scene.store); saved on quit and when sent to the background.
	store &core.Store
	// The game's texts; filled from the `locales/*.txt` assets (see core.Locale).
	locale &core.Locale = &core.Locale{}
	// `console.register('cmd', 'help', fn (args []string) string {...})` adds a console command.
	console  &core.Console  = &core.Console{}
	profiler &core.Profiler = &core.Profiler{}
mut:
	keyboard_shown bool
	fade           SceneFade
	preload        Preloader
	mode           core.ScaleMode
	last_ticks     i64
	reload_timer   f32
	fps            f32
	safe_timer     f32
}

// new opens the AssetDatabase and registers built-in components. Call app.register[T]() for the game's components,
// then app.run().
//
// On Android/iOS, assets_dir is ignored: the assets packaged by `velo build android|ios` are used instead.
pub fn new(config Config) !&App {
	cfg := Config{
		...config
		assets_dir: runtime_assets_dir(config.assets_dir)!
		hot_reload: config.hot_reload && !is_mobile() && !is_web() // packaged assets never change
	}
	mode := core.scale_mode_from_str(cfg.scale_mode)!
	setup_web_gc()
	mut db := assets.open(cfg.assets_dir)!
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	audio.register_builtins(mut reg)
	mut a := &App{
		cfg:      cfg
		db:       db
		registry: reg
		loader:   serialize.new_loader(reg, db)
		input:    &core.Input{}
		mode:     mode
		store:    open_store(cfg)
	}
	a.update_fit()
	a.setup_locale()
	a.setup_console()
	println('[velo] ${db.len()} assets in ${db.root}')
	return a
}

// setup_locale loads every `locales/<lang>.txt` and picks the startup language.
fn (mut a App) setup_locale() {
	a.locale.store = a.store
	for e in a.db.all() {
		if e.kind == .text {
			a.load_locale_asset(e.id)
		}
	}
	a.locale.choose_startup_language(a.store.get_string('language', ''), a.cfg.language)
	if a.locale.language() != '' {
		println('[velo] language ${a.locale.language()} (${a.locale.languages().len} available)')
	}
}

// locale_code: 'locales/vi.txt' -> 'vi'; '' for any other asset.
fn locale_code(path string) string {
	if !path.starts_with('locales/') || !path.ends_with('.txt') {
		return ''
	}
	return path.all_after('locales/').all_before_last('.txt')
}

fn (mut a App) load_locale_asset(id string) {
	path := a.db.path_of(id) or { return }
	code := locale_code(path)
	if code == '' {
		return
	}
	t := a.db.load[assets.TextAsset](id) or {
		eprintln('[velo] ${path}: ${err}')
		return
	}
	a.locale.add_table(code, t.text)
	a.db.release(id)
}

// register registers a game component so it can be used in .scene files.
pub fn (mut a App) register[T]() {
	a.registry.register[T]()
}

// load_scene replaces the current scene (calls on_destroy on the old scene, releases assets no longer in use).
pub fn (mut a App) load_scene(key string) ! {
	mut next := a.loader.load_scene(key)!
	next.input = a.input
	next.store = a.store
	next.locale = a.locale
	next.profiler = a.profiler
	next.key = a.db.resolve(key) or { key }
	a.apply_fit(mut next)
	if a.scene != unsafe { nil } {
		next.take_persistent(mut a.scene)
		a.scene.unload()
	}
	a.scene = next
	a.scene_id = next.key
	if a.cfg.on_scene_loaded != unsafe { nil } {
		a.cfg.on_scene_loaded(mut a)
	}
	println('[velo] loaded scene "${a.db.path_of(a.scene_id) or { key }}" (${a.scene.node_count()} nodes, ${a.db.loaded_count()} assets in memory)')
}

pub fn (mut a App) run() {
	a.ctx = gg.new_context(
		bg_color:     gg.Color{a.cfg.background.r, a.cfg.background.g, a.cfg.background.b, 255}
		width:        if a.cfg.window_width > 0 { a.cfg.window_width } else { a.cfg.width }
		height:       if a.cfg.window_height > 0 { a.cfg.window_height } else { a.cfg.height }
		window_title: a.cfg.title
		font_path:    if a.cfg.font_path != '' { a.cfg.font_path } else { system_font() }
		init_fn:      on_init
		frame_fn:     on_frame
		cleanup_fn:   on_cleanup
		event_fn:     on_event
		user_data:    a
	)
	$if android {
		// sokol asks for GLES 3.1 by default, which emulators and older devices lack; gg only needs 3.0.
		a.ctx.window.gl.major_version = 3
		a.ctx.window.gl.minor_version = 0
	}
	a.ctx.run()
}

fn on_init(mut a App) {
	a.renderer = render.new_renderer(a.ctx, a.db)
	audio.start()
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

	if a.cfg.debug_tools {
		if a.input.was_pressed(.f1) {
			a.renderer.debug = !a.renderer.debug
		}
		if a.input.was_pressed(.f2) {
			a.profiler.enabled = !a.profiler.enabled
			a.profiler.reset()
		}
	}
	a.profiler.begin('update')
	a.fit_scale()
	a.update_fit()
	a.safe_timer -= dt
	if a.safe_timer <= 0 {
		a.safe_timer = 0.5 // cheap, but not free on Android (JNI); insets only change on rotation
		if insets := query_safe_insets(a.ctx.scale) {
			if insets != a.safe_insets {
				a.safe_insets = insets
				println('[velo] safe area insets: left ${insets.left} top ${insets.top} right ${insets.right} bottom ${insets.bottom}')
			}
		}
	}
	a.apply_fit(mut a.scene)
	a.scene.update(dt)
	a.profiler.end('update')
	a.sync_keyboard()
	a.input.end_frame()
	a.preload.pump(mut a.renderer)
	a.update_scene_change(dt)
	a.scene.loading = if a.fade.fading { a.preload.progress() } else { f32(1) }
	a.profiler.begin('audio')
	audio.pump()
	a.profiler.end('audio')

	a.profiler.begin('draw')
	a.ctx.begin()
	a.renderer.base_clip =
		render.Rect{a.fit.area_pos.x, a.fit.area_pos.y, a.fit.area_size.x, a.fit.area_size.y}
	a.renderer.draw_scene(a.scene, a.fit.to_window())
	a.draw_fade()
	a.draw_bars()
	a.draw_debug_overlay()
	a.ctx.end()
	a.profiler.end('draw')
	a.profiler.new_frame(dt * 1000)

	for ev in a.db.drain_events() {
		a.on_asset_event(ev)
	}
	if a.cfg.hot_reload {
		a.reload_timer += dt
		if a.reload_timer >= 0.5 {
			a.reload_timer = 0
			a.check_hot_reload()
		}
	}
}

// sync_keyboard shows the phone's on-screen keyboard while a text field is being edited.
fn (mut a App) sync_keyboard() {
	if a.input.text_editing != a.keyboard_shown {
		a.keyboard_shown = a.input.text_editing
		$if android || ios || emscripten ? {
			sapp.show_keyboard(a.keyboard_shown)
		}
	}
}

fn on_cleanup(mut a App) {
	a.store.save_if_changed()
	a.preload.pool.close()
	audio.shutdown()
}

// SceneFade — the fade of a scene change in progress (see core.Scene.change_scene).
struct SceneFade {
mut:
	target   string
	change   core.SceneChange
	alpha    f32 // 0 = clear, 1 = covered
	fading   bool
	coming   bool // fading back in, after loading
	web_save f32
}

// update_scene_change carries out scene.change_scene: fade out (the old scene keeps running) while the textures
// and sounds of the next scene are decoded in the background (see Preloader), load it, fade in.
fn (mut a App) update_scene_change(dt f32) {
	mut f := &a.fade
	// scene.preload: decode ahead without switching; the references are dropped when a scene change finishes
	for key in a.scene.preload_requests {
		a.preload.start(mut a.db, a.renderer, key)
	}
	a.scene.preload_requests.clear()
	if a.scene.preload_cancel {
		a.scene.preload_cancel = false
		if !f.fading {
			a.preload.release(mut a.db)
		}
	}
	if a.scene.next_scene != '' && !f.fading {
		f.target = a.scene.next_scene
		f.change = a.scene.next_change
		f.fading = true
		f.coming = false
		a.scene.next_scene = ''
		a.preload.start(mut a.db, a.renderer, f.target)
	}
	if f.fading {
		step := if f.change.fade > 0 { dt / f.change.fade } else { f32(1) }
		if !f.coming {
			// a cut (fade 0) keeps showing the old scene until the new one is decoded
			if f.change.fade > 0 {
				f.alpha = if f.alpha + step > 1 { f32(1) } else { f.alpha + step }
			}
			if (f.alpha >= 1 || f.change.fade <= 0) && a.preload.done() {
				a.load_scene(f.target) or { eprintln('[velo] change_scene("${f.target}"): ${err}') }
				a.preload.release(mut a.db)
				f.coming = true
			}
		} else {
			f.alpha = if f.alpha - step < 0 { f32(0) } else { f.alpha - step }
			if f.alpha <= 0 {
				f.fading = false
			}
		}
	}
	$if emscripten ? {
		// a browser tab can close without warning: keep localStorage up to date
		f.web_save += dt
		if f.web_save >= 1 {
			f.web_save = 0
			a.store.save_if_changed()
		}
	}
}

// loading_progress: 0..1 while the next scene's assets are decoded during a scene change, else 1.
pub fn (a &App) loading_progress() f32 {
	return a.preload.progress()
}

fn (mut a App) draw_fade() {
	if a.fade.alpha <= 0 {
		return
	}
	c := a.fade.change.color
	w := a.window_points()
	a.ctx.draw_rect_filled(0, 0, w.x, w.y, gg.Color{c.r, c.g, c.b, u8(f32(c.a) * a.fade.alpha)})
	// still decoding once the screen is covered: show how far it is (white or black, whichever contrasts)
	if a.fade.change.progress && a.fade.fading && !a.fade.coming && a.fade.alpha >= 1 && !a.preload.done() {
		lum := int(c.r) + int(c.g) + int(c.b)
		v := if lum > 384 { u8(0) } else { u8(255) }
		bar_w := w.x * 0.4
		x := (w.x - bar_w) / 2
		y := w.y * 0.9
		a.ctx.draw_rect_filled(x, y, bar_w, 4, gg.Color{v, v, v, 70})
		a.ctx.draw_rect_filled(x, y, bar_w * a.preload.progress(), 4, gg.Color{v, v, v, 230})
	}
}

// on_asset_event: the renderer frees GPU images, the mixer forgets decoded sounds.
fn (mut a App) on_asset_event(ev assets.AssetEvent) {
	a.renderer.on_asset_event(ev)
	if ev.kind in [.modified, .added] {
		a.load_locale_asset(ev.id)
	}
	if ev.kind in [.unloaded, .removed] {
		mut m := audio.mixer()
		m.forget(ev.id)
	}
}

// window_points: the window size in points (the configured size until the window exists).
fn (a &App) window_points() core.Vec2 {
	if a.ctx == unsafe { nil } {
		return core.vec2(if a.cfg.window_width > 0 { a.cfg.window_width } else { a.cfg.width }, if a.cfg.window_height > 0 {
			a.cfg.window_height
		} else {
			a.cfg.height
		})
	}
	sz := a.ctx.window_size() // gg.window_size() assumes the dpi scale, which Android does not use
	return core.vec2(sz.width, sz.height)
}

// update_fit recomputes where the design resolution goes in the window (it changes when the window is resized
// or the phone rotates).
fn (mut a App) update_fit() {
	a.fit = core.fit_screen(a.window_points(), core.vec2(a.cfg.width, a.cfg.height), a.mode)
}

// apply_fit gives the scene its visible area and safe area, in screen units.
fn (a &App) apply_fit(mut s core.Scene) {
	s.view_origin = a.fit.view_origin
	s.view_size = a.fit.view_size
	s.safe_insets = a.fit.insets_from_window(a.window_points(), a.safe_insets)
}

// to_screen converts a window point (gg mouse/touch coordinates) to screen units.
fn (a &App) to_screen(x f32, y f32) core.Vec2 {
	return a.fit.from_window(core.vec2(x, y))
}

// draw_bars covers what is outside the game area (letterbox bars of the `fit` scale mode) in black.
fn (mut a App) draw_bars() {
	w := a.window_points()
	p := a.fit.area_pos
	sz := a.fit.area_size
	if p.x <= 0 && p.y <= 0 && sz.x >= w.x && sz.y >= w.y {
		return
	}
	a.ctx.scissor_rect(0, 0, int(w.x), int(w.y))
	black := gg.Color{0, 0, 0, 255}
	a.ctx.draw_rect_filled(0, 0, w.x, p.y, black)
	a.ctx.draw_rect_filled(0, p.y + sz.y, w.x, w.y - p.y - sz.y, black)
	a.ctx.draw_rect_filled(0, p.y, p.x, sz.y, black)
	a.ctx.draw_rect_filled(p.x + sz.x, p.y, w.x - p.x - sz.x, sz.y, black)
}

// fit_scale: gg's scale (framebuffer pixels per window point) comes from the configured size on Android at
// startup but from the screen density after a rotation. Pin it to the density; the scale mode does the fitting.
// Text must use the same scale, which gg forgets when it loads the font from memory (as on Android).
fn (mut a App) fit_scale() {
	$if android {
		a.ctx.scale = gg.dpi_scale()
	}
	if a.ctx.ft != unsafe { nil } && a.ctx.ft.scale != a.ctx.scale {
		a.ctx.ft.scale = a.ctx.scale
	}
}

// check_hot_reload: texture changed -> draw the new image; scene/prefab changed -> reload the current scene.
fn (mut a App) check_hot_reload() {
	events := a.db.poll_changes()
	mut reload := false
	used := a.db.dependencies_deep(a.scene_id)
	for ev in events {
		a.on_asset_event(ev)
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
	if a.cfg.debug_tools && a.console_event(e) {
		return
	}
	match e.typ {
		.key_down {
			if e.key_repeat {
				a.input.key_repeat(int(e.key_code))
			} else {
				a.input.key_down(int(e.key_code))
			}
			if e.key_code == .escape && !a.keyboard_shown { // Esc while typing leaves the text field instead
				a.ctx.quit()
			}
		}
		.char {
			a.input.type_char(e.char_code)
		}
		.key_up {
			a.input.key_up(int(e.key_code))
		}
		.mouse_move {
			a.input.mouse = a.to_screen(e.mouse_x, e.mouse_y) // gg already divides by the dpi scale
		}
		.mouse_down {
			// A click can arrive without a move before it (first click in a browser page, synthetic events).
			a.input.mouse = a.to_screen(e.mouse_x, e.mouse_y)
			if e.mouse_button == .left {
				a.input.mouse_press()
			}
		}
		.mouse_up {
			a.input.mouse = a.to_screen(e.mouse_x, e.mouse_y)
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
		.suspended, .iconified {
			mut m := audio.mixer()
			m.set_paused(true) // app in the background (phones) or minimized
			a.store.save_if_changed() // a phone may kill a background app without warning
		}
		.resumed, .restored {
			mut m := audio.mixer()
			m.set_paused(false)
		}
		else {}
	}
}

// on_touch forwards every finger that changed to Input (which also emulates the mouse with the first one).
fn (mut a App) on_touch(e &gg.Event) {
	scale := if a.ctx.scale > 0 { a.ctx.scale } else { f32(1) }
	for i in 0 .. e.num_touches {
		t := e.touches[i]
		if !t.changed {
			continue
		}
		pos := a.to_screen(t.pos_x / scale, t.pos_y / scale)
		match e.typ {
			.touches_began { a.input.touch_begin(t.identifier, pos) }
			.touches_moved { a.input.touch_move(t.identifier, pos) }
			.touches_ended { a.input.touch_end(t.identifier, pos, false) }
			else { a.input.touch_end(t.identifier, pos, true) }
		}
	}
}
