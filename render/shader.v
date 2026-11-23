module render

import sokol.gfx
import sokol.sgl
import velo.core
import velo.assets

// Shader effects. A Sprite with a `shader` (a .glsl asset) is drawn through it instead of the plain texture.
// The file is a GLSL fragment function, plus any helper functions and constants it needs:
//
//   // flash.glsl — mixes the sprite toward PARAM_COLOR by PARAMS.x
//   vec4 effect(vec4 color, vec2 uv) {      // color: the Sprite's tint (0..1), uv: texture coordinates
//       vec4 c = texel(uv) * color;          // texel(uv): the Sprite's texture at uv
//       return vec4(mix(c.rgb, PARAM_COLOR.rgb, PARAMS.x), c.a);
//   }
//
// Built in (read only):
//   TIME          float  seconds of scene time (real time under an `unscaled_time` node; animates in the editor)
//   TEXTURE_SIZE  vec2   the texture's size in pixels (one texel = 1.0 / TEXTURE_SIZE)
//   FRAME_RECT    vec4   the current frame's uv rectangle (u0, v0, u1, v1), for effects local to one frame of a sheet
//   PARAMS        vec2   Sprite.shader_params
//   PARAM_COLOR   vec4   Sprite.shader_color (0..1)
//
// The same file runs everywhere: as GLSL 4.1 (desktop OpenGL), GLSL ES 3.0 (Android, Emscripten), Metal (macOS,
// iOS: the code is wrapped so GLSL's types and functions compile as Metal) and WebGL. Keep to what they share:
// no `uniform`/`in`/`out` declarations or `out`/`inout` parameters, no arrays, and sample with texel(), not texture().

// ShaderLang — the shading language of the graphics backend.
pub enum ShaderLang {
	glsl410   // desktop OpenGL (Linux, Windows, macOS with -d darwin_sokol_glcore33)
	glsl300es // Android, Emscripten
	msl       // Metal (macOS, iOS)
}

// shader_sources wraps the effect in a vertex + fragment shader pair for `lang`, compatible with sokol_gl's
// vertex layout and uniform block (mvp + texture matrix; the texture matrix carries the built-ins, see
// shader_uniforms).
pub fn shader_sources(effect string, lang ShaderLang) !(string, string) {
	if !effect.contains('effect') {
		return error('no `vec4 effect(vec4 color, vec2 uv)` function')
	}
	return match lang {
		.glsl410 { glsl_vs('#version 410\n'), glsl_fs('#version 410\n', effect) }
		.glsl300es { glsl_vs('#version 300 es\n'), glsl_fs(gles_fs_header, effect) }
		.msl { msl_vs, msl_fs(effect) }
	}
}

const gles_fs_header = '#version 300 es\nprecision highp float;\nprecision highp int;\n'

const shader_builtins = '#define TIME velo_p0.x
#define TEXTURE_SIZE velo_p0.yz
#define PARAMS velo_p1.xy
#define PARAM_COLOR velo_p2
#define FRAME_RECT velo_p3
'

fn glsl_vs(header string) string {
	return header +
		'uniform vec4 vs_params[8];
layout(location = 0) in vec4 position;
layout(location = 1) in vec2 texcoord0;
layout(location = 2) in vec4 color0;
layout(location = 3) in float psize;
out vec4 velo_uv;
out vec4 velo_color;
flat out vec4 velo_p0;
flat out vec4 velo_p1;
flat out vec4 velo_p2;
flat out vec4 velo_p3;
void main() {
	gl_Position = mat4(vs_params[0], vs_params[1], vs_params[2], vs_params[3]) * position;
	gl_PointSize = psize;
	velo_uv = vec4(texcoord0, 0.0, 1.0);
	velo_color = color0;
	velo_p0 = vs_params[4];
	velo_p1 = vs_params[5];
	velo_p2 = vs_params[6];
	velo_p3 = vs_params[7];
}
'
}

fn glsl_fs(header string, effect string) string {
	return header +
		'uniform sampler2D tex_smp;
in vec4 velo_uv;
in vec4 velo_color;
flat in vec4 velo_p0;
flat in vec4 velo_p1;
flat in vec4 velo_p2;
flat in vec4 velo_p3;
layout(location = 0) out vec4 velo_frag_color;
vec4 texel(vec2 uv) { return texture(tex_smp, uv); }
' +
		shader_builtins + '#line 1\n' + effect +
		'\nvoid main() { velo_frag_color = effect(velo_color, velo_uv.xy); }\n'
}

