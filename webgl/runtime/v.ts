// V language support for code transpiled by tools/v2js (and used by the runtime itself).
//
// How V values map to JavaScript:
//   numbers (all int and float types)  number          (int `/` truncates: idiv; casts wrap: u8(), u16(), ...)
//   string                             string          (methods in S; `len` is the UTF-16 length)
//   []T                                Array           (methods in A)
//   map[K]V                            Map             (helpers in M)
//   struct                             class instance  (value structs are cloned where V copies them: clone())
//   enum                               the field name as a string ('quad_out'); @[flag] enums are numbers
//   ?T                                 the value, or null for `none`
//   !T                                 the value; errors are thrown as VError
//   sum type / interface               the value itself (`is` checks: is_type)
//   fn                                 function (closures capture by value, like V)

// ---------- Errors, options, panics ----------

// VError — a V error (`error('...')`, `return error_with_code(...)`), thrown by `!T` functions.
export class VError extends Error {
	vcode: number
	constructor(message: string, code = 0) {
		super(message)
		this.vcode = code
	}
	msg(): string {
		return this.message
	}
	code(): number {
		return this.vcode
	}
	str(): string {
		return this.message
	}
	override toString(): string {
		return this.message
	}
}

export function error(message: string): VError {
	return new VError(message)
}

export function error_with_code(message: string, code: number): VError {
	return new VError(message, code)
}

// as_error turns anything caught in an `or { }` block into a VError (so `err.msg()` works); JavaScript errors
// (bugs, not V errors) are re-thrown so they are not silently swallowed by game code.
export function as_error(e: unknown): VError {
	if (e instanceof VError) return e
	throw e
}

// VPanic — `panic()`: stops the game (the app shows it on the page).
export class VPanic extends Error {}

export function panic(message: unknown): never {
	throw new VPanic(typeof message === 'string' ? message : str(message))
}

// VExit — `exit(code)`.
export class VExit extends Error {
	status: number
	constructor(status: number) {
		super(`exit(${status})`)
		this.status = status
	}
}

export function exit(status: number): never {
	throw new VExit(status)
}

// unwrap returns an option's value, or throws (`opt()!` used on an option, or `?` outside an option function).
export function unwrap<T>(x: T | null | undefined, what = 'none'): T {
	if (x === null || x === undefined) throw new VError(what)
	return x
}

export function is_none(x: unknown): boolean {
	return x === null || x === undefined
}

// ---------- Numbers ----------

export function idiv(a: number, b: number): number {
	if (b === 0) panic('division by zero')
	return Math.trunc(a / b)
}

export function imod(a: number, b: number): number {
	if (b === 0) panic('modulo by zero')
	return a % b
}

export const int = (x: number): number => (Number.isFinite(x) ? Math.trunc(x) | 0 : 0)
export const i8 = (x: number): number => (Math.trunc(x) << 24) >> 24
export const i16 = (x: number): number => (Math.trunc(x) << 16) >> 16
export const i64 = (x: number): number => (Number.isFinite(x) ? Math.trunc(x) : 0)
export const u8 = (x: number): number => Math.trunc(x) & 0xff
export const u16 = (x: number): number => Math.trunc(x) & 0xffff
export const u32 = (x: number): number => Math.trunc(x) >>> 0
export const u64 = (x: number): number => (Number.isFinite(x) ? Math.trunc(x) : 0)
export const f32 = (x: number): number => x
export const f64 = (x: number): number => x

// ---------- Strings ----------

// fstr formats a float like V does: always with a decimal point (`2.0`, `0.5`, `1e+21`).
export function fstr(x: number): string {
	if (Number.isNaN(x)) return 'nan'
	if (x === Infinity) return '+inf'
	if (x === -Infinity) return '-inf'
	const s = String(x)
	return Number.isInteger(x) && !s.includes('e') ? s + '.0' : s
}

// str converts any value to text, as V's `.str()` / string interpolation do.
export function str(x: unknown, float = false): string {
	return to_str(x, float, 0, true)
}

