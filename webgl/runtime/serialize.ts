// velo.serialize for the WebGL runtime: the .scene parser, the component Registry and the SceneLoader (prefab
// instances + overrides). V reads and writes component fields with comptime reflection (`$for field in T.fields`);
// here every component class lists its serializable fields in a static `__fields` (tools/v2js writes it for game
// components, from the V struct: same fields, same order, `@[hide]` left out, `@[choices]` kept).

import * as V from './v.ts'
import * as core from './core.ts'
import * as assets from './assets.ts'

// ---------- Values (serialize/value.v) ----------

export class AssetId {
	static __vname = 'serialize.AssetId'
	id: string
	constructor(id = '') {
		this.id = id
	}
	clone(): AssetId {
		return new AssetId(this.id)
	}
}

// Value — a property value in a .scene file: AssetId | Value[] | boolean | number | string.
export type Value = AssetId | Value[] | boolean | number | string

function to_text_short(v: Value): string {
	return Value__to_text(v)
}

export function Value__as_f64(v: Value): number {
	if (typeof v === 'number') return v
	if (typeof v === 'boolean') return v ? 1 : 0
	throw new V.VError(`expected a number, got ${to_text_short(v)}`)
}

export function Value__as_bool(v: Value): boolean {
	if (typeof v === 'boolean') return v
	if (typeof v === 'number') return v !== 0
	throw new V.VError(`expected true/false, got ${to_text_short(v)}`)
}

export function Value__as_string(v: Value): string {
	if (typeof v === 'string') return v
	throw new V.VError(`expected a string "...", got ${to_text_short(v)}`)
}

export function Value__as_asset(v: Value): string {
	if (v instanceof AssetId) return v.id
	if (typeof v === 'string') return v
	throw new V.VError(`expected @asset("id"), got ${to_text_short(v)}`)
}

export function Value__as_number_list(v: Value): number[] {
	if (Array.isArray(v)) return v.map(Value__as_f64)
	throw new V.VError(`expected a number array [...], got ${to_text_short(v)}`)
}

export function Value__as_numbers(v: Value, n: number): number[] {
	const out = Value__as_number_list(v)
	if (out.length !== n) throw new V.VError(`expected an array of ${n} numbers, got ${out.length} elements`)
	return out
}

export function Value__as_vec2(v: Value): core.Vec2 {
	const n = Value__as_numbers(v, 2)
	return core.vec2(n[0], n[1])
}

export function Value__as_color(v: Value): core.Color {
	const n = Value__as_number_list(v)
	if (n.length === 3) return core.rgba(V.u8(n[0]), V.u8(n[1]), V.u8(n[2]), 255)
	if (n.length !== 4) throw new V.VError('a color needs [r, g, b] or [r, g, b, a]')
	return core.rgba(V.u8(n[0]), V.u8(n[1]), V.u8(n[2]), V.u8(n[3]))
}

export function vec2_value(p: core.Vec2): Value {
	return [p.x, p.y]
}

export function color_value(c: core.Color): Value {
	return [c.r, c.g, c.b, c.a]
}

export function Value__to_text(v: Value): string {
	if (v instanceof AssetId) return `@asset("${v.id}")`
	if (typeof v === 'boolean') return v ? 'true' : 'false'
	if (typeof v === 'number') return fmt_num(v)
	if (typeof v === 'string') return '"' + v.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"'
	return '[' + v.map(Value__to_text).join(', ') + ']'
}

export function Value__type_name(v: Value): string {
	if (v instanceof AssetId) return 'serialize.AssetId'
	if (typeof v === 'boolean') return 'bool'
	if (typeof v === 'number') return 'f64'
	if (typeof v === 'string') return 'string'
	return '[]serialize.Value'
}

function fmt_num(x: number): string {
	if (Number.isInteger(x) && Math.abs(x) < 1e15) return String(x)
	return x.toFixed(4).replace(/0+$/, '').replace(/\.$/, '')
}

// ---------- Parser (serialize/parser.v) ----------

export class ComponentDesc {
	static __vname = 'serialize.ComponentDesc'
	type_name = ''
	props = new Map<string, Value>()
	line = 0
}

export class NodeDesc {
	static __vname = 'serialize.NodeDesc'
	name = ''
	from = ''
	props = new Map<string, Value>()
	components: ComponentDesc[] = []
	children: NodeDesc[] = []
	line = 0
}