const msl_vs = '#include <metal_stdlib>
using namespace metal;
struct vs_params { float4x4 mvp; float4x4 tm; };
struct velo_vs_in {
	float4 position [[attribute(0)]];
	float2 texcoord0 [[attribute(1)]];
	float4 color0 [[attribute(2)]];
	float psize [[attribute(3)]];
};
struct velo_vs_out {
	float4 uv [[user(locn0)]];
	float4 color [[user(locn1)]];
	float4 p0 [[user(locn2), flat]];
	float4 p1 [[user(locn3), flat]];
	float4 p2 [[user(locn4), flat]];
	float4 p3 [[user(locn5), flat]];
	float4 pos [[position]];
	float psize [[point_size]];
};
vertex velo_vs_out main0(velo_vs_in in [[stage_in]], constant vs_params& u [[buffer(0)]]) {
	velo_vs_out out = {};
	out.pos = u.mvp * in.position;
	out.psize = in.psize;
	out.uv = float4(in.texcoord0, 0.0, 1.0);
	out.color = in.color0;
	out.p0 = u.tm[0];
	out.p1 = u.tm[1];
	out.p2 = u.tm[2];
	out.p3 = u.tm[3];
	return out;
}
'

// msl_fs: Metal has no globals, so the effect becomes the body of a struct whose members are the built-ins
// (its functions are member functions and see them); GLSL's names map to Metal's with typedefs and helpers.
fn msl_fs(effect string) string {
	return
		'#include <metal_stdlib>
using namespace metal;
typedef float2 vec2;
typedef float3 vec3;
typedef float4 vec4;
typedef int2 ivec2;
typedef int3 ivec3;
typedef int4 ivec4;
typedef uint2 uvec2;
typedef uint3 uvec3;
typedef uint4 uvec4;
typedef bool2 bvec2;
typedef bool3 bvec3;
typedef bool4 bvec4;
typedef float2x2 mat2;
typedef float3x3 mat3;
typedef float4x4 mat4;
template <typename T, typename U> inline T mod(T x, U y) { return x -
		y * floor(x / y); }
inline float atan(float y, float x) { return atan2(y, x); }
inline vec2 atan(vec2 y, vec2 x) { return atan2(y, x); }
inline vec3 atan(vec3 y, vec3 x) { return atan2(y, x); }
inline vec4 atan(vec4 y, vec4 x) { return atan2(y, x); }
#define inversesqrt rsqrt
#define dFdx dfdx
#define dFdy dfdy
#define lowp
#define mediump
#define highp
struct velo_fs_in {
	float4 uv [[user(locn0)]];
	float4 color [[user(locn1)]];
	float4 p0 [[user(locn2), flat]];
	float4 p1 [[user(locn3), flat]];
	float4 p2 [[user(locn4), flat]];
	float4 p3 [[user(locn5), flat]];
};
' +
		shader_builtins +
		'struct velo_effect {
	vec4 velo_p0;
	vec4 velo_p1;
	vec4 velo_p2;
	vec4 velo_p3;
	texture2d<float> velo_tex;
	sampler velo_smp;
	vec4 texel(vec2 uv) const { return velo_tex.sample(velo_smp, uv); }
#line 1
' +
		effect +
		'
};
fragment float4 main0(velo_fs_in in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
	velo_effect e;
	e.velo_p0 = in.p0;
	e.velo_p1 = in.p1;
	e.velo_p2 = in.p2;
	e.velo_p3 = in.p3;
	e.velo_tex = tex;
	e.velo_smp = smp;
	return e.effect(in.color, in.uv.xy);
}
'
}

// shader_uniforms packs the built-ins into a column-major 4x4 matrix (sokol_gl's texture matrix):
// column 0 = TIME, TEXTURE_SIZE; 1 = PARAMS; 2 = PARAM_COLOR; 3 = FRAME_RECT.
pub fn shader_uniforms(time f32, tex_w f32, tex_h f32, params core.Vec2, color core.Color, frame_rect [4]f32) []f32 {
	return [time, tex_w, tex_h, 0, params.x, params.y, 0, 0, f32(color.r) / 255, f32(color.g) / 255,
		f32(color.b) / 255, f32(color.a) / 255, frame_rect[0], frame_rect[1], frame_rect[2], frame_rect[3]]
}

