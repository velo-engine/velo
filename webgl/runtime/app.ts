// velo.app for the WebGL runtime: the game loop (requestAnimationFrame), browser input, scaling, scene changes
// and saved data (localStorage). The same API as app/app.v: `app.new(cfg)`, `game.registry`, `game.run()`.
//
// boot(main) is what a transpiled game's entry calls: it downloads the assets first (showing progress), so
// that main() — the game's own V main — runs synchronously as on desktop.

import * as V from './v.ts'
import * as core from './core.ts'
import * as assets from './assets.ts'
import * as serialize from './serialize.ts'
import * as render from './render.ts'
import * as audio from './audio.ts'
import { Gfx } from './gfx.ts'

export class Config {
	static __vname = 'app.Config'
	title = 'Velo Engine'
	width = 960
	height = 540
	scale_mode = 'expand'
	window_width = 0
	window_height = 0
	assets_dir = 'assets'
	scene = ''
	background = core.rgba(30, 30, 40, 255)
	hot_reload = true
	font_path = ''
	app_id = ''
	save_file = ''
	// Language used when neither the saved choice nor the browser's language has a table in `locales/` (see core.Locale).
	language = 'en'
	// Pack small textures into shared pages so sprites on different textures draw as one batch (see Gfx.atlas_slot).
	atlas = true
	on_scene_loaded: ((a: App) => void) | null = null
}

class SceneFade {
	target = ''
	change = new core.SceneChange()
	alpha = 0
	fading = false
	coming = false
	web_save = 0
}

let preloaded: assets.AssetDatabase | null = null
let canvas_el: HTMLCanvasElement | null = null

export function is_mobile(): boolean {
	return typeof navigator !== 'undefined' && /Android|iPhone|iPad|iPod/i.test(navigator.userAgent)
}

export function is_web(): boolean {
	return true
}

// locale_code: 'locales/vi.txt' -> 'vi'; '' for any other asset.
function locale_code(path: string): string {
	if (!path.startsWith('locales/') || !path.endsWith('.txt')) return ''
	return path.slice('locales/'.length, -'.txt'.length)
}

export class App {
	static __vname = 'app.App'
	cfg: Config
	gfx: Gfx | null = null
	db: assets.AssetDatabase
	registry: serialize.Registry
	loader: serialize.SceneLoader
	scene: core.Scene = null as unknown as core.Scene
	input = new core.Input()
	renderer: render.Renderer = null as unknown as render.Renderer
	scene_id = ''
	fit = new core.ScreenFit()
	safe_insets = new core.Insets()
	store: core.Store
	locale = new core.Locale() // the game's texts; filled from the `locales/*.txt` assets
	keyboard_shown = false
	fade = new SceneFade()
	mode: core.ScaleMode
	last_ms = 0
	fps = 0
	safe_timer = 0
	running = false
	text_el: HTMLInputElement | null = null
	safe_probe: HTMLDivElement | null = null

	constructor(cfg: Config, db: assets.AssetDatabase) {
		this.cfg = cfg
		this.db = db
		this.mode = core.scale_mode_from_str(cfg.scale_mode)
		this.registry = serialize.new_registry()
		render.register_builtins(this.registry)
		audio.register_builtins(this.registry)
		this.loader = serialize.new_loader(this.registry, db)
		this.store = open_store(cfg)
		this.update_fit()
		this.setup_locale()
	}

	// setup_locale loads every `locales/<lang>.txt` and picks the startup language.
	setup_locale() {
		this.locale.store = this.store
		for (const e of this.db.all()) {
			if (e.kind === 'text') this.load_locale_asset(e.id)
		}
		this.locale.choose_startup_language(this.store.get_string('language', ''), this.cfg.language)
		if (this.locale.language() !== '') console.log(`[velo] language ${this.locale.language()} (${this.locale.languages().length} available)`)
	}

	load_locale_asset(id: string) {
		const path = this.db.path_of(id)
		if (path === null) return
		const code = locale_code(path)
		if (code === '') return
		let t: assets.TextAsset
		try {
			t = this.db.load<assets.TextAsset>(assets.TextAsset, id)
		} catch (e) {
			console.error(`[velo] ${path}: ${V.as_error(e).message}`)
			return
		}
		this.locale.add_table(code, t.text)
		this.db.release(id)
	}

	register(t: V.TypeDesc) {
		this.registry.register(t)
	}

