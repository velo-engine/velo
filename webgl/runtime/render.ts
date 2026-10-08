// velo.render for the WebGL runtime — a port of render/*.v. Components keep their V names and fields; the
// Renderer draws through Gfx (WebGL) instead of gg.

import * as V from './v.ts'
import * as core from './core.ts'
import * as assets from './assets.ts'
import * as serialize from './serialize.ts'
import { Gfx, type GfxColor, type HAlign, type VAlign } from './gfx.ts'

type FieldSpec = core.FieldSpec
const { Vec2, Affine2, vec2, rgba } = core
type Vec2 = core.Vec2
type Affine2 = core.Affine2
type Color = core.Color

// ---------- Interfaces (as runtime descriptors for get_component / `is`) ----------

export interface DebugShape {
	debug_outline(): Vec2[]
	debug_color(): Color
}
export const DebugShape = V.iface('render.DebugShape', ['debug_outline', 'debug_color'])

export interface MeshDrawable {
	meshes(): TexturedMesh[]
}
export const MeshDrawable = V.iface('render.MeshDrawable', ['meshes'])

export interface Previewable {
	preview(dt: number): void
}
export const Previewable = V.iface('render.Previewable', ['preview'])

export interface TextMeasurer {
	width(s: string, size: number): number
}
export const TextMeasurer = V.iface('render.TextMeasurer', ['width'])

// ---------- Rect ----------

export class Rect {
	static __vname = 'render.Rect'
	x = 0
	y = 0
	w = 0
	h = 0
	constructor(x = 0, y = 0, w = 0, h = 0) {
		this.x = x
		this.y = y
		this.w = w
		this.h = h
	}
	clone(): Rect {
		return new Rect(this.x, this.y, this.w, this.h)
	}
	op_eq(o: Rect): boolean {
		return this.x === o.x && this.y === o.y && this.w === o.w && this.h === o.h
	}
	has(p: Vec2): boolean {
		return p.x >= this.x && p.x <= this.x + this.w && p.y >= this.y && p.y <= this.y + this.h
	}
	intersect(o: Rect): Rect {
		const x0 = Math.max(this.x, o.x)
		const y0 = Math.max(this.y, o.y)
		const x1 = Math.min(this.x + this.w, o.x + o.w)
		const y1 = Math.min(this.y + this.h, o.y + o.h)
		return new Rect(x0, y0, Math.max(x1 - x0, 0), Math.max(y1 - y0, 0))
	}
}

// ---------- Sprite (render/components.v, render/sprite_modes.v) ----------

export class Sprite extends core.Component {
	static __vname = 'render.Sprite'
	static __fields: FieldSpec[] = [
		{ name: 'texture', type: 'asset:texture' },
		{ name: 'color', type: 'Color' },
		{ name: 'anchor', type: 'Vec2' },
		{ name: 'size', type: 'Vec2' },
		{ name: 'frame', type: 'int' },
		{ name: 'flip_x', type: 'bool' },
		{ name: 'flip_y', type: 'bool' },
		{ name: 'draw_mode', type: 'string', choices: ['simple', 'sliced', 'tiled'] },
		{ name: 'border_left', type: 'int' },
		{ name: 'border_top', type: 'int' },
		{ name: 'border_right', type: 'int' },
		{ name: 'border_bottom', type: 'int' },
		{ name: 'fill_center', type: 'bool' },
		{ name: 'pixel_scale', type: 'f32' },
		{ name: 'shader', type: 'asset:shader' },
		{ name: 'shader_params', type: 'Vec2' },
		{ name: 'shader_color', type: 'Color' },
	]
	texture = new assets.AssetRef('', assets.Texture)
	color = core.white.clone()
	anchor = new Vec2(0.5, 0.5)
	size = new Vec2()
	frame = 0
	flip_x = false
	flip_y = false
	draw_mode = 'simple'
	border_left = 0
	border_top = 0
	border_right = 0
	border_bottom = 0
	fill_center = true
	pixel_scale = 1
	shader = new assets.AssetRef('', assets.Shader)
	shader_params = new Vec2()
	shader_color = core.white.clone()
	tex: assets.Texture | null = null
	loaded = ''
	shader_data: assets.Shader | null = null

	on_load() {
		this.acquire()
		if (this.shader_data === null) this.shader_data = load_shader(this.node, this.shader)
	}
	on_destroy() {
		this.drop()
		this.shader_data = release_shader_asset(this.node, this.shader_data)
	}
	set_shader(r: assets.AssetRef) {
		this.shader_data = release_shader_asset(this.node, this.shader_data)
		this.shader = r.clone()
		this.shader_data = load_shader(this.node, this.shader)
	}
	set_texture(r: assets.AssetRef) {
		this.drop()
		this.texture = r.clone()
		this.acquire()
	}
	acquire() {
		if (!this.texture.is_set() || !this.node || !this.node.scene) return
		const db = this.node.scene.assets
		if (!db || this.loaded === this.texture.id) return
		try {
			this.tex = db.get<assets.Texture>(assets.Texture, this.texture)
		} catch (e) {
			console.error(`[Sprite] ${this.node.path()}: ${V.as_error(e).message}`)
			return
		}
		this.loaded = this.texture.id
	}
	drop() {
		if (this.loaded === '' || !this.node || !this.node.scene) return
		const db = this.node.scene.assets
		if (db) db.release(this.loaded)
		this.loaded = ''
		this.tex = null
	}
	display_size(): Vec2 {
		if (this.size.x > 0 && this.size.y > 0) return this.size.clone()
		if (this.tex === null) return new Vec2()
		return vec2(this.tex.frame_w(), this.tex.frame_h())
	}
	local_rect(): [number, number, number, number] {
		const sz = this.display_size()
		return [-this.anchor.x * sz.x, -this.anchor.y * sz.y, sz.x, sz.y]
	}
	is_sliced_mode(): boolean {
		return this.draw_mode === 'sliced' || this.draw_mode === 'tiled'
	}
	borders(): [number, number, number, number] {
		if (this.tex === null) return [0, 0, 0, 0]
		const [l, r] = clamp_pair(this.border_left, this.border_right, this.tex.frame_w())
		const [t, b] = clamp_pair(this.border_top, this.border_bottom, this.tex.frame_h())
		return [l, t, r, b]
	}
	slice_lines(): [number, number, number, number] {
		const [x, y, w, h] = this.local_rect()
		const [l, t, r, b] = this.borders()
		const scale = sprite_pixel_scale(this.pixel_scale)
		const [dl, dr] = fit_borders(l * scale, r * scale, w)
		const [dt, db] = fit_borders(t * scale, b * scale, h)
		return [x + dl, y + dt, x + w - dr, y + h - db]
	}
	quads(): SpriteQuad[] {
		if (this.tex === null) return []
		const [x, y, w, h] = this.local_rect()
		const [fx, fy, fw, fh] = this.tex.frame_rect(this.frame)
		if (!this.is_sliced_mode()) {
			return [this.flipped(x, y, w, h, { d0: 0, d1: w, s0: fx, s1: fx + fw, mid: false }, { d0: 0, d1: h, s0: fy, s1: fy + fh, mid: false })]
		}
		const [l, t, r, b] = this.borders()
		const scale = sprite_pixel_scale(this.pixel_scale)
		const tile = this.draw_mode === 'tiled'
		const xs = axis_segments(w, fx, fw, l, r, scale, tile)
		const ys = axis_segments(h, fy, fh, t, b, scale, tile)
		const out: SpriteQuad[] = []
		for (const sy of ys) {
			for (const sx of xs) {
				if (!this.fill_center && sx.mid && sy.mid) continue
				out.push(this.flipped(x, y, w, h, sx, sy))
			}
		}
		return out
	}
	flipped(x: number, y: number, w: number, h: number, sx: Seg, sy: Seg): SpriteQuad {
		let qx = x + sx.d0
		const qw = sx.d1 - sx.d0
		let u0 = sx.s0
		let u1 = sx.s1
		if (this.flip_x) {
			qx = x + w - sx.d1
			u0 = sx.s1
			u1 = sx.s0
		}
		let qy = y + sy.d0
		const qh = sy.d1 - sy.d0
		let v0 = sy.s0
		let v1 = sy.s1
		if (this.flip_y) {
			qy = y + h - sy.d1
			v0 = sy.s1
			v1 = sy.s0
		}
		return new SpriteQuad(qx, qy, qw, qh, u0, v0, u1, v1)
	}
}

export class SpriteQuad {
	static __vname = 'render.SpriteQuad'
	x = 0
	y = 0
	w = 0
	h = 0
	u0 = 0
	v0 = 0
	u1 = 0
	v1 = 0
	constructor(x = 0, y = 0, w = 0, h = 0, u0 = 0, v0 = 0, u1 = 0, v1 = 0) {
		this.x = x
		this.y = y
		this.w = w
		this.h = h
		this.u0 = u0
		this.v0 = v0
		this.u1 = u1
		this.v1 = v1
	}
	clone(): SpriteQuad {
		return new SpriteQuad(this.x, this.y, this.w, this.h, this.u0, this.v0, this.u1, this.v1)
	}
}

interface Seg {
	d0: number
	d1: number
	s0: number
	s1: number
	mid: boolean
}

const max_tiles_per_axis = 256

function clamp_pair(a: number, b: number, len: number): [number, number] {
	let x = Math.max(a, 0)
	let y = Math.max(b, 0)
	if (x + y > len) {
		x = Math.min(x, len)
		y = len - x
	}
	return [x, y]
}

function sprite_pixel_scale(v: number): number {
	return v > 0 ? v : 1
}

function fit_borders(a: number, b: number, len: number): [number, number] {
	if (a + b <= len || a + b <= 0) return [a, b]
	const k = Math.max(len, 0) / (a + b)
	return [a * k, b * k]
}

function axis_segments(len: number, start: number, src_len: number, b0: number, b1: number, scale: number, tile: boolean): Seg[] {
	const out: Seg[] = []
	if (len <= 0 || src_len <= 0) return out
	const [d0, d1] = fit_borders(b0 * scale, b1 * scale, len)
	const s = start
	const e = start + src_len
	if (d0 > 0) out.push({ d0: 0, d1: d0, s0: s, s1: s + b0, mid: false })
	const mid_src0 = s + b0
	const mid_src1 = e - b1
	const mid_len = len - d0 - d1
	if (mid_len > 0 && mid_src1 > mid_src0) {
		if (tile) {
			let step = (mid_src1 - mid_src0) * scale
			if (mid_len / step > max_tiles_per_axis) step = mid_len / max_tiles_per_axis
			let p = d0
			const end = len - d1
			while (p < end - 0.001) {
				const q = Math.min(p + step, end)
				out.push({ d0: p, d1: q, s0: mid_src0, s1: mid_src0 + ((mid_src1 - mid_src0) * (q - p)) / step, mid: true })
				p = q
			}
		} else {
			out.push({ d0, d1: len - d1, s0: mid_src0, s1: mid_src1, mid: true })
		}
	}
	if (d1 > 0) out.push({ d0: len - d1, d1: len, s0: e - b1, s1: e, mid: false })
	return out
}

// ---------- SpriteAnimator ----------

export class SpriteAnimator extends core.Component {
	static __vname = 'render.SpriteAnimator'
	static __fields: FieldSpec[] = [
		{ name: 'fps', type: 'f32' },
		{ name: 'playing', type: 'bool' },
		{ name: 'looping', type: 'bool' },
		{ name: 'first_frame', type: 'int' },
		{ name: 'frame_count', type: 'int' },
	]
	fps = 10
	playing = true
	looping = true
	first_frame = 0
	frame_count = 0
	time = 0

	update(dt: number) {
		const sprite = this.node.get_component<Sprite>(Sprite)
		if (sprite === null || sprite.tex === null || !this.playing) return
		const total = this.frame_count > 0 ? this.frame_count : sprite.tex.frame_count() - this.first_frame
		if (total <= 0) return
		this.time += dt
		let idx = Math.trunc(this.time * this.fps)
		if (this.looping) idx = idx % total
		else if (idx >= total) {
			idx = total - 1
			this.playing = false
		}
		sprite.frame = this.first_frame + idx
	}
}

// ---------- Text (render/text_layout.v) ----------

export class TextBlock {
	static __vname = 'render.TextBlock'
	lines: string[] = []
	size = 0
	line_height = 0
	clone(): TextBlock {
		const b = new TextBlock()
		b.lines = this.lines.slice()
		b.size = this.size
		b.line_height = this.line_height
		return b
	}
	height(): number {
		if (this.lines.length === 0) return 0
		return (this.lines.length - 1) * this.line_height + this.size
	}
}

