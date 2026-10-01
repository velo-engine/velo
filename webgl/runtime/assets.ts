// velo.assets for the WebGL runtime. In a browser there is no directory to scan: `velo build webgl` writes
// assets.json (every asset's ID, path, kind, .meta settings and dependencies) next to the copied assets, and
// `preload` downloads everything before the game starts, so loading stays synchronous like on desktop.

import * as V from './v.ts'

export type AssetKind = 'unknown' | 'texture' | 'audio' | 'scene' | 'text' | 'font' | 'shader'

export function kind_from_ext(path: string): AssetKind {
	const ext = V.S.all_after_last(path, '.').toLowerCase()
	switch (ext) {
		case 'png':
		case 'jpg':
		case 'jpeg':
		case 'bmp':
		case 'tga':
			return 'texture'
		case 'wav':
		case 'ogg':
		case 'mp3':
			return 'audio'
		case 'scene':
		case 'prefab':
			return 'scene'
		case 'txt':
		case 'json':
		case 'md':
		case 'csv':
			return 'text'
		case 'ttf':
		case 'otf':
			return 'font'
		case 'glsl':
		case 'frag':
			return 'shader'
	}
	return 'unknown'
}

export function kind_from_str(s: string): AssetKind {
	return s === 'texture' || s === 'audio' || s === 'scene' || s === 'text' || s === 'font' || s === 'shader' ? s : 'unknown'
}

// AssetRef[T] — a typed asset reference, stored as a stable ID. `type` is the asset class (Texture, ...).
export class AssetRef {
	static __vname = 'assets.AssetRef'
	id: string
	type: V.TypeDesc | null
	constructor(id = '', type: V.TypeDesc | null = null) {
		this.id = id
		this.type = type
	}
	clone(): AssetRef {
		return new AssetRef(this.id, this.type)
	}
	op_eq(o: AssetRef): boolean {
		return this.id === o.id
	}
	is_set(): boolean {
		return this.id !== ''
	}
	str(): string {
		return `AssetRef{id: '${this.id}'}`
	}
}

export function ref(t: V.TypeDesc, id: string): AssetRef {
	return new AssetRef(id, t)
}

// ---------- Loaded asset data ----------

export class Texture {
	static __vname = 'assets.Texture'
	id = ''
	path = ''
	width = 0
	height = 0
	frame_width = 0
	frame_height = 0
	filter = 'linear'
	version = 0
	// the decoded image, uploaded to the GPU by the renderer on first use
	image: TexImageSource | null = null

	frame_count(): number {
		const fw = this.frame_w()
		const fh = this.frame_h()
		if (fw <= 0 || fh <= 0) return 1
		return Math.trunc(this.width / fw) * Math.trunc(this.height / fh)
	}
	frame_w(): number {
		return this.frame_width > 0 ? this.frame_width : this.width
	}
	frame_h(): number {
		return this.frame_height > 0 ? this.frame_height : this.height
	}
	// frame_rect returns (x, y, w, h) of frame i in the source image.
	frame_rect(i: number): [number, number, number, number] {
		const fw = this.frame_w()
		const fh = this.frame_h()
		const cols = fw > 0 ? Math.trunc(this.width / fw) : 1
		const count = this.frame_count()
		const idx = count > 0 ? ((i % count) + count) % count : 0
		const c = cols > 0 ? idx % cols : 0
		const r = cols > 0 ? Math.trunc(idx / cols) : 0
		return [c * fw, r * fh, fw, fh]
	}
}

export class SceneAsset {
	static __vname = 'assets.SceneAsset'
	id = ''
	path = ''
	source = ''
	version = 0
}

export class TextAsset {
	static __vname = 'assets.TextAsset'
	id = ''
	path = ''
	text = ''
	version = 0
}

export class Font {
	static __vname = 'assets.Font'
	id = ''
	path = ''
	version = 0
	// the CSS font family the font was registered under (FontFace)
	family = ''
}

// Shader — a .glsl fragment effect for Sprite (see render/shader.v); the renderer compiles it on first use.
export class Shader {
	static __vname = 'assets.Shader'
	id = ''
	path = ''
	source = ''
	version = 0
}