	load_scene(key: string) {
		const next = this.loader.load_scene(key)
		next.input = this.input
		next.store = this.store
		next.locale = this.locale
		next.key = this.db.resolve(key) ?? key
		this.apply_fit(next)
		if (this.scene) {
			next.take_persistent(this.scene)
			this.scene.unload()
		}
		this.scene = next
		this.scene_id = next.key
		if (this.cfg.on_scene_loaded) this.cfg.on_scene_loaded(this)
		console.log(`[velo] loaded scene "${this.db.path_of(this.scene_id) ?? key}" (${this.scene.node_count()} nodes, ${this.db.loaded_count()} assets in memory)`)
	}

	run() {
		if (this.running) return
		this.running = true
		;(globalThis as any).velo = this // for the browser's developer console: velo.scene, velo.input, ...
		document.title = this.cfg.title
		const canvas = canvas_el ?? make_canvas()
		this.gfx = new Gfx(canvas)
		this.renderer = render.new_renderer(this.gfx, this.db)
		this.renderer.atlas_on = this.cfg.atlas
		audio.start()
		this.load_scene(this.cfg.scene)
		this.install_input(canvas)
		this.last_ms = performance.now()
		const frame = (now: number) => {
			if (!this.running) return
			try {
				this.frame(now)
			} catch (e) {
				this.running = false
				show_error(e)
				throw e
			}
			requestAnimationFrame(frame)
		}
		requestAnimationFrame(frame)
	}

	frame(now: number) {
		let dt = (now - this.last_ms) / 1000
		this.last_ms = now
		if (dt > 0.1) dt = 0.1
		if (dt < 0) dt = 0
		if (dt > 0) this.fps = this.fps * 0.95 + (1 / dt) * 0.05
		if (this.input.was_pressed('f1')) this.renderer.debug = !this.renderer.debug
		this.update_fit()
		this.safe_timer -= dt
		if (this.safe_timer <= 0) {
			this.safe_timer = 0.5
			this.safe_insets = this.query_safe_insets()
		}
		this.apply_fit(this.scene)
		this.scene.update(dt)
		this.sync_keyboard()
		this.input.end_frame()
		this.update_scene_change(dt)
		audio.pump()

		const gfx = this.gfx!
		const w = this.window_points()
		const bg = this.cfg.background
		gfx.begin(w.x, w.y, window.devicePixelRatio || 1, bg)
		this.renderer.base_clip = new render.Rect(this.fit.area_pos.x, this.fit.area_pos.y, this.fit.area_size.x, this.fit.area_size.y)
		this.renderer.draw_scene(this.scene, this.fit.to_window())
		this.draw_fade()
		this.draw_bars()
		if (this.renderer.debug) {
			gfx.draw_text(w.x - 10, 10, `FPS ${Math.trunc(this.fps)} | node ${this.scene.node_count()} | asset ${this.db.loaded_count()}/${this.db.len()} | draw ${gfx.draw_calls}`, {
				size: 16,
				color: core.rgba(255, 255, 0, 255),
				align: 'right',
			})
		}
		gfx.end()
		for (const ev of this.db.drain_events()) this.on_asset_event(ev)
	}

	// ---------- Scene changes ----------

	update_scene_change(dt: number) {
		const f = this.fade
		if (this.scene.next_scene !== '' && !f.fading) {
			f.target = this.scene.next_scene
			f.change = this.scene.next_change.clone()
			f.fading = true
			f.coming = false
			this.scene.next_scene = ''
		}
		if (f.fading) {
			const step = f.change.fade > 0 ? dt / f.change.fade : 1
			if (!f.coming) {
				f.alpha = Math.min(1, f.alpha + step)
				if (f.alpha >= 1) {
					try {
						this.load_scene(f.target)
					} catch (e) {
						console.error(`[velo] change_scene("${f.target}"): ${V.as_error(e).message}`)
					}
					f.coming = true
				}
			} else {
				f.alpha = Math.max(0, f.alpha - step)
				if (f.alpha <= 0) f.fading = false
			}
		}
		// a browser tab can close without warning: keep localStorage up to date
		f.web_save += dt
		if (f.web_save >= 1) {
			f.web_save = 0
			this.store.save_if_changed()
		}
	}

	draw_fade() {
		if (this.fade.alpha <= 0) return
		const c = this.fade.change.color
		const w = this.window_points()
		this.gfx!.rect(0, 0, w.x, w.y, core.rgba(c.r, c.g, c.b, Math.trunc(c.a * this.fade.alpha)))
	}