export function wrap_lines(text: string, max_width: number, size: number, m: TextMeasurer): string[] {
	const out: string[] = []
	for (const para of text.split('\n')) {
		if (max_width <= 0 || m.width(para, size) <= max_width) {
			out.push(para)
			continue
		}
		let line = ''
		for (const word of para.split(' ')) {
			const candidate = line === '' ? word : line + ' ' + word
			if (m.width(candidate, size) <= max_width) {
				line = candidate
				continue
			}
			if (line !== '') {
				out.push(line)
				line = ''
			}
			if (m.width(word, size) <= max_width) {
				line = word
				continue
			}
			let piece = ''
			for (const r of word) {
				const next = piece + r
				if (piece !== '' && m.width(next, size) > max_width) {
					out.push(piece)
					piece = r
				} else {
					piece = next
				}
			}
			line = piece
		}
		out.push(line)
	}
	return out
}

export function layout_text(text: string, size: number, spacing: number, wrap: boolean, shrink: boolean, box_w: number, box_h: number, min_size: number, m: TextMeasurer): TextBlock {
	let s = size
	for (;;) {
		const block = new TextBlock()
		block.lines = wrap_lines(text, wrap ? box_w : 0, s, m)
		block.size = s
		block.line_height = s * spacing
		if (!shrink || s <= min_size || fits(block, box_w, box_h, m)) return block
		s = s - 1 < min_size ? min_size : s - 1
	}
}

function fits(b: TextBlock, w: number, h: number, m: TextMeasurer): boolean {
	if (h > 0 && b.height() > h) return false
	if (w > 0) for (const l of b.lines) if (m.width(l, b.size) > w) return false
	return true
}

// ---------- Label ----------

export class Label extends core.Component {
	static __vname = 'render.Label'
	static __fields: FieldSpec[] = [
		{ name: 'text', type: 'string' },
		{ name: 'size', type: 'int' },
		{ name: 'color', type: 'Color' },
		{ name: 'align', type: 'string', choices: ['left', 'center', 'right'] },
		{ name: 'valign', type: 'string', choices: ['top', 'middle', 'bottom'] },
		{ name: 'font', type: 'asset:font' },
		{ name: 'wrap', type: 'bool' },
		{ name: 'shrink', type: 'bool' },
		{ name: 'line_spacing', type: 'f32' },
		{ name: 'shadow_color', type: 'Color' },
		{ name: 'shadow_offset', type: 'Vec2' },
		{ name: 'outline_color', type: 'Color' },
		{ name: 'outline_width', type: 'f32' },
	]
	text = ''
	size = 20
	color = core.white.clone()
	align = 'left'
	valign = 'top'
	font = new assets.AssetRef('', assets.Font)
	wrap = false
	shrink = false
	line_spacing = 1.25
	shadow_color = rgba(0, 0, 0, 0)
	shadow_offset = new Vec2(2, 2)
	outline_color = rgba(0, 0, 0, 0)
	outline_width = 1.5
	font_data: assets.Font | null = null
	layout_key = ''
	layout = new TextBlock()

	on_load() {
		this.font_data = load_font(this.node, this.font)
	}
	on_destroy() {
		this.font_data = release_font(this.node, this.font_data)
	}
	set_font(r: assets.AssetRef) {
		this.font_data = release_font(this.node, this.font_data)
		this.font = r.clone()
		this.font_data = load_font(this.node, r)
	}
	text_point(): Vec2 {
		const t = this.node.get_component<UITransform>(UITransform)
		if (t === null) return new Vec2()
		const r = t.rect()
		const x = this.align === 'center' ? r.x + r.w / 2 : this.align === 'right' ? r.x + r.w : r.x
		const y = this.valign === 'middle' ? r.y + r.h / 2 : this.valign === 'bottom' ? r.y + r.h : r.y
		return vec2(x, y)
	}
}

function load_font(n: core.Node, r: assets.AssetRef): assets.Font | null {
	if (!r.is_set() || !n || !n.scene || !n.scene.assets) return null
	try {
		return n.scene.assets.get<assets.Font>(assets.Font, r)
	} catch (e) {
		console.error(`[render] ${n.path()}: ${V.as_error(e).message}`)
		return null
	}
}

function release_font(n: core.Node, f: assets.Font | null): assets.Font | null {
	if (f !== null && n && n.scene && n.scene.assets) n.scene.assets.release(f.id)
	return null
}

function load_shader(n: core.Node, r: assets.AssetRef): assets.Shader | null {
	if (!r.is_set() || !n || !n.scene || !n.scene.assets) return null
	try {
		return n.scene.assets.get<assets.Shader>(assets.Shader, r)
	} catch (e) {
		console.error(`[render] ${n.path()}: ${V.as_error(e).message}`)
		return null
	}
}

function release_shader_asset(n: core.Node, s: assets.Shader | null): assets.Shader | null {
	if (s !== null && n && n.scene && n.scene.assets) n.scene.assets.release(s.id)
	return null
}

// shader_time: TIME for a node — the scene's game time, or its real time under an `unscaled_time` node.
export function shader_time(n: core.Node): number {
	if (!n || !n.scene) return 0
	for (let p: core.Node | null = n; p; p = p.parent) if (p.unscaled_time) return n.scene.real_time
	return n.scene.time
}

function font_family(f: assets.Font | null): string {
	return f !== null ? f.family : ''
}

// ---------- TextInput (render/text_input.v) ----------

export class TextInput extends core.Component {
	static __vname = 'render.TextInput'
	static __fields: FieldSpec[] = [
		{ name: 'text', type: 'string' },
		{ name: 'placeholder', type: 'string' },
		{ name: 'size', type: 'int' },
		{ name: 'color', type: 'Color' },
		{ name: 'placeholder_color', type: 'Color' },
		{ name: 'caret_color', type: 'Color' },
		{ name: 'font', type: 'asset:font' },
		{ name: 'max_length', type: 'int' },
		{ name: 'password', type: 'bool' },
		{ name: 'padding', type: 'f32' },
		{ name: 'blur_on_submit', type: 'bool' },
	]
	text = ''
	placeholder = ''
	size = 20
	color = core.white.clone()
	placeholder_color = rgba(255, 255, 255, 110)
	caret_color = rgba(255, 255, 255, 230)
	font = new assets.AssetRef('', assets.Font)
	max_length = 0
	password = false
	padding = 8
	blur_on_submit = true
	focused = false
	changed = false
	submitted = false
	caret = 0
	blink = 0
	scroll = 0
	font_data: assets.Font | null = null

	on_load() {
		this.font_data = load_font(this.node, this.font)
		this.caret = [...this.text].length
	}
	on_destroy() {
		this.blur()
		this.font_data = release_font(this.node, this.font_data)
	}
	focus() {
		if (this.focused) return
		this.focused = true
		this.caret = [...this.text].length
		this.blink = 0
	}
	blur() {
		if (!this.focused) return
		this.focused = false
	}
	update(_dt: number) {
		this.changed = false
		this.submitted = false
		const input = this.input()
		for (const p of input.pointers()) {
			if (p.phase === 'began') {
				if (ui_hit(this.node, p.pos)) this.focus()
				else this.blur()
			}
		}
		if (!this.focused) return
		input.text_editing = true
		this.blink += this.scene().unscaled_dt
		const runes = [...this.text]
		this.caret = this.caret < 0 ? 0 : this.caret > runes.length ? runes.length : this.caret
		const before = this.text
		if (input.text !== '') {
			for (const r of input.text) {
				if (this.max_length > 0 && runes.length >= this.max_length) break
				runes.splice(this.caret, 0, r)
				this.caret++
			}
		}
		if (input.was_typed('backspace') && this.caret > 0) {
			runes.splice(this.caret - 1, 1)
			this.caret--
		}
		if (input.was_typed('delete') && this.caret < runes.length) runes.splice(this.caret, 1)
		if (input.was_typed('left') && this.caret > 0) this.caret--
		if (input.was_typed('right') && this.caret < runes.length) this.caret++
		if (input.was_pressed('home')) this.caret = 0
		if (input.was_pressed('end')) this.caret = runes.length
		this.text = runes.join('')
		if (this.text !== before || input.text !== '' || input.was_typed('left') || input.was_typed('right')) this.blink = 0
		this.changed = this.text !== before
		if (input.was_pressed('enter')) {
			this.submitted = true
			if (this.blur_on_submit) this.blur()
		}
		if (input.was_pressed('escape')) this.blur()
	}
	shown(): string {
		return this.password ? '*'.repeat([...this.text].length) : this.text
	}
	caret_visible(): boolean {
		return this.focused && Math.trunc(this.blink * 2) % 2 === 0
	}
	update_scroll(caret_x: number, text_w: number, inner: number): number {
		if (caret_x - this.scroll > inner) this.scroll = caret_x - inner
		if (caret_x < this.scroll) this.scroll = caret_x
		const max_scroll = text_w > inner ? text_w - inner : 0
		if (this.scroll > max_scroll) this.scroll = max_scroll
		if (this.scroll < 0) this.scroll = 0
		return this.scroll
	}
}

// ---------- UI (render/ui.v) ----------

export class UITransform extends core.Component {
	static __vname = 'render.UITransform'
	static __fields: FieldSpec[] = [
		{ name: 'size', type: 'Vec2' },
		{ name: 'anchor', type: 'Vec2' },
	]
	size = new Vec2(100, 100)
	anchor = new Vec2(0.5, 0.5)
	rect(): Rect {
		return new Rect(-this.anchor.x * this.size.x, -this.anchor.y * this.size.y, this.size.x, this.size.y)
	}
}

export function node_rect(n: core.Node): Rect | null {
	const t = n.get_component<UITransform>(UITransform)
	if (t !== null) return t.rect()
	const s = n.get_component<Sprite>(Sprite)
	if (s !== null) {
		const [x, y, w, h] = s.local_rect()
		if (w > 0 && h > 0) return new Rect(x, y, w, h)
	}
	const tm = n.get_component<TileMap>(TileMap)
	if (tm !== null) {
		const [x, y, w, h] = tm.local_rect()
		if (w > 0 && h > 0) return new Rect(x, y, w, h)
	}
	return null
}

export function hit_test(n: core.Node, p: Vec2): boolean {
	return hit_test_in(n, p, true)
}

export function hit_test_world(n: core.Node, p: Vec2): boolean {
	return hit_test_in(n, p, false)
}

function hit_test_in(n: core.Node, p: Vec2, screen: boolean): boolean {
	const r = node_rect(n)
	if (r === null || !r.has(node_point(n, p, screen))) return false
	let cur = n.parent
	while (cur !== null) {
		const sv = cur.get_component<ScrollView>(ScrollView)
		if (sv !== null && sv.enabled && sv.clip) {
			const vr = node_rect(cur) ?? new Rect()
			if (!vr.has(node_point(cur, p, screen))) return false
		}
		cur = cur.parent
	}
	return true
}

function node_point(n: core.Node, p: Vec2, screen: boolean): Vec2 {
	const m = screen ? n.screen_matrix() : n.world_matrix()
	return m.inverse().apply(p)
}

const pointer_cache = { scene: null as core.Scene | null, frame: -1, targets: [] as core.Node[] }

function is_pointer_target(n: core.Node): boolean {
	for (const c of n.components) {
		if (!c.enabled) continue
		if (c instanceof Button || c instanceof ScrollView || c instanceof Joystick || c instanceof TextInput) return true
		if (c instanceof Panel && c.block_input) return true
	}
	return false
}

function pointer_targets(sc: core.Scene): core.Node[] {
	const pc = pointer_cache
	if (pc.scene !== sc || pc.frame !== sc.frame) {
		pc.scene = sc
		pc.frame = sc.frame
		pc.targets = draw_order(sc.root).filter(is_pointer_target)
	}
	return pc.targets
}

export function pointer_target(sc: core.Scene, p: Vec2): core.Node | null {
	const targets = pointer_targets(sc)
	for (let i = targets.length - 1; i >= 0; i--) {
		const n = targets[i]
		if (!n.destroyed && hit_test(n, p)) return n
	}
	return null
}

export function pointer_over_ui(sc: core.Scene, p: Vec2): boolean {
	return pointer_target(sc, p) !== null
}

export function ui_hit(n: core.Node, p: Vec2): boolean {
	if (!hit_test(n, p)) return false
	if (!n.scene) return true
	const t = pointer_target(n.scene, p)
	if (t === null) return true
	return t === n || n.is_ancestor_of(t)
}

function in_dragged_scroll_view(n: core.Node): boolean {
	let cur = n.parent
	while (cur !== null) {
		const sv = cur.get_component<ScrollView>(ScrollView)
		if (sv !== null && sv.dragging) return true
		cur = cur.parent
	}
	return false
}

