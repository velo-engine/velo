// velo.core for the WebGL runtime — a line-by-line port of core/*.v. Names match the V API exactly
// (snake_case), because code transpiled from V calls them as they are written in V.

import * as V from './v.ts'
import type { AssetDatabase } from './assets.ts'

// ---------- Math (core/math.v) ----------

// Vec2 — 2D vector. Screen coordinate system: x to the right, y downward. A value type: copy with clone().
export class Vec2 {
	static __vname = 'core.Vec2'
	x = 0
	y = 0
	constructor(x = 0, y = 0) {
		this.x = x
		this.y = y
	}
	clone(): Vec2 {
		return new Vec2(this.x, this.y)
	}
	op_add(b: Vec2): Vec2 {
		return new Vec2(this.x + b.x, this.y + b.y)
	}
	op_sub(b: Vec2): Vec2 {
		return new Vec2(this.x - b.x, this.y - b.y)
	}
	// component-wise multiplication (used for scale)
	op_mul(b: Vec2): Vec2 {
		return new Vec2(this.x * b.x, this.y * b.y)
	}
	op_eq(b: Vec2): boolean {
		return this.x === b.x && this.y === b.y
	}
	mul(s: number): Vec2 {
		return new Vec2(this.x * s, this.y * s)
	}
	length(): number {
		return Math.sqrt(this.x * this.x + this.y * this.y)
	}
	distance(b: Vec2): number {
		return Math.hypot(this.x - b.x, this.y - b.y)
	}
	normalized(): Vec2 {
		const l = this.length()
		if (l < 1e-6) return new Vec2()
		return new Vec2(this.x / l, this.y / l)
	}
	lerp(b: Vec2, t: number): Vec2 {
		return new Vec2(this.x + (b.x - this.x) * t, this.y + (b.y - this.y) * t)
	}
	str(): string {
		return `(${V.fstr(this.x)}, ${V.fstr(this.y)})`
	}
}

export function vec2(x: number, y: number): Vec2 {
	return new Vec2(x, y)
}

// Insets — distances in from each edge of a rectangle.
export class Insets {
	static __vname = 'core.Insets'
	left = 0
	top = 0
	right = 0
	bottom = 0
	constructor(left = 0, top = 0, right = 0, bottom = 0) {
		this.left = left
		this.top = top
		this.right = right
		this.bottom = bottom
	}
	clone(): Insets {
		return new Insets(this.left, this.top, this.right, this.bottom)
	}
	is_zero(): boolean {
		return this.left === 0 && this.top === 0 && this.right === 0 && this.bottom === 0
	}
}

// Color — 8-bit RGBA color.
export class Color {
	static __vname = 'core.Color'
	r = 0
	g = 0
	b = 0
	a = 0
	constructor(r = 255, g = 255, b = 255, a = 255) {
		this.r = r
		this.g = g
		this.b = b
		this.a = a
	}
	clone(): Color {
		return new Color(this.r, this.g, this.b, this.a)
	}
	op_eq(o: Color): boolean {
		return this.r === o.r && this.g === o.g && this.b === o.b && this.a === o.a
	}
	lerp(b: Color, t: number): Color {
		return new Color(lerp_u8(this.r, b.r, t), lerp_u8(this.g, b.g, t), lerp_u8(this.b, b.b, t), lerp_u8(this.a, b.a, t))
	}
	str(): string {
		return `Color{${this.r}, ${this.g}, ${this.b}, ${this.a}}`
	}
}

function lerp_u8(a: number, b: number, t: number): number {
	const v = a + (b - a) * t + 0.5
	return v <= 0 ? 0 : v >= 255 ? 255 : Math.trunc(v)
}

export function rgba(r: number, g: number, b: number, a: number): Color {
	return new Color(r & 255, g & 255, b & 255, a & 255)
}

export const white = new Color()
export const black = new Color(0, 0, 0, 255)

// Affine2 — 2D transformation matrix:  | a c tx |  | b d ty |
// TickStack — Node.tick's scratch space. The array is never shortened (`top` marks the end) so it keeps its
// capacity; entries above `top` are stale.
export class TickStack {
	nodes: Node[] = []
	top = 0
}

export class Affine2 {
	static __vname = 'core.Affine2'
	a = 0
	b = 0
	c = 0
	d = 0
	tx = 0
	ty = 0
	constructor(a = 1, b = 0, c = 0, d = 1, tx = 0, ty = 0) {
		this.a = a
		this.b = b
		this.c = c
		this.d = d
		this.tx = tx
		this.ty = ty
	}
	static identity(): Affine2 {
		return new Affine2()
	}
	// trs builds a matrix from position, rotation (degrees, clockwise on screen) and scale.
	static trs(pos: Vec2, rotation_deg: number, scale: Vec2): Affine2 {
		if (rotation_deg === 0) return new Affine2(scale.x, 0, 0, scale.y, pos.x, pos.y)
		const r = (rotation_deg * Math.PI) / 180
		const cs = Math.cos(r)
		const sn = Math.sin(r)
		return new Affine2(cs * scale.x, sn * scale.x, -sn * scale.y, cs * scale.y, pos.x, pos.y)
	}
	clone(): Affine2 {
		return new Affine2(this.a, this.b, this.c, this.d, this.tx, this.ty)
	}
	// set_trs: trs() written into this matrix (no allocation).
	set_trs(px: number, py: number, rotation_deg: number, sx: number, sy: number): Affine2 {
		let cs = 1
		let sn = 0
		if (rotation_deg !== 0) {
			const r = (rotation_deg * Math.PI) / 180
			cs = Math.cos(r)
			sn = Math.sin(r)
		}
		this.a = cs * sx
		this.b = sn * sx
		this.c = -sn * sy
		this.d = cs * sy
		this.tx = px
		this.ty = py
		return this
	}
	// set_mul: this = m * o, without allocating (`this` may be `m` or `o`).
	set_mul(m: Affine2, o: Affine2): Affine2 {
		const a = m.a * o.a + m.c * o.b
		const b = m.b * o.a + m.d * o.b
		const c = m.a * o.c + m.c * o.d
		const d = m.b * o.c + m.d * o.d
		const tx = m.a * o.tx + m.c * o.ty + m.tx
		const ty = m.b * o.tx + m.d * o.ty + m.ty
		this.a = a
		this.b = b
		this.c = c
		this.d = d
		this.tx = tx
		this.ty = ty
		return this
	}
	// mul returns m * o (applies o first, then m).
	mul(o: Affine2): Affine2 {
		const m = this
		return new Affine2(
			m.a * o.a + m.c * o.b,
			m.b * o.a + m.d * o.b,
			m.a * o.c + m.c * o.d,
			m.b * o.c + m.d * o.d,
			m.a * o.tx + m.c * o.ty + m.tx,
			m.b * o.tx + m.d * o.ty + m.ty,
		)
	}
	apply(p: Vec2): Vec2 {
		return new Vec2(this.a * p.x + this.c * p.y + this.tx, this.b * p.x + this.d * p.y + this.ty)
	}
	// apply_xy: apply() without allocating a Vec2 for the input (used by the renderer).
	apply_x(x: number, y: number): number {
		return this.a * x + this.c * y + this.tx
	}
	apply_y(x: number, y: number): number {
		return this.b * x + this.d * y + this.ty
	}
	position(): Vec2 {
		return new Vec2(this.tx, this.ty)
	}
	rotation_deg(): number {
		return (Math.atan2(this.b, this.a) * 180) / Math.PI
	}
	scale(): Vec2 {
		const sx = Math.sqrt(this.a * this.a + this.b * this.b)
		const det = this.a * this.d - this.b * this.c
		const sy = Math.sqrt(this.c * this.c + this.d * this.d)
		return new Vec2(sx, det < 0 ? -sy : sy)
	}
	inverse(): Affine2 {
		const m = this
		const det = m.a * m.d - m.b * m.c
		if (Math.abs(det) < 1e-9) return new Affine2()
		const inv = 1 / det
		return new Affine2(m.d * inv, -m.b * inv, -m.c * inv, m.a * inv, (m.c * m.ty - m.d * m.tx) * inv, (m.b * m.tx - m.a * m.ty) * inv)
	}
	op_eq(o: Affine2): boolean {
		return this.a === o.a && this.b === o.b && this.c === o.c && this.d === o.d && this.tx === o.tx && this.ty === o.ty
	}
}