	draw_bars() {
		const w = this.window_points()
		const p = this.fit.area_pos
		const sz = this.fit.area_size
		if (p.x <= 0 && p.y <= 0 && sz.x >= w.x && sz.y >= w.y) return
		const g = this.gfx!
		g.set_scissor(0, 0, w.x, w.y)
		const black = core.rgba(0, 0, 0, 255)
		g.rect(0, 0, w.x, p.y, black)
		g.rect(0, p.y + sz.y, w.x, w.y - p.y - sz.y, black)
		g.rect(0, p.y, p.x, sz.y, black)
		g.rect(p.x + sz.x, p.y, w.x - p.x - sz.x, sz.y, black)
	}

	on_asset_event(ev: assets.AssetEvent) {
		this.renderer.on_asset_event(ev)
		if (ev.kind === 'modified' || ev.kind === 'added') this.load_locale_asset(ev.id)
		if (ev.kind === 'unloaded' || ev.kind === 'removed') audio.mixer().forget(ev.id)
	}

	// ---------- Screen ----------

	window_points(): core.Vec2 {
		const c = this.gfx?.canvas ?? canvas_el
		if (c) {
			const r = c.getBoundingClientRect()
			if (r.width > 0 && r.height > 0) return core.vec2(r.width, r.height)
		}
		return core.vec2(this.cfg.window_width > 0 ? this.cfg.window_width : this.cfg.width, this.cfg.window_height > 0 ? this.cfg.window_height : this.cfg.height)
	}

	update_fit() {
		this.fit = core.fit_screen(this.window_points(), core.vec2(this.cfg.width, this.cfg.height), this.mode)
	}

	apply_fit(s: core.Scene) {
		s.view_origin = this.fit.view_origin.clone()
		s.view_size = this.fit.view_size.clone()
		s.safe_insets = this.fit.insets_from_window(this.window_points(), this.safe_insets)
	}

	to_screen(x: number, y: number): core.Vec2 {
		return this.fit.from_window(core.vec2(x, y))
	}

	// query_safe_insets reads the page's safe area (notches, rounded corners) from CSS env(safe-area-inset-*).
	query_safe_insets(): core.Insets {
		if (!this.safe_probe) {
			const d = document.createElement('div')
			d.style.cssText =
				'position:fixed;left:0;top:0;width:0;height:0;visibility:hidden;pointer-events:none;' +
				'padding-left:env(safe-area-inset-left);padding-top:env(safe-area-inset-top);' +
				'padding-right:env(safe-area-inset-right);padding-bottom:env(safe-area-inset-bottom)'
			document.body.appendChild(d)
			this.safe_probe = d
		}
		const cs = getComputedStyle(this.safe_probe)
		return new core.Insets(parseFloat(cs.paddingLeft) || 0, parseFloat(cs.paddingTop) || 0, parseFloat(cs.paddingRight) || 0, parseFloat(cs.paddingBottom) || 0)
	}

	// ---------- Input ----------