export function mul_color(a: Color, b: Color): Color {
	return new core.Color(Math.trunc((a.r * b.r) / 255), Math.trunc((a.g * b.g) / 255), Math.trunc((a.b * b.b) / 255), Math.trunc((a.a * b.a) / 255))
}

export class Panel extends core.Component {
	static __vname = 'render.Panel'
	static __fields: FieldSpec[] = [
		{ name: 'color', type: 'Color' },
		{ name: 'radius', type: 'f32' },
		{ name: 'border_color', type: 'Color' },
		{ name: 'border_width', type: 'int' },
		{ name: 'block_input', type: 'bool' },
	]
	color = rgba(60, 60, 72, 255)
	radius = 0
	border_color = rgba(255, 255, 255, 80)
	border_width = 0
	block_input = true
}

export type ClickHandler = (b: Button) => void

export class Button extends core.Component {
	static __vname = 'render.Button'
	static __fields: FieldSpec[] = [
		{ name: 'interactable', type: 'bool' },
		{ name: 'target', type: 'string' },
		{ name: 'normal_color', type: 'Color' },
		{ name: 'hover_color', type: 'Color' },
		{ name: 'pressed_color', type: 'Color' },
		{ name: 'disabled_color', type: 'Color' },
	]
	interactable = true
	target = ''
	normal_color = core.white.clone()
	hover_color = rgba(225, 225, 225, 255)
	pressed_color = rgba(170, 170, 170, 255)
	disabled_color = rgba(140, 140, 140, 180)
	hovered = false
	pressed = false
	pointer = 0
	clicked = false
	handlers: ClickHandler[] = []
	base_color = new core.Color()
	has_base = false

	on_click(f: ClickHandler) {
		this.handlers.push(f)
	}
	on_destroy() {
		this.set_tint(core.white)
		this.has_base = false
	}
	update(_dt: number) {
		this.clicked = false
		if (!this.interactable) {
			this.hovered = false
			this.pressed = false
			this.set_tint(this.disabled_color)
			return
		}
		const input = this.input()
		this.hovered = ui_hit(this.node, input.mouse)
		if (!this.pressed) {
			for (const p of input.pointers()) {
				if (p.phase === 'began' && ui_hit(this.node, p.pos)) {
					this.pressed = true
					this.pointer = p.id
					break
				}
			}
		}
		if (this.pressed && in_dragged_scroll_view(this.node)) this.pressed = false
		let inside = false
		if (this.pressed) {
			const p = input.pointer(this.pointer)
			if (p !== null) {
				inside = ui_hit(this.node, p.pos)
				if (p.is_up()) {
					this.pressed = false
					if (inside && p.phase === 'ended') {
						this.clicked = true
						for (const h of this.handlers) h(this)
					}
				}
			} else {
				this.pressed = false
			}
		}
		this.set_tint(this.pressed && inside ? this.pressed_color : this.hovered || inside ? this.hover_color : this.normal_color)
	}
	set_tint(c: Color) {
		if (!this.node) return
		const target = this.target === '' ? this.node : this.node.find(this.target)
		if (target === null) return
		const p = target.get_component<Panel>(Panel)
		if (p !== null) {
			if (!this.has_base) {
				this.base_color = p.color.clone()
				this.has_base = true
			}
			p.color = mul_color(this.base_color, c)
			return
		}
		const s = target.get_component<Sprite>(Sprite)
		if (s !== null) {
			if (!this.has_base) {
				this.base_color = s.color.clone()
				this.has_base = true
			}
			s.color = mul_color(this.base_color, c)
		}
	}
}

export class Toggle extends core.Component {
	static __vname = 'render.Toggle'
	static __fields: FieldSpec[] = [
		{ name: 'is_on', type: 'bool' },
		{ name: 'checkmark', type: 'string' },
	]
	is_on = false
	checkmark = 'Checkmark'
	changed = false
	on_load() {
		this.sync()
	}
	update(_dt: number) {
		this.changed = false
		const btn = this.node.get_component<Button>(Button)
		if (btn !== null && btn.clicked) {
			this.is_on = !this.is_on
			this.changed = true
		}
		this.sync()
	}
	sync() {
		if (!this.node) return
		const c = this.node.find(this.checkmark)
		if (c !== null) c.active = this.is_on
	}
}

export class ProgressBar extends core.Component {
	static __vname = 'render.ProgressBar'
	static __fields: FieldSpec[] = [
		{ name: 'progress', type: 'f32' },
		{ name: 'direction', type: 'string', choices: ['horizontal', 'vertical'] },
		{ name: 'reverse', type: 'bool' },
		{ name: 'fill_color', type: 'Color' },
		{ name: 'back_color', type: 'Color' },
		{ name: 'radius', type: 'f32' },
	]
	progress = 0.5
	direction = 'horizontal'
	reverse = false
	fill_color = rgba(90, 200, 120, 255)
	back_color = rgba(0, 0, 0, 120)
	radius = 0
	fill_rect(r: Rect): Rect {
		const k = clamp01(this.progress)
		if (this.direction === 'vertical') {
			const h = r.h * k
			return this.reverse ? new Rect(r.x, r.y, r.w, h) : new Rect(r.x, r.y + r.h - h, r.w, h)
		}
		const w = r.w * k
		return this.reverse ? new Rect(r.x + r.w - w, r.y, w, r.h) : new Rect(r.x, r.y, w, r.h)
	}
}

export class ScrollView extends core.Component {
	static __vname = 'render.ScrollView'
	static __fields: FieldSpec[] = [
		{ name: 'content', type: 'string' },
		{ name: 'horizontal', type: 'bool' },
		{ name: 'vertical', type: 'bool' },
		{ name: 'clip', type: 'bool' },
		{ name: 'inertia', type: 'bool' },
		{ name: 'deceleration', type: 'f32' },
		{ name: 'elastic', type: 'bool' },
		{ name: 'wheel_speed', type: 'f32' },
	]
	content = 'Content'
	horizontal = false
	vertical = true
	clip = true
	inertia = true
	deceleration = 4
	elastic = true
	wheel_speed = 40
	dragging = false
	velocity = new Vec2()
	tracking = false
	press_pos = new Vec2()
	last_pos = new Vec2()

	content_node(): core.Node | null {
		return this.node.find(this.content)
	}
	update(dt: number) {
		const content = this.content_node()
		if (content === null) return
		const view = node_rect(this.node)
		if (view === null) return
		const input = this.input()
		const local = this.node.screen_matrix().inverse().apply(input.mouse)
		const inside = ui_hit(this.node, input.mouse)
		if (input.mouse_pressed && inside) {
			this.tracking = true
			this.press_pos = local.clone()
			this.last_pos = local.clone()
			this.velocity = new Vec2()
		}
		if (this.tracking && input.mouse_down) {
			if (!this.dragging && local.distance(this.press_pos) > 6) this.dragging = true
			if (this.dragging) {
				const d = this.mask(local.op_sub(this.last_pos))
				this.last_pos = local.clone()
				this.move_content(content, view, d)
				if (dt > 0) this.velocity = this.velocity.lerp(d.mul(1 / dt), 0.5)
			}
		} else if (this.tracking) {
			this.tracking = false
			this.dragging = false
			if (!this.inertia) this.velocity = new Vec2()
		}
		if (inside && (input.scroll.x !== 0 || input.scroll.y !== 0)) {
			let d = vec2(input.scroll.x, input.scroll.y).mul(this.wheel_speed)
			if (!this.vertical && d.x === 0) d = vec2(d.y, 0)
			this.velocity = new Vec2()
			this.move_content(content, view, this.mask(d))
			this.clamp_content(content, view, 1)
			return
		}
		if (this.dragging) return
		if (this.velocity.length() > 1) {
			this.move_content(content, view, this.velocity.mul(dt))
			this.velocity = this.velocity.mul(Math.exp(-this.deceleration * dt))
		} else {
			this.velocity = new Vec2()
		}
		const k = this.elastic ? Math.min(1, 12 * dt) : 1
		if (this.clamp_content(content, view, k)) this.velocity = new Vec2()
	}
	mask(d: Vec2): Vec2 {
		return vec2(this.horizontal ? d.x : 0, this.vertical ? d.y : 0)
	}
	overflow(content: core.Node, view: Rect): Vec2 {
		const cr = node_rect(content)
		if (cr === null) return new Vec2()
		const sx = Math.abs(content.scale.x)
		const sy = Math.abs(content.scale.y)
		const left = content.position.x + cr.x * sx
		const top = content.position.y + cr.y * sy
		return vec2(range_overflow(left, view.x, view.w, cr.w * sx), range_overflow(top, view.y, view.h, cr.h * sy))
	}
	move_content(content: core.Node, view: Rect, d: Vec2) {
		const step = d.clone()
		if (this.dragging && this.elastic) {
			const o = this.overflow(content, view)
			if (o.x * d.x > 0) step.x *= 0.4
			if (o.y * d.y > 0) step.y *= 0.4
		}
		content.position = content.position.op_add(step)
		if (!this.elastic) this.clamp_content(content, view, 1)
	}
	clamp_content(content: core.Node, view: Rect, k: number): boolean {
		const o = this.overflow(content, view)
		if (o.x === 0 && o.y === 0) return false
		const fix = o.mul(-k)
		if (Math.abs(o.x) < 0.5) fix.x = -o.x
		if (Math.abs(o.y) < 0.5) fix.y = -o.y
		content.position = content.position.op_add(fix)
		return true
	}
	scroll_to_top() {
		const content = this.content_node()
		const view = node_rect(this.node)
		if (content === null || view === null) return
		const cr = node_rect(content)
		if (cr === null) return
		content.position.y = view.y - cr.y * Math.abs(content.scale.y)
		this.velocity = new Vec2()
	}
	scroll_to_bottom() {
		const content = this.content_node()
		const view = node_rect(this.node)
		if (content === null || view === null) return
		const cr = node_rect(content)
		if (cr === null) return
		const sy = Math.abs(content.scale.y)
		content.position.y = view.y + Math.min(view.h - cr.h * sy, 0) - cr.y * sy
		this.velocity = new Vec2()
	}
}

function range_overflow(start: number, view_start: number, view_len: number, len: number): number {
	const hi = view_start
	const lo = len > view_len ? view_start + view_len - len : view_start
	if (start > hi) return start - hi
	if (start < lo) return start - lo
	return 0
}

export class Joystick extends core.Component {
	static __vname = 'render.Joystick'
	static __fields: FieldSpec[] = [
		{ name: 'radius', type: 'f32' },
		{ name: 'dead_zone', type: 'f32' },
		{ name: 'floating', type: 'bool' },
		{ name: 'base', type: 'string' },
		{ name: 'knob', type: 'string' },
	]
	radius = 50
	dead_zone = 0.1
	floating = true
	base = 'Base'
	knob = 'Base/Knob'
	value = new Vec2()
	held = false
	pointer = 0
	rest = new Vec2()
	has_rest = false

	start() {
		const base = this.node.find(this.base)
		if (base !== null) {
			this.rest = base.position.clone()
			this.has_rest = true
		}
	}
	on_destroy() {
		this.release()
	}
	update(_dt: number) {
		const input = this.input()
		if (!this.held) {
			for (const p of input.pointers()) {
				if (p.phase === 'began' && ui_hit(this.node, p.pos)) {
					this.held = true
					this.pointer = p.id
					if (this.floating) {
						const base = this.node.find(this.base)
						if (base !== null) base.position = this.to_local(p.pos)
					}
					break
				}
			}
		}
		if (!this.held) return
		const p = input.pointer(this.pointer)
		if (p === null || p.is_up()) {
			this.release()
			return
		}
		const base = this.node.find(this.base)
		const center = base !== null ? base.position.clone() : new Vec2()
		let d = this.to_local(p.pos).op_sub(center)
		if (this.radius > 0 && d.length() > this.radius) d = d.normalized().mul(this.radius)
		const knob = this.node.find(this.knob)
		if (knob !== null) knob.position = d.clone()
		const v = this.radius > 0 ? d.mul(1 / this.radius) : new Vec2()
		this.value = v.length() < this.dead_zone ? new Vec2() : v
	}
	release() {
		this.held = false
		this.value = new Vec2()
		if (!this.node) return
		const knob = this.node.find(this.knob)
		if (knob !== null) knob.position = new Vec2()
		if (this.floating && this.has_rest) {
			const base = this.node.find(this.base)
			if (base !== null) base.position = this.rest.clone()
		}
	}
	to_local(p: Vec2): Vec2 {
		return this.node.screen_matrix().inverse().apply(p)
	}
}

