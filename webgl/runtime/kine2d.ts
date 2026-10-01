// velo.kine2d for the WebGL runtime — a port of kine2d/*.v: plays skeletal animations exported by the Kine2D
// editor (<name>.skel.json + <name>.atlas.json + <name>.png) and draws them as render.TexturedMesh.

import * as V from './v.ts'
import * as core from './core.ts'
import * as assets from './assets.ts'
import * as render from './render.ts'
import type * as serialize from './serialize.ts'

type FieldSpec = core.FieldSpec

export const default_canvas_width = 800
export const default_canvas_height = 600

// ---------- Data (kine2d/data.v) ----------

export class Bone {
	static __vname = 'kine2d.Bone'
	name = ''
	id = ''
	parent = ''
	x = 0
	y = 0
	rotation = 0
	scale_x = 1
	scale_y = 1
	pose(): Pose {
		return new Pose(this.x, this.y, this.rotation, this.scale_x, this.scale_y)
	}
	clone(): Bone {
		return Object.assign(new Bone(), this)
	}
}

export class Mesh {
	static __vname = 'kine2d.Mesh'
	vertices: number[] = []
	uvs: number[] = []
	triangles: number[] = []
	bind_bones: Bone[] = []
	weights: Map<string, number>[] = []
	has_size = false
	width = 0
	height = 0
}

export class Attachment {
	static __vname = 'kine2d.Attachment'
	path = ''
	has_size = false
	width = 0
	height = 0
	x = 0
	y = 0
	rotation = 0
	scale_x = 1
	scale_y = 1
	mesh: Mesh | null = null
}

export class SlotState {
	static __vname = 'kine2d.SlotState'
	attachments: Attachment[] = []
	display_index: number | null = null
	active_path: string | null = null
	hidden_by_path = false
}

export class Slot {
	static __vname = 'kine2d.Slot'
	key = ''
	name = ''
	bone = ''
	state = new SlotState()
}

export class SkinEntry {
	static __vname = 'kine2d.SkinEntry'
	hidden = false
	state = new SlotState()
}

export class Skin {
	static __vname = 'kine2d.Skin'
	id = ''
	name = ''
	attachments = new Map<string, SkinEntry>()
}

export class Curve {
	static __vname = 'kine2d.Curve'
	x1 = 0
	y1 = 0
	x2 = 1
	y2 = 1
	kind = ''
}

export class BoneKey {
	static __vname = 'kine2d.BoneKey'
	frame = 0
	x: number | null = null
	y: number | null = null
	rotation: number | null = null
	scale_x: number | null = null
	scale_y: number | null = null
	pos_curve: Curve | null = null
	rot_curve: Curve | null = null
}

export class OrderKey {
	frame = 0
	slots: string[] = []
}

export class DisplayKey {
	frame = 0
	values = new Map<string, number>()
}

export class DeformKey {
	frame = 0
	offsets: number[] = []
}

export class Animation {
	static __vname = 'kine2d.Animation'
	name = ''
	length = 48
	fps = 10
	bones = new Map<string, BoneKey[]>()
	order: OrderKey[] = []
	display: DisplayKey[] = []
	deforms = new Map<string, DeformKey[]>()
	duration(): number {
		return this.fps > 0 ? this.length / this.fps : 0
	}
}

export class Region {
	static __vname = 'kine2d.Region'
	path = ''
	page = 0
	x = 0
	y = 0
	width = 0
	height = 0
}

export class Atlas {
	static __vname = 'kine2d.Atlas'
	pages: string[] = []
	regions: Region[] = []
	find(path: string): Region | null {
		return this.regions.find((r) => r.path === path) ?? null
	}
}

export class Pose {
	static __vname = 'kine2d.Pose'
	x: number
	y: number
	rotation: number
	scale_x: number
	scale_y: number
	constructor(x = 0, y = 0, rotation = 0, scale_x = 1, scale_y = 1) {
		this.x = x
		this.y = y
		this.rotation = rotation
		this.scale_x = scale_x
		this.scale_y = scale_y
	}
	clone(): Pose {
		return new Pose(this.x, this.y, this.rotation, this.scale_x, this.scale_y)
	}
}

export class DrawPiece {
	static __vname = 'kine2d.DrawPiece'
	slot = ''
	page = 0
	positions: number[] = []
	uvs: number[] = []
	indices: number[] = []
}

