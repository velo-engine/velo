// velo.model3d for the WebGL runtime (model3d/*.v): 3D model data — meshes, a skeleton, animation clips, embedded
// textures — the built-in primitives, and binary FBX import. GPU free; render3d.ts draws models.
//
// Unlike desktop, FBX files are parsed before the game starts (FBX arrays are zlib-compressed and the browser only
// inflates asynchronously): render3d registers an assets.preload_hooks entry that calls parse_model_asset for every
// `model` asset, so load_fbx stays synchronous for game code.

import * as core from './core.ts'
import { Vec3, Quat, Mat4, vec3, rgba } from './core.ts'
import type { Color } from './core.ts'

// MeshData — triangles with one vertex per corner, in model space.
export class MeshData {
	static __vname = 'model3d.MeshData'
	name = ''
	positions: number[] = [] // x, y, z per vertex
	normals: number[] = [] // x, y, z per vertex
	uvs: number[] = [] // u, v per vertex (v = 0 at the top of the texture)
	// Skinning (empty for a rigid mesh): four bone indices and weights per vertex, weights summing to 1.
	joints: number[] = []
	weights: number[] = []
	indices: number[] = [] // three per triangle, counter-clockwise = front
	texture = -1 // index into Model.textures for the base color, -1 = none
	color: Color = core.white.clone() // material base color

	vertex_count(): number {
		return Math.trunc(this.positions.length / 3)
	}
	is_skinned(): boolean {
		return this.joints.length > 0 && this.joints.length === Math.trunc(this.positions.length / 3) * 4
	}
	vert(p: Vec3, n: Vec3, u: number, v: number): number {
		this.positions.push(p.x, p.y, p.z)
		this.normals.push(n.x, n.y, n.z)
		this.uvs.push(u, v)
		return this.positions.length / 3 - 1
	}
	tri(a: number, b: number, c: number) {
		this.indices.push(a, b, c)
	}
	// quad a b c d, counter-clockwise seen from the front.
	quad(a: number, b: number, c: number, d: number) {
		this.tri(a, b, c)
		this.tri(a, c, d)
	}
}

// Bone — one joint of the skeleton. Bones are ordered parents first.
export class Bone {
	static __vname = 'model3d.Bone'
	name = ''
	parent = -1
	// rest pose, relative to the parent
	t = new Vec3()
	r = Quat.identity()
	s = new Vec3(1, 1, 1)
	// model space -> bone space at bind time
	inverse_bind = Mat4.identity()
}

// Clip — an animation baked at a fixed rate: frame f holds every bone's local TRS.
export class Clip {
	static __vname = 'model3d.Clip'
	name = ''
	duration = 0 // seconds
	fps = 30
	t: Vec3[][] = []
	r: Quat[][] = []
	s: Vec3[][] = []
	frame_count(): number {
		return this.t.length
	}
}

// Image — an encoded texture (PNG/JPEG bytes) embedded in the model, or the file it names. `bitmap` is the decoded
// image (render3d's preload decodes it).
export class Image {
	static __vname = 'model3d.Image'
	name = ''
	bytes: Uint8Array<ArrayBuffer> = new Uint8Array(0)
	file = ''
	bitmap: ImageBitmap | null = null
}

export class Model {
	static __vname = 'model3d.Model'
	name = ''
	meshes: MeshData[] = []
	bones: Bone[] = []
	clips: Clip[] = []
	textures: Image[] = []
	// model-space bounds of the rest pose
	min = new Vec3()
	max = new Vec3()

	// clip_index: the clip named `name` ('' = the first one), -1 if none.
	clip_index(name: string): number {
		for (let i = 0; i < this.clips.length; i++) if (name === '' || this.clips[i].name === name) return i
		return -1
	}
	bone_index(name: string): number {
		for (let i = 0; i < this.bones.length; i++) {
			const b = this.bones[i].name
			if (b === name || after_colon(b) === name) return i
		}
		return -1
	}
	triangle_count(): number {
		let n = 0
		for (const me of this.meshes) n += Math.trunc(me.indices.length / 3)
		return n
	}
	compute_bounds() {
		let lx = 1e30, ly = 1e30, lz = 1e30, hx = -1e30, hy = -1e30, hz = -1e30
		for (const me of this.meshes) {
			const p = me.positions
			for (let i = 0; i + 2 < p.length; i += 3) {
				lx = Math.min(lx, p[i])
				ly = Math.min(ly, p[i + 1])
				lz = Math.min(lz, p[i + 2])
				hx = Math.max(hx, p[i])
				hy = Math.max(hy, p[i + 1])
				hz = Math.max(hz, p[i + 2])
			}
		}
		if (lx > hx) {
			this.min = new Vec3()
			this.max = new Vec3()
		} else {
			this.min = new Vec3(lx, ly, lz)
			this.max = new Vec3(hx, hy, hz)
		}
	}

	// rest_pose: the skeleton's bind/rest pose.
	rest_pose(): Pose {
		const p = new Pose()
		p.t = this.bones.map((b) => b.t.clone())
		p.r = this.bones.map((b) => b.r.clone())
		p.s = this.bones.map((b) => b.s.clone())
		return p
	}

	// sample writes clip `ci` at `time` seconds into `pose` (wrapping when `looping`, else holding the last frame).
	sample(ci: number, time: number, looping: boolean, pose: Pose) {
		if (pose.t.length !== this.bones.length) pose.set_from(this.rest_pose())
		if (ci < 0 || ci >= this.clips.length) return
		const c = this.clips[ci]
		const n = c.frame_count()
		if (n === 0) return
		let f = time * c.fps
		const last = n - 1
		if (looping && last > 0) {
			f = f - last * Math.trunc(f / last)
			if (f < 0) f += last
		} else if (f > last) {
			f = last
		} else if (f < 0) {
			f = 0
		}
		const f0 = Math.trunc(f)
		const f1 = f0 + 1 < n ? f0 + 1 : f0
		const k = f - f0
		const t0 = c.t[f0], t1 = c.t[f1], r0 = c.r[f0], r1 = c.r[f1], s0 = c.s[f0], s1 = c.s[f1]
		for (let b = 0; b < this.bones.length; b++) {
			if (b >= t0.length) break
			pose.t[b] = t0[b].lerp(t1[b], k)
			pose.r[b] = r0[b].nlerp(r1[b], k)
			pose.s[b] = s0[b].lerp(s1[b], k)
		}
	}