type TokKind = 'ident' | 'str' | 'num' | 'lbrace' | 'rbrace' | 'lbrack' | 'rbrack' | 'comma' | 'eq' | 'at' | 'lparen' | 'rparen' | 'eof'

interface Token {
	kind: TokKind
	text: string
	line: number
}

class Parser {
	file: string
	toks: Token[]
	pos = 0
	constructor(file: string, toks: Token[]) {
		this.file = file
		this.toks = toks
	}

	parse_node(): NodeDesc {
		const kw = this.next()
		if (kw.kind !== 'ident' || kw.text !== 'node') throw this.err_at(kw, `expected keyword \`node\`, got "${kw.text}"`)
		const name_tok = this.next()
		if (name_tok.kind !== 'ident' && name_tok.kind !== 'str') throw this.err_at(name_tok, 'expected a node name after `node`')
		const n = new NodeDesc()
		n.name = name_tok.text
		n.line = kw.line
		if (this.peek().kind === 'ident' && this.peek().text === 'from') {
			this.next()
			const v = this.parse_value()
			try {
				n.from = Value__as_asset(v)
			} catch {
				throw this.err('expected @asset("id") after `from`')
			}
		}
		this.expect('lbrace', '{')
		for (;;) {
			const t = this.peek()
			if (t.kind === 'rbrace') {
				this.next()
				break
			}
			if (t.kind === 'eof') throw this.err_at(t, `missing \`}\` closing node "${n.name}" (opened on line ${n.line})`)
			if (t.kind === 'ident' && t.text === 'node') {
				n.children.push(this.parse_node())
				continue
			}
			if (t.kind !== 'ident') throw this.err_at(t, `unexpected "${t.text}"`)
			this.next()
			const after = this.peek()
			if (after.kind === 'eq') {
				this.next()
				n.props.set(t.text, this.parse_value())
			} else if (after.kind === 'lbrace') {
				n.components.push(this.parse_component(t))
			} else {
				throw this.err_at(after, `expected \`=\` (property) or \`{\` (component) after "${t.text}"`)
			}
		}
		return n
	}

	parse_component(name: Token): ComponentDesc {
		this.expect('lbrace', '{')
		const c = new ComponentDesc()
		c.type_name = name.text
		c.line = name.line
		for (;;) {
			const t = this.next()
			if (t.kind === 'rbrace') break
			if (t.kind !== 'ident') throw this.err_at(t, `expected a field name in component ${c.type_name}, got "${t.text}"`)
			this.expect('eq', '=')
			c.props.set(t.text, this.parse_value())
		}
		return c
	}

	parse_value(): Value {
		const t = this.next()
		switch (t.kind) {
			case 'num':
				return Number(t.text)
			case 'str':
				return t.text
			case 'ident':
				if (t.text === 'true') return true
				if (t.text === 'false') return false
				throw this.err_at(t, `invalid value "${t.text}" (strings must be enclosed in "...")`)
			case 'lbrack': {
				const arr: Value[] = []
				if (this.peek().kind === 'rbrack') {
					this.next()
					return arr
				}
				for (;;) {
					arr.push(this.parse_value())
					const sep = this.next()
					if (sep.kind === 'rbrack') break
					if (sep.kind !== 'comma') throw this.err_at(sep, 'expected `,` or `]` in array')
				}
				return arr
			}
			case 'at': {
				const fn_name = this.next()
				if (fn_name.text !== 'asset') throw this.err_at(fn_name, 'only @asset("...") is supported')
				this.expect('lparen', '(')
				const s = this.next()
				if (s.kind !== 'str') throw this.err_at(s, '@asset expects a string')
				this.expect('rparen', ')')
				return new AssetId(s.text)
			}
		}
		throw this.err_at(t, `expected a value, got "${t.text}"`)
	}

	peek(): Token {
		return this.toks[this.pos]
	}
	next(): Token {
		const t = this.toks[this.pos]
		if (this.pos < this.toks.length - 1) this.pos++
		return t
	}
	expect(k: TokKind, what: string) {
		const t = this.next()
		if (t.kind !== k) throw this.err_at(t, `expected \`${what}\`, got "${t.text}"`)
	}
	err(msg: string): V.VError {
		return new V.VError(`${this.file}:${this.toks[this.pos].line}: ${msg}`)
	}
	err_at(t: Token, msg: string): V.VError {
		return new V.VError(`${this.file}:${t.line}: ${msg}`)
	}
}

