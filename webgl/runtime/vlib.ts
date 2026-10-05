// The parts of V's standard library that game code commonly uses, for the WebGL runtime. Generic V functions
// (math.abs[T], arrays.sum[T], ...) are called without type arguments here.

import * as V from './v.ts'

// ---------- math ----------

export const math = {
	pi: Math.PI,
	pi_2: Math.PI / 2,
	pi_4: Math.PI / 4,
	tau: Math.PI * 2,
	tau_over2: Math.PI,
	tau_over4: Math.PI / 2,
	tau_over8: Math.PI / 4,
	e: Math.E,
	phi: 1.618033988749895,
	sqrt2: Math.SQRT2,
	sqrt_3: Math.sqrt(3),
	sqrt_5: Math.sqrt(5),
	sqrt_e: Math.sqrt(Math.E),
	sqrt_pi: Math.sqrt(Math.PI),
	sqrt_tau: Math.sqrt(Math.PI * 2),
	sqrt_phi: Math.sqrt(1.618033988749895),
	ln2: Math.LN2,
	ln10: Math.LN10,
	log2_e: Math.LOG2E,
	log10_e: Math.LOG10E,
	one_over_pi: 1 / Math.PI,
	one_over_tau: 1 / (Math.PI * 2),
	two_thirds: 2 / 3,
	epsilon: 2.220446049250313e-16,
	max_f32: 3.4028234663852886e38,
	max_f64: Number.MAX_VALUE,
	smallest_non_zero_f32: 1.401298464324817e-45,
	smallest_non_zero_f64: 4.9406564584124654e-324,
	abs: (x: number) => Math.abs(x),
	min: (a: number, b: number) => (a < b ? a : b),
	max: (a: number, b: number) => (a > b ? a : b),
	clamp: (x: number, lo: number, hi: number) => (x < lo ? lo : x > hi ? hi : x),
	minmax: (a: number, b: number): [number, number] => (a < b ? [a, b] : [b, a]),
	sqrt: Math.sqrt,
	sqrtf: Math.sqrt,
	sqrti: (x: number) => Math.trunc(Math.sqrt(x)),
	cbrt: Math.cbrt,
	pow: Math.pow,
	powf: Math.pow,
	powi: (a: number, b: number) => Math.trunc(Math.pow(a, b)),
	pow10: (n: number) => Math.pow(10, n),
	sin: Math.sin,
	sinf: Math.sin,
	cos: Math.cos,
	cosf: Math.cos,
	tan: Math.tan,
	tanf: Math.tan,
	cot: (x: number) => 1 / Math.tan(x),
	sincos: (x: number): [number, number] => [Math.sin(x), Math.cos(x)],
	asin: Math.asin,
	acos: Math.acos,
	atan: Math.atan,
	atan2: Math.atan2,
	sinh: Math.sinh,
	cosh: Math.cosh,
	tanh: Math.tanh,
	asinh: Math.asinh,
	acosh: Math.acosh,
	atanh: Math.atanh,
	exp: Math.exp,
	exp2: (x: number) => Math.pow(2, x),
	expm1: Math.expm1,
	log: Math.log,
	logf: Math.log,
	log2: Math.log2,
	log10: Math.log10,
	log1p: Math.log1p,
	log_n: (x: number, b: number) => Math.log(x) / Math.log(b),
	floor: Math.floor,
	floorf: Math.floor,
	ceil: Math.ceil,
	round: (x: number) => (x < 0 ? -Math.round(-x) : Math.round(x)),
	round_to_even: (x: number) => {
		const r = Math.round(x)
		return Math.abs(x % 1) === 0.5 && r % 2 !== 0 ? r - 1 : r
	},
	round_sig: (x: number, digits: number) => Number(x.toFixed(Math.max(0, digits))),
	trunc: Math.trunc,
	fmod: (a: number, b: number) => a % b,
	mod: (a: number, b: number) => a % b,
	modf: (x: number): [number, number] => [Math.trunc(x), x - Math.trunc(x)],
	hypot: Math.hypot,
	sign: (x: number) => (x > 0 ? 1 : x < 0 ? -1 : 0),
	signi: (x: number) => (x > 0 ? 1 : x < 0 ? -1 : 0),
	signbit: (x: number) => x < 0 || Object.is(x, -0),
	copysign: (x: number, y: number) => (y < 0 || Object.is(y, -0) ? -Math.abs(x) : Math.abs(x)),
	radians: (deg: number) => (deg * Math.PI) / 180,
	degrees: (rad: number) => (rad * 180) / Math.PI,
	angle_diff: (a: number, b: number) => {
		let d = (b - a) % (Math.PI * 2)
		if (d > Math.PI) d -= Math.PI * 2
		if (d < -Math.PI) d += Math.PI * 2
		return d
	},
	is_nan: Number.isNaN,
	is_inf: (x: number, sign: number) => (sign >= 0 && x === Infinity) || (sign <= 0 && x === -Infinity),
	is_finite: Number.isFinite,
	inf: (sign: number) => (sign >= 0 ? Infinity : -Infinity),
	nan: () => NaN,
	close: (a: number, b: number) => Math.abs(a - b) <= 1e-14 * Math.max(1, Math.abs(a), Math.abs(b)),
	veryclose: (a: number, b: number) => Math.abs(a - b) <= 4e-16 * Math.max(1, Math.abs(a), Math.abs(b)),
	alike: (a: number, b: number) => a === b || (Number.isNaN(a) && Number.isNaN(b)),
	tolerance: (a: number, b: number, e: number) => Math.abs(a - b) <= e,
	gcd: (a: number, b: number) => {
		a = Math.abs(a)
		b = Math.abs(b)
		while (b) [a, b] = [b, a % b]
		return a
	},
	lcm: (a: number, b: number) => (a === 0 || b === 0 ? 0 : Math.abs(a * b) / math.gcd(a, b)),
	factorial: (n: number) => {
		let r = 1
		for (let i = 2; i <= n; i++) r *= i
		return r
	},
	factoriali: (n: number) => {
		let r = 1
		for (let i = 2; i <= n; i++) r *= i
		return r
	},
	digits: (n: number, base = 10) => {
		const out: number[] = []
		let x = Math.abs(Math.trunc(n))
		if (x === 0) return [0]
		while (x > 0) {
			out.push(x % base)
			x = Math.trunc(x / base)
		}
		return out
	},
	count_digits: (n: number) => String(Math.abs(Math.trunc(n))).length,
	f32_bits: (x: number) => {
		const b = new DataView(new ArrayBuffer(4))
		b.setFloat32(0, x)
		return b.getUint32(0)
	},
	f32_from_bits: (u: number) => {
		const b = new DataView(new ArrayBuffer(4))
		b.setUint32(0, u)
		return b.getFloat32(0)
	},
	q_rsqrt: (x: number) => 1 / Math.sqrt(x),
	cubic_bezier: (t: number, p0: number, p1: number, p2: number, p3: number) => {
		const u = 1 - t
		return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
	},
}