export class AudioClip {
	static __vname = 'assets.AudioClip'
	id = ''
	path = ''
	bytes = 0
	stream = ''
	version = 0
	// the file's bytes (the audio module decodes them)
	data: ArrayBuffer | null = null
}

// ---------- Meta ----------

export class Meta {
	static __vname = 'assets.Meta'
	id = ''
	kind = ''
	version = 1
	settings = new Map<string, string>()
	setting_int(key: string, def: number): number {
		const v = this.settings.get(key)
		return v === undefined ? def : V.S.int(v)
	}
	clone(): Meta {
		const m = new Meta()
		m.id = this.id
		m.kind = this.kind
		m.version = this.version
		m.settings = new Map(this.settings)
		return m
	}
}

export function parse_meta(src: string): Meta {
	const m = new Meta()
	for (const raw of V.S.split_into_lines(src)) {
		const line = raw.trim()
		if (line === '' || line.startsWith('#')) continue
		const key = V.S.all_before(line, ':').trim()
		const val = V.S.all_after(line, ':').trim()
		if (!line.includes(':') || key === '') throw new V.VError(`invalid line: "${line}"`)
		if (key === 'id') m.id = val
		else if (key === 'kind') m.kind = val
		else if (key === 'version') m.version = V.S.int(val)
		else m.settings.set(key, val)
	}
	if (m.id === '') throw new V.VError('missing id')
	return m
}

// ---------- Database ----------

export class AssetEntry {
	static __vname = 'assets.AssetEntry'
	id = ''
	path = ''
	kind: AssetKind = 'unknown'
	meta = new Meta()
	deps: string[] = []
	hash = 0
	mtime = 0
	refs = 0
	texture: Texture | null = null
	scene: SceneAsset | null = null
	text: TextAsset | null = null
	audio: AudioClip | null = null
	font: Font | null = null
	shader: Shader | null = null

	is_loaded(): boolean {
		return this.texture !== null || this.scene !== null || this.text !== null || this.audio !== null || this.font !== null || this.shader !== null
	}
}

export type AssetEventKind = 'added' | 'modified' | 'moved' | 'removed' | 'unloaded'

export class AssetEvent {
	static __vname = 'assets.AssetEvent'
	kind: AssetEventKind
	id: string
	path: string
	constructor(kind: AssetEventKind = 'added', id = '', path = '') {
		this.kind = kind
		this.id = id
		this.path = path
	}
	clone(): AssetEvent {
		return new AssetEvent(this.kind, this.id, this.path)
	}
}

// ManifestEntry — one asset in assets.json (written by `velo build webgl`).
export interface ManifestEntry {
	id: string
	path: string
	kind: string
	settings: Record<string, string>
	deps: string[]
	bytes: number
	hash: number
}

export interface Manifest {
	entries: ManifestEntry[]
}

// Preloaded — what the browser downloaded before the game started, by asset ID.
export class Preloaded {
	text = new Map<string, string>()
	images = new Map<string, TexImageSource & { width: number; height: number }>()
	bytes = new Map<string, ArrayBuffer>()
	fonts = new Map<string, string>() // id -> CSS family
}

export class AssetDatabase {
	static __vname = 'assets.AssetDatabase'
	root: string
	entries = new Map<string, AssetEntry>()
	by_path = new Map<string, string>()
	events: AssetEvent[] = []
	warnings: string[] = []
	data: Preloaded

	constructor(root: string, manifest: Manifest, data: Preloaded) {
		this.root = root
		this.data = data
		for (const m of manifest.entries) {
			const e = new AssetEntry()
			e.id = m.id
			e.path = m.path
			e.kind = kind_from_str(m.kind)
			e.meta.id = m.id
			e.meta.kind = m.kind
			e.meta.settings = new Map(Object.entries(m.settings ?? {}))
			e.deps = m.deps ?? []
			e.hash = m.hash ?? 0
			this.entries.set(e.id, e)
			this.by_path.set(e.path, e.id)
		}
	}

	// ---------- Lookup ----------

