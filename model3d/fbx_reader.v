module model3d

import compress.zlib
import encoding.binary
import math

// Binary FBX (version 7.x, as written by the FBX SDK, Blender, Maya, Mixamo, ...) as a tree of named nodes,
// each with a list of typed properties. fbx_import.v turns the tree into a Model.

@[heap]
pub struct FbxNode {
pub mut:
	name     string
	props    []FbxProp
	children []&FbxNode
}

// FbxProp — one property of a node. Numbers are widened: ints/longs/bools land in `i`/`ints`, floats/doubles
// in `f`/`floats`; `s` holds strings (FBX's "Name\x00\x01Class" separator becomes "::"), `raw` raw bytes.
pub struct FbxProp {
pub:
	kind   u8 // the FBX type code: Y C I L F D S R, or f d l i b for arrays
	i      i64
	f      f64
	s      string
	raw    []u8
	ints   []i64
	floats []f64
}

pub fn (p FbxProp) is_array() bool {
	return p.kind in [`f`, `d`, `l`, `i`, `b`]
}

// num: the property as a number, whatever its type.
pub fn (p FbxProp) num() f64 {
	return match p.kind {
		`F`, `D` { p.f }
		else { f64(p.i) }
	}
}

pub fn (p FbxProp) numbers() []f64 {
	return match p.kind {
		`f`, `d` { p.floats }
		`l`, `i`, `b` { p.ints.map(f64(it)) }
		else { [p.num()] }
	}
}

pub fn (p FbxProp) int_list() []i64 {
	return match p.kind {
		`l`, `i`, `b` { p.ints }
		`f`, `d` { p.floats.map(i64(it)) }
		else { [p.i] }
	}
}

// child: the first child named `name`.
pub fn (n &FbxNode) child(name string) ?&FbxNode {
	for c in n.children {
		if c.name == name {
			return c
		}
	}
	return none
}

pub fn (n &FbxNode) children_named(name string) []&FbxNode {
	return n.children.filter(it.name == name)
}

pub fn (n &FbxNode) prop(i int) ?FbxProp {
	if i < 0 || i >= n.props.len {
		return none
	}
	return n.props[i]
}

// id: the object ID (property 0 of every entry under Objects).
pub fn (n &FbxNode) id() i64 {
	if n.props.len == 0 {
		return 0
	}
	return n.props[0].i
}

// Properties70 lookup: `P: "Lcl Translation", "Lcl Translation", "", "A", x, y, z` -> [x, y, z].
pub fn (n &FbxNode) p70(name string) ?[]f64 {
	props := n.child('Properties70') or { return none }
	for p in props.children {
		if p.name == 'P' && p.props.len >= 4 && p.props[0].s == name {
			mut out := []f64{}
			for v in p.props[4..] {
				if v.kind != `S` {
					out << v.num()
				}
			}
			return out
		}
	}
	return none
}

pub fn (n &FbxNode) p70_string(name string) ?string {
	props := n.child('Properties70') or { return none }
	for p in props.children {
		if p.name == 'P' && p.props.len >= 5 && p.props[0].s == name {
			return p.props[4].s
		}
	}
	return none
}

// FbxDocument — the top-level nodes of a file (FBXHeaderExtension, GlobalSettings, Objects, Connections, ...).
pub struct FbxDocument {
pub:
	version int
	nodes   []&FbxNode
}

pub fn (d &FbxDocument) node(name string) ?&FbxNode {
	for n in d.nodes {
		if n.name == name {
			return n
		}
	}
	return none
}

const fbx_magic = 'Kaydara FBX Binary  '

struct FbxReader {
	data []u8
	wide bool // version >= 7500: 64-bit offsets in node records
mut:
	pos int
}

// parse_fbx reads a binary FBX file. ASCII FBX is not supported (re-export as binary).
pub fn parse_fbx(data []u8) !FbxDocument {
	if data.len < 27 || data[..20].bytestr() != fbx_magic {
		if data.len > 0 && data[..math.min(data.len, 200)].bytestr().contains('FBXHeaderExtension') {
			return error('ASCII FBX is not supported, export it as binary FBX')
		}
		return error('not a binary FBX file')
	}
	version := int(binary.little_endian_u32(data[23..27]))
	if version < 7000 {
		return error('FBX version ${version} is too old (7.0 or later needed)')
	}
	mut r := FbxReader{
		data: data
		wide: version >= 7500
		pos:  27
	}
	mut nodes := []&FbxNode{}
	for r.pos < data.len {
		n := r.read_node()!
		if n == unsafe { nil } {
			break
		}
		nodes << n
	}
	return FbxDocument{
		version: version
		nodes:   nodes
	}
}