export function parse(src: string, file: string): NodeDesc {
	const p = new Parser(file, tokenize(src, file))
	const root = p.parse_node()
	if (p.peek().kind !== 'eof') throw p.err('only one root node is allowed per file')
	return root
}

export function parse_value_text(src: string): Value {
	const p = new Parser('value', tokenize(src, 'value'))
	const v = p.parse_value()
	if (p.peek().kind !== 'eof') throw p.err(`unexpected "${p.peek().text}" after the value`)
	return v
}

const singles: Record<string, TokKind> = {
	'{': 'lbrace',
	'}': 'rbrace',
	'[': 'lbrack',
	']': 'rbrack',
	',': 'comma',
	'=': 'eq',
	'@': 'at',
	'(': 'lparen',
	')': 'rparen',
}

function is_digit(c: string): boolean {
	return c >= '0' && c <= '9'
}

function is_letter(c: string): boolean {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

function tokenize(src: string, file: string): Token[] {
	const toks: Token[] = []
	let i = 0
	let line = 1
	while (i < src.length) {
		const c = src[i]
		if (c === '\n') {
			line++
			i++
			continue
		}
		if (c === ' ' || c === '\t' || c === '\r' || c === ';') {
			i++
			continue
		}
		if (c === '#') {
			while (i < src.length && src[i] !== '\n') i++
			continue
		}
		const single = singles[c]
		if (single) {
			toks.push({ kind: single, text: c, line })
			i++
			continue
		}
		if (c === '"') {
			i++
			let s = ''
			while (i < src.length && src[i] !== '"') {
				if (src[i] === '\\' && i + 1 < src.length) {
					i++
					s += src[i] === 'n' ? '\n' : src[i] === 't' ? '\t' : src[i]
				} else {
					if (src[i] === '\n') line++
					s += src[i]
				}
				i++
			}
			if (i >= src.length) throw new V.VError(`${file}:${line}: unterminated string \`"\``)
			i++
			toks.push({ kind: 'str', text: s, line })
			continue
		}
		if (is_digit(c) || c === '-' || c === '+' || c === '.') {
			const start = i
			i++
			while (i < src.length && (is_digit(src[i]) || '.eE-+'.includes(src[i]))) i++
			toks.push({ kind: 'num', text: src.slice(start, i), line })
			continue
		}
		if (is_letter(c) || c === '_') {
			const start = i
			while (i < src.length && (is_letter(src[i]) || is_digit(src[i]) || src[i] === '_')) i++
			toks.push({ kind: 'ident', text: src.slice(start, i), line })
			continue
		}
		throw new V.VError(`${file}:${line}: invalid character "${c}"`)
	}
	toks.push({ kind: 'eof', text: '<end of file>', line })
	return toks
}

// ---------- Reflection (serialize/reflect.v) ----------

const asset_classes: Record<string, V.TypeDesc> = {
	texture: assets.Texture,
	scene: assets.SceneAsset,
	audio: assets.AudioClip,
	text: assets.TextAsset,
	font: assets.Font,
}

// fields_of: the serializable fields of a component class (see core.FieldSpec).
export function fields_of(t: V.TypeDesc): core.FieldSpec[] {
	const f = (t as any).__fields
	if (!Array.isArray(f)) throw new V.VError(`${V.type_name(t)} does not describe its fields (missing static __fields)`)
	return f
}

export function set_fields(t: V.TypeDesc, obj: any, props: Map<string, Value>) {
	const used = new Set<string>()
	for (const field of fields_of(t)) {
		const v = props.get(field.name)
		if (v === undefined) continue
		used.add(field.name)
		switch (field.type) {
			case 'f32':
			case 'f64':
				obj[field.name] = Value__as_f64(v)
				break
			case 'int':
				obj[field.name] = Math.trunc(Value__as_f64(v))
				break
			case 'bool':
				obj[field.name] = Value__as_bool(v)
				break
			case 'string': {
				const s = Value__as_string(v)
				const allowed = field.choices ?? []
				if (allowed.length > 0 && !allowed.includes(s)) {
					throw new V.VError(`${core.short_type_name(V.type_name(t))}.${field.name} must be one of ${allowed.join(' | ')}, not "${s}"`)
				}
				obj[field.name] = s
				break
			}
			case '[]int':
				obj[field.name] = Value__as_number_list(v).map((x) => Math.trunc(x))
				break
			case 'Vec2':
				obj[field.name] = Value__as_vec2(v)
				break
			case 'Color':
				obj[field.name] = Value__as_color(v)
				break
			default:
				if (field.type.startsWith('asset:')) {
					obj[field.name] = new assets.AssetRef(Value__as_asset(v), asset_classes[field.type.slice(6)] ?? null)
				} else {
					used.delete(field.name)
				}
		}
	}
	for (const k of props.keys()) {
		if (!used.has(k)) throw new V.VError(`${core.short_type_name(V.type_name(t))} has no serializable field "${k}"`)
	}
}

export function dump_fields(t: V.TypeDesc, obj: any): Map<string, Value> {
	const out = new Map<string, Value>()
	for (const field of fields_of(t)) {
		const x = obj[field.name]
		switch (field.type) {
			case 'f32':
			case 'f64':
			case 'int':
			case 'bool':
			case 'string':
				out.set(field.name, x)
				break
			case '[]int':
				out.set(field.name, (x as number[]).slice())
				break
			case 'Vec2':
				out.set(field.name, vec2_value(x))
				break
			case 'Color':
				out.set(field.name, color_value(x))
				break
			default:
				if (field.type.startsWith('asset:')) out.set(field.name, new AssetId(x.id))
		}
	}
	return out
}

export class FieldInfo {
	static __vname = 'serialize.FieldInfo'
	name = ''
	type_name = ''
	asset_kind: assets.AssetKind = 'unknown'
	is_list = false
	choices: string[] = []
}

export function describe_fields(t: V.TypeDesc): FieldInfo[] {
	return fields_of(t).map((f) => {
		const info = new FieldInfo()
		info.name = f.name
		info.type_name = f.type
		info.asset_kind = f.type.startsWith('asset:') ? assets.kind_from_str(f.type.slice(6)) : 'unknown'
		info.is_list = f.type === '[]int'
		info.choices = f.choices ?? []
		return info
	})
}

// ---------- Registry (serialize/registry.v) ----------

export class ComponentType {
	static __vname = 'serialize.ComponentType'
	name = ''
	create: () => core.IComponent = () => {
		throw new V.VError('no constructor')
	}
	apply: (c: core.IComponent, props: Map<string, Value>) => void = () => {}
	dump: (c: core.IComponent) => Map<string, Value> = () => new Map()
	fields: FieldInfo[] = []
}

export class Registry {
	static __vname = 'serialize.Registry'
	types = new Map<string, ComponentType>()

	register(t: V.TypeDesc) {
		const cls = t as unknown as new () => core.IComponent
		const name = core.short_type_name(V.type_name(t))
		fields_of(t) // fail early when the class has no field list
		const ct = new ComponentType()
		ct.name = name
		ct.create = () => new cls()
		ct.apply = (c, props) => {
			if (!(c instanceof cls)) throw new V.VError(`component is not of type ${V.type_name(t)}`)
			set_fields(t, c, props)
		}
		ct.dump = (c) => (c instanceof cls ? dump_fields(t, c) : new Map())
		ct.fields = describe_fields(t)
		this.types.set(name, ct)
	}

	get(name: string): ComponentType | null {
		return this.types.get(name) ?? null
	}

	names(): string[] {
		return [...this.types.keys()].sort()
	}
}

export function new_registry(): Registry {
	return new Registry()
}

// ---------- Loader (serialize/loader.v) ----------

interface CachedDesc {
	hash: number
	desc: NodeDesc
}

export class SceneLoader {
	static __vname = 'serialize.SceneLoader'
	registry: Registry
	db: assets.AssetDatabase
	cache = new Map<string, CachedDesc>()
	stack: string[] = []

	constructor(registry: Registry, db: assets.AssetDatabase) {
		this.registry = registry
		this.db = db
	}

	load_scene(key: string): core.Scene {
		const root = this.instantiate(key)
		root.prefab_id = ''
		return this.new_scene(root)
	}

	new_scene(root: core.Node): core.Scene {
		const scene = core.Scene.new(root.name)
		scene.assets = this.db
		scene.instantiate_fn = (k: string) => this.instantiate(k)
		scene.set_root(root)
		return scene
	}

	load_document(key: string): core.Node {
		const id = this.db.resolve(key)
		if (id === null) throw new V.VError(`scene "${key}" not found`)
		this.stack.push(id)
		try {
			const desc = this.parse_asset(id)
			return this.build(desc, this.db.path_of(id) ?? id)
		} finally {
			this.stack.pop()
		}
	}

	instantiate_source(src: string, file: string): core.Node {
		this.stack.push(this.db.id_of(file) ?? file)
		try {
			return this.build(parse(src, file), file)
		} finally {
			this.stack.pop()
		}
	}

	instantiate(key: string): core.Node {
		const id = this.db.resolve(key)
		if (id === null) throw new V.VError(`prefab "${key}" not found`)
		if (this.stack.includes(id)) {
			const chain = this.stack.map((x) => this.db.path_of(x) ?? x)
			throw new V.VError(`circular prefab nesting: ${chain.join(' -> ')} -> ${this.db.path_of(id) ?? id}`)
		}
		this.stack.push(id)
		try {
			const desc = this.parse_asset(id)
			const n = this.build(desc, this.db.path_of(id) ?? id)
			n.prefab_id = id
			return n
		} finally {
			this.stack.pop()
		}
	}

	parse_asset(id: string): NodeDesc {
		const e = this.db.entry(id)
		if (e === null) throw new V.VError(`asset ${id} not found`)
		const cached = this.cache.get(id)
		if (cached && cached.hash === e.hash) return cached.desc
		const sa = this.db.load<assets.SceneAsset>(assets.SceneAsset, id)
		const src = sa.source
		this.db.release(id)
		const desc = parse(src, e.path)
		this.cache.set(id, { hash: e.hash, desc })
		return desc
	}

	build(desc: NodeDesc, file: string): core.Node {
		let n: core.Node
		if (desc.from !== '') {
			try {
				n = this.instantiate(desc.from)
			} catch (err) {
				throw new V.VError(`${file}:${desc.line}: ${V.as_error(err).message}`)
			}
			n.name = desc.name
		} else {
			n = core.Node.new(desc.name)
		}
		this.apply_desc(n, desc, file)
		return n
	}

	apply_desc(n: core.Node, desc: NodeDesc, file: string) {
		try {
			apply_node_props(n, desc.props)
		} catch (err) {
			throw new V.VError(`${file}:${desc.line}: ${V.as_error(err).message}`)
		}
		for (const cd of desc.components) {
			const t = this.registry.get(cd.type_name)
			if (t === null) {
				throw new V.VError(`${file}:${cd.line}: component "${cd.type_name}" is not registered (registered: ${this.registry.names().join(', ')})`)
			}
			const existing = n.component_by_type_name(cd.type_name)
			try {
				if (existing !== null) {
					t.apply(existing, cd.props)
				} else {
					const c = t.create()
					t.apply(c, cd.props)
					n.add_component_dyn(c)
				}
			} catch (err) {
				throw new V.VError(`${file}:${cd.line}: ${V.as_error(err).message}`)
			}
		}
		for (const cdesc of desc.children) {
			if (cdesc.from === '') {
				const existing = direct_child(n, cdesc.name)
				if (existing !== null) {
					this.apply_desc(existing, cdesc, file)
					continue
				}
			}
			n.add_child(this.build(cdesc, file))
		}
	}
}

export function new_loader(registry: Registry, db: assets.AssetDatabase): SceneLoader {
	return new SceneLoader(registry, db)
}

export function direct_child(n: core.Node, name: string): core.Node | null {
	for (const c of n.children) if (c.name === name) return c
	return null
}

export function apply_node_props(n: core.Node, props: Map<string, Value>) {
	for (const [k, v] of props) {
		switch (k) {
			case 'position':
				n.position = Value__as_vec2(v)
				break
			case 'rotation':
				n.rotation = Value__as_f64(v)
				break
			case 'scale':
				n.scale = Value__as_vec2(v)
				break
			case 'active':
				n.active = Value__as_bool(v)
				break
			case 'z_index':
				n.z_index = Math.trunc(Value__as_f64(v))
				break
			case 'y_sort':
				n.y_sort = Value__as_bool(v)
				break
			case 'unscaled_time':
				n.unscaled_time = Value__as_bool(v)
				break
			case 'persistent':
				n.persistent = Value__as_bool(v)
				break
			default:
				throw new V.VError(`node has no property "${k}" (only position, rotation, scale, active, z_index, y_sort, unscaled_time, persistent)`)
		}
	}
}