// ---------- Component (core/component.v) ----------

// IComponent — what every component has (Component provides all of it).
export interface IComponent {
	node: Node
	enabled: boolean
	started: boolean
	on_load(): void
	start(): void
	update(dt: number): void
	on_destroy(): void
}

// Component — base to extend (embed in V). The default lifecycle methods do nothing.
export class Component implements IComponent {
	static __vname = 'core.Component'
	static __fields: FieldSpec[] = []
	node: Node = null as unknown as Node
	enabled = true
	started = false
	on_load() {}
	start() {}
	update(_dt: number) {}
	on_destroy() {}
	scene(): Scene {
		return this.node.scene
	}
	input(): Input {
		return this.node.scene.input
	}
	assets(): AssetDatabase {
		return this.node.scene.assets
	}
}

// FieldSpec — a serializable field, as V's comptime reflection sees it (see serialize.set_fields).
// `type`: f32 | f64 | int | bool | string | []int | Vec2 | Color | asset:<texture|scene|audio|text|font>
export interface FieldSpec {
	name: string
	type: string
	choices?: string[]
}

// ---------- Node (core/node.v) ----------

export class Node {
	static __vname = 'core.Node'
	name = ''
	position = new Vec2()
	rotation = 0 // degrees, positive = clockwise on screen
	scale = new Vec2(1, 1)
	active = true
	z_index = 0
	y_sort = false
	unscaled_time = false
	persistent = false
	parent: Node | null = null
	children: Node[] = []
	components: IComponent[] = []
	scene: Scene = null as unknown as Scene
	destroyed = false
	prefab_id = ''
	tweens: Tween[] = []
	timers: Timer[] = []
	// local_matrix_ref() cache: the transform it was computed from
	_lm = new Affine2()
	_lm_ok = false
	_lm_px = 0
	_lm_py = 0
	_lm_rot = 0
	_lm_sx = 1
	_lm_sy = 1

	static new(name: string): Node {
		const n = new Node()
		n.name = name
		return n
	}

	// ---------- Parent / child tree ----------

	add_child(child: Node): Node {
		return this.insert_child(child, this.children.length)
	}

	insert_child(child: Node, index: number): Node {
		if (child.parent !== null) child.remove_from_parent()
		child.parent = this
		const i = index < 0 ? 0 : index > this.children.length ? this.children.length : index
		this.children.splice(i, 0, child)
		if (this.scene && child.scene !== this.scene) child.attach_to_scene(this.scene)
		return child
	}

	child_index(): number {
		if (this.parent === null) return -1
		return this.parent.children.indexOf(this)
	}

	is_ancestor_of(other: Node | null): boolean {
		let cur = other
		while (cur !== null) {
			if (cur === this) return true
			cur = cur.parent
		}
		return false
	}

	child(c: Node): Node {
		this.add_child(c)
		return this
	}

	remove_from_parent() {
		if (this.parent === null) return
		const p = this.parent
		const i = p.children.indexOf(this)
		if (i >= 0) p.children.splice(i, 1)
		this.parent = null
	}

	// find looks up a child node by path 'World/Player/Weapon' (relative to this node).
	find(path: string): Node | null {
		let cur: Node = this
		for (const part of path.split('/')) {
			if (part === '' || part === '.') continue
			if (part === '..') {
				if (cur.parent === null) return null
				cur = cur.parent
				continue
			}
			let found: Node | null = null
			for (const c of cur.children) {
				if (c.name === part && !c.destroyed) {
					found = c
					break
				}
			}
			if (found === null) return null
			cur = found
		}
		return cur
	}

	path(): string {
		if (this.parent === null) return this.name
		return `${this.parent.path()}/${this.name}`
	}

	is_active_in_hierarchy(): boolean {
		if (!this.active || this.destroyed) return false
		if (this.parent === null) return true
		return this.parent.is_active_in_hierarchy()
	}

	// ---------- Component ----------

	add_component<T extends IComponent>(_t: V.TypeDesc, c: T): T {
		this.add_component_dyn(c)
		return c
	}

	with(c: IComponent): Node {
		this.add_component_dyn(c)
		return this
	}

	add_component_dyn(c: IComponent) {
		this.components.push(c)
		c.node = this
		if (this.scene) c.on_load()
	}

	remove_component(idx: number) {
		if (idx < 0 || idx >= this.components.length) return
		if (this.scene) this.components[idx].on_destroy()
		this.components.splice(idx, 1)
	}

	get_component<T>(t: V.TypeDesc): T | null {
		for (const c of this.components) if (V.is_type(c, t)) return c as unknown as T
		return null
	}

	get_components<T>(t: V.TypeDesc): T[] {
		return this.components.filter((c) => V.is_type(c, t)) as unknown as T[]
	}

	get_component_in_children<T>(t: V.TypeDesc): T | null {
		const c = this.get_component<T>(t)
		if (c !== null) return c
		for (const ch of this.children) {
			const cc = ch.get_component_in_children<T>(t)
			if (cc !== null) return cc
		}
		return null
	}

	component_by_type_name(name: string): IComponent | null {
		for (const c of this.components) if (short_type_name(V.type_name_of(c)) === name) return c
		return null
	}

	// ---------- Transform ----------

	local_matrix(): Affine2 {
		return this.local_matrix_ref().clone()
	}

	// local_matrix_ref: the cached local matrix itself (callers must not change it). sin/cos only run again when
	// position, rotation or scale changed.
	local_matrix_ref(): Affine2 {
		const p = this.position
		const s = this.scale
		if (
			!this._lm_ok || p.x !== this._lm_px || p.y !== this._lm_py || this.rotation !== this._lm_rot ||
			s.x !== this._lm_sx || s.y !== this._lm_sy
		) {
			this._lm.set_trs(p.x, p.y, this.rotation, s.x, s.y)
			this._lm_px = p.x
			this._lm_py = p.y
			this._lm_rot = this.rotation
			this._lm_sx = s.x
			this._lm_sy = s.y
			this._lm_ok = true
		}
		return this._lm
	}

	world_matrix(): Affine2 {
		if (this.parent === null) return this.local_matrix()
		return this.parent.world_matrix().mul(this.local_matrix_ref())
	}

	world_position(): Vec2 {
		return this.world_matrix().position()
	}

