// Gfx — the WebGL drawing layer of the runtime (what gg + sokol_gl are on desktop): textured, colored
// triangles in one dynamic batch, flushed when the texture, blend mode or scissor rectangle changes.
// Coordinates are window points (CSS pixels); the projection scales them to the framebuffer (devicePixelRatio).
// Text is rasterized with the browser's canvas 2D into an atlas texture (any font, any language).

import type { Texture } from './assets.ts'

export interface GfxColor {
	r: number
	g: number
	b: number
	a: number
}

export type HAlign = 'left' | 'center' | 'right'
export type VAlign = 'top' | 'middle' | 'bottom'

export interface TextCfg {
	size: number // points
	color: GfxColor
	align?: HAlign
	valign?: VAlign
	family?: string // CSS font family ('' = the default font)
}

const VS = `
attribute vec2 a_pos;
attribute vec2 a_uv;
attribute vec4 a_color;
uniform vec2 u_scale;
varying vec2 v_uv;
varying vec4 v_color;
void main() {
	gl_Position = vec4(a_pos.x * u_scale.x - 1.0, 1.0 - a_pos.y * u_scale.y, 0.0, 1.0);
	v_uv = a_uv;
	v_color = a_color;
}`

const FS = `
precision mediump float;
uniform sampler2D u_tex;
varying vec2 v_uv;
varying vec4 v_color;
void main() {
	gl_FragColor = texture2D(u_tex, v_uv) * v_color;
}`

const MAX_VERTS = 65535
const FLOATS_PER_VERT = 5 // x, y, u, v, rgba (packed in one float32 slot as 4 bytes)

export const default_font_family = 'system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", sans-serif'

interface GpuTex {
	tex: WebGLTexture
	version: number
	width: number
	height: number
}

export class Gfx {
	gl: WebGLRenderingContext
	canvas: HTMLCanvasElement
	prog: WebGLProgram
	vbuf: WebGLBuffer
	ibuf: WebGLBuffer
	verts: ArrayBuffer
	vf32: Float32Array
	vu32: Uint32Array
	idx: Uint16Array
	nverts = 0
	nidx = 0
	cur_tex: WebGLTexture | null = null
	cur_additive = false
	white: WebGLTexture
	u_scale: WebGLUniformLocation
	textures = new Map<string, GpuTex>()
	dpr = 1
	width = 0 // window points
	height = 0
	scissor_on = false
	scissor = { x: 0, y: 0, w: 0, h: 0 }
	draw_calls = 0
	text: TextAtlas