export class Widget extends core.Component {
	static __vname = 'render.Widget'
	static __fields: FieldSpec[] = [
		{ name: 'align_left', type: 'bool' },
		{ name: 'left', type: 'f32' },
		{ name: 'align_right', type: 'bool' },
		{ name: 'right', type: 'f32' },
		{ name: 'align_top', type: 'bool' },
		{ name: 'top', type: 'f32' },
		{ name: 'align_bottom', type: 'bool' },
		{ name: 'bottom', type: 'f32' },
		{ name: 'align_center_x', type: 'bool' },
		{ name: 'center_x', type: 'f32' },
		{ name: 'align_center_y', type: 'bool' },
		{ name: 'center_y', type: 'f32' },
		{ name: 'always', type: 'bool' },
		{ name: 'safe_area', type: 'bool' },
	]
	align_left = false
	left = 0
	align_right = false
	right = 0
	align_top = false
	top = 0
	align_bottom = false
	bottom = 0
	align_center_x = false
	center_x = 0
	align_center_y = false
	center_y = 0
	always = true
	safe_area = true

	start() {
		this.align()
	}
	update(_dt: number) {
		if (this.always) this.align()
	}
	parent_rect(): Rect | null {
		const p = this.node.parent
		if (p === null) return null
		const r = node_rect(p)
		if (r !== null) return r
		if (!this.node.scene) return null
		const inv = p.screen_matrix().inverse()
		const sc = this.node.scene
		const ins = this.safe_area ? sc.safe_insets : new core.Insets()
		const o = sc.view_origin
		const a = inv.apply(vec2(o.x + ins.left, o.y + ins.top))
		const b = inv.apply(vec2(o.x + sc.view_size.x - ins.right, o.y + sc.view_size.y - ins.bottom))
		return new Rect(Math.min(a.x, b.x), Math.min(a.y, b.y), Math.abs(b.x - a.x), Math.abs(b.y - a.y))
	}
	align() {
		const pr = this.parent_rect()
		if (pr === null) return
		const n = this.node
		let anchor = new Vec2(0.5, 0.5)
		let size = new Vec2()
		const t = n.get_component<UITransform>(UITransform)
		if (t !== null) {
			anchor = t.anchor.clone()
			size = t.size.clone()
		}
		const sx = Math.abs(n.scale.x)
		const sy = Math.abs(n.scale.y)
		if (this.align_left && this.align_right && sx > 0) size.x = Math.max((pr.w - this.left - this.right) / sx, 0)
		if (this.align_top && this.align_bottom && sy > 0) size.y = Math.max((pr.h - this.top - this.bottom) / sy, 0)
		if (t !== null) t.size = size.clone()
		if (this.align_left) n.position.x = pr.x + this.left + anchor.x * size.x * sx
		else if (this.align_right) n.position.x = pr.x + pr.w - this.right - (1 - anchor.x) * size.x * sx
		else if (this.align_center_x) n.position.x = pr.x + pr.w / 2 + this.center_x + (anchor.x - 0.5) * size.x * sx
		if (this.align_top) n.position.y = pr.y + this.top + anchor.y * size.y * sy
		else if (this.align_bottom) n.position.y = pr.y + pr.h - this.bottom - (1 - anchor.y) * size.y * sy
		else if (this.align_center_y) n.position.y = pr.y + pr.h / 2 + this.center_y + (anchor.y - 0.5) * size.y * sy
	}
}

export class Layout extends core.Component {
	static __vname = 'render.Layout'
	static __fields: FieldSpec[] = [
		{ name: 'kind', type: 'string', choices: ['vertical', 'horizontal', 'grid'] },
		{ name: 'spacing', type: 'Vec2' },
		{ name: 'padding', type: 'f32' },
		{ name: 'child_align', type: 'string', choices: ['start', 'center', 'end'] },
		{ name: 'columns', type: 'int' },
		{ name: 'resize', type: 'bool' },
	]
	kind = 'vertical'
	spacing = new Vec2(8, 8)
	padding = 0
	child_align = 'start'
	columns = 0
	resize = true

	update(_dt: number) {
		this.arrange()
	}
	arrange() {
		const items: { node: core.Node; r: Rect }[] = []
		for (const ch of this.node.children) {
			if (!ch.active || ch.destroyed) continue
			const r = node_rect(ch)
			if (r === null) continue
			const sx = Math.abs(ch.scale.x)
			const sy = Math.abs(ch.scale.y)
			items.push({ node: ch, r: new Rect(r.x * sx, r.y * sy, r.w * sx, r.h * sy) })
		}
		let own = node_rect(this.node) ?? new Rect()
		const pad = this.padding
		if (this.kind === 'horizontal') {
			let total = pad * 2
			items.forEach((it, i) => (total += it.r.w + (i > 0 ? this.spacing.x : 0)))
			own = this.fit(own, total, -1)
			let x = own.x + pad
			for (const it of items) {
				it.node.position.x = x - it.r.x
				it.node.position.y = cross(this.child_align, own.y + pad, own.h - pad * 2, it.r.h) - it.r.y
				x += it.r.w + this.spacing.x
			}
		} else if (this.kind === 'grid') {
			let cell = new Vec2()
			for (const it of items) cell = vec2(Math.max(cell.x, it.r.w), Math.max(cell.y, it.r.h))
			let cols = this.columns
			if (cols <= 0) cols = cell.x + this.spacing.x > 0 ? Math.trunc((own.w - pad * 2 + this.spacing.x) / (cell.x + this.spacing.x)) : 1
			cols = Math.max(cols, 1)
			const rows = Math.trunc((items.length + cols - 1) / cols)
			own = this.fit(own, -1, pad * 2 + rows * cell.y + Math.max(rows - 1, 0) * this.spacing.y)
			items.forEach((it, i) => {
				const cx = own.x + pad + (i % cols) * (cell.x + this.spacing.x)
				const cy = own.y + pad + Math.trunc(i / cols) * (cell.y + this.spacing.y)
				it.node.position.x = cx + (cell.x - it.r.w) / 2 - it.r.x
				it.node.position.y = cy + (cell.y - it.r.h) / 2 - it.r.y
			})
		} else {
			let total = pad * 2
			items.forEach((it, i) => (total += it.r.h + (i > 0 ? this.spacing.y : 0)))
			own = this.fit(own, -1, total)
			let y = own.y + pad
			for (const it of items) {
				it.node.position.y = y - it.r.y
				it.node.position.x = cross(this.child_align, own.x + pad, own.w - pad * 2, it.r.w) - it.r.x
				y += it.r.h + this.spacing.y
			}
		}
	}
	fit(own: Rect, w: number, h: number): Rect {
		if (!this.resize) return own
		const t = this.node.get_component<UITransform>(UITransform)
		if (t === null) return own
		if (w >= 0) t.size.x = w
		if (h >= 0) t.size.y = h
		return t.rect()
	}
}

function cross(align: string, start: number, avail: number, len: number): number {
	return align === 'center' ? start + (avail - len) / 2 : align === 'end' ? start + avail - len : start
}

function clamp01(v: number): number {
	return v < 0 ? 0 : v > 1 ? 1 : v
}

// ---------- Meshes (render/mesh.v) ----------

export class TexturedMesh {
	static __vname = 'render.TexturedMesh'
	texture: assets.Texture | null = null
	positions: number[] = []
	uvs: number[] = []
	indices: number[] = []
	color = core.white.clone()
	colors: Color[] = []
	additive = false
	clone(): TexturedMesh {
		return Object.assign(new TexturedMesh(), this)
	}
}

// ---------- ParticleSystem (render/particles.v) ----------

export class Particle {
	static __vname = 'render.Particle'
	pos = new Vec2()
	vel = new Vec2()
	age = 0
	life = 0
	size_start = 0
	size_end = 0
	rotation = 0
	spin = 0
	frame = 0
	clone(): Particle {
		const p = Object.assign(new Particle(), this)
		p.pos = this.pos.clone()
		p.vel = this.vel.clone()
		return p
	}
}

const preview_pause = 0.5

export class ParticleSystem extends core.Component {
	static __vname = 'render.ParticleSystem'
	static __fields: FieldSpec[] = [
		{ name: 'texture', type: 'asset:texture' },
		{ name: 'playing', type: 'bool' },
		{ name: 'looping', type: 'bool' },
		{ name: 'duration', type: 'f32' },
		{ name: 'rate', type: 'f32' },
		{ name: 'burst', type: 'int' },
		{ name: 'max_particles', type: 'int' },
		{ name: 'lifetime', type: 'f32' },
		{ name: 'lifetime_var', type: 'f32' },
		{ name: 'speed', type: 'f32' },
		{ name: 'speed_var', type: 'f32' },
		{ name: 'angle', type: 'f32' },
		{ name: 'spread', type: 'f32' },
		{ name: 'gravity', type: 'Vec2' },
		{ name: 'damping', type: 'f32' },
		{ name: 'shape', type: 'string', choices: ['point', 'circle', 'box'] },
		{ name: 'shape_size', type: 'Vec2' },
		{ name: 'start_size', type: 'f32' },
		{ name: 'end_size', type: 'f32' },
		{ name: 'size_var', type: 'f32' },
		{ name: 'start_color', type: 'Color' },
		{ name: 'end_color', type: 'Color' },
		{ name: 'spin', type: 'f32' },
		{ name: 'spin_var', type: 'f32' },
		{ name: 'random_angle', type: 'bool' },
		{ name: 'random_frame', type: 'bool' },
		{ name: 'world_space', type: 'bool' },
		{ name: 'additive', type: 'bool' },
		{ name: 'auto_destroy', type: 'bool' },
	]
	texture = new assets.AssetRef('', assets.Texture)
	playing = true
	looping = true
	duration = 1
	rate = 20
	burst = 0
	max_particles = 500
	lifetime = 1
	lifetime_var = 0
	speed = 100
	speed_var = 0
	angle = -90
	spread = 30
	gravity = new Vec2()
	damping = 0
	shape = 'point'
	shape_size = new Vec2()
	start_size = 16
	end_size = 16
	size_var = 0
	start_color = core.white.clone()
	end_color = new core.Color(255, 255, 255, 0)
	spin = 0
	spin_var = 0
	random_angle = false
	random_frame = false
	world_space = true
	additive = false
	auto_destroy = false
	particles: Particle[] = []
	_buf = new ParticleBuffers() // meshes() storage, reused every frame
	elapsed = 0
	burst_done = false
	carry = 0
	tex: assets.Texture | null = null
	loaded = ''