	install_input(canvas: HTMLCanvasElement) {
		const inp = this.input
		const pos = (e: { clientX: number; clientY: number }) => {
			const r = canvas.getBoundingClientRect()
			return this.to_screen(e.clientX - r.left, e.clientY - r.top)
		}
		canvas.style.touchAction = 'none'
		canvas.tabIndex = 0
		canvas.addEventListener('contextmenu', (e) => e.preventDefault())
		canvas.addEventListener('pointerdown', (e) => {
			audio.resume()
			canvas.focus({ preventScroll: true })
			if (e.pointerType === 'mouse') {
				inp.mouse = pos(e)
				if (e.button === 0) inp.mouse_press()
			} else {
				inp.touch_begin(e.pointerId, pos(e))
			}
			try {
				canvas.setPointerCapture(e.pointerId)
			} catch {}
			e.preventDefault()
		})
		canvas.addEventListener('pointermove', (e) => {
			if (e.pointerType === 'mouse') inp.mouse = pos(e)
			else inp.touch_move(e.pointerId, pos(e))
		})
		const up = (e: PointerEvent, cancelled: boolean) => {
			if (e.pointerType === 'mouse') {
				inp.mouse = pos(e)
				if (e.button === 0) inp.mouse_release()
			} else {
				inp.touch_end(e.pointerId, pos(e), cancelled)
			}
			// a tap that focused a text field may show the phone keyboard now (it needs a user gesture)
			this.sync_keyboard(true)
		}
		canvas.addEventListener('pointerup', (e) => up(e, false))
		canvas.addEventListener('pointercancel', (e) => up(e, true))
		canvas.addEventListener(
			'wheel',
			(e) => {
				const k = e.deltaMode === 1 ? 1 : e.deltaMode === 2 ? 10 : 1 / 100
				inp.mouse_scroll(-e.deltaX * k, -e.deltaY * k)
				e.preventDefault()
			},
			{ passive: false },
		)
		window.addEventListener('keydown', (e) => {
			audio.resume()
			const key = key_name(e.code)
			const editing = this.text_el !== null && document.activeElement === this.text_el
			if (key !== '') {
				if (e.repeat) inp.key_repeat(key)
				else inp.key_down(key)
			}
			// typed characters (the hidden text field reports them itself while it has the focus)
			if (!editing && e.key.length >= 1 && [...e.key].length === 1 && !e.ctrlKey && !e.metaKey) inp.type_char(e.key.codePointAt(0)!)
			// keys that would scroll the page or move the focus belong to the game
			if (key !== '' && !e.ctrlKey && !e.metaKey && (editing ? key === 'tab' : prevent_keys.has(key))) e.preventDefault()
		})
		window.addEventListener('keyup', (e) => {
			const key = key_name(e.code)
			if (key !== '') inp.key_up(key)
		})
		window.addEventListener('blur', () => {
			// keys held when the page loses the focus never report a key up
			for (const [k, down] of inp.down) if (down) inp.key_up(k)
			if (inp.mouse_down) inp.mouse_release()
		})
		document.addEventListener('visibilitychange', () => {
			if (document.hidden) {
				audio.mixer().set_paused(true)
				this.store.save_if_changed()
			} else {
				audio.mixer().set_paused(false)
			}
		})
		window.addEventListener('pagehide', () => this.store.save_if_changed())
	}

	// sync_keyboard focuses a hidden text field while a TextInput edits, so phones show their keyboard and
	// any input method (accents, CJK) can type into the game.
	sync_keyboard(from_gesture = false) {
		const want = this.input.text_editing
		if (want === this.keyboard_shown && !(want && from_gesture && document.activeElement !== this.text_el)) return
		this.keyboard_shown = want
		if (want) {
			const el = this.text_field()
			if (document.activeElement !== el) el.focus({ preventScroll: true })
		} else if (this.text_el && document.activeElement === this.text_el) {
			this.text_el.blur()
			this.gfx?.canvas.focus({ preventScroll: true })
		}
	}

	text_field(): HTMLInputElement {
		if (this.text_el) return this.text_el
		const el = document.createElement('input')
		el.type = 'text'
		el.autocomplete = 'off'
		el.autocapitalize = 'off'
		el.spellcheck = false
		el.setAttribute('aria-hidden', 'true')
		el.style.cssText = 'position:fixed;left:0;bottom:0;width:1px;height:1px;opacity:0;border:0;padding:0;font-size:16px;pointer-events:none'
		document.body.appendChild(el)
		let composing = false
		el.addEventListener('compositionstart', () => (composing = true))
		el.addEventListener('compositionend', () => {
			composing = false
			flush()
		})
		const flush = () => {
			if (composing) return
			for (const ch of el.value) this.input.type_char(ch.codePointAt(0)!)
			el.value = ''
		}
		el.addEventListener('input', flush)
		this.text_el = el
		return el
	}
}

const prevent_keys = new Set(['space', 'up', 'down', 'left', 'right', 'tab', 'backspace', 'page_up', 'page_down', 'home', 'end', 'f1'])

const code_names: Record<string, string> = {
	Space: 'space',
	Quote: 'apostrophe',
	Comma: 'comma',
	Minus: 'minus',
	Period: 'period',
	Slash: 'slash',
	Semicolon: 'semicolon',
	Equal: 'equal',
	BracketLeft: 'left_bracket',
	Backslash: 'backslash',
	BracketRight: 'right_bracket',
	Backquote: 'grave_accent',
	Escape: 'escape',
	Enter: 'enter',
	NumpadEnter: 'enter',
	Tab: 'tab',
	Backspace: 'backspace',
	Insert: 'insert',
	Delete: 'delete',
	ArrowRight: 'right',
	ArrowLeft: 'left',
	ArrowDown: 'down',
	ArrowUp: 'up',
	PageUp: 'page_up',
	PageDown: 'page_down',
	Home: 'home',
	End: 'end',
	ShiftLeft: 'left_shift',
	ControlLeft: 'left_control',
	AltLeft: 'left_alt',
	MetaLeft: 'left_super',
	ShiftRight: 'right_shift',
	ControlRight: 'right_control',
	AltRight: 'right_alt',
	MetaRight: 'right_super',
}

