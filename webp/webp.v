module webp

// Pure V decoder for lossless WebP (VP8L, RFC 9649), also inside an extended (VP8X) container.
// Lossy WebP (VP8) is not supported: `decode` returns an error naming it, so exporters can switch to
// lossless WebP or PNG. No GPU and no C dependency, so it runs in tests, tools and on every platform.

pub struct Image {
pub:
	width  int
	height int
	rgba   []u8 // width * height * 4, straight (as stored) RGBA
}

// info returns the size of a WebP file from its header without decoding pixels.
pub fn info(data []u8) !(int, int) {
	chunk := find_chunk(data)!
	if chunk.kind == 'VP8L' {
		mut br := new_reader(data[chunk.start..chunk.end])
		if br.read(8) != 0x2f {
			return error('webp: bad VP8L signature')
		}
		w := int(br.read(14)) + 1
		h := int(br.read(14)) + 1
		return w, h
	}
	if chunk.kind == 'VP8 ' && chunk.end - chunk.start >= 10 {
		b := data[chunk.start..]
		w := int(u32(b[6]) | (u32(b[7]) << 8)) & 0x3fff
		h := int(u32(b[8]) | (u32(b[9]) << 8)) & 0x3fff
		return w, h
	}
	return error('webp: no image chunk')
}

// is_webp: the bytes start with a RIFF/WEBP header.
pub fn is_webp(data []u8) bool {
	return data.len >= 12 && data[0] == `R` && data[1] == `I` && data[2] == `F` && data[3] == `F`
		&& data[8] == `W` && data[9] == `E` && data[10] == `B` && data[11] == `P`
}

// decode decodes a lossless WebP file to RGBA.
pub fn decode(data []u8) !Image {
	chunk := find_chunk(data)!
	if chunk.kind == 'VP8 ' {
		return error('webp: lossy (VP8) WebP is not supported, only lossless (VP8L); export lossless WebP or PNG')
	}
	mut br := new_reader(data[chunk.start..chunk.end])
	if br.read(8) != 0x2f {
		return error('webp: bad VP8L signature')
	}
	w := int(br.read(14)) + 1
	h := int(br.read(14)) + 1
	br.read(1) // alpha hint
	if br.read(3) != 0 {
		return error('webp: unknown VP8L version')
	}
	argb := decode_vp8l(mut br, w, h)!
	mut out := []u8{len: w * h * 4}
	for i, p in argb {
		out[i * 4] = u8(p >> 16)
		out[i * 4 + 1] = u8(p >> 8)
		out[i * 4 + 2] = u8(p)
		out[i * 4 + 3] = u8(p >> 24)
	}
	return Image{w, h, out}
}

struct Chunk {
	kind  string
	start int
	end   int
}

fn find_chunk(data []u8) !Chunk {
	if !is_webp(data) {
		return error('webp: not a RIFF/WEBP file')
	}
	mut pos := 12
	for pos + 8 <= data.len {
		kind := data[pos..pos + 4].bytestr()
		size := int(u32(data[pos + 4]) | (u32(data[pos + 5]) << 8) | (u32(data[pos + 6]) << 16) | (u32(data[pos +
			7]) << 24))
		start := pos + 8
		end := if start + size > data.len { data.len } else { start + size }
		if kind == 'VP8L' || kind == 'VP8 ' {
			return Chunk{kind, start, end}
		}
		pos = start + size + (size & 1)
	}
	return error('webp: no VP8L/VP8 chunk')
}

// ---------------------------------------------------------------- bit reader (LSB first)

struct BitReader {
	data []u8
mut:
	pos  int // next byte
	bits u64
	n    int // valid bits in `bits`
	eos  bool
}

fn new_reader(data []u8) BitReader {
	return BitReader{
		data: data
	}
}

@[inline]
fn (mut br BitReader) fill() {
	for br.n <= 56 {
		if br.pos < br.data.len {
			br.bits |= u64(br.data[br.pos]) << br.n
			br.pos++
		} else {
			br.eos = true
		}
		br.n += 8
	}
}

@[inline]
fn (mut br BitReader) read(count int) u32 {
	if count == 0 {
		return 0
	}
	if br.n < count {
		br.fill()
	}
	v := u32(br.bits & ((u64(1) << count) - 1))
	br.bits >>= count
	br.n -= count
	return v
}