	on_load() {
		this.acquire()
	}
	on_destroy() {
		this.drop()
	}
	update(dt: number) {
		this.simulate(dt)
		if (this.playing) {
			this.step_emission(dt)
			if (!this.looping && this.elapsed >= this.duration) this.playing = false
		}
		if (this.auto_destroy && this.is_done() && this.node) this.node.destroy()
	}
	preview(dt: number) {
		this.simulate(Math.min(dt, 0.1))
		if (!this.playing) {
			this.particles.length = 0
			this.restart()
			return
		}
		if (this.looping || !this.burst_done || this.elapsed < this.duration) {
			this.step_emission(dt)
		} else {
			this.elapsed += dt
			if (this.particles.length === 0 && this.elapsed >= this.duration + preview_pause) this.restart()
		}
	}
	restart() {
		this.elapsed = 0
		this.carry = 0
		this.burst_done = false
	}
	step_emission(dt: number) {
		if (!this.burst_done) {
			this.burst_done = true
			this.emit(this.burst)
		}
		this.carry += this.rate * dt
		const n = Math.trunc(this.carry)
		this.carry -= n
		this.emit(n)
		this.elapsed += dt
	}
	set_texture(r: assets.AssetRef) {
		this.drop()
		this.texture = r.clone()
		this.acquire()
	}
	play() {
		this.playing = true
		this.restart()
	}
	stop() {
		this.playing = false
	}
	clear() {
		this.particles.length = 0
	}
	alive(): number {
		return this.particles.length
	}
	is_done(): boolean {
		return !this.playing && this.particles.length === 0
	}
	emit(count: number) {
		const n = Math.min(count, this.max_particles - this.particles.length)
		if (n <= 0) return
		const m = this.world_space && this.node ? this.node.world_matrix() : Affine2.identity()
		const frames = this.random_frame && this.tex !== null ? this.tex.frame_count() : 1
		for (let i = 0; i < n; i++) {
			const dir = ((this.angle + this.spread * signed_rand()) * Math.PI) / 180
			const v = vec2(Math.cos(dir), Math.sin(dir)).mul(this.speed + this.speed_var * signed_rand())
			const p = this.spawn_point()
			const ds = this.size_var * signed_rand()
			const pt = new Particle()
			pt.pos = m.apply(p)
			pt.vel = direction(m, v)
			pt.life = Math.max(this.lifetime + this.lifetime_var * signed_rand(), 0.01)
			pt.size_start = Math.max(this.start_size + ds, 0)
			pt.size_end = Math.max(this.end_size + ds, 0)
			pt.rotation = this.random_angle ? Math.random() * 360 : 0
			pt.spin = this.spin + this.spin_var * signed_rand()
			pt.frame = frames > 1 ? Math.floor(Math.random() * frames) : 0
			this.particles.push(pt)
		}
	}
	simulate(dt: number) {
		const keep = this.damping > 0 ? Math.max(1 - this.damping * dt, 0) : 1
		let j = 0
		const ps = this.particles
		const gx = this.gravity.x * dt
		const gy = this.gravity.y * dt
		for (let i = 0; i < ps.length; i++) {
			const p = ps[i]
			p.age += dt
			if (p.age >= p.life) continue
			p.vel.x = (p.vel.x + gx) * keep
			p.vel.y = (p.vel.y + gy) * keep
			p.pos.x += p.vel.x * dt
			p.pos.y += p.vel.y * dt
			p.rotation += p.spin * dt
			ps[j++] = p
		}
		ps.length = j
	}
	spawn_point(): Vec2 {
		if (this.shape === 'circle') {
			const a = Math.random() * 2 * Math.PI
			const r = this.shape_size.x * Math.sqrt(Math.random())
			return vec2(Math.cos(a) * r, Math.sin(a) * r)
		}
		if (this.shape === 'box') return vec2((this.shape_size.x * signed_rand()) / 2, (this.shape_size.y * signed_rand()) / 2)
		return new Vec2()
	}
	// meshes shares the system's buffers (typed arrays, viewed at this frame's length): valid until the next call.
	meshes(): TexturedMesh[] {
		if (this.particles.length === 0) return []
		const to_node = this.world_space && this.node ? this.node.world_matrix().inverse() : Affine2.identity()
		const tex = this.tex !== null && this.tex.width > 0 && this.tex.height > 0 ? this.tex : null
		const n = this.particles.length
		const b = this._buf
		b.reserve(n)
		const pos = b.pos
		const uvs = b.uvs
		// matrix math in locals: writing doubles into Affine2 fields would box them (an allocation each)
		const ta = to_node.a
		const tb = to_node.b
		const tc = to_node.c
		const td = to_node.d
		const ttx = to_node.tx
		const tty = to_node.ty
		for (let i = 0; i < n; i++) {
			const p = this.particles[i]
			const k = p.age / p.life
			const h = (p.size_start + (p.size_end - p.size_start) * k) / 2
			lerp_color_into(b.colors[i * 4], this.start_color, this.end_color, k) // the quad's 4 entries share it
			// m = to_node * trs(pos, rotation, (h, h))
			let cs = 1
			let sn = 0
			if (p.rotation !== 0) {
				const rad = (p.rotation * Math.PI) / 180
				cs = Math.cos(rad)
				sn = Math.sin(rad)
			}
			const qa = cs * h
			const qb = sn * h
			const qc = -sn * h
			const qd = cs * h
			const px = p.pos.x
			const py = p.pos.y
			const ma = ta * qa + tc * qb
			const mb = tb * qa + td * qb
			const mc = ta * qc + tc * qd
			const md = tb * qc + td * qd
			const mtx = ta * px + tc * py + ttx
			const mty = tb * px + td * py + tty
			// corners (-1,-1) (1,-1) (1,1) (-1,1)
			const o = i * 8
			pos[o] = -ma - mc + mtx
			pos[o + 1] = -mb - md + mty
			pos[o + 2] = ma - mc + mtx
			pos[o + 3] = mb - md + mty
			pos[o + 4] = ma + mc + mtx
			pos[o + 5] = mb + md + mty
			pos[o + 6] = -ma + mc + mtx
			pos[o + 7] = -mb + md + mty
			if (tex) {
				const fx = tex.frame_x(p.frame)
				const fy = tex.frame_y(p.frame)
				const u0 = fx / tex.width
				const v0 = fy / tex.height
				const u1 = (fx + tex.frame_w()) / tex.width
				const v1 = (fy + tex.frame_h()) / tex.height
				uvs[o] = u0
				uvs[o + 1] = v0
				uvs[o + 2] = u1
				uvs[o + 3] = v0
				uvs[o + 4] = u1
				uvs[o + 5] = v1
				uvs[o + 6] = u0
				uvs[o + 7] = v1
			}
		}
		const mesh = b.mesh
		mesh.texture = tex
		mesh.additive = this.additive
		mesh.positions = pos.subarray(0, n * 8) as unknown as number[]
		mesh.uvs = tex ? (uvs.subarray(0, n * 8) as unknown as number[]) : []
		mesh.indices = b.idx.subarray(0, n * 6) as unknown as number[]
		mesh.colors = b.colors // may be longer than 4 per particle: draw_mesh only reads the first ones
		return b.out
	}
	debug_outline(): Vec2[] {
		if (this.shape === 'circle') {
			const r = Math.max(this.shape_size.x, 1)
			return V.make_array(24, (i) => vec2(Math.cos((i * Math.PI) / 12) * r, Math.sin((i * Math.PI) / 12) * r))
		}
		if (this.shape === 'box') {
			const w = this.shape_size.x / 2
			const h = this.shape_size.y / 2
			return [vec2(-w, -h), vec2(w, -h), vec2(w, h), vec2(-w, h)]
		}
		return [vec2(0, -4), vec2(4, 0), vec2(0, 4), vec2(-4, 0)]
	}
	debug_color(): Color {
		return rgba(255, 150, 40, 200)
	}
	acquire() {
		if (!this.texture.is_set() || !this.node || !this.node.scene) return
		const db = this.node.scene.assets
		if (!db || this.loaded === this.texture.id) return
		try {
			this.tex = db.get<assets.Texture>(assets.Texture, this.texture)
		} catch (e) {
			console.error(`[ParticleSystem] ${this.node.path()}: ${V.as_error(e).message}`)
			return
		}
		this.loaded = this.texture.id
	}
	drop() {
		if (this.loaded === '' || !this.node || !this.node.scene) return
		const db = this.node.scene.assets
		if (db) db.release(this.loaded)
		this.loaded = ''
		this.tex = null
	}
}

function direction(m: Affine2, v: Vec2): Vec2 {
	const d = m.apply(v).op_sub(m.position())
	return d.normalized().mul(v.length())
}

function signed_rand(): number {
	return Math.random() * 2 - 1
}

// lerp_color_into: lerp_color written into `out` (no allocation).
function lerp_color_into(out: Color, a: Color, b: Color, t: number) {
	out.r = Math.trunc(a.r + (b.r - a.r) * t + 0.5) & 255
	out.g = Math.trunc(a.g + (b.g - a.g) * t + 0.5) & 255
	out.b = Math.trunc(a.b + (b.b - a.b) * t + 0.5) & 255
	out.a = Math.trunc(a.a + (b.a - a.a) * t + 0.5) & 255
}

// ParticleBuffers — ParticleSystem.meshes' storage, grown as needed and reused every frame.
class ParticleBuffers {
	pos = new Float64Array(0) // f64 like the arrays it replaced: the same vertices as before
	uvs = new Float32Array(0)
	idx = new Uint32Array(0) // the quad index pattern 0 1 2 0 2 3, 4 5 6 ...
	colors: Color[] = [] // 4 entries per particle pointing at the same Color object
	mesh = new TexturedMesh()
	out = [this.mesh]
	// reserve makes room for n particles
	reserve(n: number) {
		if (this.pos.length >= n * 8) return
		const cap = Math.max(n, 64, (this.pos.length / 8) * 2)
		this.pos = new Float64Array(cap * 8)
		this.uvs = new Float32Array(cap * 8)
		this.idx = new Uint32Array(cap * 6)
		for (let q = 0; q < cap; q++) {
			const v = q * 4
			this.idx.set([v, v + 1, v + 2, v, v + 2, v + 3], q * 6)
		}
		for (let q = this.colors.length / 4; q < cap; q++) {
			const c = new core.Color(255, 255, 255, 255)
			this.colors.push(c, c, c, c)
		}
	}
}

function lerp_color(a: Color, b: Color, t: number): Color {
	return new core.Color(
		Math.trunc(a.r + (b.r - a.r) * t + 0.5) & 255,
		Math.trunc(a.g + (b.g - a.g) * t + 0.5) & 255,
		Math.trunc(a.b + (b.b - a.b) * t + 0.5) & 255,
		Math.trunc(a.a + (b.a - a.a) * t + 0.5) & 255,
	)
}

// ---------- TileMap (render/tilemap.v) ----------

export const no_tile = -1

// inside_convex: true if (px, py) lies in the convex polygon (edges count as inside)
function inside_convex(poly: Vec2[], px: number, py: number): boolean {
	let pos = false
	let neg = false
	for (let i = 0; i < poly.length; i++) {
		const a = poly[i]
		const b = poly[(i + 1) % poly.length]
		const cr = (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x)
		if (cr > 0) pos = true
		else if (cr < 0) neg = true
	}
	return !(pos && neg)
}

export class TileMap extends core.Component {
	static __vname = 'render.TileMap'
	static __fields: FieldSpec[] = [
		{ name: 'tileset', type: 'asset:texture' },
		{ name: 'columns', type: 'int' },
		{ name: 'rows', type: 'int' },
		{ name: 'tile_size', type: 'Vec2' },
		{ name: 'anchor', type: 'Vec2' },
		{ name: 'color', type: 'Color' },
		{ name: 'layout', type: 'string', choices: ['orthogonal', 'isometric', 'staggered', 'hex_pointy', 'hex_flat'] },
		{ name: 'stagger_odd', type: 'bool' },
		{ name: 'hex_side', type: 'f32' },
		{ name: 'tiles', type: '[]int' },
	]
	tileset = new assets.AssetRef('', assets.Texture)
	columns = 16
	rows = 10
	tile_size = new Vec2()
	anchor = new Vec2()
	color = core.white.clone()
	layout = 'orthogonal'
	stagger_odd = true
	hex_side = 0
	tiles: number[] = []
	tex: assets.Texture | null = null
	loaded = ''