// ---------- rand ----------

let seeded: (() => number) | null = null

function rnd(): number {
	return seeded ? seeded() : Math.random()
}

function range_error(lo: number, hi: number): never {
	throw new V.VError(`max must be greater than min (min: ${lo}, max: ${hi})`)
}

export const rand = {
	seed: (s: number[]) => {
		// mulberry32 from the first seed word, for reproducible sequences
		let a = (s[0] ?? 0) >>> 0
		seeded = () => {
			a = (a + 0x6d2b79f5) | 0
			let t = Math.imul(a ^ (a >>> 15), 1 | a)
			t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
			return ((t ^ (t >>> 14)) >>> 0) / 4294967296
		}
	},
	f32: () => rnd(),
	f64: () => rnd(),
	f32n: (max: number) => {
		if (max <= 0) throw new V.VError('max must be positive')
		return rnd() * max
	},
	f64n: (max: number) => {
		if (max <= 0) throw new V.VError('max must be positive')
		return rnd() * max
	},
	f32cp: () => rnd(),
	f64cp: () => rnd(),
	f32_in_range: (lo: number, hi: number) => (hi <= lo ? range_error(lo, hi) : lo + rnd() * (hi - lo)),
	f64_in_range: (lo: number, hi: number) => (hi <= lo ? range_error(lo, hi) : lo + rnd() * (hi - lo)),
	intn: (max: number) => {
		if (max <= 0) throw new V.VError('max must be positive')
		return Math.floor(rnd() * max)
	},
	i32n: (max: number) => {
		if (max <= 0) throw new V.VError('max must be positive')
		return Math.floor(rnd() * max)
	},
	i64n: (max: number) => {
		if (max <= 0) throw new V.VError('max must be positive')
		return Math.floor(rnd() * max)
	},
	u32n: (max: number) => {
		if (max <= 0) throw new V.VError('max must be positive')
		return Math.floor(rnd() * max)
	},
	u64n: (max: number) => {
		if (max <= 0) throw new V.VError('max must be positive')
		return Math.floor(rnd() * max)
	},
	int_in_range: (lo: number, hi: number) => (hi <= lo ? range_error(lo, hi) : lo + Math.floor(rnd() * (hi - lo))),
	i32_in_range: (lo: number, hi: number) => (hi <= lo ? range_error(lo, hi) : lo + Math.floor(rnd() * (hi - lo))),
	i64_in_range: (lo: number, hi: number) => (hi <= lo ? range_error(lo, hi) : lo + Math.floor(rnd() * (hi - lo))),
	u32_in_range: (lo: number, hi: number) => (hi <= lo ? range_error(lo, hi) : lo + Math.floor(rnd() * (hi - lo))),
	u64_in_range: (lo: number, hi: number) => (hi <= lo ? range_error(lo, hi) : lo + Math.floor(rnd() * (hi - lo))),
	int: () => Math.floor(rnd() * 4294967296) - 2147483648,
	i32: () => Math.floor(rnd() * 4294967296) - 2147483648,
	i64: () => Math.floor((rnd() - 0.5) * Number.MAX_SAFE_INTEGER * 2),
	int31: () => Math.floor(rnd() * 2147483648),
	int63: () => Math.floor(rnd() * Number.MAX_SAFE_INTEGER),
	u8: () => Math.floor(rnd() * 256),
	u16: () => Math.floor(rnd() * 65536),
	u32: () => Math.floor(rnd() * 4294967296),
	u64: () => Math.floor(rnd() * Number.MAX_SAFE_INTEGER),
	i8: () => Math.floor(rnd() * 256) - 128,
	i16: () => Math.floor(rnd() * 65536) - 32768,
	bernoulli: (p: number) => rnd() < p,
	normal: (mean = 0, stdev = 1) => {
		const u = 1 - rnd()
		const v = rnd()
		return mean + stdev * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)
	},
	exponential: (lambda: number) => -Math.log(1 - rnd()) / lambda,
	string: (len: number) => rand.string_from_set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', len),
	hex: (len: number) => rand.string_from_set('0123456789abcdef', len),
	ascii: (len: number) => rand.string_from_set('!"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~', len),
	string_from_set: (set: string, len: number) => {
		let s = ''
		for (let i = 0; i < len; i++) s += set[Math.floor(rnd() * set.length)]
		return s
	},
	uuid_v4: () =>
		'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
			const r = Math.floor(rnd() * 16)
			return (c === 'x' ? r : (r & 3) | 8).toString(16)
		}),
	element: <T>(a: T[]): T => {
		if (a.length === 0) throw new V.VError('array is empty')
		return a[Math.floor(rnd() * a.length)]
	},
	choose: <T>(a: T[], k: number): T[] => {
		if (k > a.length) throw new V.VError('cannot choose more elements than the array has')
		const b = a.slice()
		rand.shuffle(b)
		return b.slice(0, k)
	},
	shuffle: <T>(a: T[]) => {
		for (let i = a.length - 1; i > 0; i--) {
			const j = Math.floor(rnd() * (i + 1))
			;[a[i], a[j]] = [a[j], a[i]]
		}
	},
	shuffle_clone: <T>(a: T[]): T[] => {
		const b = a.slice()
		rand.shuffle(b)
		return b
	},
}