@[inline]
fn (mut br BitReader) bit() u32 {
	return br.read(1)
}

// ---------------------------------------------------------------- prefix codes (canonical Huffman)

struct Huffman {
mut:
	single int = -1 // the only symbol (zero bits)
	counts []int // codes per length 0..15
	syms   []int // symbols ordered by (length, symbol)
	// fast table for codes up to 8 bits: index = next 8 bits (LSB first), value = sym<<4 | len (0 = slow path)
	fast []int
}

fn reverse_bits(v int, n int) int {
	mut r := 0
	mut x := v
	for _ in 0 .. n {
		r = (r << 1) | (x & 1)
		x >>= 1
	}
	return r
}

fn build_huffman(lengths []int) !Huffman {
	mut h := Huffman{
		counts: []int{len: 16}
		fast:   []int{len: 256}
	}
	mut nonzero := 0
	mut last := 0
	for s, l in lengths {
		if l > 0 {
			nonzero++
			last = s
			h.counts[l]++
		}
	}
	if nonzero == 0 {
		h.single = 0
		return h
	}
	if nonzero == 1 {
		h.single = last
		return h
	}
	mut start := []int{len: 16}
	for l in 1 .. 16 {
		start[l] = start[l - 1] + h.counts[l - 1]
	}
	h.syms = []int{len: nonzero}
	mut fill := start.clone()
	for s, l in lengths {
		if l > 0 {
			h.syms[fill[l] - h.counts[0]] = s
			fill[l]++
		}
	}
	// fast table
	mut code := 0
	mut idx := 0
	for l in 1 .. 16 {
		for _ in 0 .. h.counts[l] {
			if l <= 8 {
				sym := h.syms[idx]
				rev := reverse_bits(code, l)
				for k := rev; k < 256; k += 1 << l {
					h.fast[k] = (sym << 4) | l
				}
			}
			code++
			idx++
		}
		code <<= 1
	}
	return h
}

@[direct_array_access]
fn (h &Huffman) decode(mut br BitReader) int {
	if h.single >= 0 {
		return h.single
	}
	if br.n < 16 {
		br.fill()
	}
	f := h.fast[int(br.bits & 0xff)]
	if f != 0 {
		l := f & 15
		br.bits >>= l
		br.n -= l
		return f >> 4
	}
	// slow path: canonical decode bit by bit (puff style)
	mut code := 0
	mut first := 0
	mut index := 0
	for l in 1 .. 16 {
		code |= int(br.bit())
		count := h.counts[l]
		if code - count < first {
			return h.syms[index + (code - first)]
		}
		index += count
		first += count
		first <<= 1
		code <<= 1
	}
	return 0
}

const code_length_order = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

fn read_huffman(mut br BitReader, alphabet int) !Huffman {
	mut lengths := []int{len: alphabet}
	if br.bit() == 1 {
		// simple code: 1 or 2 symbols
		num := int(br.bit()) + 1
		first_bits := if br.bit() == 1 { 8 } else { 1 }
		s0 := int(br.read(first_bits))
		if s0 >= alphabet {
			return error('webp: bad simple code')
		}
		lengths[s0] = 1
		if num == 2 {
			s1 := int(br.read(8))
			if s1 >= alphabet {
				return error('webp: bad simple code')
			}
			lengths[s1] = 1
		}
		return build_huffman(lengths)
	}
	mut cl_lengths := []int{len: 19}
	n := int(br.read(4)) + 4
	for i in 0 .. n {
		cl_lengths[code_length_order[i]] = int(br.read(3))
	}
	cl := build_huffman(cl_lengths)!
	mut max_symbol := alphabet
	if br.bit() == 1 {
		length_nbits := 2 + 2 * int(br.read(3))
		max_symbol = 2 + int(br.read(length_nbits))
		if max_symbol > alphabet {
			return error('webp: bad max_symbol')
		}
	}
	mut sym := 0
	mut prev := 8
	for sym < alphabet {
		if max_symbol == 0 {
			break
		}
		max_symbol--
		c := cl.decode(mut br)
		if c < 16 {
			lengths[sym] = c
			sym++
			if c != 0 {
				prev = c
			}
			continue
		}
		mut repeat := 0
		mut val := 0
		match c {
			16 {
				repeat = 3 + int(br.read(2))
				val = prev
			}
			17 {
				repeat = 3 + int(br.read(3))
			}
			else {
				repeat = 11 + int(br.read(7))
			}
		}
		if sym + repeat > alphabet {
			return error('webp: code lengths overflow')
		}
		for _ in 0 .. repeat {
			lengths[sym] = val
			sym++
		}
	}
	return build_huffman(lengths)
}