export class SkeletonData {
	static __vname = 'kine2d.SkeletonData'
	canvas_width = default_canvas_width
	canvas_height = default_canvas_height
	bones: Bone[] = []
	slots: Slot[] = []
	skins: Skin[] = []
	active_skin = ''
	animations = new Map<string, Animation>()
	names: string[] = []

	find_skin(key: string): Skin | null {
		return this.skins.find((s) => s.id === key || s.name === key) ?? null
	}

	bone_name(key: string): string {
		for (const b of this.bones) if (b.name === key || (b.id !== '' && b.id === key)) return b.name
		return key
	}

	sample_pose(anim: Animation | null, frame: number): Map<string, Pose> {
		const out = new Map<string, Pose>()
		for (const b of this.bones) {
			let p = b.pose()
			if (anim) {
				const keys = anim.bones.get(b.name) ?? anim.bones.get(b.id) ?? []
				if (keys.length > 0) p = sample_bone(b, keys, frame)
			}
			out.set(b.name, p)
		}
		return out
	}

	slots_at(anim: Animation | null, frame: number): Slot[] {
		if (!anim) return this.slots
		let oi = -1
		anim.order.forEach((k, i) => {
			if (k.frame <= frame) oi = i
		})
		if (oi < 0) return this.slots
		const used = new Set<string>()
		const out: Slot[] = []
		for (const key of anim.order[oi].slots) {
			const sl = this.slots.find((s) => s.key === key && !used.has(s.key))
			if (sl) {
				out.push(sl)
				used.add(key)
			}
		}
		for (const sl of this.slots) if (!used.has(sl.key)) out.push(sl)
		return out
	}

	attachment_at(slot: Slot, skin: Skin | null, anim: Animation | null, frame: number): Attachment | null {
		let state = slot.state
		if (skin) {
			const e = skin.attachments.get(slot.key)
			if (e) {
				if (e.hidden) return null
				state = e.state
			}
		}
		const legacy = state.hidden_by_path ? -1 : state.active_path !== null ? state.attachments.map((a) => a.path).indexOf(state.active_path) : 0
		let index = state.display_index ?? legacy
		if (anim) {
			for (const k of anim.display) {
				if (k.frame > frame) break
				const v = k.values.get(slot.key)
				if (v !== undefined) index = v
			}
		}
		if (index < 0 || index >= state.attachments.length) return null
		return state.attachments[index]
	}

	skin_for(key: string): Skin | null {
		const k = key === '' ? this.active_skin : key
		if (k === '' || k === 'default') return null
		return this.find_skin(k)
	}

	build(atlas: Atlas, anim: Animation | null, frame: number, skin_key: string): DrawPiece[] {
		const pose = this.sample_pose(anim, frame)
		const skin = this.skin_for(skin_key)
		const out: DrawPiece[] = []
		for (const slot of this.slots_at(anim, frame)) {
			const att = this.attachment_at(slot, skin, anim, frame)
			if (!att) continue
			const bone_name = this.bone_name(slot.bone)
			const bone = pose.get(bone_name)
			if (!bone) continue
			const region = atlas.find(att.path)
			if (!region) continue
			if (att.mesh) {
				const piece = this.mesh_piece(slot, att, att.mesh, region, bone_name, pose, anim, frame)
				if (piece) out.push(piece)
			} else {
				out.push(this.region_piece(slot, att, region, bone))
			}
		}
		return out
	}

	origin(p: Pose): [number, number] {
		return [(p.x * this.canvas_width) / 100, (p.y * this.canvas_height) / 180]
	}

	region_piece(slot: Slot, att: Attachment, region: Region, bone: Pose): DrawPiece {
		const w = att.has_size ? att.width : region.width
		const h = att.has_size ? att.height : region.height
		const sx = bone.scale_x * att.scale_x
		const sy = bone.scale_y * att.scale_y
		const [ox, oy] = this.origin(bone)
		const [cx, cy] = rotate(att.x + (w * sx) / 2, att.y, bone.rotation)
		const rot = bone.rotation + att.rotation
		const hw = (w * sx) / 2
		const hh = (h * sy) / 2
		const positions: number[] = []
		for (const [x, y] of [
			[-hw, -hh],
			[hw, -hh],
			[hw, hh],
			[-hw, hh],
		]) {
			const [dx, dy] = rotate(x, y, rot)
			positions.push(ox + cx + dx, oy + cy + dy)
		}
		const p = new DrawPiece()
		p.slot = slot.key
		p.page = region.page
		p.positions = positions
		const u0 = region.x
		const v0 = region.y
		const u1 = u0 + region.width
		const v1 = v0 + region.height
		p.uvs = [u0, v0, u1, v0, u1, v1, u0, v1]
		p.indices = [0, 1, 2, 0, 2, 3]
		return p
	}