// ---------- os ----------

export const os = {
	args: [] as string[],
	path_separator: '/',
	join_path: (base: string, parts: string[] | string = []) => {
		const all = [base, ...(Array.isArray(parts) ? parts : [parts])].filter((p) => p !== '')
		return all.join('/').replace(/\/+/g, '/')
	},
	join_path_single: (a: string, b: string) => (a === '' ? b : `${a}/${b}`),
	dir: (p: string) => {
		const i = p.lastIndexOf('/')
		return i < 0 ? '.' : i === 0 ? '/' : p.slice(0, i)
	},
	base: (p: string) => p.slice(p.lastIndexOf('/') + 1),
	file_name: (p: string) => p.slice(p.lastIndexOf('/') + 1),
	file_ext: (p: string) => {
		const n = p.slice(p.lastIndexOf('/') + 1)
		const i = n.lastIndexOf('.')
		return i <= 0 ? '' : n.slice(i)
	},
	getenv: (_k: string) => '',
	getenv_opt: (_k: string): string | null => null,
	exists: (_p: string) => false,
	is_file: (_p: string) => false,
	is_dir: (_p: string) => false,
	read_file: (p: string): string => {
		throw new V.VError(`os.read_file("${p}"): there are no files in a browser (load a TextAsset instead)`)
	},
	write_file: (p: string, _s: string) => {
		throw new V.VError(`os.write_file("${p}"): there are no files in a browser (use scene.store)`)
	},
	ls: (_p: string): string[] => [],
	real_path: (p: string) => p,
	abs_path: (p: string) => p,
	home_dir: () => '/',
	user_os: () => 'browser',
	executable: () => 'velo-webgl',
	now: () => Date.now(),
}