// shader_time: TIME for a node — the scene's game time, or its real time under an `unscaled_time` node.
pub fn shader_time(n &core.Node) f32 {
	if n == unsafe { nil } || n.scene == unsafe { nil } {
		return 0
	}
	mut p := unsafe { n }
	for p != unsafe { nil } {
		if p.unscaled_time {
			return f32(n.scene.real_time)
		}
		p = p.parent
	}
	return f32(n.scene.time)
}

// ---------- GPU side ----------

struct GpuShader {
	shd     gfx.Shader
	pip     sgl.Pipeline
	version int
	ok      bool // false: failed to compile (not retried until the file changes)
}

fn backend_lang() ?ShaderLang {
	return match gfx.query_backend() {
		.glcore33 { ShaderLang.glsl410 }
		.gles3 { ShaderLang.glsl300es }
		.metal_ios, .metal_macos, .metal_simulator { ShaderLang.msl }
		else { none }
	}
}

// pipeline_for compiles the shader on first use, and again when the file changes (hot reload).
// none = it does not compile (the error is printed once); the sprite is then drawn without it.
fn (mut r Renderer) pipeline_for(s &assets.Shader) ?sgl.Pipeline {
	if g := r.shaders[s.id] {
		if g.version == s.version {
			return if g.ok { g.pip } else { none }
		}
		r.release_shader(s.id)
	}
	g := make_gpu_shader(s) or {
		eprintln('[render] shader ${s.path}: ${err}')
		r.shaders[s.id] = GpuShader{
			version: s.version
		}
		return none
	}
	r.shaders[s.id] = g
	return g.pip
}

fn make_gpu_shader(s &assets.Shader) !GpuShader {
	lang := backend_lang() or {
		return error('not supported by the ${gfx.query_backend()} backend')
	}
	vs, fs := shader_sources(s.source, lang)!
	mut desc := gfx.ShaderDesc{}
	unsafe { vmemset(&desc, 0, int(sizeof(desc))) }
	desc.label = c'velo-shader'
	desc.attrs[0].name = c'position'
	desc.attrs[1].name = c'texcoord0'
	desc.attrs[2].name = c'color0'
	desc.attrs[3].name = c'psize'
	desc.vs.source = &char(vs.str)
	desc.fs.source = &char(fs.str)
	if lang == .msl {
		desc.vs.entry = c'main0'
		desc.fs.entry = c'main0'
	}
	desc.vs.uniform_blocks[0].size = 128 // mvp + texture matrix, as sokol_gl fills it
	desc.vs.uniform_blocks[0].uniforms[0].name = c'vs_params'
	desc.vs.uniform_blocks[0].uniforms[0].@type = .float4
	desc.vs.uniform_blocks[0].uniforms[0].array_count = 8
	desc.fs.images[0].used = true
	desc.fs.images[0].image_type = ._2d
	desc.fs.images[0].sample_type = .float
	desc.fs.samplers[0].used = true
	desc.fs.samplers[0].sampler_type = .filtering
	desc.fs.image_sampler_pairs[0].used = true
	desc.fs.image_sampler_pairs[0].image_slot = 0
	desc.fs.image_sampler_pairs[0].sampler_slot = 0
	desc.fs.image_sampler_pairs[0].glsl_name = c'tex_smp'
	shd := gfx.make_shader(&desc)
	if gfx.query_shader_state(shd) != .valid {
		gfx.destroy_shader(shd)
		return error('does not compile (see the graphics log above)')
	}
	mut pd := gfx.PipelineDesc{}
	unsafe { vmemset(&pd, 0, int(sizeof(pd))) }
	pd.label = c'velo-shader-pipeline'
	pd.shader = shd
	pd.colors[0] = gfx.ColorTargetState{
		blend: gfx.BlendState{
			enabled:        true
			src_factor_rgb: .src_alpha
			dst_factor_rgb: .one_minus_src_alpha
		}
	}
	return GpuShader{
		shd:     shd
		pip:     sgl.make_pipeline(&pd)
		version: s.version
		ok:      true
	}
}

fn (mut r Renderer) release_shader(id string) {
	if g := r.shaders[id] {
		if g.ok {
			sgl.destroy_pipeline(g.pip)
			gfx.destroy_shader(g.shd)
		}
		r.shaders.delete(id)
	}
}