	// globals: each bone's model-space matrix for `pose` (into `out`, resized in place as needed).
	globals(pose: Pose, out: Mat4[]) {
		const n = this.bones.length
		if (out.length !== n) {
			out.length = 0
			for (let i = 0; i < n; i++) out.push(Mat4.identity())
		}
		for (let i = 0; i < n; i++) {
			const b = this.bones[i]
			const local = i < pose.t.length ? Mat4.trs(pose.t[i], pose.r[i], pose.s[i]) : Mat4.trs(b.t, b.r, b.s)
			if (b.parent >= 0) core.mat4_mul_into(out[i].m, out[b.parent].m, local.m)
			else out[i].m.set(local.m)
		}
	}

	// skin_matrices: model-space globals times inverse bind (what the vertex shader multiplies skinned vertices by).
	skin_matrices(globals: Mat4[], out: Mat4[]) {
		const n = this.bones.length
		if (out.length !== n) {
			out.length = 0
			for (let i = 0; i < n; i++) out.push(Mat4.identity())
		}
		for (let i = 0; i < n; i++) core.mat4_mul_into(out[i].m, globals[i].m, this.bones[i].inverse_bind.m)
	}
}

function after_colon(s: string): string {
	const i = s.indexOf(':')
	return i < 0 ? s : s.slice(i + 1)
}

// Pose — every bone's local TRS at one moment (sampled from clips, blended, then turned into skin matrices).
export class Pose {
	static __vname = 'model3d.Pose'
	t: Vec3[] = []
	r: Quat[] = []
	s: Vec3[] = []
	clone(): Pose {
		const p = new Pose()
		p.t = this.t.map((v) => v.clone())
		p.r = this.r.map((v) => v.clone())
		p.s = this.s.map((v) => v.clone())
		return p
	}
	set_from(o: Pose) {
		this.t = o.t
		this.r = o.r
		this.s = o.s
	}
	// blend moves the pose toward `other` by `w` (0 = unchanged, 1 = other).
	blend(other: Pose, w: number) {
		for (let b = 0; b < this.t.length; b++) {
			if (b >= other.t.length) break
			this.t[b] = this.t[b].lerp(other.t[b], w)
			this.r[b] = this.r[b].nlerp(other.r[b], w)
			this.s[b] = this.s[b].lerp(other.s[b], w)
		}
	}
}

// ---------- Primitives (model3d/primitives.v) ----------

export const primitive_names = ['cube', 'sphere', 'cylinder', 'cone', 'capsule', 'plane', 'torus', 'ring', 'disc']

// primitive builds a mesh by name (null = unknown name).
export function primitive(name: string): MeshData | null {
	switch (name) {
		case 'cube':
		case 'box':
			return cube(1)
		case 'sphere':
			return sphere(0.5, 24, 16)
		case 'cylinder':
			return cylinder(0.5, 1, 24)
		case 'cone':
			return cone(0.5, 1, 24)
		case 'capsule':
			return capsule(0.5, 2, 24, 8)
		case 'plane':
			return plane(1, 1)
		case 'torus':
			return torus(0.5, 0.15, 32, 12)
		case 'ring':
			return torus(0.5, 0.035, 48, 8)
		case 'disc':
			return disc(0.5, 48)
	}
	return null
}

function named(name: string): MeshData {
	const m = new MeshData()
	m.name = name
	return m
}

export function cube(size: number): MeshData {
	const m = named('cube')
	const h = size / 2
	const faces = [
		[vec3(1, 0, 0), vec3(0, 0, -1), vec3(0, -1, 0)],
		[vec3(-1, 0, 0), vec3(0, 0, 1), vec3(0, -1, 0)],
		[vec3(0, 1, 0), vec3(1, 0, 0), vec3(0, 0, 1)],
		[vec3(0, -1, 0), vec3(1, 0, 0), vec3(0, 0, -1)],
		[vec3(0, 0, 1), vec3(1, 0, 0), vec3(0, -1, 0)],
		[vec3(0, 0, -1), vec3(-1, 0, 0), vec3(0, -1, 0)],
	]
	for (const [n, u, v] of faces) {
		const c = n.mul(h)
		const uh = u.mul(h)
		const vh = v.mul(h)
		const a = m.vert(c.op_sub(uh).op_sub(vh), n, 0, 0)
		const b = m.vert(c.op_sub(uh).op_add(vh), n, 0, 1)
		const cc = m.vert(c.op_add(uh).op_add(vh), n, 1, 1)
		const d = m.vert(c.op_add(uh).op_sub(vh), n, 1, 0)
		m.quad(a, b, cc, d)
	}
	return m
}

export function plane(w: number, d: number): MeshData {
	const m = named('plane')
	const n = vec3(0, 1, 0)
	const a = m.vert(vec3(-w / 2, 0, -d / 2), n, 0, 0)
	const b = m.vert(vec3(-w / 2, 0, d / 2), n, 0, 1)
	const c = m.vert(vec3(w / 2, 0, d / 2), n, 1, 1)
	const e = m.vert(vec3(w / 2, 0, -d / 2), n, 1, 0)
	m.quad(a, b, c, e)
	return m
}

// grid: a plane of `cells` x `cells` quads whose uvs repeat once per cell.
export function grid(size: number, cells: number): MeshData {
	const m = named('grid')
	const n = vec3(0, 1, 0)
	const step = size / cells
	for (let z = 0; z <= cells; z++) for (let x = 0; x <= cells; x++) m.vert(vec3(-size / 2 + x * step, 0, -size / 2 + z * step), n, x, z)
	const w = cells + 1
	for (let z = 0; z < cells; z++) {
		for (let x = 0; x < cells; x++) {
			const i = z * w + x
			m.quad(i, i + w, i + w + 1, i + 1)
		}
	}
	return m
}

export function sphere(radius: number, segments: number, rings: number): MeshData {
	const m = named('sphere')
	for (let r = 0; r <= rings; r++) {
		const v = r / rings
		const phi = v * Math.PI
		for (let s = 0; s <= segments; s++) {
			const u = s / segments
			const th = u * 2 * Math.PI
			const n = vec3(Math.sin(phi) * Math.sin(th), Math.cos(phi), Math.sin(phi) * Math.cos(th))
			m.vert(n.mul(radius), n, u, v)
		}
	}
	const w = segments + 1
	for (let r = 0; r < rings; r++) {
		for (let s = 0; s < segments; s++) {
			const i = r * w + s
			m.quad(i, i + w, i + w + 1, i + 1)
		}
	}
	return m
}