// ---------- time ----------

export class Time {
	static __vname = 'time.Time'
	ms: number
	constructor(ms = Date.now()) {
		this.ms = ms
	}
	clone(): Time {
		return new Time(this.ms)
	}
	unix(): number {
		return Math.floor(this.ms / 1000)
	}
	unix_milli(): number {
		return this.ms
	}
	unix_micro(): number {
		return this.ms * 1000
	}
	get year() {
		return new Date(this.ms).getFullYear()
	}
	get month() {
		return new Date(this.ms).getMonth() + 1
	}
	get day() {
		return new Date(this.ms).getDate()
	}
	get hour() {
		return new Date(this.ms).getHours()
	}
	get minute() {
		return new Date(this.ms).getMinutes()
	}
	get second() {
		return new Date(this.ms).getSeconds()
	}
	str(): string {
		const d = new Date(this.ms)
		const p = (n: number) => String(n).padStart(2, '0')
		return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
	}
	format(): string {
		return this.str().slice(0, 16)
	}
	ymmdd(): string {
		return this.str().slice(0, 10)
	}
	hhmmss(): string {
		return this.str().slice(11)
	}
	op_sub(o: Time): number {
		return (this.ms - o.ms) * 1e6 // a Duration, in nanoseconds
	}
}

export class StopWatch {
	static __vname = 'time.StopWatch'
	start_ms = performance.now()
	stopped_ms = -1
	start() {
		this.start_ms = performance.now()
		this.stopped_ms = -1
	}
	restart() {
		this.start()
	}
	stop() {
		this.stopped_ms = performance.now()
	}
	elapsed(): number {
		const end = this.stopped_ms >= 0 ? this.stopped_ms : performance.now()
		return (end - this.start_ms) * 1e6
	}
}

export const time = {
	nanosecond: 1,
	microsecond: 1e3,
	millisecond: 1e6,
	second: 1e9,
	minute: 60e9,
	hour: 3600e9,
	now: () => new Time(),
	utc: () => new Time(),
	unix: (s: number) => new Time(s * 1000),
	ticks: () => Math.floor(performance.now()),
	sys_mono_now: () => Math.floor(performance.now() * 1e6),
	sleep: (_d: number) => {},
	new_stopwatch: () => new StopWatch(),
	since: (t: Time) => (Date.now() - t.ms) * 1e6,
	Time,
	StopWatch,
}

// ---------- strings ----------