	on_load() {
		this.acquire()
	}
	on_destroy() {
		this.drop()
	}
	set_tileset(r: assets.AssetRef) {
		this.drop()
		this.tileset = r.clone()
		this.acquire()
	}
	in_bounds(col: number, row: number): boolean {
		return col >= 0 && row >= 0 && col < this.columns && row < this.rows
	}
	get(col: number, row: number): number {
		if (!this.in_bounds(col, row)) return no_tile
		const i = row * this.columns + col
		return i < this.tiles.length ? this.tiles[i] : no_tile
	}
	set(col: number, row: number, tile: number): boolean {
		const t = tile < 0 ? no_tile : tile
		if (!this.in_bounds(col, row) || this.get(col, row) === t) return false
		this.normalize()
		this.tiles[row * this.columns + col] = t
		return true
	}
	fill_rect(col0: number, row0: number, col1: number, row1: number, tile: number) {
		for (let r = Math.max(Math.min(row0, row1), 0); r < Math.min(Math.max(row0, row1) + 1, this.rows); r++) {
			for (let c = Math.max(Math.min(col0, col1), 0); c < Math.min(Math.max(col0, col1) + 1, this.columns); c++) this.set(c, r, tile)
		}
	}
	flood_fill(col: number, row: number, tile: number): number {
		const target = this.get(col, row)
		if (!this.in_bounds(col, row) || target === (tile < 0 ? no_tile : tile)) return 0
		const stack = [col, row]
		let n = 0
		while (stack.length > 0) {
			const r = stack.pop()!
			const c = stack.pop()!
			if (this.get(c, r) !== target || !this.in_bounds(c, r)) continue
			this.set(c, r, tile)
			n++
			for (const nb of this.neighbors(c, r)) stack.push(nb[0], nb[1])
		}
		return n
	}
	clear() {
		this.tiles = V.make_array(this.columns * this.rows, () => no_tile)
	}
	resize(columns: number, rows: number) {
		const cols = Math.max(columns, 1)
		const rs = Math.max(rows, 1)
		const out = V.make_array(cols * rs, () => no_tile)
		for (let r = 0; r < Math.min(rs, this.rows); r++) for (let c = 0; c < Math.min(cols, this.columns); c++) out[r * cols + c] = this.get(c, r)
		this.columns = cols
		this.rows = rs
		this.tiles = out
	}
	count(): number {
		let n = 0
		for (let r = 0; r < this.rows; r++) for (let c = 0; c < this.columns; c++) if (this.get(c, r) >= 0) n++
		return n
	}
	normalize() {
		const want = Math.max(this.columns, 0) * Math.max(this.rows, 0)
		if (this.tiles.length > want) this.tiles.length = want
		while (this.tiles.length < want) this.tiles.push(no_tile)
	}
	cell_size(): Vec2 {
		if (this.tile_size.x > 0 && this.tile_size.y > 0) return this.tile_size.clone()
		if (this.tex !== null && this.tex.frame_w() > 0 && this.tex.frame_h() > 0) return vec2(this.tex.frame_w(), this.tex.frame_h())
		return vec2(16, 16)
	}
	shifted(i: number): boolean {
		return (i & 1) === 1 === this.stagger_odd
	}
	neighbors(col: number, row: number): number[][] {
		switch (this.layout) {
			case 'staggered':
			case 'hex_pointy': {
				const d = this.shifted(row) ? 1 : -1
				const out = [[col, row - 1], [col + d, row - 1], [col, row + 1], [col + d, row + 1]]
				if (this.layout === 'hex_pointy') out.push([col + 1, row], [col - 1, row])
				return out
			}
			case 'hex_flat': {
				const d = this.shifted(col) ? 1 : -1
				return [[col, row - 1], [col, row + 1], [col - 1, row], [col - 1, row + d], [col + 1, row], [col + 1, row + d]]
			}
			default:
				return [[col + 1, row], [col - 1, row], [col, row + 1], [col, row - 1]]
		}
	}
	hex_edge(cs: Vec2): number {
		if (this.hex_side > 0) return this.hex_side
		return this.layout === 'hex_flat' ? cs.x / 2 : cs.y / 2
	}
	step(cs: Vec2): [number, number] {
		switch (this.layout) {
			case 'isometric':
				return [cs.x / 2, cs.y / 2]
			case 'staggered':
				return [cs.x, cs.y / 2]
			case 'hex_pointy':
				return [cs.x, (cs.y + this.hex_edge(cs)) / 2]
			case 'hex_flat':
				return [(cs.x + this.hex_edge(cs)) / 2, cs.y]
			default:
				return [cs.x, cs.y]
		}
	}
	local_rect(): [number, number, number, number] {
		const cs = this.cell_size()
		const cols = Math.max(this.columns, 0)
		const rs = Math.max(this.rows, 0)
		const [sx, sy] = this.step(cs)
		let w = 0
		let h = 0
		if (cols > 0 && rs > 0) {
			switch (this.layout) {
				case 'isometric':
					w = (cols + rs) * sx
					h = (cols + rs) * sy
					break
				case 'staggered':
				case 'hex_pointy':
					w = cols * cs.x + cs.x / 2
					h = (rs - 1) * sy + cs.y
					break
				case 'hex_flat':
					w = (cols - 1) * sx + cs.x
					h = rs * cs.y + cs.y / 2
					break
				default:
					w = cols * cs.x
					h = rs * cs.y
			}
		}
		return [-this.anchor.x * w, -this.anchor.y * h, w, h]
	}
	cell_origin(col: number, row: number, cs: Vec2): [number, number] {
		const [sx, sy] = this.step(cs)
		switch (this.layout) {
			case 'isometric':
				return [(this.rows - 1 + col - row) * sx, (col + row) * sy]
			case 'staggered':
			case 'hex_pointy':
				return [col * cs.x + (this.shifted(row) ? cs.x / 2 : 0), row * sy]
			case 'hex_flat':
				return [col * sx, row * cs.y + (this.shifted(col) ? cs.y / 2 : 0)]
			default:
				return [col * cs.x, row * cs.y]
		}
	}
	tile_outline(cs: Vec2): Vec2[] {
		const w = cs.x
		const h = cs.y
		switch (this.layout) {
			case 'isometric':
			case 'staggered':
				return [vec2(w / 2, 0), vec2(w, h / 2), vec2(w / 2, h), vec2(0, h / 2)]
			case 'hex_pointy': {
				const a = (h - this.hex_edge(cs)) / 2
				return [vec2(w / 2, 0), vec2(w, a), vec2(w, h - a), vec2(w / 2, h), vec2(0, h - a), vec2(0, a)]
			}
			case 'hex_flat': {
				const a = (w - this.hex_edge(cs)) / 2
				return [vec2(a, 0), vec2(w - a, 0), vec2(w, h / 2), vec2(w - a, h), vec2(a, h), vec2(0, h / 2)]
			}
			default:
				return [vec2(0, 0), vec2(w, 0), vec2(w, h), vec2(0, h)]
		}
	}
	cell_polygon(col: number, row: number): Vec2[] {
		const [x, y] = this.cell_local_rect(col, row)
		return this.tile_outline(this.cell_size()).map((p) => vec2(x + p.x, y + p.y))
	}
	local_to_cell(p: Vec2): [number, number] {
		const [x, y] = this.local_rect()
		const cs = this.cell_size()
		const rx = p.x - x
		const ry = p.y - y
		if (this.layout !== 'isometric' && this.layout !== 'staggered' && this.layout !== 'hex_pointy' && this.layout !== 'hex_flat') {
			return [Math.floor(rx / cs.x), Math.floor(ry / cs.y)]
		}
		const [sx, sy] = this.step(cs)
		if (this.layout === 'isometric') {
			const a = rx / sx - this.rows
			const b = ry / sy - 1
			return [Math.floor((a + b) / 2 + 0.5), Math.floor((b - a) / 2 + 0.5)]
		}
		const outline = this.tile_outline(cs)
		const cg = Math.floor(rx / sx)
		const rg = Math.floor(ry / sy)
		let best_c = cg
		let best_r = rg
		let best_d = 1e30
		for (let r = rg - 2; r < rg + 2; r++) {
			for (let c = cg - 2; c < cg + 2; c++) {
				const [ox, oy] = this.cell_origin(c, r, cs)
				const qx = rx - ox
				const qy = ry - oy
				if (inside_convex(outline, qx, qy)) return [c, r]
				const d = Math.hypot(qx - cs.x / 2, qy - cs.y / 2)
				if (d < best_d) {
					best_c = c
					best_r = r
					best_d = d
				}
			}
		}
		return [best_c, best_r]
	}
	// visible_cells: the cells whose tile box touches the node-space rectangle, as row * columns + col, back to front
	visible_cells(x0: number, y0: number, x1: number, y1: number): number[] {
		const out: number[] = []
		const [ox, oy] = this.local_rect()
		const cs = this.cell_size()
		const [sx, sy] = this.step(cs)
		const rx0 = x0 - ox
		const ry0 = y0 - oy
		const rx1 = x1 - ox
		const ry1 = y1 - oy
		const cols = this.columns
		const rows = this.rows
		if (this.layout === 'isometric') {
			const s_lo = Math.max(Math.floor((ry0 - cs.y) / sy) + 1, 0)
			const s_hi = Math.min(Math.ceil(ry1 / sy) - 1, cols + rows - 2)
			const d_lo = Math.floor((rx0 - cs.x) / sx) + 1 - (rows - 1)
			const d_hi = Math.ceil(rx1 / sx) - 1 - (rows - 1)
			for (let s = s_lo; s <= s_hi; s++) {
				const c_lo = Math.max(s - rows + 1, 0, Math.ceil((s + d_lo) / 2))
				const c_hi = Math.min(s, cols - 1, Math.floor((s + d_hi) / 2))
				for (let c = c_lo; c <= c_hi; c++) {
					const r = s - c
					const d = c - r
					if (r >= 0 && r < rows && d >= d_lo && d <= d_hi) out.push(r * cols + c)
				}
			}
		} else if (this.layout === 'staggered' || this.layout === 'hex_pointy' || this.layout === 'hex_flat') {
			const flat = this.layout === 'hex_flat'
			const r_lo = flat ? Math.ceil((ry0 - cs.y * 1.5) / cs.y) : Math.ceil((ry0 - cs.y) / sy)
			const r_hi = flat ? Math.floor(ry1 / cs.y) : Math.floor(ry1 / sy)
			const c_lo = flat ? Math.ceil((rx0 - cs.x) / sx) : Math.ceil((rx0 - cs.x * 1.5) / cs.x)
			const c_hi = flat ? Math.floor(rx1 / sx) : Math.floor(rx1 / cs.x)
			for (let r = Math.max(r_lo, 0); r < Math.min(r_hi + 1, rows); r++) {
				for (let c = Math.max(c_lo, 0); c < Math.min(c_hi + 1, cols); c++) {
					const [x, y] = this.cell_origin(c, r, cs)
					if (x < rx1 && x + cs.x > rx0 && y < ry1 && y + cs.y > ry0) out.push(r * cols + c)
				}
			}
		} else {
			const r_from = Math.max(Math.floor(ry0 / cs.y), 0)
			const r_to = Math.min(Math.ceil(ry1 / cs.y) - 1, rows - 1)
			const c_from = Math.max(Math.floor(rx0 / cs.x), 0)
			const c_to = Math.min(Math.ceil(rx1 / cs.x) - 1, cols - 1)
			for (let r = r_from; r <= r_to; r++) for (let c = c_from; c <= c_to; c++) out.push(r * cols + c)
		}
		return out
	}
	world_to_cell(p: Vec2): [number, number] {
		return this.local_to_cell(this.node.world_matrix().inverse().apply(p))
	}
	tile_at(p: Vec2): number {
		const [c, r] = this.world_to_cell(p)
		return this.get(c, r)
	}
	cell_local_rect(col: number, row: number): [number, number, number, number] {
		const [x, y] = this.local_rect()
		const cs = this.cell_size()
		const [cx, cy] = this.cell_origin(col, row, cs)
		return [x + cx, y + cy, cs.x, cs.y]
	}
	cell_center(col: number, row: number): Vec2 {
		const [x, y, w, h] = this.cell_local_rect(col, row)
		return this.node.world_matrix().apply(vec2(x + w / 2, y + h / 2))
	}
	debug_outline(): Vec2[] {
		const [x, y, w, h] = this.local_rect()
		return [vec2(x, y), vec2(x + w, y), vec2(x + w, y + h), vec2(x, y + h)]
	}
	debug_color(): Color {
		return rgba(120, 200, 255, 110)
	}
	acquire() {
		if (!this.tileset.is_set() || !this.node || !this.node.scene) return
		const db = this.node.scene.assets
		if (!db || this.loaded === this.tileset.id) return
		try {
			this.tex = db.get<assets.Texture>(assets.Texture, this.tileset)
		} catch (e) {
			console.error(`[TileMap] ${this.node.path()}: ${V.as_error(e).message}`)
			return
		}
		this.loaded = this.tileset.id
	}
	drop() {
		if (this.loaded === '' || !this.node || !this.node.scene) return
		const db = this.node.scene.assets
		if (db) db.release(this.loaded)
		this.loaded = ''
		this.tex = null
	}
}

// ---------- Color tweens (render/tween.v) ----------

export function fade_to(n: core.Node, alpha: number, duration: number, ease: core.Ease): core.Tween {
	return n.tween().value(alpha_get(n), alpha_set(n), alpha, duration, ease)
}

export function color_to(n: core.Node, c: Color, duration: number, ease: core.Ease): core.Tween {
	let from = core.white.clone()
	const to = c.clone()
	return n.tween().value(
		() => {
			from = color_of(n) ?? core.white.clone()
			return 0
		},
		(v) => set_color(n, from.lerp(to, v)),
		1,
		duration,
		ease,
	)
}

export function alpha_get(n: core.Node): () => number {
	return () => {
		const c = color_of(n)
		return c === null ? 255 : c.a
	}
}

export function alpha_set(n: core.Node): (v: number) => void {
	return (v: number) => {
		const a = v <= 0 ? 0 : v >= 255 ? 255 : Math.trunc(v + 0.5)
		const c = color_of(n)
		if (c === null) return
		set_color(n, new core.Color(c.r, c.g, c.b, a))
	}
}

export function color_of(n: core.Node): Color | null {
	for (const c of n.components) {
		if (c instanceof Sprite || c instanceof Label || c instanceof Panel || c instanceof TileMap) return c.color.clone()
	}
	return null
}

export function set_color(n: core.Node, col: Color) {
	for (const c of n.components) {
		if (c instanceof Sprite || c instanceof Label || c instanceof Panel || c instanceof TileMap) c.color = col.clone()
	}
}

// ---------- Registration ----------

export function register_builtins(r: serialize.Registry) {
	r.register(core.Camera)
	r.register(core.Canvas)
	r.register(Sprite)
	r.register(SpriteAnimator)
	r.register(Label)
	r.register(UITransform)
	r.register(Panel)
	r.register(Button)
	r.register(Toggle)
	r.register(ProgressBar)
	r.register(ScrollView)
	r.register(Widget)
	r.register(Layout)
	r.register(Joystick)
	r.register(TextInput)
	r.register(ParticleSystem)
	r.register(TileMap)
}

// ---------- Renderer (render/renderer.v) ----------