	constructor(canvas: HTMLCanvasElement) {
		this.canvas = canvas
		const opts: WebGLContextAttributes = { alpha: false, antialias: true, premultipliedAlpha: false, preserveDrawingBuffer: false }
		const gl = (canvas.getContext('webgl2', opts) ?? canvas.getContext('webgl', opts)) as WebGLRenderingContext | null
		if (!gl) throw new Error('WebGL is not available in this browser')
		this.gl = gl
		this.prog = link(gl, VS, FS)
		gl.useProgram(this.prog)
		this.u_scale = gl.getUniformLocation(this.prog, 'u_scale')!
		gl.uniform1i(gl.getUniformLocation(this.prog, 'u_tex'), 0)
		this.vbuf = gl.createBuffer()!
		this.ibuf = gl.createBuffer()!
		this.verts = new ArrayBuffer(MAX_VERTS * FLOATS_PER_VERT * 4)
		this.vf32 = new Float32Array(this.verts)
		this.vu32 = new Uint32Array(this.verts)
		this.idx = new Uint16Array(MAX_VERTS * 3)
		gl.bindBuffer(gl.ARRAY_BUFFER, this.vbuf)
		gl.bufferData(gl.ARRAY_BUFFER, this.verts.byteLength, gl.DYNAMIC_DRAW)
		gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.ibuf)
		gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, this.idx.byteLength, gl.DYNAMIC_DRAW)
		const stride = FLOATS_PER_VERT * 4
		const a_pos = gl.getAttribLocation(this.prog, 'a_pos')
		const a_uv = gl.getAttribLocation(this.prog, 'a_uv')
		const a_color = gl.getAttribLocation(this.prog, 'a_color')
		gl.enableVertexAttribArray(a_pos)
		gl.vertexAttribPointer(a_pos, 2, gl.FLOAT, false, stride, 0)
		gl.enableVertexAttribArray(a_uv)
		gl.vertexAttribPointer(a_uv, 2, gl.FLOAT, false, stride, 8)
		gl.enableVertexAttribArray(a_color)
		gl.vertexAttribPointer(a_color, 4, gl.UNSIGNED_BYTE, true, stride, 16)
		gl.enable(gl.BLEND)
		gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.disable(gl.DEPTH_TEST)
		gl.disable(gl.CULL_FACE)
		gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false)
		this.white = gl.createTexture()!
		gl.bindTexture(gl.TEXTURE_2D, this.white)
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([255, 255, 255, 255]))
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
		this.text = new TextAtlas(this)
	}

	// begin starts a frame: the canvas is resized to its CSS size times the pixel ratio, and cleared.
	begin(width: number, height: number, dpr: number, bg: GfxColor) {
		const gl = this.gl
		this.width = width
		this.height = height
		if (dpr !== this.dpr) this.text.reset()
		this.dpr = dpr
		const pw = Math.max(1, Math.round(width * dpr))
		const ph = Math.max(1, Math.round(height * dpr))
		if (this.canvas.width !== pw || this.canvas.height !== ph) {
			this.canvas.width = pw
			this.canvas.height = ph
		}
		gl.viewport(0, 0, pw, ph)
		gl.disable(gl.SCISSOR_TEST)
		this.scissor_on = false
		gl.clearColor(bg.r / 255, bg.g / 255, bg.b / 255, 1)
		gl.clear(gl.COLOR_BUFFER_BIT)
		gl.useProgram(this.prog)
		gl.uniform2f(this.u_scale, 2 / width, 2 / height)
		this.draw_calls = 0
		this.cur_tex = null
		this.text.frame++
	}

	end() {
		this.flush()
	}

	// ---------- Batching ----------

	flush() {
		if (this.nidx === 0) {
			this.nverts = 0
			return
		}
		const gl = this.gl
		gl.bindBuffer(gl.ARRAY_BUFFER, this.vbuf)
		gl.bufferSubData(gl.ARRAY_BUFFER, 0, new Uint8Array(this.verts, 0, this.nverts * FLOATS_PER_VERT * 4))
		gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.ibuf)
		gl.bufferSubData(gl.ELEMENT_ARRAY_BUFFER, 0, this.idx.subarray(0, this.nidx))
		gl.activeTexture(gl.TEXTURE0)
		gl.bindTexture(gl.TEXTURE_2D, this.cur_tex ?? this.white)
		if (this.cur_additive) gl.blendFunc(gl.SRC_ALPHA, gl.ONE)
		else gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.drawElements(gl.TRIANGLES, this.nidx, gl.UNSIGNED_SHORT, 0)
		this.draw_calls++
		this.nverts = 0
		this.nidx = 0
	}

	// prepare makes room for `nv` vertices / `ni` indices drawn with `tex` and the blend mode.
	prepare(tex: WebGLTexture | null, additive: boolean, nv: number, ni: number) {
		const t = tex ?? this.white
		if (t !== (this.cur_tex ?? this.white) || additive !== this.cur_additive || this.nverts + nv > MAX_VERTS || this.nidx + ni > this.idx.length) {
			this.flush()
			this.cur_tex = t
			this.cur_additive = additive
		}
	}

	vertex(x: number, y: number, u: number, v: number, c: GfxColor) {
		const i = this.nverts * FLOATS_PER_VERT
		this.vf32[i] = x
		this.vf32[i + 1] = y
		this.vf32[i + 2] = u
		this.vf32[i + 3] = v
		this.vu32[i + 4] = (c.r & 255) | ((c.g & 255) << 8) | ((c.b & 255) << 16) | ((c.a & 255) << 24)
		this.nverts++
	}

	vertex_rgba(x: number, y: number, u: number, v: number, packed: number) {
		const i = this.nverts * FLOATS_PER_VERT
		this.vf32[i] = x
		this.vf32[i + 1] = y
		this.vf32[i + 2] = u
		this.vf32[i + 3] = v
		this.vu32[i + 4] = packed
		this.nverts++
	}

	// quad draws a textured quad: four corners (clockwise from top-left) with their texture coordinates.
	quad(
		tex: WebGLTexture | null,
		x0: number, y0: number, u0: number, v0: number,
		x1: number, y1: number, u1: number, v1: number,
		x2: number, y2: number, u2: number, v2: number,
		x3: number, y3: number, u3: number, v3: number,
		c: GfxColor,
		additive = false,
	) {
		this.prepare(tex, additive, 4, 6)
		const b = this.nverts
		this.vertex(x0, y0, u0, v0, c)
		this.vertex(x1, y1, u1, v1, c)
		this.vertex(x2, y2, u2, v2, c)
		this.vertex(x3, y3, u3, v3, c)
		const ix = this.idx
		let n = this.nidx
		ix[n++] = b
		ix[n++] = b + 1
		ix[n++] = b + 2
		ix[n++] = b
		ix[n++] = b + 2
		ix[n++] = b + 3
		this.nidx = n
	}

	// rect fills an axis-aligned rectangle with a plain color.
	rect(x: number, y: number, w: number, h: number, c: GfxColor) {
		if (w <= 0 || h <= 0 || c.a === 0) return
		this.quad(null, x, y, 0, 0, x + w, y, 0, 0, x + w, y + h, 0, 0, x, y + h, 0, 0, c)
	}

	// convex_poly fills a convex polygon (points as x0, y0, x1, y1, ...).
	convex_poly(pts: number[], c: GfxColor) {
		const n = pts.length / 2
		if (n < 3 || c.a === 0) return
		this.prepare(null, false, n, (n - 2) * 3)
		const b = this.nverts
		for (let i = 0; i < n; i++) this.vertex(pts[i * 2], pts[i * 2 + 1], 0, 0, c)
		for (let i = 1; i < n - 1; i++) {
			this.idx[this.nidx++] = b
			this.idx[this.nidx++] = b + i
			this.idx[this.nidx++] = b + i + 1
		}
	}

	// line draws a segment `width` points thick.
	line(x0: number, y0: number, x1: number, y1: number, c: GfxColor, width = 1) {
		const dx = x1 - x0
		const dy = y1 - y0
		const len = Math.hypot(dx, dy)
		if (len < 1e-6 || c.a === 0) return
		const nx = (-dy / len) * width * 0.5
		const ny = (dx / len) * width * 0.5
		this.quad(null, x0 + nx, y0 + ny, 0, 0, x1 + nx, y1 + ny, 0, 0, x1 - nx, y1 - ny, 0, 0, x0 - nx, y0 - ny, 0, 0, c)
	}

	// poly_empty outlines a closed polygon.
	poly_empty(pts: number[], c: GfxColor, width = 1) {
		const n = pts.length / 2
		for (let i = 0; i < n; i++) {
			const j = (i + 1) % n
			this.line(pts[i * 2], pts[i * 2 + 1], pts[j * 2], pts[j * 2 + 1], c, width)
		}
	}

	rect_empty(x: number, y: number, w: number, h: number, c: GfxColor) {
		this.poly_empty([x, y, x + w, y, x + w, y + h, x, y + h], c)
	}

	circle_filled(x: number, y: number, r: number, c: GfxColor) {
		const seg = Math.max(8, Math.min(64, Math.round(r * 1.5)))
		const pts: number[] = []
		for (let i = 0; i < seg; i++) {
			const a = (i / seg) * Math.PI * 2
			pts.push(x + Math.cos(a) * r, y + Math.sin(a) * r)
		}
		this.convex_poly(pts, c)
	}

	// rounded_points: the outline of a rounded rectangle, clockwise.
	rounded_points(x: number, y: number, w: number, h: number, radius: number): number[] {
		const r = Math.max(0, Math.min(radius, w / 2, h / 2))
		if (r <= 0.01) return [x, y, x + w, y, x + w, y + h, x, y + h]
		const seg = Math.max(3, Math.min(16, Math.round(r * this.dpr * 0.6)))
		const pts: number[] = []
		const corner = (cx: number, cy: number, a0: number) => {
			for (let i = 0; i <= seg; i++) {
				const a = a0 + (i / seg) * (Math.PI / 2)
				pts.push(cx + Math.cos(a) * r, cy + Math.sin(a) * r)
			}
		}
		corner(x + w - r, y + r, -Math.PI / 2)
		corner(x + w - r, y + h - r, 0)
		corner(x + r, y + h - r, Math.PI / 2)
		corner(x + r, y + r, Math.PI)
		return pts
	}

	rounded_rect_filled(x: number, y: number, w: number, h: number, radius: number, c: GfxColor) {
		if (w <= 0 || h <= 0 || c.a === 0) return
		this.convex_poly(this.rounded_points(x, y, w, h, radius), c)
	}

	rounded_rect_empty(x: number, y: number, w: number, h: number, radius: number, c: GfxColor) {
		if (w <= 0 || h <= 0 || c.a === 0) return
		this.poly_empty(this.rounded_points(x, y, w, h, radius), c)
	}

	// set_scissor clips drawing to a rectangle in window points (null = no clipping).
	set_scissor(x: number, y: number, w: number, h: number) {
		const s = this.scissor
		const full = x <= 0 && y <= 0 && x + w >= this.width && y + h >= this.height
		if (full && !this.scissor_on) return
		if (!full && this.scissor_on && s.x === x && s.y === y && s.w === w && s.h === h) return
		this.flush()
		const gl = this.gl
		if (full) {
			gl.disable(gl.SCISSOR_TEST)
			this.scissor_on = false
			return
		}
		s.x = x
		s.y = y
		s.w = w
		s.h = h
		const d = this.dpr
		const px = Math.round(x * d)
		const py = Math.round(y * d)
		const pw = Math.max(0, Math.round((x + w) * d) - px)
		const ph = Math.max(0, Math.round((y + h) * d) - py)
		gl.enable(gl.SCISSOR_TEST)
		gl.scissor(px, this.canvas.height - py - ph, pw, ph)
		this.scissor_on = true
	}

	// ---------- Textures ----------

	// texture uploads an asset texture on first use (and again when its version changes).
	texture(t: Texture): WebGLTexture | null {
		const cached = this.textures.get(t.id)
		if (cached && cached.version === t.version) return cached.tex
		if (!t.image) return null
		const gl = this.gl
		if (cached) gl.deleteTexture(cached.tex)
		const tex = gl.createTexture()!
		gl.bindTexture(gl.TEXTURE_2D, tex)
		gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false)
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, t.image)
		const filter = t.filter === 'nearest' ? gl.NEAREST : gl.LINEAR
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		this.textures.set(t.id, { tex, version: t.version, width: t.width, height: t.height })
		this.cur_tex = null // the binding changed: make the next prepare() flush
		return tex
	}

	release_texture(id: string) {
		const cached = this.textures.get(id)
		if (!cached) return
		this.flush()
		this.gl.deleteTexture(cached.tex)
		this.textures.delete(id)
	}

	// ---------- Text ----------

	text_width(s: string, size: number, family = ''): number {
		return this.text.width(s, size, family)
	}

	draw_text(x: number, y: number, s: string, cfg: TextCfg) {
		this.text.draw(x, y, s, cfg)
	}
}