export class Builder {
	static __vname = 'strings.Builder'
	parts: string[] = []
	len = 0
	write_string(s: string) {
		this.parts.push(s)
		this.len += s.length
	}
	write_u8(c: number) {
		this.write_string(String.fromCharCode(c))
	}
	write_rune(r: number) {
		this.write_string(String.fromCodePoint(r))
	}
	write_decimal(n: number) {
		this.write_string(String(n))
	}
	writeln(s: string) {
		this.write_string(s + '\n')
	}
	write(bytes: number[]) {
		this.write_string(String.fromCharCode(...bytes))
		return bytes.length
	}
	str(): string {
		const s = this.parts.join('')
		this.parts = []
		this.len = 0
		return s
	}
	clear() {
		this.parts = []
		this.len = 0
	}
	go_back(n: number) {
		const s = this.parts.join('')
		this.parts = [s.slice(0, Math.max(0, s.length - n))]
		this.len = this.parts[0].length
	}
	last_n(n: number): string {
		const s = this.parts.join('')
		return s.slice(Math.max(0, s.length - n))
	}
	free() {}
}

export const strings = {
	new_builder: (_cap: number) => new Builder(),
	repeat: (c: number, n: number) => String.fromCharCode(c).repeat(Math.max(0, n)),
	repeat_string: (s: string, n: number) => s.repeat(Math.max(0, n)),
	levenshtein_distance: (a: string, b: string) => {
		const d: number[] = []
		for (let j = 0; j <= b.length; j++) d[j] = j
		for (let i = 1; i <= a.length; i++) {
			let prev = d[0]
			d[0] = i
			for (let j = 1; j <= b.length; j++) {
				const tmp = d[j]
				d[j] = Math.min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] === b[j - 1] ? 0 : 1))
				prev = tmp
			}
		}
		return d[b.length]
	},
	split_capital: (s: string) => s.split(/(?=[A-Z])/).filter((p) => p !== ''),
	Builder,
}

// ---------- strconv ----------

function strict_int(s: string): number {
	const t = s.trim().replace(/_/g, '')
	if (!/^[+-]?(0x[0-9a-f]+|0b[01]+|0o[0-7]+|\d+)$/i.test(t)) throw new V.VError(`strconv: invalid number "${s}"`)
	return V.S.i64(t)
}

export const strconv = {
	atoi: strict_int,
	atoi8: strict_int,
	atoi16: strict_int,
	atoi32: strict_int,
	atoi64: strict_int,
	atou: strict_int,
	parse_int: (s: string, _base: number, _bits: number) => strict_int(s),
	parse_uint: (s: string, _base: number, _bits: number) => strict_int(s),
	atof64: (s: string) => {
		const v = Number(s.trim().replace(/_/g, ''))
		if (Number.isNaN(v) && s.trim() !== 'nan') throw new V.VError(`strconv: invalid number "${s}"`)
		return v
	},
	atof_quick: (s: string) => Number(s) || 0,
	f64_to_str: (x: number, digits: number) => x.toExponential(digits),
	f64_to_str_l: (x: number) => String(x),
	f32_to_str_l: (x: number) => String(x),
	format_int: (n: number, radix: number) => Math.trunc(n).toString(radix),
	format_uint: (n: number, radix: number) => Math.trunc(n).toString(radix),
}

// ---------- arrays / maps ----------