function to_str(x: unknown, float: boolean, depth: number, top: boolean): string {
	if (x === null || x === undefined) return 'none'
	switch (typeof x) {
		case 'string':
			return top ? x : `'${x}'`
		case 'number':
			return float ? fstr(x) : String(x)
		case 'boolean':
			return x ? 'true' : 'false'
		case 'function':
			return 'fn ()'
		case 'bigint':
			return String(x)
	}
	if (depth > 4) return '...'
	if (Array.isArray(x)) {
		return '[' + x.map((e) => to_str(e, float, depth + 1, false)).join(', ') + ']'
	}
	if (x instanceof Map) {
		const parts: string[] = []
		for (const [k, v] of x) parts.push(`${to_str(k, false, depth + 1, false)}: ${to_str(v, float, depth + 1, false)}`)
		return '{' + parts.join(', ') + '}'
	}
	const o = x as any
	if (typeof o.str === 'function') return o.str()
	if (o instanceof Error) return o.message
	const name = type_name_of(o)
	const pad = '    '.repeat(depth + 1)
	const lines: string[] = []
	for (const k of Object.keys(o)) {
		const v = o[k]
		if (typeof v === 'function') continue
		lines.push(`${pad}${k}: ${to_str(v, false, depth + 1, false)}`)
	}
	return `${name}{\n${lines.join('\n')}\n${'    '.repeat(depth)}}`
}

// fmt formats one interpolated value with a format spec, like `${x:.2f}`, `${n:5}`, `${n:-5}`, `${n:05}`, `${n:x}`.
export function fmt(x: unknown, kind: string, width: number, precision: number, plus: boolean, zero_fill: boolean, float = false): string {
	let s: string
	if (typeof x === 'number') {
		switch (kind) {
			case 'f':
			case 'F':
				s = x.toFixed(precision >= 0 && precision !== 987698 ? precision : 6)
				break
			case 'e':
			case 'E':
				s = x.toExponential(precision >= 0 && precision !== 987698 ? precision : 6)
				if (kind === 'E') s = s.toUpperCase()
				break
			case 'g':
			case 'G':
				s = precision >= 0 && precision !== 987698 ? String(Number(x.toPrecision(precision || 1))) : String(x)
				break
			case 'x':
				s = (x < 0 ? x >>> 0 : x).toString(16)
				break
			case 'X':
				s = (x < 0 ? x >>> 0 : x).toString(16).toUpperCase()
				break
			case 'o':
				s = x.toString(8)
				break
			case 'b':
				s = (x < 0 ? x >>> 0 : x).toString(2)
				break
			case 'c':
				s = String.fromCodePoint(x)
				break
			default:
				s = float && precision >= 0 && precision !== 987698 ? x.toFixed(precision) : float ? fstr(x) : String(x)
		}
		if (plus && x >= 0 && kind !== 'x' && kind !== 'X') s = '+' + s
	} else {
		s = str(x, float)
	}
	if (width !== 0) {
		const w = Math.abs(width)
		if (s.length < w) {
			if (width < 0) s = s.padEnd(w, ' ')
			else if (zero_fill && typeof x === 'number') {
				const neg = s.startsWith('-') || s.startsWith('+')
				s = neg ? s[0] + s.slice(1).padStart(w - 1, '0') : s.padStart(w, '0')
			} else s = s.padStart(w, ' ')
		}
	}
	return s
}

const ws = new Set([32, 9, 10, 11, 12, 13])

function trim_set(s: string, cutset: string, left: boolean, right: boolean): string {
	let a = 0
	let b = s.length
	if (left) while (a < b && cutset.includes(s[a])) a++
	if (right) while (b > a && cutset.includes(s[b - 1])) b--
	return s.slice(a, b)
}

function parse_int_prefix(s: string): number {
	const t = s.trim().replace(/_/g, '')
	const m = /^([+-]?)(0x[0-9a-f]+|0b[01]+|0o[0-7]+|\d+)/i.exec(t)
	if (!m) return 0
	const sign = m[1] === '-' ? -1 : 1
	const body = m[2].toLowerCase()
	let v: number
	if (body.startsWith('0x')) v = parseInt(body.slice(2), 16)
	else if (body.startsWith('0b')) v = parseInt(body.slice(2), 2)
	else if (body.startsWith('0o')) v = parseInt(body.slice(2), 8)
	else v = parseInt(body, 10)
	return sign * v
}