	mesh_piece(slot: Slot, att: Attachment, mesh: Mesh, region: Region, bone_name: string, pose: Map<string, Pose>, anim: Animation | null, frame: number): DrawPiece | null {
		if (mesh.vertices.length !== mesh.uvs.length || mesh.vertices.length % 2 !== 0) return null
		const vertices = deformed(mesh.vertices, anim, slot.key, frame)
		const bind = new Map<string, Pose>()
		for (const b of mesh.bind_bones.length > 0 ? mesh.bind_bones : this.bones) {
			bind.set(b.name, b.pose())
			if (b.id !== '') bind.set(b.id, b.pose())
		}
		const rest_bone = bind.get(bone_name)
		const cur_bone = pose.get(bone_name)
		if (!rest_bone || !cur_bone) return null
		const rest = this.mesh_positions(att, mesh, vertices, rest_bone)
		const current = this.mesh_positions(att, mesh, vertices, cur_bone)
		const positions = new Array<number>(vertices.length).fill(0)
		for (let i = 0; i < positions.length; i += 2) {
			const weights = i / 2 < mesh.weights.length ? mesh.weights[i / 2] : new Map<string, number>()
			let x = 0
			let y = 0
			let total = 0
			for (const [name, w] of weights) {
				if (w <= 0) continue
				const setup = bind.get(name)
				const cur = pose.get(this.bone_name(name))
				if (!setup || !cur) continue
				const [px, py] = this.from_setup(rest[i], rest[i + 1], setup, cur)
				x += px * w
				y += py * w
				total += w
			}
			if (total > 0) {
				positions[i] = x / total
				positions[i + 1] = y / total
			} else {
				positions[i] = current[i]
				positions[i + 1] = current[i + 1]
			}
		}
		const uvs = new Array<number>(mesh.uvs.length)
		for (let i = 0; i < uvs.length; i += 2) {
			uvs[i] = region.x + mesh.uvs[i] * region.width
			uvs[i + 1] = region.y + mesh.uvs[i + 1] * region.height
		}
		const p = new DrawPiece()
		p.slot = slot.key
		p.page = region.page
		p.positions = positions
		p.uvs = uvs
		p.indices = mesh.triangles.slice()
		return p
	}

	mesh_positions(att: Attachment, mesh: Mesh, vertices: number[], bone: Pose): number[] {
		const sx = bone.scale_x * att.scale_x
		const sy = bone.scale_y * att.scale_y
		const local = new Array<number>(vertices.length)
		let min_x = Infinity
		let min_y = Infinity
		let max_x = -Infinity
		let max_y = -Infinity
		for (let i = 0; i < vertices.length; i += 2) {
			const x = att.x + vertices[i] * sx
			const y = att.y + vertices[i + 1] * sy
			local[i] = x
			local[i + 1] = y
			min_x = Math.min(min_x, x)
			max_x = Math.max(max_x, x)
			min_y = Math.min(min_y, y)
			max_y = Math.max(max_y, y)
		}
		const cx = mesh.has_size ? att.x + (mesh.width * sx) / 2 : (min_x + max_x) / 2
		const cy = mesh.has_size ? att.y : (min_y + max_y) / 2
		const [ox, oy] = this.origin(bone)
		const out = new Array<number>(vertices.length)
		for (let i = 0; i < local.length; i += 2) {
			const [ax, ay] = rotate(local[i] - cx, local[i + 1] - cy, att.rotation)
			const [bx, by] = rotate(cx + ax, cy + ay, bone.rotation)
			out[i] = ox + bx
			out[i + 1] = oy + by
		}
		return out
	}

	from_setup(x: number, y: number, setup: Pose, cur: Pose): [number, number] {
		const [sox, soy] = this.origin(setup)
		let [lx, ly] = rotate(x - sox, y - soy, -setup.rotation)
		lx /= Math.abs(setup.scale_x) > 1e-6 ? setup.scale_x : 1
		ly /= Math.abs(setup.scale_y) > 1e-6 ? setup.scale_y : 1
		const [cox, coy] = this.origin(cur)
		const [rx, ry] = rotate(lx * cur.scale_x, ly * cur.scale_y, cur.rotation)
		return [cox + rx, coy + ry]
	}
}