struct Group {
mut:
	codes []Huffman // green+len+cache, red, blue, alpha, distance
}

fn read_group(mut br BitReader, cache_size int) !Group {
	mut g := Group{}
	g.codes << read_huffman(mut br, 256 + 24 + cache_size)!
	g.codes << read_huffman(mut br, 256)!
	g.codes << read_huffman(mut br, 256)!
	g.codes << read_huffman(mut br, 256)!
	g.codes << read_huffman(mut br, 40)!
	return g
}

// ---------------------------------------------------------------- image stream

const dist_map = [0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a, 0x26, 0x2a, 0x38, 0x05,
	0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a, 0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b,
	0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03, 0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a,
	0x23, 0x2d, 0x44, 0x4c, 0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e, 0x66, 0x6a,
	0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b, 0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d,
	0x11, 0x1f, 0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b, 0x31, 0x3f, 0x63, 0x6d,
	0x52, 0x5e, 0x00, 0x74, 0x7c, 0x41, 0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f,
	0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70]

fn plane_to_distance(xsize int, code int) int {
	if code > 120 {
		return code - 120
	}
	m := dist_map[code - 1]
	yoff := m >> 4
	xoff := 8 - (m & 0xf)
	d := yoff * xsize + xoff
	return if d >= 1 { d } else { 1 }
}

fn prefix_value(mut br BitReader, prefix int) int {
	if prefix < 4 {
		return prefix + 1
	}
	extra := (prefix - 2) >> 1
	offset := (2 + (prefix & 1)) << extra
	return offset + int(br.read(extra)) + 1
}

fn div_round_up(a int, bits int) int {
	return (a + (1 << bits) - 1) >> bits
}

// decode_stream reads one entropy-coded image (the main image when `top`, else a sub-image).
@[direct_array_access]
fn decode_stream(mut br BitReader, w int, h int, top bool) ![]u32 {
	mut cache_bits := 0
	if br.bit() == 1 {
		cache_bits = int(br.read(4))
		if cache_bits < 1 || cache_bits > 11 {
			return error('webp: bad color cache size')
		}
	}
	cache_size := if cache_bits > 0 { 1 << cache_bits } else { 0 }
	mut meta := []u32{}
	mut meta_bits := 0
	mut meta_w := 0
	mut ngroups := 1
	if top && br.bit() == 1 {
		meta_bits = int(br.read(3)) + 2
		meta_w = div_round_up(w, meta_bits)
		meta = decode_stream(mut br, meta_w, div_round_up(h, meta_bits), false)!
		for i, p in meta {
			g := int((p >> 8) & 0xffff)
			meta[i] = u32(g)
			if g + 1 > ngroups {
				ngroups = g + 1
			}
		}
	}
	mut groups := []Group{cap: ngroups}
	for _ in 0 .. ngroups {
		groups << read_group(mut br, cache_size)!
	}
	mut cache := []u32{len: cache_size}
	total := w * h
	mut px := []u32{len: total}
	mut i := 0
	mut last_cached := 0
	mut gi := 0
	for i < total {
		if meta.len > 0 && (i % w) & ((1 << meta_bits) - 1) == 0 {
			x := i % w
			y := i / w
			gi = int(meta[(y >> meta_bits) * meta_w + (x >> meta_bits)])
		}
		s := groups[gi].codes[0].decode(mut br)
		if s < 256 {
			r := u32(groups[gi].codes[1].decode(mut br))
			b := u32(groups[gi].codes[2].decode(mut br))
			a := u32(groups[gi].codes[3].decode(mut br))
			px[i] = (a << 24) | (r << 16) | (u32(s) << 8) | b
			i++
		} else if s < 256 + 24 {
			length := prefix_value(mut br, s - 256)
			dsym := groups[gi].codes[4].decode(mut br)
			dcode := prefix_value(mut br, dsym)
			dist := plane_to_distance(w, dcode)
			if dist > i || i + length > total {
				return error('webp: bad backward reference')
			}
			for k in 0 .. length {
				px[i + k] = px[i + k - dist]
			}
			i += length
			// the copy may have crossed into another block: pick the group for where decoding resumes
			if meta.len > 0 && i < total {
				x := i % w
				y := i / w
				gi = int(meta[(y >> meta_bits) * meta_w + (x >> meta_bits)])
			}
		} else {
			idx := s - 256 - 24
			if idx >= cache_size {
				return error('webp: bad color cache index')
			}
			// bring the cache up to date before reading it
			for last_cached < i {
				p := px[last_cached]
				cache[int((u32(0x1e35a7bd) * p) >> u32(32 - cache_bits))] = p
				last_cached++
			}
			px[i] = cache[idx]
			i++
		}
		if cache_size > 0 {
			for last_cached < i {
				p := px[last_cached]
				cache[int((u32(0x1e35a7bd) * p) >> u32(32 - cache_bits))] = p
				last_cached++
			}
		}
	}
	if br.eos && br.pos >= br.data.len && br.n < 0 {
		return error('webp: truncated data')
	}
	return px
}