// S — methods of V strings: `s.trim_space()` is transpiled to `S.trim_space(s)`.
export const S = {
	str: (s: string) => s,
	clone: (s: string) => s,
	contains: (s: string, sub: string) => s.includes(sub),
	contains_any: (s: string, chars: string) => [...chars].some((c) => s.includes(c)),
	contains_u8: (s: string, c: number) => s.includes(String.fromCharCode(c)),
	contains_only: (s: string, chars: string) => [...s].every((c) => chars.includes(c)),
	starts_with: (s: string, p: string) => s.startsWith(p),
	ends_with: (s: string, p: string) => s.endsWith(p),
	index: (s: string, sub: string): number | null => {
		const i = s.indexOf(sub)
		return i < 0 ? null : i
	},
	index_after: (s: string, sub: string, start: number): number | null => {
		const i = s.indexOf(sub, Math.max(start, 0))
		return i < 0 ? null : i
	},
	index_u8: (s: string, c: number) => s.indexOf(String.fromCharCode(c)),
	last_index: (s: string, sub: string): number | null => {
		const i = s.lastIndexOf(sub)
		return i < 0 ? null : i
	},
	last_index_u8: (s: string, c: number) => s.lastIndexOf(String.fromCharCode(c)),
	index_any: (s: string, chars: string) => {
		for (let i = 0; i < s.length; i++) if (chars.includes(s[i])) return i
		return -1
	},
	count: (s: string, sub: string) => (sub === '' ? 0 : s.split(sub).length - 1),
	split: (s: string, sep: string) => (sep === '' ? [...s] : s.split(sep)),
	split_any: (s: string, chars: string) => {
		const out: string[] = []
		let cur = ''
		for (const c of s) {
			if (chars.includes(c)) {
				out.push(cur)
				cur = ''
			} else cur += c
		}
		out.push(cur)
		return out.filter((p, i) => p !== '' || i < out.length - 1 || out.length === 1).filter((p) => p !== '')
	},
	split_nth: (s: string, sep: string, n: number) => {
		const parts = s.split(sep)
		if (n <= 0 || parts.length <= n) return parts
		return [...parts.slice(0, n - 1), parts.slice(n - 1).join(sep)]
	},
	split_into_lines: (s: string) => {
		if (s === '') return []
		const lines = s.split(/\r\n|\n|\r/)
		if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
		return lines
	},
	fields: (s: string) => s.split(/\s+/).filter((p) => p !== ''),
	trim: (s: string, cutset: string) => trim_set(s, cutset, true, true),
	trim_left: (s: string, cutset: string) => trim_set(s, cutset, true, false),
	trim_right: (s: string, cutset: string) => trim_set(s, cutset, false, true),
	trim_space: (s: string) => s.replace(/^[ \t\n\v\f\r]+|[ \t\n\v\f\r]+$/g, ''),
	trim_space_left: (s: string) => s.replace(/^[ \t\n\v\f\r]+/, ''),
	trim_space_right: (s: string) => s.replace(/[ \t\n\v\f\r]+$/, ''),
	trim_string_left: (s: string, p: string) => (p !== '' && s.startsWith(p) ? s.slice(p.length) : s),
	trim_string_right: (s: string, p: string) => (p !== '' && s.endsWith(p) ? s.slice(0, s.length - p.length) : s),
	trim_prefix: (s: string, p: string) => (p !== '' && s.startsWith(p) ? s.slice(p.length) : s),
	trim_suffix: (s: string, p: string) => (p !== '' && s.endsWith(p) ? s.slice(0, s.length - p.length) : s),
	to_upper: (s: string) => s.toUpperCase(),
	to_lower: (s: string) => s.toLowerCase(),
	to_upper_ascii: (s: string) => s.replace(/[a-z]/g, (c) => c.toUpperCase()),
	to_lower_ascii: (s: string) => s.replace(/[A-Z]/g, (c) => c.toLowerCase()),
	is_upper: (s: string) => s === s.toUpperCase() && s !== s.toLowerCase(),
	is_lower: (s: string) => s === s.toLowerCase() && s !== s.toUpperCase(),
	is_title: (s: string) => s.split(' ').every((w) => w === '' || w[0] === w[0].toUpperCase()),
	is_blank: (s: string) => s.trim() === '',
	capitalize: (s: string) => (s === '' ? s : s[0].toUpperCase() + s.slice(1)),
	uncapitalize: (s: string) => (s === '' ? s : s[0].toLowerCase() + s.slice(1)),
	title: (s: string) =>
		s
			.split(' ')
			.map((w) => (w === '' ? w : w[0].toUpperCase() + w.slice(1)))
			.join(' '),
	replace: (s: string, a: string, b: string) => (a === '' ? s : s.split(a).join(b)),
	replace_once: (s: string, a: string, b: string) => (a === '' ? s : s.replace(a, () => b)),
	replace_each: (s: string, pairs: string[]) => {
		let out = ''
		let i = 0
		outer: while (i < s.length) {
			for (let k = 0; k + 1 < pairs.length; k += 2) {
				const a = pairs[k]
				if (a !== '' && s.startsWith(a, i)) {
					out += pairs[k + 1]
					i += a.length
					continue outer
				}
			}
			out += s[i++]
		}
		return out
	},
	replace_char: (s: string, c: number, rep: number, n: number) => s.split(String.fromCharCode(c)).join(String.fromCharCode(rep).repeat(n)),
	repeat: (s: string, n: number) => (n > 0 ? s.repeat(n) : ''),
	reverse: (s: string) => [...s].reverse().join(''),
	int: (s: string) => int(parse_int_prefix(s)),
	i8: (s: string) => i8(parse_int_prefix(s)),
	i16: (s: string) => i16(parse_int_prefix(s)),
	i32: (s: string) => int(parse_int_prefix(s)),
	i64: (s: string) => parse_int_prefix(s),
	u8: (s: string) => u8(parse_int_prefix(s)),
	u16: (s: string) => u16(parse_int_prefix(s)),
	u32: (s: string) => u32(parse_int_prefix(s)),
	u64: (s: string) => Math.max(0, parse_int_prefix(s)),
	f32: (s: string) => {
		const v = parseFloat(s.trim().replace(/_/g, ''))
		return Number.isNaN(v) ? 0 : v
	},
	f64: (s: string) => {
		const v = parseFloat(s.trim().replace(/_/g, ''))
		return Number.isNaN(v) ? 0 : v
	},
	bool: (s: string) => s === 'true',
	runes: (s: string) => Array.from(s, (c) => c.codePointAt(0)!),
	bytes: (s: string) => Array.from(new TextEncoder().encode(s)),
	len_utf8: (s: string) => [...s].length,
	all_before: (s: string, sub: string) => {
		const i = s.indexOf(sub)
		return i < 0 ? s : s.slice(0, i)
	},
	all_before_last: (s: string, sub: string) => {
		const i = s.lastIndexOf(sub)
		return i < 0 ? s : s.slice(0, i)
	},
	all_after: (s: string, sub: string) => {
		const i = s.indexOf(sub)
		return i < 0 ? s : s.slice(i + sub.length)
	},
	all_after_last: (s: string, sub: string) => {
		const i = s.lastIndexOf(sub)
		return i < 0 ? s : s.slice(i + sub.length)
	},
	all_after_first: (s: string, sub: string) => {
		const i = s.indexOf(sub)
		return i < 0 ? s : s.slice(i + sub.length)
	},
	after: (s: string, sub: string) => {
		const i = s.lastIndexOf(sub)
		return i < 0 ? s : s.slice(i + sub.length)
	},
	before: (s: string, sub: string) => {
		const i = s.indexOf(sub)
		return i < 0 ? s : s.slice(0, i)
	},
	find_between: (s: string, a: string, b: string) => {
		const i = s.indexOf(a)
		if (i < 0) return ''
		const rest = s.slice(i + a.length)
		const j = rest.indexOf(b)
		return j < 0 ? '' : rest.slice(0, j)
	},
	substr: (s: string, a: number, b: number) => s.slice(a, b),
	substr_ni: (s: string, a: number, b: number) => s.slice(a < 0 ? s.length + a : a, b < 0 ? s.length + b : b),
	limit: (s: string, n: number) => [...s].slice(0, n).join(''),
	compare: (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0),
	equal_fold: (a: string, b: string) => a.toLowerCase() === b.toLowerCase(),
	hash: (s: string) => {
		let h = 0
		for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0
		return h
	},
	strip_margin: (s: string) =>
		s
			.split('\n')
			.map((l) => {
				const m = /^\s*\|/.exec(l)
				return m ? l.slice(m[0].length) : l
			})
			.join('\n'),
	is_int: (s: string) => /^[+-]?\d+$/.test(s.trim()),
	is_hex: (s: string) => /^0x[0-9a-f]+$/i.test(s),
	match_glob: (s: string, glob: string) =>
		new RegExp('^' + glob.replace(/[.+^${}()|\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.') + '$').test(s),
	utf32_code: (s: string) => s.codePointAt(0) ?? 0,
	at: (s: string, i: number) => s.charCodeAt(i),
	wrap: (s: string, width: number) => {
		const out: string[] = []
		let line = ''
		for (const w of s.split(' ')) {
			if (line !== '' && line.length + 1 + w.length > width) {
				out.push(line)
				line = w
			} else line = line === '' ? w : line + ' ' + w
		}
		out.push(line)
		return out.join('\n')
	},
	// `s[i]` of a string: the byte (here: the UTF-16 code unit)
	byte: (s: string, i: number) => {
		if (i < 0 || i >= s.length) panic(`index out of range (index: ${i}, len: ${s.length})`)
		return s.charCodeAt(i)
	},
}

// N — methods of V integers / runes / bytes (`n.str()`, `c.is_digit()`, `x.hex()`).
export const N = {
	str: (n: number) => String(n),
	hex: (n: number) => (n < 0 ? n >>> 0 : n).toString(16),
	hex_full: (n: number) => (n >>> 0).toString(16).padStart(8, '0'),
	ascii_str: (c: number) => String.fromCharCode(c),
	is_digit: (c: number) => c >= 48 && c <= 57,
	is_hex_digit: (c: number) => (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70),
	is_oct_digit: (c: number) => c >= 48 && c <= 55,
	is_bin_digit: (c: number) => c === 48 || c === 49,
	is_letter: (c: number) => (c >= 97 && c <= 122) || (c >= 65 && c <= 90),
	is_alnum: (c: number) => (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57),
	is_space: (c: number) => ws.has(c),
	is_capital: (c: number) => c >= 65 && c <= 90,
	is_upper: (c: number) => c >= 65 && c <= 90,
	is_lower: (c: number) => c >= 97 && c <= 122,
	to_upper: (c: number) => (c >= 97 && c <= 122 ? c - 32 : c),
	to_lower: (c: number) => (c >= 65 && c <= 90 ? c + 32 : c),
	repeat: (c: number, n: number) => String.fromCharCode(c).repeat(Math.max(n, 0)),
	str_escaped: (c: number) => JSON.stringify(String.fromCharCode(c)).slice(1, -1),
	min: (a: number, b: number) => Math.min(a, b),
	max: (a: number, b: number) => Math.max(a, b),
}

// R — methods of runes (code points).
export const R = {
	...N,
	str: (r: number) => String.fromCodePoint(r),
	bytes: (r: number) => Array.from(new TextEncoder().encode(String.fromCodePoint(r))),
	length_in_bytes: (r: number) => new TextEncoder().encode(String.fromCodePoint(r)).length,
	is_letter: (r: number) => /\p{L}/u.test(String.fromCodePoint(r)),
	is_space: (r: number) => /\s/u.test(String.fromCodePoint(r)),
	to_upper: (r: number) => String.fromCodePoint(r).toUpperCase().codePointAt(0)!,
	to_lower: (r: number) => String.fromCodePoint(r).toLowerCase().codePointAt(0)!,
}

// F — methods of V floats.
export const F = {
	str: (x: number) => fstr(x),
	strg: (x: number) => String(x),
	strsci: (x: number, digits: number) => x.toExponential(digits),
	eq_epsilon: (a: number, b: number) => Math.abs(a - b) <= 1e-6 * Math.max(1, Math.abs(a), Math.abs(b)),
	min: (a: number, b: number) => Math.min(a, b),
	max: (a: number, b: number) => Math.max(a, b),
}

// B — methods of bools.
export const B = {
	str: (b: boolean) => (b ? 'true' : 'false'),
}

// ---------- Arrays ----------

function check_index(a: unknown[], i: number) {
	if (i < 0 || i >= a.length) panic(`index out of range (index: ${i}, len: ${a.length})`)
}

// A — methods of V arrays: `a.delete(i)` is transpiled to `A.delete(a, i)`.
export const A = {
	clone: <T>(a: T[]) => a.map(clone),
	str: (a: unknown[]) => str(a),
	first: <T>(a: T[]) => {
		check_index(a, 0)
		return a[0]
	},
	last: <T>(a: T[]) => {
		check_index(a, a.length - 1)
		return a[a.length - 1]
	},
	pop: <T>(a: T[]) => {
		check_index(a, a.length - 1)
		return a.pop() as T
	},
	pop_left: <T>(a: T[]) => {
		check_index(a, 0)
		return a.shift() as T
	},
	delete: (a: unknown[], i: number) => {
		check_index(a, i)
		a.splice(i, 1)
	},
	delete_many: (a: unknown[], i: number, n: number) => {
		a.splice(i, n)
	},
	delete_last: (a: unknown[]) => {
		a.pop()
	},
	insert: <T>(a: T[], i: number, v: T | T[]) => {
		if (Array.isArray(v)) a.splice(i, 0, ...v)
		else a.splice(i, 0, v)
	},
	prepend: <T>(a: T[], v: T | T[]) => {
		if (Array.isArray(v)) a.unshift(...v)
		else a.unshift(v)
	},
	clear: (a: unknown[]) => {
		a.length = 0
	},
	reset: (a: unknown[]) => {
		a.fill(0)
	},
	trim: (a: unknown[], n: number) => {
		if (n < a.length) a.length = Math.max(n, 0)
	},
	drop: (a: unknown[], n: number) => {
		a.splice(0, Math.min(n, a.length))
	},
	index: <T>(a: T[], v: T) => a.findIndex((x) => eq(x, v)),
	last_index: <T>(a: T[], v: T) => {
		for (let i = a.length - 1; i >= 0; i--) if (eq(a[i], v)) return i
		return -1
	},
	contains: <T>(a: T[], v: T) => a.some((x) => eq(x, v)),
	join: (a: string[], sep: string) => a.join(sep),
	reverse: <T>(a: T[]) => a.slice().reverse(),
	reverse_in_place: (a: unknown[]) => {
		a.reverse()
	},
	bytestr: (a: number[]) => new TextDecoder().decode(new Uint8Array(a)),
	string: (a: number[]) => String.fromCodePoint(...a),
	hex: (a: number[]) => a.map((b) => b.toString(16).padStart(2, '0')).join(''),
	repeat: <T>(a: T[], n: number) => {
		const out: T[] = []
		for (let i = 0; i < n; i++) for (const x of a) out.push(clone(x))
		return out
	},
	// sort with a comparator returning true when `a` goes before `b` (V's `a.sort(a.x < b.x)`)
	sort: <T>(a: T[], less?: (x: T, y: T) => boolean) => {
		if (less) a.sort((x, y) => (less(x, y) ? -1 : less(y, x) ? 1 : 0))
		else a.sort((x: any, y: any) => (x < y ? -1 : x > y ? 1 : 0))
	},
	sorted: <T>(a: T[], less?: (x: T, y: T) => boolean) => {
		const b = a.slice()
		A.sort(b, less)
		return b
	},
	sort_with_compare: <T>(a: T[], cmp: (x: T, y: T) => number) => {
		a.sort(cmp)
	},
	sorted_with_compare: <T>(a: T[], cmp: (x: T, y: T) => number) => a.slice().sort(cmp),
	filter: <T>(a: T[], f: (x: T) => boolean) => a.filter((x) => f(x)),
	map: <T, U>(a: T[], f: (x: T) => U) => a.map((x) => f(x)),
	any: <T>(a: T[], f: (x: T) => boolean) => a.some((x) => f(x)),
	all: <T>(a: T[], f: (x: T) => boolean) => a.every((x) => f(x)),
	count: <T>(a: T[], f: (x: T) => boolean) => a.reduce((n, x) => (f(x) ? n + 1 : n), 0),
	slice: <T>(a: T[], lo: number, hi: number) => {
		if (lo < 0 || hi > a.length || lo > hi) panic(`slice out of range [${lo}..${hi}] (len: ${a.length})`)
		return a.slice(lo, hi)
	},
	ensure_cap: (_a: unknown[], _n: number) => {},
	grow_len: (a: number[], n: number) => {
		for (let i = 0; i < n; i++) a.push(0)
	},
	get: <T>(a: T[], i: number) => {
		check_index(a, i)
		return a[i]
	},
	wait: () => {},
}

// make_array builds `[]T{len: n, init: expr}`: `init` receives the index (V's `index`).
export function make_array<T>(len: number, init: (index: number) => T): T[] {
	const out = new Array<T>(Math.max(len, 0))
	for (let i = 0; i < out.length; i++) out[i] = init(i)
	return out
}

// push appends a value or (when V appended an array: `a << b`) all of another array's values.
export function push<T>(a: T[], v: T | T[], is_array: boolean): T[] {
	if (is_array) for (const x of v as T[]) a.push(clone(x))
	else a.push(v as T)
	return a
}

// ---------- Maps ----------

// M — helpers for V maps (JavaScript Map).
export const M = {
	get: <K, V>(m: Map<K, V>, k: K, zero: () => V): V => {
		const v = m.get(k)
		return v === undefined ? zero() : v
	},
	// `m[k]` used as a place that is modified (`m[k] << x`, `m[k].f = 1`): creates the zero value first.
	entry: <K, V>(m: Map<K, V>, k: K, zero: () => V): V => {
		let v = m.get(k)
		if (v === undefined) {
			v = zero()
			m.set(k, v)
		}
		return v
	},
	opt: <K, V>(m: Map<K, V>, k: K): V | null => {
		const v = m.get(k)
		return v === undefined ? null : v
	},
	keys: <K, V>(m: Map<K, V>) => [...m.keys()],
	values: <K, V>(m: Map<K, V>) => [...m.values()],
	clone: <K, V>(m: Map<K, V>) => {
		const out = new Map<K, V>()
		for (const [k, v] of m) out.set(k, clone(v))
		return out
	},
	move: <K, V>(m: Map<K, V>) => {
		const out = new Map(m)
		m.clear()
		return out
	},
	delete: <K, V>(m: Map<K, V>, k: K) => {
		m.delete(k)
	},
	clear: <K, V>(m: Map<K, V>) => {
		m.clear()
	},
	str: (m: Map<unknown, unknown>) => str(m),
	from: <K, V>(pairs: [K, V][]) => new Map<K, V>(pairs),
}

// ---------- Structs ----------

// clone copies a value struct (V copies structs on assignment); objects without `clone` (references) are shared.
export function clone<T>(x: T): T {
	if (x !== null && typeof x === 'object' && typeof (x as any).clone === 'function') return (x as any).clone()
	return x
}

// make creates a struct with its default field values, then sets the given ones (`Foo{a: 1}`).
export function make<T>(cls: new () => T, fields: Partial<T>): T {
	const o = new cls()
	Object.assign(o as object, fields)
	return o
}

// assign_into copies a struct's fields into an existing one (`*p = value`).
export function assign_into<T extends object>(dst: T, src: T): T {
	for (const k of Object.keys(src)) (dst as any)[k] = clone((src as any)[k])
	return dst
}

// eq compares two values like V's `==`: numbers/strings directly, arrays/maps/value structs field by field.
export function eq(a: unknown, b: unknown): boolean {
	if (a === b) return true
	if (a === null || b === null || a === undefined || b === undefined) return false
	if (typeof a !== 'object' || typeof b !== 'object') return false
	if (Array.isArray(a)) {
		if (!Array.isArray(b) || a.length !== b.length) return false
		for (let i = 0; i < a.length; i++) if (!eq(a[i], b[i])) return false
		return true
	}
	if (a instanceof Map) {
		if (!(b instanceof Map) || a.size !== b.size) return false
		for (const [k, v] of a) if (!b.has(k) || !eq(v, b.get(k))) return false
		return true
	}
	const oa = a as any
	if (typeof oa.op_eq === 'function') return oa.op_eq(b)
	if (Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false
	// only value structs (with clone) are compared field by field; references compare by identity
	if (typeof oa.clone !== 'function') return false
	for (const k of Object.keys(oa)) if (!eq(oa[k], (b as any)[k])) return false
	return true
}

// ---------- Types ----------

// IfaceDesc — a V interface as a runtime type: a value "is" it when it has every listed method/field.
export class IfaceDesc {
	name: string
	members: string[]
	constructor(name: string, members: string[]) {
		this.name = name
		this.members = members
	}
}

export function iface(name: string, members: string[]): IfaceDesc {
	return new IfaceDesc(name, members)
}

// TypeDesc — what transpiled code passes for a type argument or `is` check: a class, an interface, or the name
// of a primitive type ('int', 'f32', 'string', 'bool', '[]int', 'map', ...).
export type TypeDesc = Function | IfaceDesc | string

// is_type: V's `x is T` (sum types, interfaces, generics).
export function is_type(x: unknown, t: TypeDesc): boolean {
	if (x === null || x === undefined) return false
	if (typeof t === 'function') return x instanceof (t as any)
	if (t instanceof IfaceDesc) {
		const o = x as any
		return typeof o === 'object' && t.members.every((m) => m in o)
	}
	switch (t) {
		case 'string':
			return typeof x === 'string'
		case 'bool':
			return typeof x === 'boolean'
		case 'f32':
		case 'f64':
		case 'float_literal':
			return typeof x === 'number'
		case 'int':
		case 'i8':
		case 'i16':
		case 'i32':
		case 'i64':
		case 'u8':
		case 'u16':
		case 'u32':
		case 'u64':
		case 'rune':
		case 'isize':
		case 'usize':
		case 'int_literal':
			return typeof x === 'number' && Number.isInteger(x)
		case 'map':
			return x instanceof Map
		case 'fn':
			return typeof x === 'function'
	}
	if (t.startsWith('[]')) return Array.isArray(x)
	if (t.startsWith('map[')) return x instanceof Map
	return false
}

// type_name_of: the V type name of a value ('main.Player', 'core.Node', 'int', ...).
export function type_name_of(x: unknown): string {
	if (x === null || x === undefined) return 'none'
	switch (typeof x) {
		case 'string':
			return 'string'
		case 'number':
			return Number.isInteger(x) ? 'int' : 'f64'
		case 'boolean':
			return 'bool'
		case 'function':
			return 'fn'
	}
	if (Array.isArray(x)) return 'array'
	if (x instanceof Map) return 'map'
	const ctor = (x as any).constructor
	return type_name(ctor)
}

// type_name: the V name of a type descriptor.
export function type_name(t: TypeDesc): string {
	if (typeof t === 'string') return t
	if (t instanceof IfaceDesc) return t.name
	return (t as any).__vname ?? (t as any).name ?? '?'
}

// ---------- Output ----------

let print_buf = ''

export function print(s: unknown) {
	print_buf += typeof s === 'string' ? s : str(s)
	const nl = print_buf.lastIndexOf('\n')
	if (nl >= 0) {
		console.log(print_buf.slice(0, nl))
		print_buf = print_buf.slice(nl + 1)
	}
}

export function println(s: unknown) {
	if (print_buf !== '') {
		console.log(print_buf + (typeof s === 'string' ? s : str(s)))
		print_buf = ''
		return
	}
	console.log(typeof s === 'string' ? s : str(s))
}

export function eprint(s: unknown) {
	console.error(typeof s === 'string' ? s : str(s))
}

export function eprintln(s: unknown) {
	console.error(typeof s === 'string' ? s : str(s))
}

export function dump<T>(x: T, expr = ''): T {
	console.log(`[dump] ${expr}: ${str(x)}`)
	return x
}

// ---------- Misc ----------

// capture: V closures copy what they capture when they are created (`fn [x] () {}`).
export function capture<T>(x: T): T {
	return clone(x)
}

// defer helper: runs `body`, then the deferred functions in reverse order (V `defer { }`).
export function with_defers<T>(body: (defers: (() => void)[]) => T): T {
	const defers: (() => void)[] = []
	try {
		return body(defers)
	} finally {
		for (let i = defers.length - 1; i >= 0; i--) defers[i]()
	}
}

export function utf32_to_str(c: number): string {
	return String.fromCodePoint(c)
}

export function isnil(x: unknown): boolean {
	return x === null || x === undefined
}

export function assert_(ok: boolean, msg: string) {
	if (!ok) panic(`assertion failed: ${msg}`)
}

// ---------- More helpers used by transpiled code ----------

// bind: a method used as a value (`arr.map(obj.method)`), bound to its receiver.
export function bind(obj: any, name: string): any {
	const f = obj[name]
	return typeof f === 'function' ? f.bind(obj) : f
}

// update: `T{...base, field: value}` — a copy of `base` with some fields changed.
export function update<T extends object>(base: T, fields: Partial<T>): T {
	const o = typeof (base as any).clone === 'function' ? (base as any).clone() : Object.assign(Object.create(Object.getPrototypeOf(base)), base)
	return Object.assign(o, fields)
}

// mixin: a struct embedding more than one struct gets the methods of the others (the first is `extends`).
export function mixin(cls: any, embedded: any) {
	let proto = embedded.prototype
	while (proto && proto !== Object.prototype) {
		for (const k of Object.getOwnPropertyNames(proto)) {
			if (k === 'constructor' || k in cls.prototype) continue
			Object.defineProperty(cls.prototype, k, Object.getOwnPropertyDescriptor(proto, k)!)
		}
		proto = Object.getPrototypeOf(proto)
	}
}

// init_embed: the fields (with their defaults) of a second embedded struct.
export function init_embed(obj: any, embedded: any) {
	const tmp = new embedded()
	for (const k of Object.keys(tmp)) if (!(k in obj)) obj[k] = tmp[k]
}

// enum_from_int: `MyEnum(3)` — the field of an enum with that value.
export function enum_from_int(ints: Record<string, number>, n: number): string {
	for (const k of Object.keys(ints)) if (ints[k] === n) return k
	return String(n)
}

// zero: the zero value of a type argument (`T{}` in a generic function).
export function zero(t: TypeDesc): unknown {
	if (typeof t === 'function') return new (t as any)()
	if (t instanceof IfaceDesc) return null
	switch (t) {
		case 'string':
			return ''
		case 'bool':
			return false
		case 'map':
			return new Map()
	}
	if (t.startsWith('[]')) return []
	return 0
}

// copy: V's builtin `copy(mut dst, src)`.
export function copy<T>(dst: T[], src: T[]): number {
	const n = Math.min(dst.length, src.length)
	for (let i = 0; i < n; i++) dst[i] = src[i]
	return n
}

export const min_i8 = -128
export const max_i8 = 127
export const min_i16 = -32768
export const max_i16 = 32767
export const min_i32 = -2147483648
export const max_i32 = 2147483647
export const min_int = -2147483648
export const max_int = 2147483647
export const min_i64 = Number.MIN_SAFE_INTEGER
export const max_i64 = Number.MAX_SAFE_INTEGER
export const min_u8 = 0
export const max_u8 = 255
export const min_u16 = 0
export const max_u16 = 65535
export const min_u32 = 0
export const max_u32 = 4294967295
export const min_u64 = 0
export const max_u64 = 18446744073709551615
export const max_f32 = 3.4028234663852886e38
export const max_f64 = Number.MAX_VALUE

// f32str formats an f32 like V: the shortest decimal that reads back as the same 32-bit float
// (0.1 + 0.2 computed as f32 prints 0.3, not 0.30000000000000004), with a decimal point.
export function f32str(x: number): string {
	if (!Number.isFinite(x)) return fstr(x)
	const f = Math.fround(x)
	let s = String(f)
	for (let p = 1; p <= 9; p++) {
		const t = f.toPrecision(p)
		if (Math.fround(Number(t)) === f) {
			s = String(Number(t))
			break
		}
	}
	return s.includes('.') || s.includes('e') ? s : s + '.0'
}