	entry(id: string): AssetEntry | null {
		return this.entries.get(id) ?? null
	}
	id_of(path: string): string | null {
		return this.by_path.get(normalize(path)) ?? null
	}
	path_of(id: string): string | null {
		const e = this.entries.get(id)
		return e ? e.path : null
	}
	resolve(key: string): string | null {
		if (this.entries.has(key)) return key
		return this.id_of(key)
	}
	abs_path(e: AssetEntry): string {
		return this.root + '/' + e.path
	}
	all(): AssetEntry[] {
		return [...this.entries.values()].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))
	}
	len(): number {
		return this.entries.size
	}

	// ---------- Typed loading + reference counting ----------

	load<T>(t: V.TypeDesc, key: string): T {
		const id = this.resolve(key)
		const e = id === null ? undefined : this.entries.get(id)
		if (!e) throw new V.VError(`asset "${key}" not found`)
		if (t === Texture) {
			this.expect_kind(e, 'texture', 'Texture')
			if (e.texture === null) e.texture = this.read_texture(e)
			e.refs++
			return e.texture as T
		}
		if (t === SceneAsset) {
			this.expect_kind(e, 'scene', 'SceneAsset')
			if (e.scene === null) {
				const s = new SceneAsset()
				s.id = e.id
				s.path = this.abs_path(e)
				s.source = this.read_text(e)
				e.scene = s
			}
			e.refs++
			return e.scene as T
		}
		if (t === TextAsset) {
			this.expect_kind(e, 'text', 'TextAsset')
			if (e.text === null) {
				const s = new TextAsset()
				s.id = e.id
				s.path = this.abs_path(e)
				s.text = this.read_text(e)
				e.text = s
			}
			e.refs++
			return e.text as T
		}
		if (t === Font) {
			this.expect_kind(e, 'font', 'Font')
			if (e.font === null) {
				const f = new Font()
				f.id = e.id
				f.path = this.abs_path(e)
				f.family = this.data.fonts.get(e.id) ?? ''
				e.font = f
			}
			e.refs++
			return e.font as T
		}
		if (t === Shader) {
			this.expect_kind(e, 'shader', 'Shader')
			if (e.shader === null) {
				const s = new Shader()
				s.id = e.id
				s.path = this.abs_path(e)
				s.source = this.read_text(e)
				e.shader = s
			}
			e.refs++
			return e.shader as T
		}
		if (t === AudioClip) {
			this.expect_kind(e, 'audio', 'AudioClip')
			if (e.audio === null) {
				const a = new AudioClip()
				a.id = e.id
				a.path = this.abs_path(e)
				a.data = this.data.bytes.get(e.id) ?? null
				a.bytes = a.data ? a.data.byteLength : 0
				a.stream = e.meta.settings.get('stream') ?? ''
				e.audio = a
			}
			e.refs++
			return e.audio as T
		}
		throw new V.VError(`unsupported asset type: ${V.type_name(t)}`)
	}

	get<T>(t: V.TypeDesc, r: AssetRef): T {
		if (!r.is_set()) throw new V.VError('empty AssetRef')
		return this.load<T>(t, r.id)
	}

	release(id: string) {
		const e = this.entries.get(id)
		if (!e || e.refs <= 0) return
		e.refs--
		if (e.refs === 0) {
			e.texture = null
			e.scene = null
			e.text = null
			e.audio = null
			e.font = null
			e.shader = null
			this.events.push(new AssetEvent('unloaded', e.id, e.path))
		}
	}

	loaded_count(): number {
		let n = 0
		for (const e of this.entries.values()) if (e.is_loaded()) n++
		return n
	}

	drain_events(): AssetEvent[] {
		const ev = this.events
		this.events = []
		return ev
	}

	// ---------- Dependency graph ----------

	dependencies(id: string): string[] {
		const e = this.entries.get(id)
		return e ? e.deps.slice() : []
	}
	dependencies_deep(id: string): string[] {
		const seen = new Set<string>()
		const stack = this.dependencies(id)
		while (stack.length > 0) {
			const cur = stack.pop()!
			if (seen.has(cur)) continue
			seen.add(cur)
			stack.push(...this.dependencies(cur))
		}
		return [...seen].sort()
	}
	dependents(id: string): string[] {
		const out: string[] = []
		for (const e of this.entries.values()) if (e.deps.includes(id)) out.push(e.id)
		return out.sort()
	}
	unused(roots: string[]): string[] {
		const reachable = new Set<string>()
		for (const r of roots) {
			const id = this.resolve(r)
			if (id === null) continue
			reachable.add(id)
			for (const d of this.dependencies_deep(id)) reachable.add(d)
		}
		return this.all()
			.filter((e) => !reachable.has(e.id))
			.map((e) => e.id)
	}
	missing_references(): string[][] {
		const out: string[][] = []
		for (const e of this.all()) for (const d of e.deps) if (!this.entries.has(d)) out.push([e.id, d])
		return out
	}

	// Packaged web assets never change on disk.
	poll_changes(): AssetEvent[] {
		return this.drain_events()
	}

	// ---------- Internal ----------

	private read_text(e: AssetEntry): string {
		const t = this.data.text.get(e.id)
		if (t === undefined) throw new V.VError(`asset "${e.path}" was not downloaded`)
		return t
	}

	private read_texture(e: AssetEntry): Texture {
		const img = this.data.images.get(e.id)
		if (!img) throw new V.VError(`cannot read image size: ${e.path}`)
		const t = new Texture()
		t.id = e.id
		t.path = this.abs_path(e)
		t.width = img.width
		t.height = img.height
		t.frame_width = e.meta.setting_int('frame_width', 0)
		t.frame_height = e.meta.setting_int('frame_height', 0)
		t.filter = e.meta.settings.get('filter') ?? 'linear'
		t.image = img
		return t
	}

	private expect_kind(e: AssetEntry, want: AssetKind, type_name: string) {
		if (e.kind !== want) throw new V.VError(`asset "${e.path}" (${e.id}) is ${e.kind}, cannot load it as ${type_name}`)
	}

	warn(msg: string) {
		this.warnings.push(msg)
		console.error(`[assets] ${msg}`)
	}
}