// ---------- Sampling (kine2d/pose.v) ----------

function track(keys: BoneKey[], frame: number, has: (k: BoneKey) => boolean): [number, number] {
	let prev = -1
	let next = -1
	keys.forEach((k, i) => {
		if (!has(k)) return
		if (k.frame <= frame) prev = i
		if (k.frame >= frame && next < 0) next = i
	})
	return [prev, next]
}

export function sample_bone(b: Bone, keys: BoneKey[], frame: number): Pose {
	const p = b.pose()
	let [prev, next] = track(keys, frame, (k) => k.x !== null || k.y !== null)
	if (prev >= 0) {
		const pk = keys[prev]
		const px = pk.x ?? b.x
		const py = pk.y ?? b.y
		if (next >= 0 && keys[next].frame !== pk.frame) {
			const nk = keys[next]
			const t = ease((frame - pk.frame) / (nk.frame - pk.frame), pk.pos_curve)
			const nx = nk.x ?? px
			const ny = nk.y ?? py
			p.x = px + (nx - px) * t
			p.y = py + (ny - py) * t
		} else {
			p.x = px
			p.y = py
		}
	}
	;[prev, next] = track(keys, frame, (k) => k.rotation !== null)
	if (prev >= 0) {
		const pk = keys[prev]
		const from = pk.rotation ?? b.rotation
		p.rotation = from
		if (next >= 0 && keys[next].frame !== pk.frame) {
			const nk = keys[next]
			const to = nk.rotation ?? from
			p.rotation = from + shortest_rotation(from, to) * ease((frame - pk.frame) / (nk.frame - pk.frame), pk.rot_curve)
		}
	}
	;[prev, next] = track(keys, frame, (k) => k.scale_x !== null || k.scale_y !== null)
	if (prev >= 0) {
		const pk = keys[prev]
		const sx = pk.scale_x ?? b.scale_x
		const sy = pk.scale_y ?? b.scale_y
		p.scale_x = sx
		p.scale_y = sy
		if (next >= 0 && keys[next].frame !== pk.frame) {
			const nk = keys[next]
			const t = (frame - pk.frame) / (nk.frame - pk.frame)
			p.scale_x = sx + ((nk.scale_x ?? sx) - sx) * t
			p.scale_y = sy + ((nk.scale_y ?? sy) - sy) * t
		}
	}
	return p
}

export function shortest_rotation(from: number, to: number): number {
	return ((((to - from) % 360) + 540) % 360) - 180
}

export function ease(t: number, curve: Curve | null): number {
	if (!curve) return t
	const x = t < 0 ? 0 : t > 1 ? 1 : t
	if (curve.kind !== '' && curve.kind !== 'bezier') return easing(x, curve.kind)
	if (x === 0 || x === 1 || (curve.x1 === curve.y1 && curve.x2 === curve.y2)) return x
	let lo = 0
	let hi = 1
	for (let i = 0; i < 24; i++) {
		const u = (lo + hi) / 2
		if (bezier(u, curve.x1, curve.x2) < x) lo = u
		else hi = u
	}
	return bezier((lo + hi) / 2, curve.y1, curve.y2)
}

function bezier(t: number, p1: number, p2: number): number {
	const u = 1 - t
	return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
}

function bounce_out(t: number): number {
	const n1 = 7.5625
	const d1 = 2.75
	if (t < 1 / d1) return n1 * t * t
	if (t < 2 / d1) {
		const t2 = t - 1.5 / d1
		return n1 * t2 * t2 + 0.75
	}
	if (t < 2.5 / d1) {
		const t2 = t - 2.25 / d1
		return n1 * t2 * t2 + 0.9375
	}
	const t2 = t - 2.625 / d1
	return n1 * t2 * t2 + 0.984375
}

function easing(t: number, kind: string): number {
	const c4 = (2 * Math.PI) / 3
	const c1 = 1.70158
	switch (kind) {
		case 'bounce-out':
			return bounce_out(t)
		case 'bounce-in':
			return 1 - bounce_out(1 - t)
		case 'bounce-in-out':
			return t < 0.5 ? (1 - bounce_out(1 - 2 * t)) / 2 : (1 + bounce_out(2 * t - 1)) / 2
		case 'elastic-out':
			return t === 0 || t === 1 ? t : Math.pow(2, -10 * t) * Math.sin((t * 10 - 0.75) * c4) + 1
		case 'elastic-in':
			return t === 0 || t === 1 ? t : -Math.pow(2, 10 * t - 10) * Math.sin((t * 10 - 10.75) * c4)
		case 'back-out':
			return 1 + (c1 + 1) * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2)
		case 'back-in':
			return (c1 + 1) * t * t * t - c1 * t * t
	}
	return t
}

