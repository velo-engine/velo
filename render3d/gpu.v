module render3d

import math
import sokol.gfx
import stbi
import velo.core
import velo.model3d

#include "@VMODROOT/render3d/render3d.h"

fn C.velo3d_depth(desc &gfx.PipelineDesc, compare int, write bool)

// Vertex — the mesh vertex layout (64 bytes).
struct Vertex {
	px f32
	py f32
	pz f32
	nx f32
	ny f32
	nz f32
	u  f32
	v  f32
	j0 f32
	j1 f32
	j2 f32
	j3 f32
	w0 f32
	w1 f32
	w2 f32
	w3 f32
}

// BVertex — billboard vertex (24 bytes).
struct BVertex {
	x f32
	y f32
	z f32
	u f32
	v f32
	c u32 // rgba8
}

pub enum Blend {
	opaque
	alpha
	additive
}

fn blend_from(s string) Blend {
	return match s {
		'alpha' { .alpha }
		'additive' { .additive }
		else { .opaque }
	}
}

// GpuMesh — a mesh uploaded to the GPU.
struct GpuMesh {
	vbuf    gfx.Buffer
	ibuf    gfx.Buffer
	count   int
	skinned bool
}

struct GpuTexture {
	img gfx.Image
	w   int
	h   int
}

const max_billboards = 16384

// Gpu — every GPU object of the 3D renderer: shaders, pipelines, uploaded meshes and textures.
@[heap]
struct Gpu {
mut:
	ok        bool
	failed    bool
	lang      Lang
	shd_mesh  gfx.Shader
	shd_skin  gfx.Shader
	shd_bb    gfx.Shader
	pips      map[int]gfx.Pipeline // pipeline_key -> pipeline
	smp       gfx.Sampler          // linear, repeat
	smp_clamp gfx.Sampler
	meshes    map[string]GpuMesh
	textures  map[string]GpuTexture
	white     gfx.Image
	bb_vbuf   gfx.Buffer
	bb_ibuf   gfx.Buffer
	bb_verts  []BVertex
}

fn pipeline_key(kind int, blend Blend, cull bool) int {
	return kind * 100 + int(blend) * 10 + if cull {
		1
	} else {
		0
	}
}

fn (mut g Gpu) init() bool {
	if g.ok || g.failed {
		return g.ok
	}
	lang := backend_lang() or {
		eprintln('[render3d] the ${gfx.query_backend()} graphics backend is not supported')
		g.failed = true
		return false
	}
	g.lang = lang
	mesh_attrs := ['position', 'normal', 'uv', 'joints', 'weights']
	g.shd_mesh = make_shader(lang, mesh_vs(lang, false), mesh_fs(lang), mesh_attrs,
		vs_static_slots, fs_slots, 'velo3d-mesh') or {
		eprintln('[render3d] ${err}')
		g.failed = true
		return false
	}
	g.shd_skin = make_shader(lang, mesh_vs(lang, true), mesh_fs(lang), mesh_attrs,
		vs_skinned_slots, fs_slots, 'velo3d-skinned') or {
		eprintln('[render3d] ${err}')
		g.failed = true
		return false
	}
	g.shd_bb = make_shader(lang, billboard_vs(lang), billboard_fs(lang),
		['position', 'uv', 'color'], 4, 0, 'velo3d-billboard') or {
		eprintln('[render3d] ${err}')
		g.failed = true
		return false
	}
	mut sd := gfx.SamplerDesc{
		min_filter: .linear
		mag_filter: .linear
		wrap_u:     .repeat
		wrap_v:     .repeat
	}
	g.smp = gfx.make_sampler(&sd)
	sd.wrap_u = .clamp_to_edge
	sd.wrap_v = .clamp_to_edge
	g.smp_clamp = gfx.make_sampler(&sd)
	g.white = make_rgba_image([u8(255), 255, 255, 255], 1, 1)
	// billboards: a stream vertex buffer + a static quad index buffer
	g.bb_vbuf = gfx.make_buffer(&gfx.BufferDesc{
		size:  usize(max_billboards * 4 * int(sizeof(BVertex)))
		usage: .stream
		label: c'velo3d-billboards'
	})
	mut idx := []u32{cap: max_billboards * 6}
	for q in 0 .. u32(max_billboards) {
		b := q * 4
		idx << b
		idx << b + 1
		idx << b + 2
		idx << b
		idx << b + 2
		idx << b + 3
	}
	g.bb_ibuf = gfx.make_buffer(&gfx.BufferDesc{
		type:  .indexbuffer
		data:  gfx.Range{
			ptr:  idx.data
			size: usize(idx.len * 4)
		}
		label: c'velo3d-billboard-indices'
	})
	g.ok = true
	return true
}