	set_world_position(p: Vec2) {
		if (this.parent === null) {
			this.position = p.clone()
			return
		}
		this.position = this.parent.world_matrix().inverse().apply(p)
	}

	// ---------- Destruction ----------

	destroy() {
		if (this.destroyed) return
		this.destroyed = true
		if (this.scene) this.scene.pending_destroy.push(this)
		else this.remove_from_parent()
	}

	// ---------- Internal ----------

	attach_to_scene(s: Scene) {
		this.scene = s
		for (let i = 0; i < this.components.length; i++) this.components[i].on_load()
		for (const ch of this.children.slice()) ch.attach_to_scene(s)
	}

	detach_from_scene() {
		for (const ch of this.children.slice()) ch.detach_from_scene()
		for (let i = 0; i < this.components.length; i++) this.components[i].on_destroy()
		this.scene = null as unknown as Scene
	}

	// `stack` is scratch space shared by the whole walk (see Scene.tick_stack): each node snapshots its children on
	// top of it instead of copying its child list.
	tick(dt: number, real: number, paused: boolean, stack: TickStack = new TickStack()) {
		if (!this.active || this.destroyed) return
		const d = this.unscaled_time ? real : dt
		const p = paused && !this.unscaled_time
		if (!p) {
			// components/children added during this frame run starting next frame
			const count = this.components.length
			for (let i = 0; i < count && i < this.components.length; i++) {
				const c = this.components[i]
				if (!c.enabled) continue
				if (!c.started) {
					c.started = true
					c.start()
				}
				c.update(d)
			}
			this.tick_timers(d)
			this.tick_tweens(d)
		}
		// snapshot the children: nodes added, removed or moved during this frame do not change who ticks now
		const base = stack.top
		const kids = this.children
		const end = base + kids.length
		const a = stack.nodes
		for (let i = 0; i < kids.length; i++) a[base + i] = kids[i]
		stack.top = end
		for (let i = base; i < end; i++) a[i].tick(d, real, p, stack)
		stack.top = base
	}

	// ---------- Timers (core/timer.v) ----------

	after(seconds: number, f: () => void): Timer {
		const t = new Timer()
		t.left = seconds
		t.cb = f
		this.timers.push(t)
		return t
	}

	every(seconds: number, f: () => void): Timer {
		const t = new Timer()
		t.left = seconds
		t.interval = seconds
		t.repeat = true
		t.cb = f
		this.timers.push(t)
		return t
	}

	cancel_timers() {
		for (const t of this.timers) t.done = true
	}

	tick_timers(dt: number) {
		if (this.timers.length === 0) return
		const count = this.timers.length
		for (let i = 0; i < count; i++) {
			const t = this.timers[i]
			if (t.done) continue
			t.left -= dt
			let calls = 0
			while (t.left <= 0 && !t.done && !this.destroyed && calls < 10) {
				calls++
				if (t.repeat && t.interval > 0) t.left += t.interval
				else t.done = true
				if (t.cb) t.cb()
			}
			if (calls >= 10 && t.left < 0) t.left = t.interval
		}
		this.timers = this.timers.filter((t) => !t.done)
	}

	// ---------- Tweens (core/tween.v) ----------

	tween(): Tween {
		const t = new Tween()
		t.node = this
		this.tweens.push(t)
		return t
	}

	kill_tweens() {
		for (const t of this.tweens) t.done = true
	}

	tick_tweens(dt: number) {
		if (this.tweens.length === 0) return
		const count = this.tweens.length
		for (let i = 0; i < count; i++) this.tweens[i].advance(dt)
		this.tweens = this.tweens.filter((t) => !t.done)
	}

	// ---------- Camera helpers (core/camera.v) ----------

	in_canvas(): boolean {
		let cur: Node | null = this
		while (cur !== null) {
			if (cur.get_component(Canvas) !== null) return true
			cur = cur.parent
		}
		return false
	}

	screen_matrix(): Affine2 {
		const m = this.world_matrix()
		if (!this.scene || this.in_canvas()) return m
		return this.scene.view_matrix().mul(m)
	}

	move_to_scene(from: Scene, to: Scene) {
		this.scene = to
		const moved = from.cameras.filter((c) => c.node === this)
		if (moved.length > 0) {
			from.cameras = from.cameras.filter((c) => c.node !== this)
			to.cameras.push(...moved)
		}
		for (const ch of this.children) ch.move_to_scene(from, to)
	}

	str(): string {
		return `Node(${this.path()})`
	}
}

// short_type_name: 'main.PlayerController' -> 'PlayerController', '&render.Sprite' -> 'Sprite'.
export function short_type_name(full: string): string {
	const t = full.replace(/^&+/, '')
	const i = t.lastIndexOf('.')
	return i < 0 ? t : t.slice(i + 1)
}

// ---------- Timer (core/timer.v) ----------

export class Timer {
	static __vname = 'core.Timer'
	left = 0
	interval = 0
	repeat = false
	cb: (() => void) | null = null
	done = false
	cancel() {
		this.done = true
	}
	is_pending(): boolean {
		return !this.done
	}
	time_left(): number {
		return this.done ? 0 : this.left
	}
}

// ---------- Tween (core/tween.v) ----------

// Ease — how a tween's progress maps to its value. Enum values are their names (strings) in the WebGL runtime.
export type Ease =
	| 'linear'
	| 'quad_in'
	| 'quad_out'
	| 'quad_in_out'
	| 'cubic_in'
	| 'cubic_out'
	| 'cubic_in_out'
	| 'sine_in'
	| 'sine_out'
	| 'sine_in_out'
	| 'expo_in'
	| 'expo_out'
	| 'back_in'
	| 'back_out'
	| 'back_in_out'
	| 'elastic_out'
	| 'bounce_out'

export const Ease__values: Ease[] = [
	'linear',
	'quad_in',
	'quad_out',
	'quad_in_out',
	'cubic_in',
	'cubic_out',
	'cubic_in_out',
	'sine_in',
	'sine_out',
	'sine_in_out',
	'expo_in',
	'expo_out',
	'back_in',
	'back_out',
	'back_in_out',
	'elastic_out',
	'bounce_out',
]

// Ease__apply is V's `e.apply(t)`: maps linear progress `t` (0..1) through the easing curve.
export function Ease__apply(e: Ease, t: number): number {
	const x = t
	const c1 = 1.70158
	const c2 = c1 * 1.525
	const c3 = c1 + 1
	switch (e) {
		case 'linear':
			return x
		case 'quad_in':
			return x * x
		case 'quad_out':
			return 1 - (1 - x) * (1 - x)
		case 'quad_in_out':
			return x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2
		case 'cubic_in':
			return x * x * x
		case 'cubic_out':
			return 1 - Math.pow(1 - x, 3)
		case 'cubic_in_out':
			return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2
		case 'sine_in':
			return 1 - Math.cos((x * Math.PI) / 2)
		case 'sine_out':
			return Math.sin((x * Math.PI) / 2)
		case 'sine_in_out':
			return -(Math.cos(Math.PI * x) - 1) / 2
		case 'expo_in':
			return x <= 0 ? 0 : Math.pow(2, 10 * x - 10)
		case 'expo_out':
			return x >= 1 ? 1 : 1 - Math.pow(2, -10 * x)
		case 'back_in':
			return c3 * x * x * x - c1 * x * x
		case 'back_out':
			return 1 + c3 * Math.pow(x - 1, 3) + c1 * Math.pow(x - 1, 2)
		case 'back_in_out':
			return x < 0.5
				? (Math.pow(2 * x, 2) * ((c2 + 1) * 2 * x - c2)) / 2
				: (Math.pow(2 * x - 2, 2) * ((c2 + 1) * (x * 2 - 2) + c2) + 2) / 2
		case 'elastic_out':
			return x <= 0 ? 0 : x >= 1 ? 1 : Math.pow(2, -10 * x) * Math.sin((x * 10 - 0.75) * ((2 * Math.PI) / 3)) + 1
		case 'bounce_out':
			return bounce_out(x)
	}
	return x
}