export const arrays = {
	sum: (a: number[]) => {
		if (a.length === 0) throw new V.VError('cannot sum an empty array')
		return a.reduce((s, x) => s + x, 0)
	},
	min: (a: number[]) => {
		if (a.length === 0) throw new V.VError('cannot find the minimum of an empty array')
		return a.reduce((m, x) => (x < m ? x : m))
	},
	max: (a: number[]) => {
		if (a.length === 0) throw new V.VError('cannot find the maximum of an empty array')
		return a.reduce((m, x) => (x > m ? x : m))
	},
	idx_min: (a: number[]) => {
		if (a.length === 0) throw new V.VError('empty array')
		let k = 0
		a.forEach((x, i) => {
			if (x < a[k]) k = i
		})
		return k
	},
	idx_max: (a: number[]) => {
		if (a.length === 0) throw new V.VError('empty array')
		let k = 0
		a.forEach((x, i) => {
			if (x > a[k]) k = i
		})
		return k
	},
	reduce: <T>(a: T[], f: (acc: T, x: T) => T) => {
		if (a.length === 0) throw new V.VError('cannot reduce an empty array')
		return a.reduce((acc, x) => f(acc, x))
	},
	fold: <T, R>(a: T[], init: R, f: (acc: R, x: T) => R) => a.reduce((acc, x) => f(acc, x), init),
	flatten: <T>(a: T[][]) => a.flat(),
	chunk: <T>(a: T[], size: number) => {
		const out: T[][] = []
		for (let i = 0; i < a.length; i += size) out.push(a.slice(i, i + size))
		return out
	},
	window: <T>(a: T[], p: { size: number; step?: number }) => {
		const out: T[][] = []
		const step = p.step ?? 1
		for (let i = 0; i + p.size <= a.length; i += step) out.push(a.slice(i, i + p.size))
		return out
	},
	concat: <T>(a: T[], ...rest: T[][]) => a.concat(...rest),
	distinct: <T>(a: T[]) => [...new Set(a)],
	uniq: <T>(a: T[]) => a.filter((x, i) => i === 0 || x !== a[i - 1]),
	merge: (a: number[], b: number[]) => [...a, ...b].sort((x, y) => x - y),
	group_by: <K, T>(a: T[], f: (x: T) => K) => {
		const m = new Map<K, T[]>()
		for (const x of a) {
			const k = f(x)
			if (!m.has(k)) m.set(k, [])
			m.get(k)!.push(x)
		}
		return m
	},
	index_of_first: <T>(a: T[], f: (i: number, x: T) => boolean) => a.findIndex((x, i) => f(i, x)),
	index_of_last: <T>(a: T[], f: (i: number, x: T) => boolean) => {
		for (let i = a.length - 1; i >= 0; i--) if (f(i, a[i])) return i
		return -1
	},
	find_first: <T>(a: T[], f: (x: T) => boolean): T | null => a.find((x) => f(x)) ?? null,
	find_last: <T>(a: T[], f: (x: T) => boolean): T | null => {
		for (let i = a.length - 1; i >= 0; i--) if (f(a[i])) return a[i]
		return null
	},
	map_indexed: <T, R>(a: T[], f: (i: number, x: T) => R) => a.map((x, i) => f(i, x)),
	filter_indexed: <T>(a: T[], f: (i: number, x: T) => boolean) => a.filter((x, i) => f(i, x)),
	each: <T>(a: T[], f: (x: T) => void) => a.forEach((x) => f(x)),
	each_indexed: <T>(a: T[], f: (i: number, x: T) => void) => a.forEach((x, i) => f(i, x)),
	flat_map: <T, R>(a: T[], f: (x: T) => R[]) => a.flatMap((x) => f(x)),
	rotate_left: <T>(a: T[], n: number) => {
		const k = ((n % a.length) + a.length) % a.length
		a.push(...a.splice(0, k))
	},
	rotate_right: <T>(a: T[], n: number) => {
		const k = ((n % a.length) + a.length) % a.length
		a.unshift(...a.splice(a.length - k, k))
	},
	binary_search: (a: number[], x: number) => {
		let lo = 0
		let hi = a.length - 1
		while (lo <= hi) {
			const mid = (lo + hi) >> 1
			if (a[mid] === x) return mid
			if (a[mid] < x) lo = mid + 1
			else hi = mid - 1
		}
		throw new V.VError('element not found')
	},
	partition: <T>(a: T[], f: (x: T) => boolean): [T[], T[]] => [a.filter((x) => f(x)), a.filter((x) => !f(x))],
	join_to_string: <T>(a: T[], sep: string, f: (x: T) => string) => a.map((x) => f(x)).join(sep),
	copy: <T>(dst: T[], src: T[]) => {
		const n = Math.min(dst.length, src.length)
		for (let i = 0; i < n; i++) dst[i] = src[i]
		return n
	},
	map_of_counts: <T>(a: T[]) => {
		const m = new Map<T, number>()
		for (const x of a) m.set(x, (m.get(x) ?? 0) + 1)
		return m
	},
}