function link(gl: WebGLRenderingContext, vs: string, fs: string): WebGLProgram {
	const compile = (type: number, src: string) => {
		const sh = gl.createShader(type)!
		gl.shaderSource(sh, src)
		gl.compileShader(sh)
		if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) throw new Error(`shader: ${gl.getShaderInfoLog(sh)}`)
		return sh
	}
	const p = gl.createProgram()!
	gl.attachShader(p, compile(gl.VERTEX_SHADER, vs))
	gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs))
	gl.linkProgram(p)
	if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(`program: ${gl.getProgramInfoLog(p)}`)
	return p
}

// ---------- Text atlas ----------

interface Glyphs {
	x: number // atlas pixels
	y: number
	w: number
	h: number
	ascent: number // pixels from the top of the image to the baseline
	left: number // pixels from the left of the image to the pen position
	width: number // advance width, pixels
	used: number // last frame drawn
}

interface Metrics {
	ascent: number
	descent: number
}

const ATLAS = 2048
const PAD = 2

// TextAtlas — whole strings rasterized by canvas 2D (white, tinted by the vertex color) and packed in shelves.
class TextAtlas {
	gfx: Gfx
	tex: WebGLTexture
	canvas: HTMLCanvasElement | OffscreenCanvas
	ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D
	measure_ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D
	entries = new Map<string, Glyphs>()
	metrics = new Map<string, Metrics>()
	shelf_x = 0
	shelf_y = 0
	shelf_h = 0
	frame = 0