function bounce_out(x: number): number {
	const n1 = 7.5625
	const d1 = 2.75
	if (x < 1 / d1) return n1 * x * x
	if (x < 2 / d1) {
		const y = x - 1.5 / d1
		return n1 * y * y + 0.75
	}
	if (x < 2.5 / d1) {
		const y = x - 2.25 / d1
		return n1 * y * y + 0.9375
	}
	const y = x - 2.625 / d1
	return n1 * y * y + 0.984375
}

export function ease_from_str(s: string): Ease {
	if ((Ease__values as string[]).includes(s)) return s as Ease
	throw new V.VError(`unknown ease "${s}"`)
}

type TrackKind = 'position' | 'rotation' | 'scale' | 'value' | 'call'

class Track {
	kind: TrackKind = 'position'
	duration = 0
	relative = false
	ease: Ease = 'linear'
	target = new Vec2()
	get: (() => number) | null = null
	set: ((v: number) => void) | null = null
	on_call: (() => void) | null = null
	from = new Vec2()
	to = new Vec2()
	captured = false
}

class Step {
	duration = 0
	tracks: Track[] = []
}

export class Tween {
	static __vname = 'core.Tween'
	node: Node | null = null
	steps: Step[] = []
	join_next = false
	step = 0
	elapsed = 0
	delay_left = 0
	loops = 1
	loop_index = 0
	yoyo = false
	complete_cb: (() => void) | null = null
	paused = false
	done = false

	private add(dur: number, init: Partial<Track>): Tween {
		const tr = Object.assign(new Track(), init)
		tr.duration = dur
		if (this.join_next && this.steps.length > 0) {
			const last = this.steps[this.steps.length - 1]
			last.tracks.push(tr)
			if (dur > last.duration) last.duration = dur
		} else {
			const s = new Step()
			s.duration = dur
			s.tracks = [tr]
			this.steps.push(s)
		}
		this.join_next = false
		return this
	}

	also(): Tween {
		this.join_next = true
		return this
	}
	move_to(p: Vec2, duration: number, ease: Ease): Tween {
		return this.add(duration, { kind: 'position', target: p.clone(), ease })
	}
	move_by(d: Vec2, duration: number, ease: Ease): Tween {
		return this.add(duration, { kind: 'position', target: d.clone(), ease, relative: true })
	}
	rotate_to(deg: number, duration: number, ease: Ease): Tween {
		return this.add(duration, { kind: 'rotation', target: new Vec2(deg, 0), ease })
	}
	rotate_by(deg: number, duration: number, ease: Ease): Tween {
		return this.add(duration, { kind: 'rotation', target: new Vec2(deg, 0), ease, relative: true })
	}
	scale_to(s: Vec2, duration: number, ease: Ease): Tween {
		return this.add(duration, { kind: 'scale', target: s.clone(), ease })
	}
	value(get: () => number, set: (v: number) => void, to: number, duration: number, ease: Ease): Tween {
		return this.add(duration, { kind: 'value', target: new Vec2(to, 0), ease, get, set })
	}
	progress(set: (v: number) => void, duration: number, ease: Ease): Tween {
		return this.add(duration, { kind: 'value', target: new Vec2(1, 0), ease, get: () => 0, set })
	}
	wait(seconds: number): Tween {
		const s = new Step()
		s.duration = seconds
		this.steps.push(s)
		this.join_next = false
		return this
	}
	call(f: () => void): Tween {
		return this.add(0, { kind: 'call', on_call: f })
	}
	delay(seconds: number): Tween {
		this.delay_left = seconds
		return this
	}
	repeat(times: number, yoyo: boolean): Tween {
		this.loops = times
		this.yoyo = yoyo
		return this
	}
	on_complete(f: () => void): Tween {
		this.complete_cb = f
		return this
	}
	kill() {
		this.done = true
	}
	pause() {
		this.paused = true
	}
	resume() {
		this.paused = false
	}
	is_playing(): boolean {
		return !this.done
	}
	finish() {
		if (this.done) return
		if (this.loops < 0) this.loops = this.loop_index + 1
		this.paused = false
		this.delay_left = 0
		this.advance(1e9)
	}

	advance(dt_in: number) {
		if (this.done || this.paused || this.node === null) return
		let dt = dt_in
		if (this.delay_left > 0) {
			this.delay_left -= dt
			if (this.delay_left > 0) return
			dt = -this.delay_left
			this.delay_left = 0
		}
		let empty_passes = 0
		while (!this.done && !this.node.destroyed) {
			if (this.step >= this.steps.length) {
				this.loop_index++
				if (this.loops >= 0 && this.loop_index >= this.loops) {
					this.done = true
					if (this.complete_cb) this.complete_cb()
					return
				}
				this.step = 0
				empty_passes++
				if (empty_passes > 1 || this.steps.length === 0) return
				continue
			}
			const backwards = this.yoyo && this.loop_index % 2 === 1
			const idx = backwards ? this.steps.length - 1 - this.step : this.step
			if (this.elapsed === 0) this.start_step(idx)
			const dur = this.steps[idx].duration
			const remaining = dur - this.elapsed
			if (dt < remaining) {
				this.elapsed += dt
				this.apply(idx, this.elapsed, backwards)
				return
			}
			if (remaining > 0) empty_passes = 0
			dt -= remaining
			this.apply(idx, dur, backwards)
			this.fire_calls(idx)
			this.step++
			this.elapsed = 0
		}
	}

	private start_step(idx: number) {
		const n = this.node!
		for (const tr of this.steps[idx].tracks) {
			if (tr.captured) continue
			tr.captured = true
			switch (tr.kind) {
				case 'position':
					tr.from = n.position.clone()
					break
				case 'rotation':
					tr.from = new Vec2(n.rotation, 0)
					break
				case 'scale':
					tr.from = n.scale.clone()
					break
				case 'value':
					tr.from = new Vec2(tr.get ? tr.get() : 0, 0)
					break
			}
			tr.to = tr.relative ? tr.from.op_add(tr.target) : tr.target.clone()
		}
	}

	private apply(idx: number, elapsed: number, backwards: boolean) {
		const n = this.node!
		const at = backwards ? this.steps[idx].duration - elapsed : elapsed
		for (const tr of this.steps[idx].tracks) {
			if (tr.kind === 'call') continue
			const u = tr.duration <= 0 || at >= tr.duration ? 1 : at <= 0 ? 0 : at / tr.duration
			const k = Ease__apply(tr.ease, u)
			const vx = tr.from.x + (tr.to.x - tr.from.x) * k
			const vy = tr.from.y + (tr.to.y - tr.from.y) * k
			switch (tr.kind) {
				case 'position':
					n.position = new Vec2(vx, vy)
					break
				case 'rotation':
					n.rotation = vx
					break
				case 'scale':
					n.scale = new Vec2(vx, vy)
					break
				case 'value':
					if (tr.set) tr.set(vx)
					break
			}
		}
	}