// pipeline: kind 0 = mesh, 1 = skinned mesh, 2 = billboard.
fn (mut g Gpu) pipeline(kind int, blend Blend, cull bool) gfx.Pipeline {
	key := pipeline_key(kind, blend, cull)
	if p := g.pips[key] {
		return p
	}
	mut pd := gfx.PipelineDesc{}
	unsafe { vmemset(&pd, 0, int(sizeof(pd))) }
	if kind == 2 {
		pd.shader = g.shd_bb
		pd.layout.buffers[0].stride = int(sizeof(BVertex))
		pd.layout.attrs[0] = gfx.VertexAttrDesc{
			format: .float3
			offset: 0
		}
		pd.layout.attrs[1] = gfx.VertexAttrDesc{
			format: .float2
			offset: 12
		}
		pd.layout.attrs[2] = gfx.VertexAttrDesc{
			format: .ubyte4n
			offset: 20
		}
	} else {
		pd.shader = if kind == 1 { g.shd_skin } else { g.shd_mesh }
		pd.layout.buffers[0].stride = int(sizeof(Vertex))
		pd.layout.attrs[0] = gfx.VertexAttrDesc{
			format: .float3
			offset: 0
		}
		pd.layout.attrs[1] = gfx.VertexAttrDesc{
			format: .float3
			offset: 12
		}
		pd.layout.attrs[2] = gfx.VertexAttrDesc{
			format: .float2
			offset: 24
		}
		pd.layout.attrs[3] = gfx.VertexAttrDesc{
			format: .float4
			offset: 32
		}
		pd.layout.attrs[4] = gfx.VertexAttrDesc{
			format: .float4
			offset: 48
		}
	}
	pd.index_type = .uint32
	pd.cull_mode = if cull { .back } else { .none }
	pd.face_winding = .ccw
	// less-equal, depth writes only for opaque geometry
	C.velo3d_depth(&pd, int(gfx.CompareFunc.less_equal), blend == .opaque)
	match blend {
		.opaque {}
		.alpha {
			pd.colors[0].blend = gfx.BlendState{
				enabled:          true
				src_factor_rgb:   .src_alpha
				dst_factor_rgb:   .one_minus_src_alpha
				src_factor_alpha: .one
				dst_factor_alpha: .one_minus_src_alpha
			}
		}
		.additive {
			pd.colors[0].blend = gfx.BlendState{
				enabled:          true
				src_factor_rgb:   .src_alpha
				dst_factor_rgb:   .one
				src_factor_alpha: .zero
				dst_factor_alpha: .one
			}
		}
	}

	pd.label = c'velo3d-pipeline'
	p := gfx.make_pipeline(&pd)
	g.pips[key] = p
	return p
}

fn make_rgba_image(px []u8, w int, h int) gfx.Image {
	mut d := gfx.ImageDesc{
		width:        w
		height:       h
		pixel_format: .rgba8
		label:        c'velo3d-texture'
	}
	d.data.subimage[0][0] = gfx.Range{
		ptr:  px.data
		size: usize(px.len)
	}
	return gfx.make_image(&d)
}