// ---------------------------------------------------------------- transforms

enum TransformKind {
	predictor
	color
	subtract_green
	color_indexing
}

struct Transform {
	kind  TransformKind
	bits  int
	xsize int // image width this transform works on (before color-indexing packing)
	data  []u32
}

fn decode_vp8l(mut br BitReader, w int, h int) ![]u32 {
	mut transforms := []Transform{}
	mut xsize := w
	mut seen := 0
	for br.bit() == 1 {
		kind := int(br.read(2))
		if seen & (1 << kind) != 0 {
			return error('webp: transform used twice')
		}
		seen |= 1 << kind
		match kind {
			0, 1 {
				bits := int(br.read(3)) + 2
				sub := decode_stream(mut br, div_round_up(xsize, bits), div_round_up(h, bits), false)!
				transforms << Transform{
					kind:  if kind == 0 { TransformKind.predictor } else { TransformKind.color }
					bits:  bits
					xsize: xsize
					data:  sub
				}
			}
			2 {
				transforms << Transform{
					kind:  .subtract_green
					xsize: xsize
				}
			}
			else {
				size := int(br.read(8)) + 1
				mut pal := decode_stream(mut br, size, 1, false)!
				for k in 1 .. pal.len {
					pal[k] = add_pixels(pal[k], pal[k - 1])
				}
				bits := if size <= 2 {
					3
				} else if size <= 4 {
					2
				} else if size <= 16 {
					1
				} else {
					0
				}
				transforms << Transform{
					kind:  .color_indexing
					bits:  bits
					xsize: xsize
					data:  pal
				}
				xsize = div_round_up(xsize, bits)
			}
		}
	}
	mut px := decode_stream(mut br, xsize, h, true)!
	for ti := transforms.len - 1; ti >= 0; ti-- {
		t := transforms[ti]
		match t.kind {
			.predictor { px = inverse_predictor(px, t, h) }
			.color { inverse_color(mut px, t, h) }
			.subtract_green { inverse_subtract_green(mut px) }
			.color_indexing { px = inverse_indexing(px, t, h) }
		}
	}
	return px
}

@[inline]
fn add_pixels(a u32, b u32) u32 {
	ag := (a & 0xff00ff00) + (b & 0xff00ff00)
	rb := (a & 0x00ff00ff) + (b & 0x00ff00ff)
	return (ag & 0xff00ff00) | (rb & 0x00ff00ff)
}

@[inline]
fn average2(a u32, b u32) u32 {
	return (((a ^ b) & 0xfefefefe) >> 1) + (a & b)
}

@[inline]
fn ch(p u32, s int) int {
	return int((p >> u32(s)) & 0xff)
}

@[inline]
fn abs_i(x int) int {
	return if x < 0 { -x } else { x }
}

fn select(l u32, t u32, tl u32) u32 {
	mut pl := 0
	mut pt := 0
	for s in [24, 16, 8, 0] {
		p := ch(l, s) + ch(t, s) - ch(tl, s)
		pl += abs_i(p - ch(l, s))
		pt += abs_i(p - ch(t, s))
	}
	return if pl < pt { l } else { t }
}