	private fire_calls(idx: number) {
		for (const tr of this.steps[idx].tracks) {
			if (tr.kind === 'call' && tr.on_call && !this.node!.destroyed) tr.on_call()
		}
	}
}

// ---------- Scene (core/scene.v) ----------

export type InstantiateFn = (key: string) => Node

// SceneChange — how change_scene switches: a fade to `color` and back, `fade` seconds each way (0 = cut).
export class SceneChange {
	static __vname = 'core.SceneChange'
	fade = 0.25
	color = rgba(0, 0, 0, 255)
	clone(): SceneChange {
		const s = new SceneChange()
		s.fade = this.fade
		s.color = this.color.clone()
		return s
	}
}

function scene_change(opts?: Partial<SceneChange>): SceneChange {
	const s = new SceneChange()
	if (opts) {
		if (opts.fade !== undefined) s.fade = opts.fade
		if (opts.color !== undefined) s.color = opts.color.clone()
	}
	return s
}

export class Scene {
	static __vname = 'core.Scene'
	name = ''
	root: Node
	input: Input
	assets: AssetDatabase = null as unknown as AssetDatabase
	time = 0
	real_time = 0
	frame = 0
	time_scale = 1
	paused = false
	dt = 0
	unscaled_dt = 0
	pending_destroy: Node[] = []
	tick_stack = new TickStack() // scratch space for the update walk (see Node.tick)
	instantiate_fn: InstantiateFn | null = null
	view_origin = new Vec2()
	view_size = new Vec2(960, 540)
	safe_insets = new Insets()
	cameras: Camera[] = []
	key = ''
	store: Store = new Store()
	locale: Locale = new Locale() // the game's texts, shared by every scene (App fills it from `locales/*.txt`)
	next_scene = ''
	next_change = new SceneChange()

	constructor() {
		this.root = Node.new('')
		this.input = new Input()
	}

	static new(name: string): Scene {
		const s = new Scene()
		s.name = name
		s.root = Node.new(name)
		s.root.scene = s
		return s
	}

	change_scene(key: string, opts?: Partial<SceneChange>) {
		this.next_scene = key
		this.next_change = scene_change(opts)
	}

	reload(opts?: Partial<SceneChange>) {
		this.change_scene(this.key, opts)
	}

	take_persistent(from: Scene) {
		const keep = from.root.children.filter((n) => n.persistent && !n.destroyed)
		for (const n of keep) {
			for (const other of this.root.children.filter((o) => o.name === n.name)) other.destroy()
			this.flush_destroyed()
			n.remove_from_parent()
			n.move_to_scene(from, this)
			this.root.children.push(n)
			n.parent = this.root
		}
	}

	set_root(root: Node) {
		root.remove_from_parent()
		this.root = root
		root.attach_to_scene(this)
	}

	add(n: Node): Node {
		return this.root.add_child(n)
	}

	find(path: string): Node | null {
		return this.root.find(path)
	}

	instantiate(key: string, parent: Node): Node {
		if (this.instantiate_fn === null) throw new V.VError(`scene "${this.name}" has no prefab loader (run it through app.App)`)
		const n = this.instantiate_fn(key)
		parent.add_child(n)
		return n
	}

	update(real_dt: number) {
		const dt = this.paused ? 0 : real_dt * (this.time_scale > 0 ? this.time_scale : 0)
		this.dt = dt
		this.unscaled_dt = real_dt
		this.time += dt
		this.real_time += real_dt
		this.frame++
		this.root.tick(dt, real_dt, this.paused, this.tick_stack)
		const cam = this.active_camera()
		if (cam !== null) cam.late_update(cam.node.unscaled_time ? real_dt : dt)
		this.flush_destroyed()
	}

	view_center(): Vec2 {
		return this.view_origin.op_add(this.view_size.mul(0.5))
	}

	active_camera(): Camera | null {
		for (const c of this.cameras) {
			if (c.enabled && c.node && !c.node.destroyed && c.node.is_active_in_hierarchy()) return c
		}
		return null
	}

	view_matrix(): Affine2 {
		const c = this.active_camera()
		if (c !== null) return c.view_matrix()
		return Affine2.identity()
	}

	screen_to_world(p: Vec2): Vec2 {
		return this.view_matrix().inverse().apply(p)
	}

	world_to_screen(p: Vec2): Vec2 {
		return this.view_matrix().apply(p)
	}

	flush_destroyed() {
		while (this.pending_destroy.length > 0) {
			const batch = this.pending_destroy.slice()
			this.pending_destroy.length = 0
			for (const n of batch) {
				n.detach_from_scene()
				n.remove_from_parent()
			}
		}
	}

	unload() {
		this.root.detach_from_scene()
		this.pending_destroy.length = 0
	}

	node_count(): number {
		return count_nodes(this.root)
	}

	after(seconds: number, f: () => void): Timer {
		return this.root.after(seconds, f)
	}

	every(seconds: number, f: () => void): Timer {
		return this.root.every(seconds, f)
	}
}

function count_nodes(n: Node): number {
	let total = 1
	for (const c of n.children) total += count_nodes(c)
	return total
}

// ---------- Camera (core/camera.v) ----------

export class Camera extends Component {
	static __vname = 'core.Camera'
	static __fields: FieldSpec[] = [
		{ name: 'zoom', type: 'f32' },
		{ name: 'follow', type: 'string' },
		{ name: 'follow_offset', type: 'Vec2' },
		{ name: 'smoothing', type: 'f32' },
		{ name: 'limit_min', type: 'Vec2' },
		{ name: 'limit_max', type: 'Vec2' },
	]
	zoom = 1
	follow = ''
	follow_offset = new Vec2()
	smoothing = 0
	limit_min = new Vec2()
	limit_max = new Vec2()
	shake_strength = 0
	shake_time = 0
	shake_duration = 0
	shake_offset = new Vec2()
	registered = false

	on_load() {
		if (this.node.scene && !this.registered) {
			this.node.scene.cameras.push(this)
			this.registered = true
		}
	}

	on_destroy() {
		if (this.node.scene && this.registered) {
			const s = this.node.scene
			s.cameras = s.cameras.filter((c) => c !== this)
		}
		this.registered = false
	}

	shake(strength: number, duration: number) {
		if (strength <= 0 || duration <= 0) return
		const left = this.shake_duration > 0 ? (this.shake_strength * this.shake_time) / this.shake_duration : 0
		if (strength < left) return
		this.shake_strength = strength
		this.shake_time = duration
		this.shake_duration = duration
	}

	late_update(dt: number) {
		if (this.follow !== '' && this.node.scene) {
			const target = this.node.scene.find(this.follow)
			if (target !== null) {
				const goal = target.world_position().op_add(this.follow_offset)
				const pos = this.node.world_position()
				const t = this.smoothing > 0 ? 1 - Math.exp(-this.smoothing * dt) : 1
				this.node.set_world_position(pos.lerp(goal, t))
			}
		}
		if (this.shake_time > 0) {
			this.shake_time = Math.max(this.shake_time - dt, 0)
			const amount = (this.shake_strength * this.shake_time) / this.shake_duration
			this.shake_offset = new Vec2((Math.random() * 2 - 1) * amount, (Math.random() * 2 - 1) * amount)
		} else {
			this.shake_offset = new Vec2()
		}
	}