	constructor(gfx: Gfx) {
		this.gfx = gfx
		const gl = gfx.gl
		this.tex = gl.createTexture()!
		gl.bindTexture(gl.TEXTURE_2D, this.tex)
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, ATLAS, ATLAS, 0, gl.RGBA, gl.UNSIGNED_BYTE, null)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		this.canvas = make_canvas(256, 64)
		this.ctx = this.canvas.getContext('2d', { willReadFrequently: false }) as CanvasRenderingContext2D
		this.measure_ctx = (make_canvas(4, 4).getContext('2d') as CanvasRenderingContext2D)
	}

	reset() {
		this.gfx.flush()
		this.entries.clear()
		this.metrics.clear()
		this.shelf_x = 0
		this.shelf_y = 0
		this.shelf_h = 0
	}

	font(px: number, family: string): string {
		const fam = family !== '' ? `"${family}", ${default_font_family}` : default_font_family
		return `${px}px ${fam}`
	}

	// width of `s` at `size` points, in points.
	width(s: string, size: number, family: string): number {
		if (s === '') return 0
		this.measure_ctx.font = this.font(size, family)
		return this.measure_ctx.measureText(s).width
	}

	font_metrics(px: number, family: string): Metrics {
		const key = `${family}|${px}`
		let m = this.metrics.get(key)
		if (!m) {
			this.measure_ctx.font = this.font(px, family)
			const tm = this.measure_ctx.measureText('Hg')
			const ascent = tm.fontBoundingBoxAscent ?? tm.actualBoundingBoxAscent ?? px * 0.8
			const descent = tm.fontBoundingBoxDescent ?? tm.actualBoundingBoxDescent ?? px * 0.2
			m = { ascent, descent }
			this.metrics.set(key, m)
		}
		return m
	}

	glyphs(s: string, px: number, family: string): Glyphs | null {
		const key = `${family}|${px}|${s}`
		const hit = this.entries.get(key)
		if (hit) {
			hit.used = this.frame
			return hit
		}
		const m = this.font_metrics(px, family)
		this.measure_ctx.font = this.font(px, family)
		const tm = this.measure_ctx.measureText(s)
		const left = Math.max(0, Math.ceil(tm.actualBoundingBoxLeft ?? 0))
		const right = Math.ceil(Math.max(tm.width, tm.actualBoundingBoxRight ?? tm.width))
		const asc = Math.ceil(Math.max(m.ascent, tm.actualBoundingBoxAscent ?? 0))
		const desc = Math.ceil(Math.max(m.descent, tm.actualBoundingBoxDescent ?? 0))
		const w = Math.min(ATLAS - PAD * 2, left + right + PAD * 2)
		const h = Math.min(ATLAS - PAD * 2, asc + desc + PAD * 2)
		if (w <= 0 || h <= 0) return null
		// find room on a shelf; when the atlas is full, start over (strings in use are drawn again)
		if (this.shelf_x + w > ATLAS) {
			this.shelf_x = 0
			this.shelf_y += this.shelf_h
			this.shelf_h = 0
		}
		if (this.shelf_y + h > ATLAS) {
			this.reset()
		}
		const x = this.shelf_x
		const y = this.shelf_y
		this.shelf_x += w
		this.shelf_h = Math.max(this.shelf_h, h)
		// rasterize
		if (this.canvas.width < w || this.canvas.height < h) {
			this.canvas.width = Math.max(this.canvas.width, w)
			this.canvas.height = Math.max(this.canvas.height, h)
		}
		const ctx = this.ctx
		ctx.clearRect(0, 0, w, h)
		ctx.font = this.font(px, family)
		ctx.fillStyle = '#fff'
		ctx.textBaseline = 'alphabetic'
		ctx.textAlign = 'left'
		ctx.fillText(s, PAD + left, PAD + asc)
		const gl = this.gfx.gl
		this.gfx.flush()
		gl.bindTexture(gl.TEXTURE_2D, this.tex)
		const img = ctx.getImageData(0, 0, w, h)
		gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false)
		gl.texSubImage2D(gl.TEXTURE_2D, 0, x, y, gl.RGBA, gl.UNSIGNED_BYTE, img)
		this.gfx.cur_tex = null
		const g: Glyphs = { x, y, w, h, ascent: PAD + asc, left: PAD + left, width: tm.width, used: this.frame }
		this.entries.set(key, g)
		return g
	}

	// draw draws one line of text at (x, y) points, aligned by cfg.align / cfg.valign (like gg's TextCfg).
	draw(x: number, y: number, s: string, cfg: TextCfg) {
		if (s === '' || cfg.color.a === 0 || cfg.size <= 0) return
		const dpr = this.gfx.dpr
		const px = Math.max(1, Math.round(cfg.size * dpr))
		const family = cfg.family ?? ''
		const g = this.glyphs(s, px, family)
		if (!g) return
		const m = this.font_metrics(px, family)
		const scale = 1 / dpr
		const adv = g.width * scale
		let ox = x
		if (cfg.align === 'center') ox -= adv / 2
		else if (cfg.align === 'right') ox -= adv
		// baseline position for the vertical alignment (fontstash: top = ascender, bottom = descender)
		let baseline = y + m.ascent * scale
		if (cfg.valign === 'middle') baseline = y + ((m.ascent - m.descent) / 2) * scale
		else if (cfg.valign === 'bottom') baseline = y - m.descent * scale
		const left = g.left * scale
		const x0 = Math.round((ox - left) * dpr) / dpr
		const y0 = Math.round((baseline - g.ascent * scale) * dpr) / dpr
		const w = g.w * scale
		const h = g.h * scale
		const u0 = g.x / ATLAS
		const v0 = g.y / ATLAS
		const u1 = (g.x + g.w) / ATLAS
		const v1 = (g.y + g.h) / ATLAS
		this.gfx.quad(this.tex, x0, y0, u0, v0, x0 + w, y0, u1, v0, x0 + w, y0 + h, u1, v1, x0, y0 + h, u0, v1, cfg.color)
	}
}

function make_canvas(w: number, h: number): HTMLCanvasElement | OffscreenCanvas {
	if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(w, h)
	const c = document.createElement('canvas')
	c.width = w
	c.height = h
	return c
}