export function cylinder(r: number, h: number, segments: number): MeshData {
	const m = named('cylinder')
	add_tube(m, r, r, h, segments)
	add_cap(m, r, h / 2, segments, true)
	add_cap(m, r, -h / 2, segments, false)
	return m
}

export function cone(r: number, h: number, segments: number): MeshData {
	const m = named('cone')
	add_tube(m, r, 0.0001, h, segments)
	add_cap(m, r, -h / 2, segments, false)
	return m
}

function add_tube(m: MeshData, r0: number, r1: number, h: number, segments: number) {
	const slope = (r0 - r1) / h
	const base = m.positions.length / 3
	for (let s = 0; s <= segments; s++) {
		const u = s / segments
		const th = u * 2 * Math.PI
		const dx = Math.sin(th)
		const dz = Math.cos(th)
		const n = vec3(dx, slope, dz).normalized()
		m.vert(vec3(dx * r0, -h / 2, dz * r0), n, u, 1)
		m.vert(vec3(dx * r1, h / 2, dz * r1), n, u, 0)
	}
	for (let s = 0; s < segments; s++) {
		const i = base + s * 2
		m.quad(i, i + 2, i + 3, i + 1)
	}
}

function add_cap(m: MeshData, r: number, y: number, segments: number, up: boolean) {
	const n = vec3(0, up ? 1 : -1, 0)
	const c = m.vert(vec3(0, y, 0), n, 0.5, 0.5)
	const base = m.positions.length / 3
	for (let s = 0; s <= segments; s++) {
		const th = (s / segments) * 2 * Math.PI
		const dx = Math.sin(th)
		const dz = Math.cos(th)
		m.vert(vec3(dx * r, y, dz * r), n, 0.5 + dx / 2, 0.5 - dz / 2)
	}
	for (let s = 0; s < segments; s++) {
		if (up) m.tri(c, base + s, base + s + 1)
		else m.tri(c, base + s + 1, base + s)
	}
}

export function disc(r: number, segments: number): MeshData {
	const m = named('disc')
	add_cap(m, r, 0, segments, true)
	return m
}

export function capsule(r: number, h: number, segments: number, cap_rings: number): MeshData {
	const m = named('capsule')
	const half = Math.max(h / 2 - r, 0)
	const rings = cap_rings * 2 + 1
	for (let ri = 0; ri <= rings; ri++) {
		const top = ri <= cap_rings
		const k = top ? ri : ri - 1
		const phi = (k / (cap_rings * 2)) * Math.PI
		const y_off = top ? half : -half
		for (let s = 0; s <= segments; s++) {
			const u = s / segments
			const th = u * 2 * Math.PI
			const n = vec3(Math.sin(phi) * Math.sin(th), Math.cos(phi), Math.sin(phi) * Math.cos(th))
			const p = n.mul(r).op_add(vec3(0, y_off, 0))
			m.vert(p, n, u, (h / 2 - p.y) / h)
		}
	}
	const w = segments + 1
	for (let ri = 0; ri < rings; ri++) {
		for (let s = 0; s < segments; s++) {
			const i = ri * w + s
			m.quad(i, i + w, i + w + 1, i + 1)
		}
	}
	return m
}

export function torus(r: number, tube: number, segments: number, sides: number): MeshData {
	const m = named('torus')
	for (let s = 0; s <= segments; s++) {
		const u = s / segments
		const th = u * 2 * Math.PI
		const cx = Math.sin(th)
		const cz = Math.cos(th)
		for (let k = 0; k <= sides; k++) {
			const v = k / sides
			const ph = v * 2 * Math.PI
			const n = vec3(cx * Math.cos(ph), Math.sin(ph), cz * Math.cos(ph))
			const p = vec3(cx * r, 0, cz * r).op_add(n.mul(tube))
			m.vert(p, n, u, v)
		}
	}
	const w = sides + 1
	for (let s = 0; s < segments; s++) {
		for (let k = 0; k < sides; k++) {
			const i = s * w + k
			m.quad(i, i + w, i + w + 1, i + 1)
		}
	}
	return m
}

// ---------- FBX reader (model3d/fbx_reader.v) ----------

// FbxProp — one property of a node. Numbers are widened: ints/longs/bools land in `i`/`ints`, floats/doubles in
// `f`/`floats`; `s` holds strings ("Name\x00\x01Class" becomes "Name::Class"), `raw` raw bytes. `key` is a 64-bit
// integer as a string (object IDs do not fit a double).
export class FbxProp {
	kind = '' // the FBX type code: Y C I L F D S R, or f d l i b for arrays
	i = 0
	key = ''
	f = 0
	s = ''
	raw: Uint8Array<ArrayBuffer> = new Uint8Array(0)
	ints: number[] = []
	floats: number[] = []

	num(): number {
		return this.kind === 'F' || this.kind === 'D' ? this.f : this.i
	}
	numbers(): number[] {
		switch (this.kind) {
			case 'f':
			case 'd':
				return this.floats
			case 'l':
			case 'i':
			case 'b':
				return this.ints
		}
		return [this.num()]
	}
	int_list(): number[] {
		switch (this.kind) {
			case 'l':
			case 'i':
			case 'b':
				return this.ints
			case 'f':
			case 'd':
				return this.floats.map((x) => Math.trunc(x))
		}
		return [this.i]
	}
}

export class FbxNode {
	name = ''
	props: FbxProp[] = []
	children: FbxNode[] = []

	child(name: string): FbxNode | null {
		for (const c of this.children) if (c.name === name) return c
		return null
	}
	// id: the object ID (property 0 of every entry under Objects), as a string.
	id(): string {
		return this.props.length === 0 ? '0' : this.props[0].key
	}
	// Properties70 lookup: `P: "Lcl Translation", "Lcl Translation", "", "A", x, y, z` -> [x, y, z].
	p70(name: string): number[] | null {
		const props = this.child('Properties70')
		if (props === null) return null
		for (const p of props.children) {
			if (p.name === 'P' && p.props.length >= 4 && p.props[0].s === name) {
				const out: number[] = []
				for (const v of p.props.slice(4)) if (v.kind !== 'S') out.push(v.num())
				return out
			}
		}
		return null
	}
}

export class FbxDocument {
	version = 0
	nodes: FbxNode[] = []
	node(name: string): FbxNode | null {
		for (const n of this.nodes) if (n.name === name) return n
		return null
	}
}