// DrawItem — one node to draw. Kept in a pool between frames (see Renderer.draw_list) with its own matrices, so
// collecting the draw list allocates nothing once the pool has grown.
class DrawItem {
	node: core.Node = null as unknown as core.Node // null once unused (see draw_tree)
	w = new Affine2() // node -> world
	m = new Affine2() // node -> window
	clip: Rect = null as unknown as Rect
	canvas = false
	z = 0
	seq = 0
}

interface CollectState {
	view: Affine2
	view_cam: Affine2
	items: DrawItem[] // the pool: items[0 .. count) are this frame's
	count: number
}

const identity_matrix = new Affine2()

// collect_draw_items fills `items` (a pool, reused) with the visible nodes sorted by draw order: world before
// Canvas, then z_index, then tree order. Returns how many of them are this frame's.
function collect_draw_items(items: DrawItem[], root: core.Node, view: Affine2, camera: Affine2, clip: Rect): number {
	const st: CollectState = { view, view_cam: view.mul(camera), items, count: 0 }
	collect_node(st, root, identity_matrix, false, 0, clip)
	// most scenes are already in draw order (no z_index, no Canvas in the middle): skip the sort then
	let ordered = true
	for (let i = 1; i < st.count; i++) {
		if (compare_draw_items(items[i - 1], items[i]) > 0) {
			ordered = false
			break
		}
	}
	if (!ordered) {
		const sorted = items.slice(0, st.count).sort(compare_draw_items)
		for (let i = 0; i < sorted.length; i++) items[i] = sorted[i]
	}
	return st.count
}

function collect_node(st: CollectState, n: core.Node, parent_world: Affine2, canvas: boolean, z: number, clip: Rect) {
	if (!n.active || n.destroyed) return
	let it = st.items[st.count]
	if (it === undefined) {
		it = new DrawItem()
		st.items.push(it)
	}
	const seq = st.count++
	// one pass over the components for what the walk needs (constant instanceof checks stay fast in V8)
	let in_canvas = canvas
	let sv: ScrollView | null = null
	for (const c of n.components) {
		if (c instanceof core.Canvas) in_canvas = true
		else if (sv === null && c instanceof ScrollView) sv = c
	}
	const w = it.w.set_mul(parent_world, n.local_matrix_ref())
	const m = it.m.set_mul(in_canvas ? st.view : st.view_cam, w)
	const zz = z + n.z_index
	it.node = n
	it.clip = clip
	it.canvas = in_canvas
	it.z = zz
	it.seq = seq
	let child_clip = clip
	if (sv !== null && sv.enabled && sv.clip) {
		const vr = node_rect(n)
		if (vr !== null) child_clip = clip.intersect(screen_bounds(m, vr))
	}
	const kids = n.y_sort && n.children.length > 1 ? y_sorted(n.children, w) : n.children
	for (const ch of kids) collect_node(st, ch, w, in_canvas, zz, child_clip)
}

function y_sorted(children: core.Node[], parent_world: Affine2): core.Node[] {
	const keys = children.map((ch, i) => ({ y: parent_world.apply_y(ch.position.x, ch.position.y), i }))
	keys.sort((a, b) => (a.y !== b.y ? (a.y < b.y ? -1 : 1) : a.i - b.i))
	return keys.map((k) => children[k.i])
}

function compare_draw_items(a: DrawItem, b: DrawItem): number {
	if (a.canvas !== b.canvas) return a.canvas ? 1 : -1
	if (a.z !== b.z) return a.z < b.z ? -1 : 1
	return a.seq - b.seq
}

export function draw_order(root: core.Node): core.Node[] {
	const items: DrawItem[] = []
	const n = collect_draw_items(items, root, Affine2.identity(), Affine2.identity(), new Rect())
	const out: core.Node[] = new Array(n)
	for (let i = 0; i < n; i++) out[i] = items[i].node
	return out
}

function screen_bounds(m: Affine2, rc: Rect): Rect {
	const xs = [m.apply_x(rc.x, rc.y), m.apply_x(rc.x + rc.w, rc.y), m.apply_x(rc.x + rc.w, rc.y + rc.h), m.apply_x(rc.x, rc.y + rc.h)]
	const ys = [m.apply_y(rc.x, rc.y), m.apply_y(rc.x + rc.w, rc.y), m.apply_y(rc.x + rc.w, rc.y + rc.h), m.apply_y(rc.x, rc.y + rc.h)]
	const x0 = Math.min(...xs)
	const y0 = Math.min(...ys)
	return new Rect(x0, y0, Math.max(...xs) - x0, Math.max(...ys) - y0)
}

function quad_points(m: Affine2, rc: Rect): number[] {
	return [
		m.apply_x(rc.x, rc.y),
		m.apply_y(rc.x, rc.y),
		m.apply_x(rc.x + rc.w, rc.y),
		m.apply_y(rc.x + rc.w, rc.y),
		m.apply_x(rc.x + rc.w, rc.y + rc.h),
		m.apply_y(rc.x + rc.w, rc.y + rc.h),
		m.apply_x(rc.x, rc.y + rc.h),
		m.apply_y(rc.x, rc.y + rc.h),
	]
}

const outline_dirs = [vec2(-1, 0), vec2(1, 0), vec2(0, -1), vec2(0, 1), vec2(-0.7, -0.7), vec2(0.7, -0.7), vec2(-0.7, 0.7), vec2(0.7, 0.7)]

class GfxMeasure implements TextMeasurer {
	gfx: Gfx
	family: string
	constructor(gfx: Gfx, family: string) {
		this.gfx = gfx
		this.family = family
	}
	width(s: string, size: number): number {
		return this.gfx.text_width(s, Math.trunc(size + 0.5), this.family)
	}
}

export class Renderer {
	static __vname = 'render.Renderer'
	gfx: Gfx
	db: assets.AssetDatabase
	debug = false
	show_shapes = false
	// draw_tree counts the GPU draws it issued from here (Gfx.draw_calls, plus the batch still pending), like
	// the native renderer counts sprite runs rather than sprites
	draws_at_start = 0
	base_clip = new Rect()
	clip = new Rect()
	// draw_tree's draw list, kept between frames (null while a draw_tree uses it: a nested one makes its own)
	draw_list: DrawItem[] | null = []

	constructor(gfx: Gfx, db: assets.AssetDatabase) {
		this.gfx = gfx
		this.db = db
	}

	get draw_calls(): number {
		return this.gfx.draw_calls - this.draws_at_start + (this.gfx.nidx > 0 ? 1 : 0)
	}

	draw_scene(scene: core.Scene, window: Affine2) {
		this.draw_tree(scene.root, window, scene.view_matrix())
		const ins = scene.safe_insets
		if (this.debug && !ins.is_zero()) {
			const o = scene.view_origin
			const sz = scene.view_size
			this.draw_quad_empty(window, new Rect(o.x + ins.left, o.y + ins.top, sz.x - ins.left - ins.right, sz.y - ins.top - ins.bottom), rgba(255, 80, 80, 200))
		}
	}

	draw_tree(root: core.Node, view: Affine2, camera: Affine2) {
		this.draws_at_start = this.gfx.draw_calls
		const base = this.base_rect()
		this.clip = base
		this.set_scissor(base)
		const list = this.draw_list ?? []
		this.draw_list = null
		const count = collect_draw_items(list, root, view, camera, base)
		for (let i = 0; i < count; i++) {
			const it = list[i]
			if (it.clip !== this.clip && !it.clip.op_eq(this.clip)) {
				this.clip = it.clip
				this.set_scissor(this.clip)
			}
			this.draw_node(it.node, it.m)
		}
		// pooled items past this frame's would keep removed nodes (a previous scene) alive
		for (let i = count; i < list.length && list[i].node !== null; i++) {
			list[i].node = null as unknown as core.Node
			list[i].clip = null as unknown as Rect
		}
		this.draw_list = list
		this.clip = base
		this.set_scissor(base)
	}

	base_rect(): Rect {
		if (this.base_clip.w > 0 && this.base_clip.h > 0) return this.base_clip.clone()
		return new Rect(0, 0, this.gfx.width, this.gfx.height)
	}

	set_scissor(c: Rect) {
		this.gfx.set_scissor(c.x, c.y, c.w, c.h)
	}

	on_asset_event(ev: assets.AssetEvent) {
		if (ev.kind === 'unloaded' || ev.kind === 'removed') {
			this.gfx.release_texture(ev.id)
			this.gfx.release_effect(ev.id)
		}
	}

	draw_node(n: core.Node, m: Affine2) {
		for (const c of n.components) {
			if (!c.enabled) continue
			if (c instanceof Sprite) this.draw_sprite(c, m)
			else if (c instanceof Label) this.draw_label(c, m)
			else if (c instanceof Panel) this.draw_panel(c, m)
			else if (c instanceof ProgressBar) this.draw_progress(c, m)
			else if (c instanceof TileMap) this.draw_tilemap(c, m)
			else if (c instanceof TextInput) this.draw_text_input(c, m)
			else if (typeof (c as any).meshes === 'function') for (const mesh of (c as any).meshes() as TexturedMesh[]) this.draw_mesh(mesh, m)
			if ((this.debug || this.show_shapes) && typeof (c as any).debug_outline === 'function') {
				const ds = c as unknown as DebugShape
				this.draw_outline(m, ds.debug_outline(), ds.debug_color())
			}
		}
		if (this.debug) {
			this.gfx.circle_filled(m.tx, m.ty, 3, rgba(255, 0, 255, 255))
			const t = n.get_component<UITransform>(UITransform)
			if (t !== null) this.draw_quad_empty(m, t.rect(), rgba(0, 200, 255, 160))
		}
	}

	fill_quad(m: Affine2, rc: Rect, radius: number, c: Color) {
		if (c.a === 0 || rc.w <= 0 || rc.h <= 0) return
		if (radius > 0 && m.b === 0 && m.c === 0 && m.a > 0 && m.d > 0) {
			const b = screen_bounds(m, rc)
			const rad = radius * m.a
			this.gfx.rounded_rect_filled(b.x, b.y, b.w, b.h, rad * 2 > b.w || rad * 2 > b.h ? (b.w < b.h ? b.w / 2 : b.h / 2) : rad, c)
		} else {
			this.gfx.convex_poly(quad_points(m, rc), c)
		}
	}

	draw_quad_empty(m: Affine2, rc: Rect, c: GfxColor) {
		this.gfx.poly_empty(quad_points(m, rc), c)
	}

	draw_outline(m: Affine2, pts: Vec2[], c: Color) {
		if (pts.length < 2) return
		const flat: number[] = []
		for (const p of pts) flat.push(m.apply_x(p.x, p.y), m.apply_y(p.x, p.y))
		this.gfx.poly_empty(flat, c)
	}

	draw_panel(p: Panel, m: Affine2) {
		const t = p.node.get_component<UITransform>(UITransform)
		if (t === null) return
		const rc = t.rect()
		this.fill_quad(m, rc, p.radius, p.color)
		if (p.border_width <= 0 || p.border_color.a === 0) return
		const rounded = p.radius > 0 && m.b === 0 && m.c === 0 && m.a > 0 && m.d > 0
		for (let i = 0; i < p.border_width; i++) {
			const inset = i + 0.5
			const ri = new Rect(rc.x + inset, rc.y + inset, rc.w - inset * 2, rc.h - inset * 2)
			if (ri.w <= 0 || ri.h <= 0) break
			if (rounded) {
				const b = screen_bounds(m, ri)
				this.gfx.rounded_rect_empty(b.x, b.y, b.w, b.h, p.radius * m.a - inset, p.border_color)
			} else {
				this.draw_quad_empty(m, ri, p.border_color)
			}
		}
	}

	draw_progress(p: ProgressBar, m: Affine2) {
		const t = p.node.get_component<UITransform>(UITransform)
		if (t === null) return
		const rc = t.rect()
		this.fill_quad(m, rc, p.radius, p.back_color)
		this.fill_quad(m, p.fill_rect(rc), p.radius, p.fill_color)
	}