@[inline]
fn clamp255(x int) u32 {
	return if x < 0 {
		u32(0)
	} else if x > 255 {
		u32(255)
	} else {
		u32(x)
	}
}

fn clamp_add_sub_full(a u32, b u32, c u32) u32 {
	mut out := u32(0)
	for s in [24, 16, 8, 0] {
		out |= clamp255(ch(a, s) + ch(b, s) - ch(c, s)) << u32(s)
	}
	return out
}

fn clamp_add_sub_half(a u32, b u32) u32 {
	mut out := u32(0)
	for s in [24, 16, 8, 0] {
		x := ch(a, s)
		out |= clamp255(x + (x - ch(b, s)) / 2) << u32(s)
	}
	return out
}

fn predict(mode int, l u32, t u32, tr u32, tl u32) u32 {
	return match mode {
		0 { u32(0xff000000) }
		1 { l }
		2 { t }
		3 { tr }
		4 { tl }
		5 { average2(average2(l, tr), t) }
		6 { average2(l, tl) }
		7 { average2(l, t) }
		8 { average2(tl, t) }
		9 { average2(t, tr) }
		10 { average2(average2(l, tl), average2(t, tr)) }
		11 { select(l, t, tl) }
		12 { clamp_add_sub_full(l, t, tl) }
		13 { clamp_add_sub_half(average2(l, t), tl) }
		else { u32(0xff000000) }
	}
}

@[direct_array_access]
fn inverse_predictor(src []u32, t Transform, h int) []u32 {
	w := t.xsize
	mut px := src.clone()
	bw := div_round_up(w, t.bits)
	for y in 0 .. h {
		for x in 0 .. w {
			i := y * w + x
			pred := if y == 0 && x == 0 {
				u32(0xff000000)
			} else if y == 0 {
				px[i - 1]
			} else if x == 0 {
				px[i - w]
			} else {
				mode := int((t.data[(y >> t.bits) * bw + (x >> t.bits)] >> 8) & 0xf)
				tr := if x == w - 1 { px[y * w] } else { px[i - w + 1] }
				predict(mode, px[i - 1], px[i - w], tr, px[i - w - 1])
			}
			px[i] = add_pixels(px[i], pred)
		}
	}
	return px
}

@[inline]
fn delta(t u32, c u32) int {
	return (int(i8(u8(t))) * int(i8(u8(c)))) >> 5
}

@[direct_array_access]
fn inverse_color(mut px []u32, t Transform, h int) {
	w := t.xsize
	bw := div_round_up(w, t.bits)
	for y in 0 .. h {
		for x in 0 .. w {
			e := t.data[(y >> t.bits) * bw + (x >> t.bits)]
			g2r := e & 0xff
			g2b := (e >> 8) & 0xff
			r2b := (e >> 16) & 0xff
			i := y * w + x
			p := px[i]
			green := (p >> 8) & 0xff
			mut red := int((p >> 16) & 0xff)
			mut blue := int(p & 0xff)
			red = (red + delta(g2r, green)) & 0xff
			blue = (blue + delta(g2b, green)) & 0xff
			blue = (blue + delta(r2b, u32(red))) & 0xff
			px[i] = (p & 0xff00ff00) | (u32(red) << 16) | u32(blue)
		}
	}
}

@[direct_array_access]
fn inverse_subtract_green(mut px []u32) {
	for i, p in px {
		g := (p >> 8) & 0xff
		r := (((p >> 16) & 0xff) + g) & 0xff
		b := ((p & 0xff) + g) & 0xff
		px[i] = (p & 0xff00ff00) | (r << 16) | b
	}
}

@[direct_array_access]
fn inverse_indexing(src []u32, t Transform, h int) []u32 {
	w := t.xsize
	packed_w := div_round_up(w, t.bits)
	mut out := []u32{len: w * h}
	bpp := 8 >> t.bits
	mask := u32((1 << bpp) - 1)
	for y in 0 .. h {
		for x in 0 .. w {
			p := src[y * packed_w + (x >> t.bits)]
			mut idx := int((p >> 8) & 0xff)
			if t.bits > 0 {
				shift := (x & ((1 << t.bits) - 1)) * bpp
				idx = int((u32(idx) >> u32(shift)) & mask)
			}
			out[y * w + x] = if idx < t.data.len { t.data[idx] } else { u32(0) }
		}
	}
	return out
}