const fbx_magic = 'Kaydara FBX Binary  '

// inflate: zlib-compressed bytes (FBX arrays) through the browser's DecompressionStream.
async function inflate(src: Uint8Array): Promise<Uint8Array> {
	const ds = new DecompressionStream('deflate')
	const out = new Response(new Blob([src as BlobPart]).stream().pipeThrough(ds))
	return new Uint8Array(await out.arrayBuffer())
}

class FbxReader {
	data: Uint8Array
	dv: DataView
	wide: boolean
	pos = 27
	jobs: Promise<void>[] = [] // compressed arrays being inflated
	constructor(data: Uint8Array, wide: boolean) {
		this.data = data
		this.dv = new DataView(data.buffer, data.byteOffset, data.byteLength)
		this.wide = wide
	}
	need(n: number) {
		if (n < 0 || this.pos + n > this.data.length) throw new Error(`FBX file is truncated (at byte ${this.pos})`)
	}
	u8(): number {
		this.need(1)
		return this.data[this.pos++]
	}
	u32(): number {
		this.need(4)
		const v = this.dv.getUint32(this.pos, true)
		this.pos += 4
		return v
	}
	u64(): number {
		this.need(8)
		const v = Number(this.dv.getBigUint64(this.pos, true))
		this.pos += 8
		return v
	}
	offset(): number {
		return this.wide ? this.u64() : this.u32()
	}
	// read_node: one node record; null = the zero record that ends a child list (or the file).
	read_node(): FbxNode | null {
		const end = this.offset()
		const nprops = this.offset()
		this.offset() // property list length in bytes
		const name_len = this.u8()
		if (end === 0) return null
		if (end > this.data.length || end < this.pos) throw new Error('FBX node record points outside the file')
		this.need(name_len)
		const node = new FbxNode()
		node.name = latin1(this.data.subarray(this.pos, this.pos + name_len))
		this.pos += name_len
		for (let i = 0; i < nprops; i++) node.props.push(this.read_prop())
		while (this.pos < end) {
			const c = this.read_node()
			if (c === null) break
			node.children.push(c)
		}
		this.pos = end
		return node
	}
	read_prop(): FbxProp {
		const t = String.fromCharCode(this.u8())
		const p = new FbxProp()
		p.kind = t
		switch (t) {
			case 'Y':
				this.need(2)
				p.i = this.dv.getInt16(this.pos, true)
				this.pos += 2
				break
			case 'C':
				p.i = this.u8()
				break
			case 'I':
				this.need(4)
				p.i = this.dv.getInt32(this.pos, true)
				this.pos += 4
				break
			case 'L': {
				this.need(8)
				const b = this.dv.getBigInt64(this.pos, true)
				this.pos += 8
				p.i = Number(b)
				p.key = b.toString()
				return p
			}
			case 'F':
				this.need(4)
				p.f = this.dv.getFloat32(this.pos, true)
				this.pos += 4
				break
			case 'D':
				this.need(8)
				p.f = this.dv.getFloat64(this.pos, true)
				this.pos += 8
				break
			case 'S':
			case 'R': {
				const n = this.u32()
				this.need(n)
				const bytes = this.data.slice(this.pos, this.pos + n)
				this.pos += n
				if (t === 'S') p.s = utf8(bytes).split('\x00\x01').join('::')
				else p.raw = bytes
				break
			}
			case 'f':
			case 'd':
			case 'l':
			case 'i':
			case 'b': {
				const count = this.u32()
				const encoding = this.u32()
				const clen = this.u32()
				this.need(clen)
				const src = this.data.subarray(this.pos, this.pos + clen)
				this.pos += clen
				if (encoding === 1) {
					this.jobs.push(inflate(src).then((bytes) => fill_array(p, t, count, bytes)))
				} else {
					fill_array(p, t, count, src)
				}
				break
			}
			default:
				throw new Error(`unknown FBX property type \`${t}\` at byte ${this.pos - 1}`)
		}
		p.key = String(p.i)
		return p
	}
}

function fill_array(p: FbxProp, t: string, count: number, bytes: Uint8Array) {
	const size = t === 'd' || t === 'l' ? 8 : t === 'f' || t === 'i' ? 4 : 1
	if (bytes.length < count * size) throw new Error('FBX array is shorter than its element count')
	const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
	const out: number[] = new Array(count)
	switch (t) {
		case 'd':
			for (let k = 0; k < count; k++) out[k] = dv.getFloat64(k * 8, true)
			p.floats = out
			break
		case 'f':
			for (let k = 0; k < count; k++) out[k] = dv.getFloat32(k * 4, true)
			p.floats = out
			break
		case 'l':
			for (let k = 0; k < count; k++) out[k] = Number(dv.getBigInt64(k * 8, true))
			p.ints = out
			break
		case 'i':
			for (let k = 0; k < count; k++) out[k] = dv.getInt32(k * 4, true)
			p.ints = out
			break
		default:
			for (let k = 0; k < count; k++) out[k] = bytes[k]
			p.ints = out
	}
}

function latin1(b: Uint8Array): string {
	let s = ''
	for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i])
	return s
}

function utf8(b: Uint8Array): string {
	return new TextDecoder('utf-8').decode(b)
}

// parse_fbx reads a binary FBX file. ASCII FBX is not supported (re-export as binary).
export async function parse_fbx(data: Uint8Array): Promise<FbxDocument> {
	if (data.length < 27 || latin1(data.subarray(0, 20)) !== fbx_magic) {
		if (data.length > 0 && latin1(data.subarray(0, Math.min(data.length, 200))).includes('FBXHeaderExtension')) {
			throw new Error('ASCII FBX is not supported, export it as binary FBX')
		}
		throw new Error('not a binary FBX file')
	}
	const version = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(23, true)
	if (version < 7000) throw new Error(`FBX version ${version} is too old (7.0 or later needed)`)
	const r = new FbxReader(data, version >= 7500)
	const doc = new FbxDocument()
	doc.version = version
	while (r.pos < data.length) {
		const n = r.read_node()
		if (n === null) break
		doc.nodes.push(n)
	}
	await Promise.all(r.jobs)
	return doc
}

// ---------- FBX import (model3d/fbx_import.v) ----------

const fbx_ticks_per_second = 46186158000.0
const bake_fps = 30

interface Conn {
	child: string
	parent: string
	prop: string
}