	draw_sprite(s: Sprite, m: Affine2) {
		const tex = s.tex
		if (tex === null || tex.width <= 0 || tex.height <= 0) return
		const gtex = this.gfx.texture(tex)
		if (gtex === null) return
		const tw = tex.width
		const th = tex.height
		const col = s.color
		const sh = s.shader_data
		const fx = sh !== null ? this.gfx.effect(sh.id, sh.version, sh.source, sh.path) : null
		if (fx === null && !s.is_sliced_mode() && !this.debug) {
			// the common case, without the quads() array: one quad over the whole display rect
			const fw = tex.frame_w()
			const fh = tex.frame_h()
			const sized = s.size.x > 0 && s.size.y > 0
			const w = sized ? s.size.x : fw
			const h = sized ? s.size.y : fh
			const x0 = -s.anchor.x * w
			const y0 = -s.anchor.y * h
			const x1 = x0 + w
			const y1 = y0 + h
			const fx0 = tex.frame_x(s.frame)
			const fy0 = tex.frame_y(s.frame)
			let u0 = fx0 / tw
			let u1 = (fx0 + fw) / tw
			let v0 = fy0 / th
			let v1 = (fy0 + fh) / th
			if (s.flip_x) {
				const t = u0
				u0 = u1
				u1 = t
			}
			if (s.flip_y) {
				const t = v0
				v0 = v1
				v1 = t
			}
			this.gfx.quad(
				gtex,
				m.apply_x(x0, y0), m.apply_y(x0, y0), u0, v0,
				m.apply_x(x1, y0), m.apply_y(x1, y0), u1, v0,
				m.apply_x(x1, y1), m.apply_y(x1, y1), u1, v1,
				m.apply_x(x0, y1), m.apply_y(x0, y1), u0, v1,
				col,
			)
			return
		}
		if (fx !== null) {
			const [fx0, fy0, fw, fh] = tex.frame_rect(s.frame)
			const p = s.shader_params
			const c = s.shader_color
			this.gfx.begin_effect(fx, new Float32Array([
				shader_time(s.node), tw, th, 0,
				p.x, p.y, 0, 0,
				c.r / 255, c.g / 255, c.b / 255, c.a / 255,
				fx0 / tw, fy0 / th, (fx0 + fw) / tw, (fy0 + fh) / th,
			]))
		}
		const quad = fx !== null ? this.gfx.effect_quad : this.gfx.quad
		for (const q of s.quads()) {
			const x1 = q.x + q.w
			const y1 = q.y + q.h
			quad.call(
				this.gfx,
				gtex,
				m.apply_x(q.x, q.y), m.apply_y(q.x, q.y), q.u0 / tw, q.v0 / th,
				m.apply_x(x1, q.y), m.apply_y(x1, q.y), q.u1 / tw, q.v0 / th,
				m.apply_x(x1, y1), m.apply_y(x1, y1), q.u1 / tw, q.v1 / th,
				m.apply_x(q.x, y1), m.apply_y(q.x, y1), q.u0 / tw, q.v1 / th,
				col,
			)
		}
		if (fx !== null) this.gfx.end_effect()
		if (this.debug) {
			const [x, y, w, h] = s.local_rect()
			this.draw_quad_empty(m, new Rect(x, y, w, h), rgba(0, 255, 0, 160))
		}
	}

	label_layout(l: Label): TextBlock {
		let box = new Rect()
		const t = l.node.get_component<UITransform>(UITransform)
		if (t !== null) box = t.rect()
		const family = font_family(l.font_data)
		const key = `${l.text}|${l.size}|${l.wrap}|${l.shrink}|${l.line_spacing}|${box.w}|${box.h}|${family}`
		if (key === l.layout_key) return l.layout
		const block = layout_text(l.text, l.size, l.line_spacing, l.wrap, l.shrink, l.wrap || l.shrink ? box.w : 0, l.shrink ? box.h : 0, 6, new GfxMeasure(this.gfx, family))
		l.layout_key = key
		l.layout = block
		return block
	}

	draw_label(l: Label, m: Affine2) {
		if (l.text === '') return
		const sc = m.scale()
		const k = sc.y < 0 ? -sc.y : sc.y
		const align = (l.align === 'center' ? 'center' : l.align === 'right' ? 'right' : 'left') as HAlign
		const family = font_family(l.font_data)
		const anchor = l.text_point()
		if (!l.wrap && !l.shrink && !l.text.includes('\n')) {
			const valign = (l.valign === 'middle' ? 'middle' : l.valign === 'bottom' ? 'bottom' : 'top') as VAlign
			const px = m.apply_x(anchor.x, anchor.y)
			const py = m.apply_y(anchor.x, anchor.y)
			this.draw_text_fx(l, px, py, l.text, Math.trunc(l.size * k), align, valign, family, k)
			return
		}
		const block = this.label_layout(l)
		const top = l.valign === 'middle' ? anchor.y - block.height() / 2 : l.valign === 'bottom' ? anchor.y - block.height() : anchor.y
		const size = Math.trunc(block.size * k)
		block.lines.forEach((line, i) => {
			if (line === '') return
			const y = top + i * block.line_height
			this.draw_text_fx(l, m.apply_x(anchor.x, y), m.apply_y(anchor.x, y), line, size, align, 'top', family, k)
		})
	}

	draw_text_fx(l: Label, x: number, y: number, text: string, size: number, align: HAlign, valign: VAlign, family: string, k: number) {
		const g = this.gfx
		if (l.shadow_color.a > 0) {
			const o = l.shadow_offset.mul(k)
			g.draw_text(Math.trunc(x + o.x), Math.trunc(y + o.y), text, { size, color: l.shadow_color, align, valign, family })
		}
		if (l.outline_color.a > 0 && l.outline_width > 0) {
			const w = l.outline_width * k
			for (const d of outline_dirs) g.draw_text(Math.trunc(x + d.x * w + 0.5), Math.trunc(y + d.y * w + 0.5), text, { size, color: l.outline_color, align, valign, family })
		}
		g.draw_text(Math.trunc(x), Math.trunc(y), text, { size, color: l.color, align, valign, family })
	}

	draw_text_input(t: TextInput, m: Affine2) {
		const tr = t.node.get_component<UITransform>(UITransform)
		if (tr === null) return
		const rc = tr.rect()
		const sc = m.scale()
		const k = sc.y < 0 ? -sc.y : sc.y
		const family = font_family(t.font_data)
		const meas = new GfxMeasure(this.gfx, family)
		const shown = t.shown()
		const runes = [...shown]
		const ci = t.caret < 0 ? 0 : t.caret > runes.length ? runes.length : t.caret
		const caret_x = meas.width(runes.slice(0, ci).join(''), t.size)
		const text_w = meas.width(shown, t.size)
		const scroll = t.update_scroll(caret_x, text_w, rc.w - 2 * t.padding)
		const old = this.clip
		this.clip = old.intersect(screen_bounds(m, rc))
		this.set_scissor(this.clip)
		const mid = rc.y + rc.h / 2
		const x0 = rc.x + t.padding - scroll
		const empty = shown === ''
		if (!empty || t.placeholder !== '') {
			this.gfx.draw_text(Math.trunc(m.apply_x(x0, mid)), Math.trunc(m.apply_y(x0, mid)), empty ? t.placeholder : shown, {
				size: Math.trunc(t.size * k),
				color: empty ? t.placeholder_color : t.color,
				valign: 'middle',
				family,
			})
		}
		if (t.caret_visible()) {
			const cx = empty ? rc.x + t.padding : x0 + caret_x
			const half = t.size * 0.55
			this.fill_quad(m, new Rect(cx, mid - half, 1.5, half * 2), 0, t.caret_color)
		}
		this.clip = old
		this.set_scissor(old)
	}

	draw_mesh(mesh: TexturedMesh, m: Affine2) {
		const textured = mesh.texture !== null
		if (mesh.indices.length < 3 || (textured && mesh.uvs.length < mesh.positions.length)) return
		const nverts = mesh.positions.length / 2
		const ind = mesh.indices
		for (let k = 0; k < ind.length; k++) if (ind[k] < 0 || ind[k] >= nverts) return
		let gtex: WebGLTexture | null = null
		if (textured) {
			gtex = this.gfx.texture(mesh.texture!)
			if (gtex === null) return
		}
		const g = this.gfx
		const c = mesh.color
		const per_vertex = mesh.colors.length >= nverts
		const nidx = mesh.indices.length - (mesh.indices.length % 3)
		// a mesh larger than one batch is drawn in pieces of whole triangles
		const max_tris = Math.floor(60000 / 3)
		for (let start = 0; start < nidx; start += max_tris * 3) {
			const end = Math.min(nidx, start + max_tris * 3)
			const count = end - start
			g.prepare(gtex, mesh.additive, count, count)
			for (let k = start; k < end; k++) {
				const i = mesh.indices[k]
				const px = mesh.positions[i * 2]
				const py = mesh.positions[i * 2 + 1]
				const u = textured ? mesh.uvs[i * 2] : 0
				const v = textured ? mesh.uvs[i * 2 + 1] : 0
				g.idx[g.nidx++] = g.nverts
				// mesh color times the vertex color (mul_color), packed straight into the vertex: no Color per vertex
				const vc = per_vertex ? mesh.colors[i] : c
				const r = per_vertex ? Math.trunc((c.r * vc.r) / 255) : c.r
				const gg = per_vertex ? Math.trunc((c.g * vc.g) / 255) : c.g
				const bb = per_vertex ? Math.trunc((c.b * vc.b) / 255) : c.b
				const a = per_vertex ? Math.trunc((c.a * vc.a) / 255) : c.a
				g.vertex_rgba(m.apply_x(px, py), m.apply_y(px, py), u, v, (r & 255) | ((gg & 255) << 8) | ((bb & 255) << 16) | ((a & 255) << 24))
			}
		}
		if (this.debug) {
			let x0 = 1e9
			let y0 = 1e9
			let x1 = -1e9
			let y1 = -1e9
			for (let i = 0; i < nverts; i++) {
				const x = m.apply_x(mesh.positions[i * 2], mesh.positions[i * 2 + 1])
				const y = m.apply_y(mesh.positions[i * 2], mesh.positions[i * 2 + 1])
				x0 = Math.min(x0, x)
				y0 = Math.min(y0, y)
				x1 = Math.max(x1, x)
				y1 = Math.max(y1, y)
			}
			this.gfx.rect_empty(x0, y0, x1 - x0, y1 - y0, rgba(0, 255, 0, 120))
		}
	}

	draw_tilemap(tm: TileMap, m: Affine2) {
		const tex = tm.tex
		if (tex === null || tex.width <= 0 || tex.height <= 0 || tm.columns <= 0 || tm.rows <= 0) return
		const gtex = this.gfx.texture(tex)
		if (gtex === null) return
		const inv = m.inverse()
		const cl = this.clip
		let lx0 = 1e30
		let ly0 = 1e30
		let lx1 = -1e30
		let ly1 = -1e30
		for (const [px, py] of [
			[cl.x, cl.y],
			[cl.x + cl.w, cl.y],
			[cl.x + cl.w, cl.y + cl.h],
			[cl.x, cl.y + cl.h],
		]) {
			const qx = inv.apply_x(px, py)
			const qy = inv.apply_y(px, py)
			lx0 = Math.min(lx0, qx)
			ly0 = Math.min(ly0, qy)
			lx1 = Math.max(lx1, qx)
			ly1 = Math.max(ly1, qy)
		}
		const cells = tm.visible_cells(lx0, ly0, lx1, ly1)
		if (cells.length === 0) return
		const [ox, oy] = tm.local_rect()
		const cs = tm.cell_size()
		const frames = tex.frame_count()
		const tw = tex.width
		const th = tex.height
		const eu = 0.01 / tw
		const ev = 0.01 / th
		const col = tm.color
		for (const i of cells) {
			const c = i % tm.columns
			const row = Math.floor(i / tm.columns)
			const t = tm.get(c, row)
			if (t < 0 || t >= frames) continue
			const [fx, fy, fw, fh] = tex.frame_rect(t)
			const u0 = fx / tw + eu
			const v0 = fy / th + ev
			const u1 = (fx + fw) / tw - eu
			const v1 = (fy + fh) / th - ev
			const [cx, cy] = tm.cell_origin(c, row, cs)
			const x = ox + cx
			const y = oy + cy
			const x1 = x + cs.x
			const y1 = y + cs.y
			this.gfx.quad(
				gtex,
				m.apply_x(x, y), m.apply_y(x, y), u0, v0,
				m.apply_x(x1, y), m.apply_y(x1, y), u1, v0,
				m.apply_x(x1, y1), m.apply_y(x1, y1), u1, v1,
				m.apply_x(x, y1), m.apply_y(x, y1), u0, v1,
				col,
			)
		}
	}

	draw_texture_frame(t: assets.Texture, frame: number, x: number, y: number, w: number, h: number) {
		const gtex = this.gfx.texture(t)
		if (gtex === null) return
		const [fx, fy, fw, fh] = t.frame_rect(frame)
		const u0 = fx / t.width
		const v0 = fy / t.height
		const u1 = (fx + fw) / t.width
		const v1 = (fy + fh) / t.height
		this.gfx.quad(gtex, x, y, u0, v0, x + w, y, u1, v0, x + w, y + h, u1, v1, x, y + h, u0, v1, core.white)
	}
}

export function new_renderer(gfx: Gfx, db: assets.AssetDatabase): Renderer {
	return new Renderer(gfx, db)
}