function rotate(x: number, y: number, deg: number): [number, number] {
	const r = (deg * Math.PI) / 180
	const cs = Math.cos(r)
	const sn = Math.sin(r)
	return [x * cs - y * sn, x * sn + y * cs]
}

function deformed(vertices: number[], anim: Animation | null, slot: string, frame: number): number[] {
	if (!anim) return vertices
	const keys = anim.deforms.get(slot)
	if (!keys) return vertices
	let prev = -1
	let next = -1
	keys.forEach((k, i) => {
		if (k.offsets.length !== vertices.length) return
		if (k.frame <= frame) prev = i
		if (k.frame >= frame && next < 0) next = i
	})
	if (prev < 0) return vertices
	const from = keys[prev].offsets
	const to = next >= 0 ? keys[next].offsets : from
	const t = next >= 0 && keys[next].frame !== keys[prev].frame ? (frame - keys[prev].frame) / (keys[next].frame - keys[prev].frame) : 0
	return vertices.map((v, i) => v + from[i] + (to[i] - from[i]) * t)
}

// ---------- Parsing ----------

type J = any

function obj(v: J): Record<string, J> | null {
	return v !== null && typeof v === 'object' && !Array.isArray(v) ? v : null
}

function arr(m: Record<string, J>, key: string): J[] {
	const v = m[key]
	return Array.isArray(v) ? v : []
}

function num(m: Record<string, J>, key: string, def: number): number {
	const v = m[key]
	return typeof v === 'number' ? v : def
}

function str(m: Record<string, J>, key: string): string {
	const v = m[key]
	return typeof v === 'string' ? v : ''
}

function parse_bone(m: Record<string, J>): Bone {
	const scale = num(m, 'scale', 1)
	return Object.assign(new Bone(), {
		name: str(m, 'name'),
		id: str(m, 'id'),
		parent: str(m, 'parent'),
		x: num(m, 'x', 0),
		y: num(m, 'y', 0),
		rotation: num(m, 'rotation', 0),
		scale_x: num(m, 'scaleX', scale),
		scale_y: num(m, 'scaleY', scale),
	})
}

function parse_slot_state(m: Record<string, J>): SlotState {
	const st = new SlotState()
	for (const v of arr(m, 'attachments')) {
		const am = obj(v)
		if (am) st.attachments.push(parse_attachment(am))
	}
	if (st.attachments.length === 0) {
		const am = obj(m['attachment'])
		if (am) st.attachments.push(parse_attachment(am))
	}
	if ('displayIndex' in m) st.display_index = Math.trunc(num(m, 'displayIndex', 0))
	if ('activeAttachmentPath' in m) {
		const p = m['activeAttachmentPath']
		if (p === null) st.hidden_by_path = true
		else if (typeof p === 'string') st.active_path = p
	}
	return st
}

function parse_attachment(m: Record<string, J>): Attachment {
	const scale = num(m, 'scale', 1)
	const a = Object.assign(new Attachment(), {
		path: str(m, 'path'),
		x: num(m, 'x', 0),
		y: num(m, 'y', 0),
		rotation: num(m, 'rotation', 0),
		scale_x: num(m, 'scaleX', scale),
		scale_y: num(m, 'scaleY', scale),
	})
	const size = obj(m['size'])
	if (size) {
		a.has_size = true
		a.width = num(size, 'width', 0)
		a.height = num(size, 'height', 0)
	}
	const mm = obj(m['mesh'])
	if (mm) {
		const mesh = new Mesh()
		mesh.vertices = arr(mm, 'vertices').map(Number)
		mesh.uvs = arr(mm, 'uvs').map(Number)
		mesh.triangles = arr(mm, 'triangles').map((x) => Math.trunc(Number(x)))
		for (const b of arr(mm, 'bindBones')) {
			const bm = obj(b)
			if (bm) mesh.bind_bones.push(parse_bone(bm))
		}
		for (const w of arr(mm, 'weights')) {
			const vw = new Map<string, number>()
			const wm = obj(w)
			if (wm) for (const [bone, weight] of Object.entries(wm)) vw.set(bone, Number(weight))
			mesh.weights.push(vw)
		}
		if ('width' in mm && 'height' in mm) {
			mesh.has_size = true
			mesh.width = num(mm, 'width', 0)
			mesh.height = num(mm, 'height', 0)
		}
		a.mesh = mesh
	}
	return a
}