// key_name maps KeyboardEvent.code to a core.Key name (the position on the keyboard, like GLFW key codes).
function key_name(code: string): string {
	const named = code_names[code]
	if (named) return named
	if (code.startsWith('Key') && code.length === 4) return code[3].toLowerCase()
	if (code.startsWith('Digit') && code.length === 6) return '_' + code[5]
	if (/^F([1-9]|1[0-2])$/.test(code)) return code.toLowerCase()
	return ''
}

// ---------- Saved data ----------

function open_store(cfg: Config): core.Store {
	const key = `${app_id_of(cfg)}/save`
	let text = ''
	try {
		text = localStorage.getItem(key) ?? ''
	} catch {}
	let st: core.Store
	try {
		st = core.Store.from_text(text)
	} catch (e) {
		console.error(`[velo] save data in localStorage: ${V.as_error(e).message} — starting empty`)
		st = new core.Store()
	}
	st.writer = (t: string) => {
		try {
			localStorage.setItem(key, t)
		} catch (e) {
			throw new V.VError(`cannot write localStorage: ${e}`)
		}
	}
	return st
}

function app_id_of(cfg: Config): string {
	if (cfg.app_id !== '') return cfg.app_id
	let out = ''
	for (const c of cfg.title.toLowerCase()) {
		if (/[a-z0-9]/.test(c)) out += c
		else if (out.length > 0 && !out.endsWith('-')) out += '-'
	}
	out = out.replace(/^-+|-+$/g, '')
	return out === '' ? 'velo-game' : out
}

// ---------- Creating the app ----------

function new_(config?: Partial<Config>): App {
	const cfg = Object.assign(new Config(), config ?? {})
	cfg.hot_reload = false
	if (preloaded === null) throw new V.VError('assets are not loaded: start the game with app.boot(main)')
	core.scale_mode_from_str(cfg.scale_mode)
	const a = new App(cfg, preloaded)
	console.log(`[velo] ${preloaded.len()} assets in ${preloaded.root}`)
	return a
}
export { new_ as new }

function make_canvas(): HTMLCanvasElement {
	let c = document.getElementById('velo-canvas') as HTMLCanvasElement | null
	if (!c) {
		c = document.createElement('canvas')
		c.id = 'velo-canvas'
		document.body.appendChild(c)
	}
	canvas_el = c
	return c
}

// ---------- Boot ----------

// boot downloads the assets (assets.json next to the page), decodes the sounds, then runs the game's main().
export async function boot(main: () => void, assets_root = 'assets') {
	const canvas = make_canvas()
	const overlay = document.getElementById('velo-loading')
	const bar = document.getElementById('velo-progress') as HTMLElement | null
	try {
		const db = await assets.preload(assets_root, (done, total) => {
			if (bar) bar.style.width = `${Math.round((done / Math.max(total, 1)) * 100)}%`
		})
		await audio.decode_all(db)
		preloaded = db
		if (overlay) overlay.style.display = 'none'
		canvas.style.display = 'block'
		main()
	} catch (e) {
		if (e instanceof V.VExit && e.status === 0) return
		show_error(e)
		throw e
	}
}

function show_error(e: unknown) {
	const msg = e instanceof V.VExit ? `exit(${e.status})` : e instanceof Error ? (e instanceof V.VPanic ? `panic: ${e.message}` : e.message) : String(e)
	console.error(e)
	let box = document.getElementById('velo-error')
	if (!box) {
		box = document.createElement('pre')
		box.id = 'velo-error'
		box.style.cssText =
			'position:fixed;left:16px;right:16px;bottom:16px;margin:0;padding:12px 14px;max-height:40vh;overflow:auto;' +
			'background:#2a1215;color:#ffb4b4;border:1px solid #7a2b33;border-radius:8px;font:13px/1.45 ui-monospace,Menlo,monospace;white-space:pre-wrap;z-index:10'
		document.body.appendChild(box)
	}
	box.textContent = msg
	const overlay = document.getElementById('velo-loading')
	if (overlay) overlay.style.display = 'none'
}