class NodeXform {
	t = new Vec3()
	r = new Vec3()
	s = new Vec3(1, 1, 1)
	pre = Quat.identity()
	post = Quat.identity()
	roff = new Vec3()
	rpiv = new Vec3()
	soff = new Vec3()
	spiv = new Vec3()
	order = 0
	clone(): NodeXform {
		return Object.assign(new NodeXform(), this)
	}
	// matrix: T * Roff * Rp * Rpre * R * Rpost^-1 * Rp^-1 * Soff * Sp * S * Sp^-1, translations in meters.
	matrix(unit: number): Mat4 {
		const tr = (v: Vec3) => Mat4.translation(v.mul(unit))
		const rot = this.pre.mul(euler_quat(this.r, this.order)).mul(this.post.conjugate())
		return tr(this.t)
			.op_mul(tr(this.roff))
			.op_mul(tr(this.rpiv))
			.op_mul(Mat4.rotation(rot))
			.op_mul(tr(this.rpiv.neg()))
			.op_mul(tr(this.soff))
			.op_mul(tr(this.spiv))
			.op_mul(Mat4.scaling(this.s))
			.op_mul(tr(this.spiv.neg()))
	}
}

function v3(a: number[] | null, def: Vec3): Vec3 {
	if (a === null || a.length < 3) return def
	return vec3(a[0], a[1], a[2])
}

// euler_quat: FBX euler angles (degrees) in the node's rotation order.
function euler_quat(e: Vec3, order: number): Quat {
	const qx = Quat.axis_angle(vec3(1, 0, 0), e.x)
	const qy = Quat.axis_angle(vec3(0, 1, 0), e.y)
	const qz = Quat.axis_angle(vec3(0, 0, 1), e.z)
	switch (order) {
		case 1:
			return qy.mul(qz).mul(qx) // XZY
		case 2:
			return qx.mul(qz).mul(qy) // YZX
		case 3:
			return qz.mul(qx).mul(qy) // YXZ
		case 4:
			return qy.mul(qx).mul(qz) // ZXY
		case 5:
			return qx.mul(qy).mul(qz) // ZYX
	}
	return qz.mul(qy).mul(qx) // XYZ
}

function node_xform(n: FbxNode): NodeXform {
	const x = new NodeXform()
	x.order = Math.trunc((n.p70('RotationOrder') ?? [0])[0])
	x.t = v3(n.p70('Lcl Translation'), new Vec3())
	x.r = v3(n.p70('Lcl Rotation'), new Vec3())
	x.s = v3(n.p70('Lcl Scaling'), new Vec3(1, 1, 1))
	x.pre = euler_quat(v3(n.p70('PreRotation'), new Vec3()), 0)
	x.post = euler_quat(v3(n.p70('PostRotation'), new Vec3()), 0)
	x.roff = v3(n.p70('RotationOffset'), new Vec3())
	x.rpiv = v3(n.p70('RotationPivot'), new Vec3())
	x.soff = v3(n.p70('ScalingOffset'), new Vec3())
	x.spiv = v3(n.p70('ScalingPivot'), new Vec3())
	return x
}

// class_of: 'LimbNode', 'Mesh', 'Null', ... (property 2 of an object).
function class_of(n: FbxNode): string {
	return n.props.length > 2 ? n.props[2].s : ''
}

function name_of(n: FbxNode): string {
	if (n.props.length < 2) return ''
	const s = n.props[1].s
	const i = s.indexOf('::')
	return i >= 0 ? s.slice(0, i) : s
}

interface LayerMap {
	mapping: string
	direct: boolean
	index: number[]
}

function layer_at(l: LayerMap, pv: number, cp: number, poly: number): number {
	let i = 0
	switch (l.mapping) {
		case 'ByPolygonVertex':
			i = pv
			break
		case 'ByControlPoint':
		case 'ByVertice':
		case 'ByVertex':
			i = cp
			break
		case 'ByPolygon':
			i = poly
			break
	}
	if (l.direct) return i
	return i < l.index.length ? l.index[i] : 0
}

function layer_map(el: FbxNode, index_name: string): LayerMap {
	const mc = el.child('MappingInformationType')
	const rc = el.child('ReferenceInformationType')
	const ic = el.child(index_name)
	const idx = ic ? ic.props[0].int_list() : []
	const refr = rc ? rc.props[0].s : 'Direct'
	return { mapping: mc ? mc.props[0].s : 'ByPolygonVertex', direct: refr === 'Direct' || idx.length === 0, index: idx }
}

function child_numbers(n: FbxNode, name: string): number[] {
	const c = n.child(name)
	if (c === null || c.props.length === 0) return []
	return c.props[0].numbers()
}

class Influence {
	bone = [0, 0, 0, 0]
	weight = [0, 0, 0, 0]
	add(bone: number, w: number) {
		// keep the 4 strongest
		let k = -1
		let low = 1e30
		for (let i = 0; i < 4; i++) {
			if (this.weight[i] < low) {
				low = this.weight[i]
				k = i
			}
		}
		if (w > low) {
			this.bone[k] = bone
			this.weight[k] = w
		}
	}
}

interface BoneSrc {
	id: string
	xform: NodeXform
}

class FbxScene {
	objs = new Map<string, FbxNode>()
	order: string[] = [] // object IDs in file order
	parents = new Map<string, Conn[]>() // child id -> its connections to parents
	children = new Map<string, Conn[]>() // parent id -> connections from its children
	unit = 1 // meters per file unit
	axis = Mat4.identity() // file axes -> y-up
	bone_index = new Map<string, number>()
	bone_ids: BoneSrc[] = []

	obj(id: string): FbxNode | null {
		return this.objs.get(id) ?? null
	}
	parents_of(id: string): Conn[] {
		return this.parents.get(id) ?? []
	}
	children_of(id: string): Conn[] {
		return this.children.get(id) ?? []
	}
	// parent_model: the Model node a Model is attached to ('0' = the scene root).
	parent_model(id: string): string {
		for (const c of this.parents_of(id)) {
			if (c.prop === '') {
				const p = this.obj(c.parent)
				if (p !== null && p.name === 'Model') return c.parent
			}
		}
		return '0'
	}
	scaled(m: Mat4): Mat4 {
		const r = m.clone()
		r.m[12] *= this.unit
		r.m[13] *= this.unit
		r.m[14] *= this.unit
		return r
	}
	model_global(id: string): Mat4 {
		let g = Mat4.identity()
		let cur = id
		while (cur !== '0') {
			const o = this.objs.get(cur)
			if (!o) break
			g = node_xform(o).matrix(this.unit).op_mul(g)
			cur = this.parent_model(cur)
		}
		return this.axis.op_mul(g)
	}