	center(): Vec2 {
		let p = this.node.world_position()
		if (this.node.scene) {
			const half = this.node.scene.view_size.mul(0.5 / this.effective_zoom())
			p = new Vec2(limit_axis(p.x, half.x, this.limit_min.x, this.limit_max.x), limit_axis(p.y, half.y, this.limit_min.y, this.limit_max.y))
		}
		return p.op_add(this.shake_offset)
	}

	effective_zoom(): number {
		return this.zoom > 0.001 ? this.zoom : 1
	}

	view_matrix(): Affine2 {
		const z = this.effective_zoom()
		const mid = this.node.scene ? this.node.scene.view_center() : new Vec2()
		const eye = Affine2.trs(this.center(), this.node.world_matrix().rotation_deg(), new Vec2(1 / z, 1 / z))
		return Affine2.trs(mid, 0, new Vec2(1, 1)).mul(eye.inverse())
	}

	visible_rect(): [Vec2, Vec2] {
		const size = this.node.scene ? this.node.scene.view_size : new Vec2()
		const sz = size.mul(1 / this.effective_zoom())
		return [this.center().op_sub(sz.mul(0.5)), sz]
	}
}

function limit_axis(v: number, half: number, lo: number, hi: number): number {
	if (hi <= lo) return v
	if (hi - lo <= half * 2) return (lo + hi) / 2
	return Math.min(Math.max(v, lo + half), hi - half)
}

// Canvas — its node and everything under it are drawn in screen space.
export class Canvas extends Component {
	static __vname = 'core.Canvas'
	static __fields: FieldSpec[] = []
}

// ---------- Screen (core/screen.v) ----------

export type ScaleMode = 'expand' | 'fit' | 'fill' | 'width' | 'height' | 'none'

export function scale_mode_from_str(s: string): ScaleMode {
	switch (s) {
		case 'expand':
		case '':
			return 'expand'
		case 'fit':
		case 'fill':
		case 'width':
		case 'height':
		case 'none':
			return s
	}
	throw new V.VError(`unknown scale mode "${s}" (expand, fit, fill, width, height or none)`)
}

export class ScreenFit {
	static __vname = 'core.ScreenFit'
	scale = 0
	view_origin = new Vec2()
	view_size = new Vec2()
	area_pos = new Vec2()
	area_size = new Vec2()
	clone(): ScreenFit {
		return Object.assign(new ScreenFit(), {
			scale: this.scale,
			view_origin: this.view_origin.clone(),
			view_size: this.view_size.clone(),
			area_pos: this.area_pos.clone(),
			area_size: this.area_size.clone(),
		})
	}
	to_window(): Affine2 {
		return Affine2.trs(this.area_pos.op_sub(this.view_origin.mul(this.scale)), 0, new Vec2(this.scale, this.scale))
	}
	from_window(p: Vec2): Vec2 {
		const s = this.scale > 0 ? this.scale : 1
		return p.op_sub(this.area_pos).mul(1 / s).op_add(this.view_origin)
	}
	insets_from_window(window: Vec2, ins: Insets): Insets {
		const s = this.scale > 0 ? this.scale : 1
		const right_bar = window.x - this.area_pos.x - this.area_size.x
		const bottom_bar = window.y - this.area_pos.y - this.area_size.y
		return new Insets(
			max0(ins.left - this.area_pos.x) / s,
			max0(ins.top - this.area_pos.y) / s,
			max0(ins.right - right_bar) / s,
			max0(ins.bottom - bottom_bar) / s,
		)
	}
}

function max0(v: number): number {
	return v > 0 ? v : 0
}

export function fit_screen(window: Vec2, design: Vec2, mode: ScaleMode): ScreenFit {
	const f = new ScreenFit()
	if (mode === 'none' || design.x <= 0 || design.y <= 0 || window.x <= 0 || window.y <= 0) {
		f.scale = 1
		f.view_size = window.clone()
		f.area_size = window.clone()
		return f
	}
	const sx = window.x / design.x
	const sy = window.y / design.y
	const s = mode === 'fill' ? Math.max(sx, sy) : mode === 'width' ? sx : mode === 'height' ? sy : Math.min(sx, sy)
	f.scale = s
	if (mode === 'fit') {
		const size = design.mul(s)
		f.view_size = design.clone()
		f.area_pos = window.op_sub(size).mul(0.5)
		f.area_size = size
		return f
	}
	const view = window.mul(1 / s)
	f.view_origin = design.op_sub(view).mul(0.5)
	f.view_size = view
	f.area_size = window.clone()
	return f
}

// ---------- Input (core/input.v) ----------

// Key — key names match V's core.Key enum (`.space`, `.a`, `.left`, `._1`, `.f1`, ...).
export type Key = string

export type TouchPhase = 'began' | 'moved' | 'stationary' | 'ended' | 'cancelled'

export class Touch {
	static __vname = 'core.Touch'
	id = 0
	pos: Vec2
	start: Vec2
	phase: TouchPhase
	constructor(id = 0, pos = new Vec2(), start = new Vec2(), phase: TouchPhase = 'began') {
		this.id = id
		this.pos = pos
		this.start = start
		this.phase = phase
	}
	clone(): Touch {
		return new Touch(this.id, this.pos.clone(), this.start.clone(), this.phase)
	}
	is_up(): boolean {
		return this.phase === 'ended' || this.phase === 'cancelled'
	}
}

interface PendingTouchEnd {
	id: number
	pos: Vec2
	cancelled: boolean
}

// The id of the mouse in Input.pointers (V: u64 max).
export const mouse_pointer_id = 18446744073709551615

export class Input {
	static __vname = 'core.Input'
	down = new Map<string, boolean>()
	pressed = new Map<string, boolean>()
	released = new Map<string, boolean>()
	repeated = new Map<string, boolean>()
	mouse_touch = 0
	mouse_start = new Vec2()
	release_pending = false
	ends_pending: PendingTouchEnd[] = []
	mouse = new Vec2()
	mouse_down = false
	mouse_pressed = false
	mouse_released = false
	scroll = new Vec2()
	touches: Touch[] = []
	mouse_from_touch = false
	text = ''
	text_editing = false