// mesh_for uploads `m` once under `key`.
fn (mut g Gpu) mesh_for(key string, m &model3d.MeshData) GpuMesh {
	if gm := g.meshes[key] {
		return gm
	}
	n := m.vertex_count()
	skinned := m.is_skinned()
	has_uv := m.uvs.len >= n * 2
	has_n := m.normals.len >= n * 3
	mut verts := []Vertex{cap: n}
	for i in 0 .. n {
		mut v := Vertex{
			px: m.positions[i * 3]
			py: m.positions[i * 3 + 1]
			pz: m.positions[i * 3 + 2]
			ny: 1
			w0: 1
		}
		if has_n {
			v = Vertex{
				...v
				nx: m.normals[i * 3]
				ny: m.normals[i * 3 + 1]
				nz: m.normals[i * 3 + 2]
			}
		}
		if has_uv {
			v = Vertex{
				...v
				u: m.uvs[i * 2]
				v: m.uvs[i * 2 + 1]
			}
		}
		if skinned {
			v = Vertex{
				...v
				j0: m.joints[i * 4]
				j1: m.joints[i * 4 + 1]
				j2: m.joints[i * 4 + 2]
				j3: m.joints[i * 4 + 3]
				w0: m.weights[i * 4]
				w1: m.weights[i * 4 + 1]
				w2: m.weights[i * 4 + 2]
				w3: m.weights[i * 4 + 3]
			}
		}
		verts << v
	}
	vbuf := gfx.make_buffer(&gfx.BufferDesc{
		data:  gfx.Range{
			ptr:  verts.data
			size: usize(verts.len * int(sizeof(Vertex)))
		}
		label: c'velo3d-vertices'
	})
	ibuf := gfx.make_buffer(&gfx.BufferDesc{
		type:  .indexbuffer
		data:  gfx.Range{
			ptr:  m.indices.data
			size: usize(m.indices.len * 4)
		}
		label: c'velo3d-indices'
	})
	gm := GpuMesh{
		vbuf:    vbuf
		ibuf:    ibuf
		count:   m.indices.len
		skinned: skinned
	}
	g.meshes[key] = gm
	return gm
}

// texture_from_bytes decodes an encoded image (PNG, JPEG, ...) once under `key`.
fn (mut g Gpu) texture_from_bytes(key string, bytes []u8) ?GpuTexture {
	if t := g.textures[key] {
		return if t.w > 0 { t } else { none }
	}
	if bytes.len == 0 {
		g.textures[key] = GpuTexture{}
		return none
	}
	img := stbi.load_from_memory(bytes.data, bytes.len, desired_channels: 4) or {
		eprintln('[render3d] texture ${key}: ${err}')
		g.textures[key] = GpuTexture{}
		return none
	}
	px := unsafe { img.data.vbytes(img.width * img.height * 4) }
	t := GpuTexture{
		img: make_rgba_image(px, img.width, img.height)
		w:   img.width
		h:   img.height
	}
	img.free()
	g.textures[key] = t
	return t
}

fn (mut g Gpu) texture_from_pixels(key string, px []u8, w int, h int) GpuTexture {
	if t := g.textures[key] {
		return t
	}
	t := GpuTexture{
		img: make_rgba_image(px, w, h)
		w:   w
		h:   h
	}
	g.textures[key] = t
	return t
}

// ---------- Procedural textures (patterns and particle shapes) ----------

pub const patterns = ['none', 'checker', 'grid', 'tiles', 'noise', 'stripes']
pub const particle_shapes = ['soft', 'spark', 'star', 'ring', 'smoke', 'square']

fn hash2(x int, y int) f32 {
	mut h := u32(x) * 374761393 + u32(y) * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return f32(h ^ (h >> 16)) / f32(4294967295)
}