	build_skeleton(m: Model) {
		// every Model that is not a mesh, ordered parents first
		const ids: string[] = []
		for (const id of this.order) {
			const o = this.objs.get(id)!
			if (o.name === 'Model' && class_of(o) !== 'Mesh') ids.push(id)
		}
		ids.sort((a, b) => {
			const x = BigInt(a)
			const y = BigInt(b)
			return x < y ? -1 : x > y ? 1 : 0
		})
		const index = new Map<string, number>()
		const srcs: BoneSrc[] = []
		let placed = true
		while (placed) {
			placed = false
			for (const id of ids) {
				if (index.has(id)) continue
				const p = this.parent_model(id)
				const pi = p === '0' ? -1 : index.get(p) ?? -2
				if (pi === -2) {
					const po = this.obj(p)
					if (po !== null && class_of(po) !== 'Mesh') continue // parent not placed yet
				}
				const o = this.objs.get(id)
				if (!o) continue
				const x = node_xform(o)
				const local = x.matrix(this.unit)
				const b = new Bone()
				b.name = name_of(o)
				b.parent = pi >= 0 ? pi : -1
				const [t, r, s] = b.parent < 0 ? this.axis.op_mul(local).decompose() : local.decompose()
				b.t = t
				b.r = r
				b.s = s
				index.set(id, m.bones.length)
				m.bones.push(b)
				srcs.push({ id, xform: x })
				placed = true
			}
		}
		this.bone_ids = srcs
		this.bone_index = index
	}

	build_meshes(m: Model) {
		const tex_index = new Map<string, number>()
		for (const gid of this.order) {
			const geo = this.objs.get(gid)!
			if (geo.name !== 'Geometry' || class_of(geo) !== 'Mesh') continue
			const vn = geo.child('Vertices')
			const pn = geo.child('PolygonVertexIndex')
			if (vn === null || pn === null) continue
			const verts_p = vn.props[0].numbers()
			const poly_idx = pn.props[0].int_list()
			// the mesh Model this geometry belongs to
			let model_id = '0'
			for (const c of this.parents_of(gid)) {
				const o = this.obj(c.parent)
				if (o !== null && o.name === 'Model') {
					model_id = c.parent
					break
				}
			}
			// skin: Geometry <- Skin <- Clusters <- bone Models
			const ncp = Math.trunc(verts_p.length / 3)
			const infl: Influence[] = []
			for (let i = 0; i < ncp; i++) infl.push(new Influence())
			let skinned = false
			let bind = Mat4.identity() // mesh global at bind time
			for (const c of this.children_of(gid)) {
				const skin = this.obj(c.child)
				if (skin === null || skin.name !== 'Deformer' || class_of(skin) !== 'Skin') continue
				for (const cc of this.children_of(c.child)) {
					const cl = this.obj(cc.child)
					if (cl === null || cl.name !== 'Deformer' || class_of(cl) !== 'Cluster') continue
					let bone = -1
					for (const bc of this.children_of(cc.child)) {
						const bi = this.bone_index.get(bc.child)
						if (bi !== undefined) bone = bi
					}
					if (bone < 0) continue
					const tl = cl.child('TransformLink')
					if (tl !== null) {
						const link = this.axis.op_mul(this.scaled(Mat4.from_f64(tl.props[0].numbers())))
						m.bones[bone].inverse_bind = link.inverse()
					}
					const tf = cl.child('Transform')
					if (tf !== null && tl !== null) {
						// the file stores Transform = TransformLink^-1 * (mesh global at bind time)
						const link = this.scaled(Mat4.from_f64(tl.props[0].numbers()))
						bind = this.axis.op_mul(link).op_mul(this.scaled(Mat4.from_f64(tf.props[0].numbers())))
					}
					const ixn = cl.child('Indexes')
					const wn = cl.child('Weights')
					const idx = ixn ? ixn.props[0].int_list() : []
					const wts = wn ? wn.props[0].numbers() : []
					for (let k = 0; k < idx.length; k++) {
						const cp = idx[k]
						if (cp < ncp && k < wts.length && wts[k] > 0) {
							infl[cp].add(bone, wts[k])
							skinned = true
						}
					}
				}
			}
			// a rigid mesh under a bone follows that bone
			let rigid_bone = -1
			if (!skinned && model_id !== '0') {
				const bi = this.bone_index.get(this.parent_model(model_id))
				if (bi !== undefined) rigid_bone = bi
			}
			const xf = skinned ? bind : this.model_global(model_id)
			if (rigid_bone >= 0) {
				const g = this.model_global(this.parent_model(model_id))
				if (m.bones[rigid_bone].inverse_bind.op_eq(Mat4.identity())) m.bones[rigid_bone].inverse_bind = g.inverse()
			}
			const nxf = xf.inverse().transposed()
			// layers
			const normals_el = geo.child('LayerElementNormal')
			const uv_el = geo.child('LayerElementUV')
			const mat_el = geo.child('LayerElementMaterial')
			const nrm = normals_el ? child_numbers(normals_el, 'Normals') : []
			const nmap: LayerMap = normals_el ? layer_map(normals_el, 'NormalsIndex') : { mapping: '', direct: false, index: [] }
			const uvs = uv_el ? child_numbers(uv_el, 'UV') : []
			const umap: LayerMap = uv_el ? layer_map(uv_el, 'UVIndex') : { mapping: '', direct: false, index: [] }
			const mats = mat_el ? child_numbers(mat_el, 'Materials').map((x) => Math.trunc(x)) : []
			let mat_mapping = 'AllSame'
			if (mat_el) {
				const c = mat_el.child('MappingInformationType')
				if (c) mat_mapping = c.props[0].s
			}
			// materials of the mesh Model, in connection order
			const materials: string[] = []
			for (const c of this.children_of(model_id)) {
				const o = this.obj(c.child)
				if (o !== null && o.name === 'Material') materials.push(c.child)
			}
			// one MeshData per material slot used
			const parts = new Map<number, number>()
			const out: MeshData[] = []
			const dedupe: Map<number, number>[] = []
			let poly = 0
			let start = 0
			for (let i = 0; i < poly_idx.length; i++) {
				if (poly_idx[i] >= 0) continue
				const slot = mats.length === 0 ? 0 : mat_mapping === 'AllSame' ? mats[0] : poly < mats.length ? mats[poly] : 0
				if (!parts.has(slot)) {
					parts.set(slot, out.length)
					const md = new MeshData()
					const mo = this.objs.get(model_id)
					md.name = mo ? name_of(mo) : ''
					if (slot < materials.length) {
						const mat = this.objs.get(materials[slot]) ?? new FbxNode()
						const dc = mat.p70('DiffuseColor')
						if (dc !== null && dc.length >= 3) md.color = rgba(Math.trunc(Math.min(dc[0], 1) * 255), Math.trunc(Math.min(dc[1], 1) * 255), Math.trunc(Math.min(dc[2], 1) * 255), 255)
						md.texture = this.material_texture(materials[slot], m, tex_index)
					}
					out.push(md)
					dedupe.push(new Map())
				}
				const pi = parts.get(slot)!
				const md = out[pi]
				const corners: number[] = []
				for (let k = start; k <= i; k++) {
					const cp = poly_idx[k] < 0 ? -poly_idx[k] - 1 : poly_idx[k]
					if (cp >= ncp) continue
					const ni = layer_at(nmap, k, cp, poly)
					const ui = layer_at(umap, k, cp, poly)
					const key = cp * 4294967296 + (ui >>> 0)
					let nx = 0, ny = 1, nz = 0
					if (ni * 3 + 2 < nrm.length) {
						const n = nxf.transform_dir(vec3(nrm[ni * 3], nrm[ni * 3 + 1], nrm[ni * 3 + 2])).normalized()
						nx = n.x
						ny = n.y
						nz = n.z
					}
					const seen = dedupe[pi].get(key)
					if (seen !== undefined) {
						const o = 3 * seen
						if (Math.abs(md.normals[o] - nx) + Math.abs(md.normals[o + 1] - ny) + Math.abs(md.normals[o + 2] - nz) < 1e-3) {
							corners.push(seen)
							continue
						}
					}
					const vi = md.positions.length / 3
					dedupe[pi].set(key, vi)
					const p = xf.transform_point(vec3(verts_p[cp * 3] * this.unit, verts_p[cp * 3 + 1] * this.unit, verts_p[cp * 3 + 2] * this.unit))
					md.positions.push(p.x, p.y, p.z)
					md.normals.push(nx, ny, nz)
					if (ui * 2 + 1 < uvs.length) md.uvs.push(uvs[ui * 2], 1 - uvs[ui * 2 + 1])
					else md.uvs.push(0, 0)
					if (skinned || rigid_bone >= 0) {
						let bones: number[]
						let weights: number[]
						if (skinned) {
							bones = infl[cp].bone
							weights = infl[cp].weight.slice()
						} else {
							bones = [rigid_bone, 0, 0, 0]
							weights = [1, 0, 0, 0]
						}
						let sum = weights[0] + weights[1] + weights[2] + weights[3]
						if (sum <= 0) {
							weights[0] = 1
							sum = 1
						}
						for (let j = 0; j < 4; j++) {
							md.joints.push(bones[j])
							md.weights.push(weights[j] / sum)
						}
					}
					corners.push(vi)
				}
				// fan triangulation
				for (let k = 1; k + 1 < corners.length; k++) md.indices.push(corners[0], corners[k], corners[k + 1])
				poly++
				start = i + 1
			}
			for (const md of out) if (md.indices.length > 0) m.meshes.push(md)
		}
		if (m.meshes.length === 0) throw new Error('no meshes')
	}