function parse_curve(v: J): Curve | null {
	const m = obj(v)
	if (!m) return null
	return Object.assign(new Curve(), { x1: num(m, 'x1', 0), y1: num(m, 'y1', 0), x2: num(m, 'x2', 1), y2: num(m, 'y2', 1), kind: str(m, 'type') })
}

function parse_animation(name: string, m: Record<string, J>): Animation {
	const a = new Animation()
	a.name = name
	a.length = num(m, 'length', 48)
	a.fps = num(m, 'fps', 10)
	const curves = obj(m['curves']) ?? {}
	const kf = obj(m['keyframes'])
	if (kf) {
		for (const [bone, frames] of Object.entries(kf)) {
			const fm = obj(frames)
			if (!fm) continue
			const bone_curves = obj(curves[bone]) ?? {}
			const keys: BoneKey[] = []
			for (const [fkey, v] of Object.entries(fm)) {
				const km = obj(v)
				if (!km) continue
				const k = new BoneKey()
				k.frame = Number(fkey) || 0
				if ('x' in km) k.x = num(km, 'x', 0)
				if ('y' in km) k.y = num(km, 'y', 0)
				if ('rotation' in km) k.rotation = num(km, 'rotation', 0)
				if ('scale' in km) {
					k.scale_x = num(km, 'scale', 1)
					k.scale_y = num(km, 'scale', 1)
				}
				if ('scaleX' in km) k.scale_x = num(km, 'scaleX', 1)
				if ('scaleY' in km) k.scale_y = num(km, 'scaleY', 1)
				const cm = obj(bone_curves[fkey])
				if (cm) {
					k.pos_curve = parse_curve(cm['position'] ?? cm['x'] ?? cm['y'] ?? null)
					k.rot_curve = parse_curve(cm['rotation'] ?? null)
				}
				keys.push(k)
			}
			keys.sort((x, y) => x.frame - y.frame)
			a.bones.set(bone, keys)
		}
	}
	const om = obj(m['slotOrderKeyframes'])
	if (om) {
		for (const [fkey, v] of Object.entries(om)) {
			if (Array.isArray(v)) a.order.push(Object.assign(new OrderKey(), { frame: Number(fkey) || 0, slots: v.map(String) }))
		}
		a.order.sort((x, y) => x.frame - y.frame)
	}
	const dm = obj(m['slotDisplayIndexKeyframes'])
	if (dm) {
		for (const [fkey, v] of Object.entries(dm)) {
			const vm = obj(v)
			if (!vm) continue
			const values = new Map<string, number>()
			for (const [slot, idx] of Object.entries(vm)) values.set(slot, Math.trunc(Number(idx)))
			a.display.push(Object.assign(new DisplayKey(), { frame: Number(fkey) || 0, values }))
		}
		a.display.sort((x, y) => x.frame - y.frame)
	}
	const fm = obj(m['deforms'])
	if (fm) {
		for (const [slot, frames] of Object.entries(fm)) {
			const sm = obj(frames)
			if (!sm) continue
			const keys: DeformKey[] = []
			for (const [fkey, v] of Object.entries(sm)) {
				if (Array.isArray(v)) keys.push(Object.assign(new DeformKey(), { frame: Number(fkey) || 0, offsets: v.map(Number) }))
			}
			keys.sort((x, y) => x.frame - y.frame)
			a.deforms.set(slot, keys)
		}
	}
	return a
}