// pattern_pixels: a 64x64 tileable grayscale-ish pattern (multiplied with the material color).
fn pattern_pixels(name string) ([]u8, int) {
	s := 64
	mut px := []u8{len: s * s * 4}
	for y in 0 .. s {
		for x in 0 .. s {
			mut v := f32(1)
			match name {
				'checker' {
					v = if (x / 32 + y / 32) % 2 == 0 { f32(1) } else { f32(0.72) }
				}
				'grid' {
					v = if x % 32 < 2 || y % 32 < 2 { f32(0.55) } else { f32(1) }
				}
				'tiles' {
					row := y / 16
					xx := x + if row % 2 == 1 { 16 } else { 0 }
					v = if y % 16 < 2 || xx % 32 < 2 {
						f32(0.6)
					} else {
						0.9 + 0.1 * hash2(xx / 32, row)
					}
				}
				'noise' {
					// value noise, two octaves, tileable
					mut acc := f32(0)
					for o in [8, 16] {
						cell := s / o
						cx, cy := x / cell, y / cell
						fx, fy := f32(x % cell) / f32(cell), f32(y % cell) / f32(cell)
						a := hash2(cx % o, cy % o)
						b := hash2((cx + 1) % o, cy % o)
						c := hash2(cx % o, (cy + 1) % o)
						d := hash2((cx + 1) % o, (cy + 1) % o)
						sx, sy := fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
						acc += (a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy) * if o == 8 {
							f32(0.65)
						} else {
							f32(0.35)
						}
					}
					v = 0.75 + 0.25 * acc
				}
				'stripes' {
					v = if (x + y) % 32 < 16 { f32(1) } else { f32(0.75) }
				}
				else {}
			}

			c := u8(math.min(v * 255, 255))
			i := (y * s + x) * 4
			px[i], px[i + 1], px[i + 2], px[i + 3] = c, c, c, 255
		}
	}
	return px, s
}

// shape_pixels: a 64x64 white particle sprite with alpha.
fn shape_pixels(name string) ([]u8, int) {
	s := 64
	mut px := []u8{len: s * s * 4}
	for y in 0 .. s {
		for x in 0 .. s {
			dx := (f32(x) + 0.5) / f32(s) * 2 - 1
			dy := (f32(y) + 0.5) / f32(s) * 2 - 1
			r := f32(math.sqrt(dx * dx + dy * dy))
			mut a := f32(0)
			match name {
				'spark' {
					// a bright core with a soft halo
					a = f32(math.max(f32(0), 1 - r)) * f32(math.max(f32(0), 1 - r))
					a = math.min(f32(1), a * 1.5 + f32(math.max(f32(0), 1 - r * 4)))
				}
				'star' {
					arms := f32(math.max(f32(0), 1 - math.abs(dx) * 8)) * f32(math.max(f32(0), 1 -
						math.abs(dy))) + f32(math.max(f32(0), 1 -
						math.abs(dy) * 8)) * f32(math.max(f32(0), 1 - math.abs(dx)))
					a = math.min(f32(1), arms + f32(math.max(f32(0), 1 - r * 3)))
				}
				'ring' {
					a = f32(math.max(f32(0), 1 - math.abs(r - 0.75) * 8))
				}
				'smoke' {
					n := hash2(x / 8, y / 8) * 0.35 + 0.65
					a = f32(math.max(f32(0), 1 - r)) * n
					a = a * a
				}
				'square' {
					a = if math.abs(dx) < 0.9 && math.abs(dy) < 0.9 { f32(1) } else { f32(0) }
				}
				else {
					// soft round blob
					a = f32(math.max(f32(0), 1 - r))
					a = a * a * (3 - 2 * a)
				}
			}

			i := (y * s + x) * 4
			px[i], px[i + 1], px[i + 2], px[i + 3] = 255, 255, 255, u8(math.min(a * 255, 255))
		}
	}
	return px, s
}

fn (mut g Gpu) pattern(name string) gfx.Image {
	if name == '' || name == 'none' {
		return g.white
	}
	key := 'pattern:${name}'
	if t := g.textures[key] {
		return t.img
	}
	px, s := pattern_pixels(name)
	return g.texture_from_pixels(key, px, s, s).img
}

fn (mut g Gpu) shape(name string) gfx.Image {
	key := 'shape:${name}'
	if t := g.textures[key] {
		return t.img
	}
	px, s := shape_pixels(name)
	return g.texture_from_pixels(key, px, s, s).img
}

// pack_color: rgba8 in memory order for .ubyte4n.
fn pack_color(c core.Color) u32 {
	return u32(c.r) | (u32(c.g) << 8) | (u32(c.b) << 16) | (u32(c.a) << 24)
}