	// material_texture: the base color texture of a material, added to m.textures on first use (-1 = none).
	material_texture(mat_id: string, m: Model, seen: Map<string, number>): number {
		for (const c of this.children_of(mat_id)) {
			const tex = this.obj(c.child)
			if (tex === null || tex.name !== 'Texture') continue
			const p = c.prop.toLowerCase()
			if (!(p.includes('diffuse') || p.includes('basecolor') || p.includes('base_color') || p === '')) continue
			const known = seen.get(c.child)
			if (known !== undefined) return known
			let bytes: Uint8Array<ArrayBuffer> = new Uint8Array(0)
			const rf = tex.child('RelativeFilename')
			let file = rf ? rf.props[0].s : ''
			if (file === '') {
				const fn = tex.child('FileName')
				file = fn ? fn.props[0].s : ''
			}
			for (const vc of this.children_of(c.child)) {
				const video = this.obj(vc.child)
				if (video !== null && video.name === 'Video') {
					const content = video.child('Content')
					if (content !== null && content.props.length > 0 && content.props[0].raw.length > 0) bytes = content.props[0].raw
				}
			}
			seen.set(c.child, m.textures.length)
			const img = new Image()
			img.name = name_of(tex)
			img.bytes = bytes
			img.file = file
			m.textures.push(img)
			return m.textures.length - 1
		}
		return -1
	}