function normalize(p: string): string {
	return p.replace(/\\/g, '/')
}

// open: in the browser the database comes from preload(); kept for API compatibility.
export function open(_root: string): AssetDatabase {
	throw new V.VError('assets.open is not available in the browser (the app preloads assets.json)')
}

// preload downloads assets.json and every asset it lists, reporting progress (0..1).
export async function preload(root: string, on_progress: (done: number, total: number) => void): Promise<AssetDatabase> {
	const res = await fetch(`${root}/assets.json`)
	if (!res.ok) throw new Error(`cannot download ${root}/assets.json (${res.status})`)
	const manifest = (await res.json()) as Manifest
	const data = new Preloaded()
	const total = manifest.entries.length
	let done = 0
	const tick = () => {
		done++
		on_progress(done, total)
	}
	const url = (p: string) => `${root}/${p.split('/').map(encodeURIComponent).join('/')}`
	const jobs = manifest.entries.map(async (e) => {
		try {
			switch (kind_from_str(e.kind)) {
				case 'scene':
				case 'text':
				case 'shader': {
					const r = await fetch(url(e.path))
					if (!r.ok) throw new Error(`HTTP ${r.status}`)
					data.text.set(e.id, await r.text())
					break
				}
				case 'texture': {
					const r = await fetch(url(e.path))
					if (!r.ok) throw new Error(`HTTP ${r.status}`)
					const blob = await r.blob()
					// premultiplication is done in the shader-friendly way by the renderer (UNPACK_PREMULTIPLY_ALPHA)
					const bmp = await createImageBitmap(blob, { premultiplyAlpha: 'none', colorSpaceConversion: 'none' })
					data.images.set(e.id, bmp)
					break
				}
				case 'audio': {
					const r = await fetch(url(e.path))
					if (!r.ok) throw new Error(`HTTP ${r.status}`)
					data.bytes.set(e.id, await r.arrayBuffer())
					break
				}
				case 'font': {
					const family = `velo-font-${e.id}`
					const face = new FontFace(family, `url(${url(e.path)})`)
					await face.load()
					;(document as any).fonts.add(face)
					data.fonts.set(e.id, family)
					break
				}
			}
		} catch (err) {
			console.error(`[assets] cannot download ${e.path}: ${err}`)
		} finally {
			tick()
		}
	})
	await Promise.all(jobs)
	return new AssetDatabase(root, manifest, data)
}