export function parse_skeleton(src: string): SkeletonData {
	let root: Record<string, J> | null
	try {
		root = obj(JSON.parse(src))
	} catch (e) {
		throw new V.VError(`skeleton: ${e}`)
	}
	if (!root) throw new V.VError('skeleton: expected a JSON object')
	const s = new SkeletonData()
	const cs = obj(root['canvasSize'])
	if (cs) {
		const w = num(cs, 'width', 0)
		const h = num(cs, 'height', 0)
		if (w > 0 && h > 0) {
			s.canvas_width = w
			s.canvas_height = h
		}
	}
	for (const b of arr(root, 'bones')) {
		const m = obj(b)
		if (m) s.bones.push(parse_bone(m))
	}
	for (const v of arr(root, 'slots')) {
		const m = obj(v)
		if (!m) continue
		const name = str(m, 'name')
		const bone = str(m, 'bone')
		const id = str(m, 'id')
		const sl = new Slot()
		sl.key = id !== '' ? id : name !== '' ? name : bone
		sl.name = name
		sl.bone = bone
		sl.state = parse_slot_state(m)
		s.slots.push(sl)
	}
	for (const v of arr(root, 'skins')) {
		const m = obj(v)
		if (!m) continue
		const skin = new Skin()
		skin.id = str(m, 'id')
		skin.name = str(m, 'name')
		const atts = obj(m['attachments'])
		if (atts) {
			for (const [key, val] of Object.entries(atts)) {
				const e = new SkinEntry()
				if (val === null) {
					e.hidden = true
				} else {
					const sm = obj(val)
					if (!sm) continue
					if ('path' in sm) {
						e.state.attachments = [parse_attachment(sm)]
						e.state.display_index = 0
					} else {
						e.state = parse_slot_state(sm)
					}
				}
				skin.attachments.set(key, e)
			}
		}
		s.skins.push(skin)
	}
	s.active_skin = str(root, 'activeSkinId')
	const anims = obj(root['animations'])
	if (anims) {
		for (const [name, v] of Object.entries(anims)) {
			const m = obj(v)
			if (!m) continue
			s.animations.set(name, parse_animation(name, m))
			s.names.push(name)
		}
	}
	return s
}

export function parse_atlas(src: string): Atlas {
	let root: Record<string, J> | null
	try {
		root = obj(JSON.parse(src))
	} catch (e) {
		throw new V.VError(`atlas: ${e}`)
	}
	if (!root) throw new V.VError('atlas: expected a JSON object')
	const a = new Atlas()
	const image = str(root, 'image')
	if (image !== '') {
		a.pages.push(image)
		for (const v of arr(root, 'regions')) {
			const m = obj(v)
			if (!m) continue
			a.regions.push(
				Object.assign(new Region(), {
					path: str(m, 'path'),
					x: Math.trunc(num(m, 'x', 0)),
					y: Math.trunc(num(m, 'y', 0)),
					width: Math.trunc(num(m, 'width', 0)),
					height: Math.trunc(num(m, 'height', 0)),
				}),
			)
		}
	}
	for (const v of arr(root, 'images')) {
		const m = obj(v)
		if (!m) continue
		const path = str(m, 'path')
		if (path === '') continue
		a.regions.push(Object.assign(new Region(), { path, page: a.pages.length }))
		a.pages.push(path)
	}
	if (a.pages.length === 0) throw new V.VError('atlas: no "image" or "images"')
	return a
}

// ---------- Component (kine2d/kine2d.v) ----------

export class Kine2D extends core.Component {
	static __vname = 'kine2d.Kine2D'
	static __fields: FieldSpec[] = [
		{ name: 'data', type: 'asset:text' },
		{ name: 'atlas', type: 'asset:text' },
		{ name: 'animation', type: 'string' },
		{ name: 'skin', type: 'string' },
		{ name: 'speed', type: 'f32' },
		{ name: 'playing', type: 'bool' },
		{ name: 'looping', type: 'bool' },
		{ name: 'color', type: 'Color' },
		{ name: 'canvas_size', type: 'Vec2' },
	]
	data = new assets.AssetRef('', assets.TextAsset)
	atlas = new assets.AssetRef('', assets.TextAsset)
	animation = ''
	skin = ''
	speed = 1
	playing = true
	looping = true
	color = core.white.clone()
	canvas_size = new core.Vec2()
	time = 0
	finished = false
	skeleton = new SkeletonData()
	regions = new Atlas()
	pages: assets.Texture[] = []
	held: string[] = []
	current = ''
	source = ''