	build_clips(m: Model) {
		for (const sid of this.order) {
			const stack = this.objs.get(sid)!
			if (stack.name !== 'AnimationStack') continue
			const chans = new Map<string, Curve[]>() // '<bone>|T' -> curves per axis (null = not animated)
			let tmax = 0
			for (const lc of this.children_of(sid)) {
				const layer = this.obj(lc.child)
				if (layer === null || layer.name !== 'AnimationLayer') continue
				for (const cc of this.children_of(lc.child)) {
					const cn = this.obj(cc.child)
					if (cn === null || cn.name !== 'AnimationCurveNode') continue
					let bone = -1
					let what = ''
					for (const pc of this.parents_of(cc.child)) {
						const bi = this.bone_index.get(pc.parent)
						if (bi !== undefined) {
							what = pc.prop === 'Lcl Translation' ? 'T' : pc.prop === 'Lcl Rotation' ? 'R' : pc.prop === 'Lcl Scaling' ? 'S' : ''
							if (what !== '') bone = bi
						}
					}
					if (bone < 0) continue
					const ch: Curve[] = [new Curve(), new Curve(), new Curve()]
					const axes = ['d|X', 'd|Y', 'd|Z']
					for (let k = 0; k < 3; k++) {
						for (const vc of this.children_of(cc.child)) {
							if (vc.prop !== axes[k]) continue
							const curve = this.obj(vc.child)
							if (curve === null) continue
							const kt = curve.child('KeyTime')
							const kv = curve.child('KeyValueFloat')
							const times = kt ? kt.props[0].int_list() : []
							const vals = kv ? kv.props[0].numbers() : []
							if (times.length === 0 || times.length !== vals.length) continue
							const secs = times.map((x) => x / fbx_ticks_per_second)
							if (secs[secs.length - 1] > tmax) tmax = secs[secs.length - 1]
							ch[k] = new Curve(secs, vals)
						}
					}
					chans.set(`${bone}|${what}`, ch)
				}
			}
			if (chans.size === 0) continue
			let dur = tmax
			const stop = stack.p70('LocalStop')
			if (stop !== null) {
				const start = (stack.p70('LocalStart') ?? [0])[0]
				const d = (stop[0] - start) / fbx_ticks_per_second
				if (d > 0) dur = d
			}
			const frames = Math.round(dur * bake_fps) + 1
			const clip = new Clip()
			clip.name = name_of(stack)
			clip.duration = dur
			clip.fps = bake_fps
			for (let f = 0; f < frames; f++) {
				const t = f / bake_fps
				const ft: Vec3[] = []
				const fr: Quat[] = []
				const fs: Vec3[] = []
				for (let b = 0; b < m.bones.length; b++) {
					const x = this.bone_ids[b].xform.clone()
					const ct = chans.get(`${b}|T`)
					if (ct) x.t = channel_at(ct, t, x.t)
					const cr = chans.get(`${b}|R`)
					if (cr) x.r = channel_at(cr, t, x.r)
					const cs = chans.get(`${b}|S`)
					if (cs) x.s = channel_at(cs, t, x.s)
					let local = x.matrix(this.unit)
					if (m.bones[b].parent < 0) local = this.axis.op_mul(local)
					const [dt, dr, ds] = local.decompose()
					ft.push(dt)
					fr.push(dr)
					fs.push(ds)
				}
				clip.t.push(ft)
				clip.r.push(fr)
				clip.s.push(fs)
			}
			m.clips.push(clip)
		}
		m.clips.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
	}
}

class Curve {
	times: number[]
	values: number[]
	constructor(times: number[] = [], values: number[] = []) {
		this.times = times
		this.values = values
	}
	eval(t: number): number {
		const n = this.times.length
		if (n === 0) return 0
		if (t <= this.times[0]) return this.values[0]
		if (t >= this.times[n - 1]) return this.values[n - 1]
		let lo = 0
		let hi = n - 1
		while (hi - lo > 1) {
			const mid = (lo + hi) >> 1
			if (this.times[mid] <= t) lo = mid
			else hi = mid
		}
		const span = this.times[hi] - this.times[lo]
		const k = span > 0 ? (t - this.times[lo]) / span : 0
		return this.values[lo] + (this.values[hi] - this.values[lo]) * k
	}
}

function channel_at(ch: Curve[], t: number, def: Vec3): Vec3 {
	const out = [def.x, def.y, def.z]
	for (let i = 0; i < 3; i++) if (ch[i].times.length > 0) out[i] = ch[i].eval(t)
	return vec3(out[0], out[1], out[2])
}

// import_fbx builds a Model from the bytes of a binary .fbx file.
export async function import_fbx(data: Uint8Array): Promise<Model> {
	const doc = await parse_fbx(data)
	const objects = doc.node('Objects')
	if (objects === null) throw new Error('no Objects section')
	const sc = new FbxScene()
	for (const o of objects.children) {
		const id = o.id()
		if (!sc.objs.has(id)) sc.order.push(id)
		sc.objs.set(id, o)
	}
	const conns = doc.node('Connections')
	if (conns !== null) {
		for (const c of conns.children) {
			if (c.name !== 'C' || c.props.length < 3) continue
			const cn: Conn = { child: c.props[1].key, parent: c.props[2].key, prop: c.props.length > 3 ? c.props[3].s : '' }
			if (!sc.parents.has(cn.child)) sc.parents.set(cn.child, [])
			sc.parents.get(cn.child)!.push(cn)
			if (!sc.children.has(cn.parent)) sc.children.set(cn.parent, [])
			sc.children.get(cn.parent)!.push(cn)
		}
	}
	const gs = doc.node('GlobalSettings')
	if (gs !== null) {
		// UnitScaleFactor = centimeters per unit
		sc.unit = (gs.p70('UnitScaleFactor') ?? [1])[0] / 100
		const up = (gs.p70('UpAxis') ?? [1])[0]
		const up_sign = (gs.p70('UpAxisSign') ?? [1])[0]
		if (Math.trunc(up) === 2) {
			// z-up -> y-up: rotate -90 degrees around x
			sc.axis = Mat4.rotation(Quat.axis_angle(vec3(1, 0, 0), up_sign > 0 ? -90 : 90))
		}
	}
	const m = new Model()
	sc.build_skeleton(m)
	sc.build_meshes(m)
	sc.build_clips(m)
	m.compute_bounds()
	return m
}

// ---------- Models parsed at preload ----------

const parsed = new Map<string, Model | null>() // asset path -> model (null: it could not be read)

// parse_model_asset parses a model's bytes (once per path) and decodes its embedded textures.
export async function parse_model_asset(path: string, data: ArrayBuffer): Promise<void> {
	if (parsed.has(path)) return
	try {
		const m = await import_fbx(new Uint8Array(data))
		if (m.name === '') m.name = V_file_stem(path)
		for (const img of m.textures) {
			if (img.bytes.length === 0) continue
			try {
				img.bitmap = await createImageBitmap(new Blob([img.bytes as BlobPart]), { premultiplyAlpha: 'none', colorSpaceConversion: 'none' })
			} catch (e) {
				console.error(`[model3d] ${path}: texture ${img.name}: ${e}`)
			}
		}
		parsed.set(path, m)
	} catch (e) {
		console.error(`[model3d] ${V_file_name(path)}: ${e instanceof Error ? e.message : e}`)
		parsed.set(path, null)
	}
}

// load_fbx returns the model parsed at preload for `path` (an error if it was not, or could not be read).
export function load_fbx(path: string): Model {
	const m = parsed.get(path)
	if (m === undefined) throw new Error(`${V_file_name(path)}: model was not preloaded`)
	if (m === null) throw new Error(`${V_file_name(path)}: cannot read the model`)
	return m
}

function V_file_name(p: string): string {
	return p.slice(p.lastIndexOf('/') + 1)
}

function V_file_stem(p: string): string {
	const n = V_file_name(p)
	const i = n.lastIndexOf('.')
	return i > 0 ? n.slice(0, i) : n
}