	is_down(k: Key): boolean {
		return this.down.get(k) === true
	}
	was_pressed(k: Key): boolean {
		return this.pressed.get(k) === true
	}
	was_released(k: Key): boolean {
		return this.released.get(k) === true
	}
	axis(negative: Key, positive: Key): number {
		let v = 0
		if (this.is_down(negative)) v -= 1
		if (this.is_down(positive)) v += 1
		return v
	}
	axis_x(): number {
		return clamp1(this.axis('left', 'right') + this.axis('a', 'd'))
	}
	axis_y(): number {
		return clamp1(this.axis('up', 'down') + this.axis('w', 's'))
	}
	key_down(code: Key) {
		if (!this.down.get(code)) this.pressed.set(code, true)
		this.down.set(code, true)
	}
	key_repeat(code: Key) {
		this.repeated.set(code, true)
	}
	was_typed(k: Key): boolean {
		return this.pressed.get(k) === true || this.repeated.get(k) === true
	}
	type_char(c: number) {
		if (c < 32 || c === 127) return
		this.text += String.fromCodePoint(c)
	}
	key_up(code: Key) {
		this.down.set(code, false)
		this.released.set(code, true)
	}
	mouse_press() {
		if (!this.mouse_down) {
			this.mouse_pressed = true
			this.mouse_start = this.mouse.clone()
		}
		this.mouse_down = true
	}
	mouse_release() {
		if (this.mouse_down && this.mouse_pressed) {
			this.release_pending = true
			return
		}
		if (this.mouse_down) this.mouse_released = true
		this.mouse_down = false
	}
	mouse_scroll(dx: number, dy: number) {
		this.scroll = this.scroll.op_add(new Vec2(dx, dy))
	}
	touch(id: number): Touch | null {
		for (const t of this.touches) if (t.id === id) return t.clone()
		return null
	}
	pointers(): Touch[] {
		const out = this.touches.map((t) => t.clone())
		if (!this.mouse_from_touch && (this.mouse_down || this.mouse_released)) {
			const phase: TouchPhase = this.mouse_released ? 'ended' : this.mouse_pressed ? 'began' : 'moved'
			out.push(new Touch(mouse_pointer_id, this.mouse.clone(), this.mouse_start.clone(), phase))
		}
		return out
	}
	pointer(id: number): Touch | null {
		if (id === mouse_pointer_id) {
			for (const p of this.pointers()) if (p.id === id) return p
			return null
		}
		return this.touch(id)
	}
	end_frame() {
		this.pressed.clear()
		this.released.clear()
		this.repeated.clear()
		this.text = ''
		this.text_editing = false
		this.mouse_pressed = false
		this.mouse_released = false
		this.scroll = new Vec2()
		this.touches = this.touches.filter((t) => !t.is_up())
		for (const t of this.touches) t.phase = 'stationary'
		if (!this.mouse_down) this.mouse_from_touch = false
		if (this.release_pending) {
			this.release_pending = false
			this.mouse_release()
		}
		const ends = this.ends_pending.slice()
		this.ends_pending.length = 0
		for (const e of ends) this.touch_end(e.id, e.pos, e.cancelled)
	}
	touch_begin(id: number, pos: Vec2) {
		this.touches = this.touches.filter((t) => t.id !== id)
		this.touches.push(new Touch(id, pos.clone(), pos.clone(), 'began'))
		if (!this.mouse_down) {
			this.mouse_touch = id
			this.mouse_from_touch = true
			this.mouse = pos.clone()
			this.mouse_press()
		}
	}
	touch_move(id: number, pos: Vec2) {
		for (const t of this.touches) {
			if (t.id === id && !t.is_up()) {
				t.pos = pos.clone()
				if (t.phase === 'stationary') t.phase = 'moved'
			}
		}
		if (this.mouse_from_touch && this.mouse_touch === id) this.mouse = pos.clone()
	}
	touch_end(id: number, pos: Vec2, cancelled: boolean) {
		for (const t of this.touches) {
			if (t.id === id && t.phase === 'began') {
				this.ends_pending.push({ id, pos: pos.clone(), cancelled })
				for (const tt of this.touches) if (tt.id === id) tt.pos = pos.clone()
				return
			}
		}
		for (const t of this.touches) {
			if (t.id === id) {
				t.pos = pos.clone()
				t.phase = cancelled ? 'cancelled' : 'ended'
			}
		}
		if (this.mouse_from_touch && this.mouse_touch === id && this.mouse_down) {
			this.mouse = pos.clone()
			this.mouse_release()
		}
	}
}

function clamp1(v: number): number {
	return v > 1 ? 1 : v < -1 ? -1 : v
}

// ---------- Store (core/store.v) ----------

type StoreValue = { t: 'bool'; v: boolean } | { t: 'int'; v: number } | { t: 'f64'; v: number } | { t: 'string'; v: string }

export class Store {
	static __vname = 'core.Store'
	values = new Map<string, StoreValue>()
	path = ''
	dirty = false
	writer: ((text: string) => void) | null = null

	static open(_path: string): Store {
		return new Store()
	}

	static from_text(text: string): Store {
		const s = new Store()
		s.values = parse_store(text)
		return s
	}

	has(key: string): boolean {
		return this.values.has(key)
	}
	keys(): string[] {
		return [...this.values.keys()].sort()
	}
	get_int(key: string, def: number): number {
		const v = this.values.get(key)
		if (!v) return def
		if (v.t === 'int') return v.v
		if (v.t === 'f64') return Math.trunc(v.v)
		return def
	}
	get_f64(key: string, def: number): number {
		const v = this.values.get(key)
		if (!v) return def
		if (v.t === 'int' || v.t === 'f64') return v.v
		return def
	}
	get_f32(key: string, def: number): number {
		return this.get_f64(key, def)
	}
	get_bool(key: string, def: boolean): boolean {
		const v = this.values.get(key)
		return v && v.t === 'bool' ? v.v : def
	}
	get_string(key: string, def: string): string {
		const v = this.values.get(key)
		return v && v.t === 'string' ? v.v : def
	}
	set_int(key: string, v: number) {
		this.set(key, { t: 'int', v: Math.trunc(v) })
	}
	set_f64(key: string, v: number) {
		this.set(key, { t: 'f64', v })
	}
	set_f32(key: string, v: number) {
		this.set(key, { t: 'f64', v })
	}
	set_bool(key: string, v: boolean) {
		this.set(key, { t: 'bool', v })
	}
	set_string(key: string, v: string) {
		this.set(key, { t: 'string', v })
	}
	private set(key: string, v: StoreValue) {
		if (!valid_key(key)) {
			console.error(`[velo] store key "${key}" must be letters, digits, _ . - (ignored)`)
			return
		}
		const old = this.values.get(key)
		if (old && old.t === v.t && old.v === v.v) return
		this.values.set(key, v)
		this.dirty = true
	}
	delete(key: string) {
		if (this.values.has(key)) {
			this.values.delete(key)
			this.dirty = true
		}
	}
	clear() {
		if (this.values.size > 0) {
			this.values.clear()
			this.dirty = true
		}
	}
	save() {
		const text = this.encode()
		if (this.writer) this.writer(text)
		this.dirty = false
	}
	save_if_changed() {
		if (this.dirty) {
			try {
				this.save()
			} catch (e) {
				console.error(`[velo] cannot save: ${e}`)
			}
		}
	}
	encode(): string {
		const lines = ['# velo save data']
		for (const k of this.keys()) lines.push(`${k} = ${encode_value(this.values.get(k)!)}`)
		return lines.join('\n') + '\n'
	}
}

// ---------- Locale (core/locale.v) ----------

// Locale — the game's text in several languages, shared by every scene through `scene.locale`: one
// `locales/<code>.txt` asset per language (`key = text`, plural forms `key.one` / `key.other` ...). App loads them
// and picks the saved language, else the browser's, else Config.language. A Label with `text_key` follows it.
export class Locale {
	static __vname = 'core.Locale'
	tables = new Map<string, Map<string, string>>() // language -> key -> text
	lang = ''
	warned = new Set<string>()
	fallback = 'en' // used for keys the current language lacks
	store: Store | null = null // saves the chosen language ('language') when set
	version = 0 // counts changes of language or tables