fn (mut r FbxReader) need(n int) ! {
	if n < 0 || r.pos + n > r.data.len {
		return error('FBX file is truncated (at byte ${r.pos})')
	}
}

fn (mut r FbxReader) u8() !u8 {
	r.need(1)!
	v := r.data[r.pos]
	r.pos++
	return v
}

fn (mut r FbxReader) u32() !u32 {
	r.need(4)!
	v := binary.little_endian_u32(r.data[r.pos..r.pos + 4])
	r.pos += 4
	return v
}

fn (mut r FbxReader) u64() !u64 {
	r.need(8)!
	v := binary.little_endian_u64(r.data[r.pos..r.pos + 8])
	r.pos += 8
	return v
}

fn (mut r FbxReader) offset() !u64 {
	return if r.wide { r.u64()! } else { u64(r.u32()!) }
}

// read_node: one node record; nil = the zero record that ends a child list (or the file).
fn (mut r FbxReader) read_node() !&FbxNode {
	end := int(r.offset()!)
	nprops := int(r.offset()!)
	_ := r.offset()! // property list length in bytes
	name_len := int(r.u8()!)
	if end == 0 {
		return unsafe { nil }
	}
	if end > r.data.len || end < r.pos {
		return error('FBX node record points outside the file')
	}
	r.need(name_len)!
	name := r.data[r.pos..r.pos + name_len].bytestr()
	r.pos += name_len
	mut node := &FbxNode{
		name: name
	}
	for _ in 0 .. nprops {
		node.props << r.read_prop()!
	}
	for r.pos < end {
		c := r.read_node()!
		if c == unsafe { nil } {
			break
		}
		node.children << c
	}
	r.pos = end
	return node
}

fn (mut r FbxReader) read_prop() !FbxProp {
	t := r.u8()!
	match t {
		`Y` {
			r.need(2)!
			v := i16(binary.little_endian_u16(r.data[r.pos..r.pos + 2]))
			r.pos += 2
			return FbxProp{
				kind: t
				i:    v
			}
		}
		`C` {
			return FbxProp{
				kind: t
				i:    r.u8()!
			}
		}
		`I` {
			return FbxProp{
				kind: t
				i:    i32(r.u32()!)
			}
		}
		`L` {
			return FbxProp{
				kind: t
				i:    i64(r.u64()!)
			}
		}
		`F` {
			return FbxProp{
				kind: t
				f:    math.f32_from_bits(r.u32()!)
			}
		}
		`D` {
			return FbxProp{
				kind: t
				f:    math.f64_from_bits(r.u64()!)
			}
		}
		`S`, `R` {
			n := int(r.u32()!)
			r.need(n)!
			bytes := r.data[r.pos..r.pos + n].clone()
			r.pos += n
			if t == `S` {
				return FbxProp{
					kind: t
					s:    bytes.bytestr().replace('\x00\x01', '::')
				}
			}
			return FbxProp{
				kind: t
				raw:  bytes
			}
		}
		`f`, `d`, `l`, `i`, `b` {
			count := int(r.u32()!)
			encoding := r.u32()!
			clen := int(r.u32()!)
			r.need(clen)!
			src := r.data[r.pos..r.pos + clen]
			r.pos += clen
			bytes := if encoding == 1 { zlib.decompress(src)! } else { src }
			size := match t {
				`d`, `l` { 8 }
				`f`, `i` { 4 }
				else { 1 }
			}

			if bytes.len < count * size {
				return error('FBX array is shorter than its element count')
			}
			match t {
				`d` {
					mut out := []f64{len: count}
					for k in 0 .. count {
						out[k] = math.f64_from_bits(binary.little_endian_u64_at(bytes, k * 8))
					}
					return FbxProp{
						kind:   t
						floats: out
					}
				}
				`f` {
					mut out := []f64{len: count}
					for k in 0 .. count {
						out[k] = math.f32_from_bits(binary.little_endian_u32_at(bytes, k * 4))
					}
					return FbxProp{
						kind:   t
						floats: out
					}
				}
				`l` {
					mut out := []i64{len: count}
					for k in 0 .. count {
						out[k] = i64(binary.little_endian_u64_at(bytes, k * 8))
					}
					return FbxProp{
						kind: t
						ints: out
					}
				}
				`i` {
					mut out := []i64{len: count}
					for k in 0 .. count {
						out[k] = i32(binary.little_endian_u32_at(bytes, k * 4))
					}
					return FbxProp{
						kind: t
						ints: out
					}
				}
				else {
					return FbxProp{
						kind: t
						ints: bytes[..count].map(i64(it))
					}
				}
			}
		}
		else {
			return error('unknown FBX property type `${rune(t)}` at byte ${r.pos - 1}')
		}
	}
}