	on_load() {
		this.reload()
	}
	on_destroy() {
		this.drop()
	}
	update(dt: number) {
		if (this.source !== this.data.id + this.atlas.id) this.reload()
		if (this.animation !== this.current) this.restart()
		if (!this.playing) return
		const d = this.duration()
		if (d <= 0) return
		this.time += dt * this.speed
		if (this.looping) {
			this.time = this.time % d
			if (this.time < 0) this.time += d
		} else if (this.time >= d || this.time < 0) {
			this.time = this.time < 0 ? 0 : d
			this.finished = true
			this.playing = false
		}
	}
	play(name: string, looping: boolean) {
		this.animation = name
		this.looping = looping
		this.playing = true
		this.restart()
	}
	restart() {
		this.current = this.animation
		this.time = 0
		this.finished = false
	}
	animations(): string[] {
		return this.skeleton.names
	}
	skins(): string[] {
		return this.skeleton.skins.map((s) => (s.name !== '' ? s.name : s.id))
	}
	current_animation(): Animation | null {
		const name = this.animation === '' && this.skeleton.names.length > 0 ? this.skeleton.names[0] : this.animation
		return this.skeleton.animations.get(name) ?? null
	}
	duration(): number {
		const a = this.current_animation()
		return a ? a.duration() : 0
	}
	frame(): number {
		const a = this.current_animation()
		return a ? this.time * a.fps : 0
	}
	meshes(): render.TexturedMesh[] {
		if (this.pages.length === 0) return []
		const out: render.TexturedMesh[] = []
		for (const p of this.skeleton.build(this.regions, this.current_animation(), this.frame(), this.skin)) {
			const tex = this.pages[p.page]
			if (!tex || tex.width <= 0 || tex.height <= 0) continue
			const uvs = new Array<number>(p.uvs.length)
			for (let i = 0; i < uvs.length; i += 2) {
				uvs[i] = p.uvs[i] / tex.width
				uvs[i + 1] = p.uvs[i + 1] / tex.height
			}
			const m = new render.TexturedMesh()
			m.texture = tex
			m.positions = p.positions
			m.uvs = uvs
			m.indices = p.indices
			m.color = this.color
			out.push(m)
		}
		return out
	}
	db(): assets.AssetDatabase | null {
		return this.node && this.node.scene && this.node.scene.assets ? this.node.scene.assets : null
	}
	reload() {
		const db = this.db()
		if (!db || !this.data.is_set() || !this.atlas.is_set()) return
		this.source = this.data.id + this.atlas.id
		try {
			this.load_from(db)
		} catch (e) {
			console.error(`[Kine2D] ${this.node.path()}: ${V.as_error(e).message}`)
		}
	}
	load_from(db: assets.AssetDatabase) {
		const data_id = db.resolve(this.data.id)
		if (data_id === null) throw new V.VError(`asset "${this.data.id}" not found`)
		const atlas_id = db.resolve(this.atlas.id)
		if (atlas_id === null) throw new V.VError(`asset "${this.atlas.id}" not found`)
		const skel_src = db.load<assets.TextAsset>(assets.TextAsset, data_id).text
		db.release(data_id)
		const atlas_src = db.load<assets.TextAsset>(assets.TextAsset, atlas_id).text
		db.release(atlas_id)
		let skeleton: SkeletonData
		let atlas: Atlas
		try {
			skeleton = parse_skeleton(skel_src)
		} catch (e) {
			throw new V.VError(`${db.path_of(data_id) ?? ''}: ${V.as_error(e).message}`)
		}
		try {
			atlas = parse_atlas(atlas_src)
		} catch (e) {
			throw new V.VError(`${db.path_of(atlas_id) ?? ''}: ${V.as_error(e).message}`)
		}
		if (this.canvas_size.x > 0 && this.canvas_size.y > 0) {
			skeleton.canvas_width = this.canvas_size.x
			skeleton.canvas_height = this.canvas_size.y
		}
		const atlas_path = db.path_of(atlas_id) ?? ''
		const dir = atlas_path.includes('/') ? atlas_path.slice(0, atlas_path.lastIndexOf('/') + 1) : ''
		const pages: assets.Texture[] = []
		const held: string[] = []
		for (const page of atlas.pages) {
			try {
				const tex = db.load<assets.Texture>(assets.Texture, dir + page)
				pages.push(tex)
				held.push(tex.id)
			} catch (e) {
				for (const id of held) db.release(id)
				throw new V.VError(`atlas image "${dir}${page}": ${V.as_error(e).message}`)
			}
		}
		for (const r of atlas.regions) {
			if (r.width <= 0 || r.height <= 0) {
				r.width = pages[r.page].width
				r.height = pages[r.page].height
			}
		}
		this.drop()
		this.skeleton = skeleton
		this.regions = atlas
		this.pages = pages
		this.held = held
		if (this.animation !== '' && !skeleton.animations.has(this.animation)) {
			console.error(`[Kine2D] ${this.node.path()}: no animation "${this.animation}" (has: ${skeleton.names.join(', ')})`)
		}
	}
	drop() {
		const db = this.db()
		if (db) for (const id of this.held) db.release(id)
		this.held = []
		this.pages = []
	}
}

export function register_builtins(r: serialize.Registry) {
	r.register(Kine2D)
}