	add_table(lang: string, text: string) {
		this.tables.set(normalize_lang(lang), parse_locale_text(text))
		this.version++
	}
	remove_table(lang: string) {
		this.tables.delete(normalize_lang(lang))
		this.version++
	}
	languages(): string[] {
		return [...this.tables.keys()].sort()
	}
	language(): string {
		return this.lang
	}
	// resolve_language picks the table for a wanted code: exact ('pt-br'), else its base ('pt'), else ''.
	resolve_language(code: string): string {
		const c = normalize_lang(code)
		if (this.tables.has(c)) return c
		const base = c.split('-')[0]
		return this.tables.has(base) ? base : ''
	}
	// set_language switches language (and saves the choice). false when no table matches the code.
	set_language(code: string): boolean {
		const found = this.resolve_language(code)
		if (found === '') return false
		this.apply(found)
		if (this.store !== null) this.store.set_string('language', found)
		return true
	}
	apply(code: string) {
		if (this.lang !== code) {
			this.lang = code
			this.version++
		}
	}
	// choose_startup_language: the saved language, else the system's, else `default_lang`, else the fallback,
	// else any table. Does not write the store.
	choose_startup_language(saved: string, default_lang: string) {
		for (const c of [saved, system_language(), default_lang, this.fallback]) {
			const found = this.resolve_language(c)
			if (found !== '') {
				this.apply(found)
				return
			}
		}
		const langs = this.languages()
		if (langs.length > 0) this.apply(langs[0])
	}
	// find returns the text of a key in the current language, else in the fallback; null when neither has it.
	find(key: string): string | null {
		const t = this.tables.get(this.lang)
		if (t !== undefined) {
			const s = t.get(key)
			if (s !== undefined) return s
			// 'pt-br' falls back to 'pt' before the fallback language
			const base = this.lang.split('-')[0]
			if (base !== this.lang) {
				const b = this.tables.get(base)?.get(key)
				if (b !== undefined) return b
			}
		}
		return this.tables.get(this.fallback)?.get(key) ?? null
	}
	has(key: string): boolean {
		return this.find(key) !== null
	}
	// tr returns the text of a key; a missing key gives the key itself (and is reported once).
	tr(key: string): string {
		const s = this.find(key)
		if (s !== null) return s
		if (!this.warned.has(key)) {
			this.warned.add(key)
			console.warn(`[velo] missing text "${key}" (language ${this.lang})`)
		}
		return key
	}
	// tr_args translates and replaces `{name}` with args[name].
	tr_args(key: string, args: Map<string, string>): string {
		return format_locale(this.tr(key), args)
	}
	// tr_n picks the plural form for `n` (`key.one`, `key.other`, ...), falling back to `key.other`, then `key`.
	tr_n(key: string, n: number): string {
		const cat = plural_category(this.lang, n)
		for (const k of [`${key}.${cat}`, `${key}.other`, key]) {
			const s = this.find(k)
			if (s !== null) return format_locale(s, new Map([['n', String(n)]]))
		}
		return this.tr(key)
	}
}

// normalize_lang: 'pt_BR.UTF-8' -> 'pt-br'.
export function normalize_lang(code: string): string {
	let c = code.split('.')[0].split('@')[0].replaceAll('_', '-').toLowerCase().trim()
	if (c === 'c' || c === 'posix') c = ''
	return c
}

// parse_locale_text reads the `key = text` format.
export function parse_locale_text(text: string): Map<string, string> {
	const out = new Map<string, string>()
	for (const line of text.split(/\r?\n/)) {
		const l = line.trim()
		if (l === '' || l.startsWith('#')) continue
		const i = l.indexOf('=')
		if (i < 0) continue
		out.set(l.slice(0, i).trim(), unescape_locale(l.slice(i + 1).trim()))
	}
	return out
}

function unescape_locale(s: string): string {
	if (!s.includes('\\')) return s
	return s.replace(/\\(.)/g, (_, c: string) => (c === 'n' ? '\n' : c === 't' ? '\t' : c))
}

function format_locale(text: string, args: Map<string, string>): string {
	if (args.size === 0 || !text.includes('{')) return text
	let out = text
	for (const [k, v] of args) out = out.replaceAll(`{${k}}`, v)
	return out
}

// system_language: the browser's language ('' when unknown).
export function system_language(): string {
	const nav = (globalThis as any).navigator
	const l = nav?.languages?.[0] ?? nav?.language ?? ''
	return normalize_lang(l)
}

// plural_category: 'zero' | 'one' | 'few' | 'many' | 'other' for a whole number, for the common languages.
export function plural_category(lang: string, n: number): string {
	const base = lang.split('-')[0]
	const count = Math.abs(Math.trunc(n))
	switch (base) {
		case 'ja': case 'zh': case 'ko': case 'vi': case 'th': case 'id': case 'ms': case 'lo': case 'my': case 'km':
			return 'other'
		case 'fr': case 'pt':
			return count === 0 || count === 1 ? 'one' : 'other'
		case 'ru': case 'uk': case 'be':
			if (count % 10 === 1 && count % 100 !== 11) return 'one'
			if (count % 10 >= 2 && count % 10 <= 4 && (count % 100 < 12 || count % 100 > 14)) return 'few'
			return 'many'
		case 'pl':
			if (count === 1) return 'one'
			if (count % 10 >= 2 && count % 10 <= 4 && (count % 100 < 12 || count % 100 > 14)) return 'few'
			return 'many'
		default:
			return count === 1 ? 'one' : 'other'
	}
}

function encode_value(v: StoreValue): string {
	switch (v.t) {
		case 'bool':
			return v.v ? 'true' : 'false'
		case 'int':
			return String(v.v)
		case 'f64': {
			const t = String(v.v)
			return t.includes('.') || t.includes('e') || t.includes('n') ? t : t + '.0'
		}
		case 'string':
			return '"' + v.v.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r') + '"'
	}
}

function parse_store(text: string): Map<string, StoreValue> {
	const out = new Map<string, StoreValue>()
	const lines = V.S.split_into_lines(text)
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i].trim()
		if (line === '' || line.startsWith('#')) continue
		if (!line.includes('=')) throw new V.VError(`line ${i + 1}: expected \`key = value\``)
		const key = V.S.all_before(line, '=').trim()
		const val = V.S.all_after(line, '=').trim()
		if (!valid_key(key)) throw new V.VError(`line ${i + 1}: bad key "${key}"`)
		out.set(key, parse_store_value(val, i + 1))
	}
	return out
}

function parse_store_value(t: string, line: number): StoreValue {
	if (t === 'true' || t === 'false') return { t: 'bool', v: t === 'true' }
	if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
		const body = t.slice(1, -1)
		let s = ''
		for (let i = 0; i < body.length; i++) {
			const c = body[i]
			if (c === '\\' && i + 1 < body.length) {
				const n = body[i + 1]
				s += n === 'n' ? '\n' : n === 'r' ? '\r' : n
				i++
				continue
			}
			s += c
		}
		return { t: 'string', v: s }
	}
	if (t.includes('.') || t.includes('e') || t.includes('n')) {
		const v = Number(t)
		if (Number.isNaN(v) && t !== 'nan') throw new V.VError(`line ${line}: bad number "${t}"`)
		return { t: 'f64', v }
	}
	if (!/^[+-]?\d+$/.test(t)) throw new V.VError(`line ${line}: bad value "${t}"`)
	return { t: 'int', v: parseInt(t, 10) }
}

function valid_key(k: string): boolean {
	return /^[A-Za-z0-9_.-]+$/.test(k)
}