export const maps = {
	filter: <K, T>(m: Map<K, T>, f: (k: K, v: T) => boolean) => new Map([...m].filter(([k, v]) => f(k, v))),
	to_array: <K, T, R>(m: Map<K, T>, f: (k: K, v: T) => R) => [...m].map(([k, v]) => f(k, v)),
	flat_map: <K, T, R>(m: Map<K, T>, f: (k: K, v: T) => R[]) => [...m].flatMap(([k, v]) => f(k, v)),
	invert: <K, T>(m: Map<K, T>) => new Map([...m].map(([k, v]) => [v, k])),
	from_array: <T>(a: T[]) => new Map(a.map((x, i) => [i, x])),
	merge_in_place: <K, T>(m: Map<K, T>, o: Map<K, T>) => {
		for (const [k, v] of o) m.set(k, v)
	},
	merge: <K, T>(m: Map<K, T>, o: Map<K, T>) => new Map([...m, ...o]),
}

// ---------- misc modules ----------

export const term = {
	red: (s: string) => s,
	green: (s: string) => s,
	yellow: (s: string) => s,
	blue: (s: string) => s,
	bold: (s: string) => s,
	gray: (s: string) => s,
	dim: (s: string) => s,
}

export const hash_fnv1a = {
	sum32_string: (s: string) => {
		let h = 0x811c9dc5
		for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 0x01000193) >>> 0
		return h
	},
	sum32: (b: number[]) => {
		let h = 0x811c9dc5
		for (const x of b) h = Math.imul(h ^ x, 0x01000193) >>> 0
		return h
	},
}

export const math_bits = {
	leading_zeros_32: (x: number) => Math.clz32(x),
	trailing_zeros_32: (x: number) => (x === 0 ? 32 : 31 - Math.clz32(x & -x)),
	ones_count_32: (x: number) => {
		let n = 0
		x >>>= 0
		while (x) {
			n += x & 1
			x >>>= 1
		}
		return n
	},
	rotate_left_32: (x: number, k: number) => ((x << (k & 31)) | (x >>> (32 - (k & 31)))) >>> 0,
}

export const encoding_binary = {
	little_endian_u16: (b: number[]) => b[0] | (b[1] << 8),
	little_endian_u32: (b: number[]) => (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) >>> 0,
	big_endian_u16: (b: number[]) => (b[0] << 8) | b[1],
	big_endian_u32: (b: number[]) => ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) >>> 0,
}

// ---------- x.json2 ----------
// raw_decode() and the Any accessors that games use to read a JSON document.

export class JsonAny {
	static __vname = 'x.json2.Any'
	v: any
	constructor(v: any) {
		this.v = v
	}
	int() {
		return typeof this.v === 'number' ? Math.trunc(this.v) : typeof this.v === 'boolean' ? +this.v : 0
	}
	i64() {
		return this.int()
	}
	u32() {
		return this.int()
	}
	u64() {
		return this.int()
	}
	f32() {
		return typeof this.v === 'number' ? this.v : 0
	}
	f64() {
		return this.f32()
	}
	bool() {
		return typeof this.v === 'boolean' ? this.v : typeof this.v === 'number' ? this.v !== 0 : false
	}
	// null reads as '' here (V prints 'null'): a missing field is an empty string
	str() {
		return this.v === null || this.v === undefined ? '' : typeof this.v === 'string' ? this.v : JSON.stringify(this.v)
	}
	arr() {
		return Array.isArray(this.v) ? this.v.map((x: any) => new JsonAny(x)) : []
	}
	as_array() {
		return this.arr()
	}
	as_map() {
		const m = new Map<string, JsonAny>()
		if (this.v !== null && typeof this.v === 'object' && !Array.isArray(this.v)) {
			for (const k of Object.keys(this.v)) {
				m.set(k, new JsonAny(this.v[k]))
			}
		}
		return m
	}
}

const jsonDecode = (s: string) => {
	try {
		return new JsonAny(JSON.parse(s))
	} catch (e) {
		throw new V.VError(`invalid json: ${(e as Error).message}`)
	}
}

// decode[json2.Any](s) is the only generic form; the type argument is dropped like every vlib generic.
export const x_json2 = { decode: jsonDecode, raw_decode: jsonDecode }
