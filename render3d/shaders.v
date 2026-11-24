module render3d

import sokol.gfx

// The 3D shaders, written out for each backend: GLSL 4.1 (desktop GL), GLSL ES 3.0 (Android, web) and Metal
// (macOS, iOS). Uniforms are arrays of vec4 so one layout works everywhere (see the slot constants below).
//
// mesh:      position, normal, uv (+ joints, weights when skinned) -> lit by a sun, a sky/ground ambient,
//            up to 4 point lights, rim light, emissive, fog. Skinned meshes blend up to 4 of max_bones bones.
// billboard: position, uv, color -> texture * color (particles, trails, blob shadows, glows).

pub const max_bones = 64
pub const max_point_lights = 4

// vertex shader uniforms (vec4 slots)
const vs_view_proj = 0 // 4 slots
const vs_model = 4 // 4 slots
const vs_bones = 8 // 3 slots per bone (rows of a 3x4 matrix)
const vs_static_slots = 8
const vs_skinned_slots = 8 + 3 * max_bones

// fragment shader uniforms (vec4 slots)
const fs_sun_dir = 0 // xyz: toward the sun
const fs_sun_color = 1 // rgb * intensity
const fs_sky = 2 // ambient from above
const fs_ground = 3 // ambient from below
const fs_tint = 4 // rgba base color
const fs_emissive = 5 // rgb, w = rim strength
const fs_camera = 6 // xyz camera position, w = fog density
const fs_fog = 7 // rgb fog color, w = 1 for unlit
const fs_uv = 8 // xy uv scale, zw uv offset
const fs_points = 9 // 2 slots per light: xyz position + range, rgb color * intensity
const fs_slots = 9 + 2 * max_point_lights

enum Lang {
	glsl410
	glsl300es
	msl
}

fn backend_lang() ?Lang {
	return match gfx.query_backend() {
		.glcore33 { Lang.glsl410 }
		.gles3 { Lang.glsl300es }
		.metal_ios, .metal_macos, .metal_simulator { Lang.msl }
		else { none }
	}
}

fn glsl_header(lang Lang) string {
	return if lang == .glsl410 {
		'#version 410\n'
	} else {
		'#version 300 es\nprecision highp float;\nprecision highp int;\n'
	}
}

fn mesh_vs(lang Lang, skinned bool) string {
	slots := if skinned { vs_skinned_slots } else { vs_static_slots }
	if lang == .msl {
		skin := if skinned {
			'
	float4 r0 = float4(0.0), r1 = float4(0.0), r2 = float4(0.0);
	for (int i = 0; i < 4; i++) {
		int b = int(in.joints[i]) * 3 + ${vs_bones};
		float w = in.weights[i];
		r0 += u.p[b] * w; r1 += u.p[b + 1] * w; r2 += u.p[b + 2] * w;
	}
	float4 p4 = float4(in.position, 1.0);
	float4 n4 = float4(in.normal, 0.0);
	float3 pos = float3(dot(r0, p4), dot(r1, p4), dot(r2, p4));
	float3 nrm = float3(dot(r0, n4), dot(r1, n4), dot(r2, n4));
'
		} else {
			'
	float3 pos = in.position;
	float3 nrm = in.normal;
'
		}
		return '#include <metal_stdlib>
using namespace metal;
struct params { float4 p[${slots}]; };
struct vs_in {
	float3 position [[attribute(0)]];
	float3 normal [[attribute(1)]];
	float2 uv [[attribute(2)]];
	float4 joints [[attribute(3)]];
	float4 weights [[attribute(4)]];
};
struct vs_out {
	float4 pos [[position]];
	float3 world [[user(locn0)]];
	float3 normal [[user(locn1)]];
	float2 uv [[user(locn2)]];
};
vertex vs_out main0(vs_in in [[stage_in]], constant params& u [[buffer(0)]]) {
	vs_out o;
${skin}
	float4x4 vp = float4x4(u.p[0], u.p[1], u.p[2], u.p[3]);
	float4x4 model = float4x4(u.p[4], u.p[5], u.p[6], u.p[7]);
	float4 w = model * float4(pos, 1.0);
	o.world = w.xyz;
	o.normal = (model * float4(nrm, 0.0)).xyz;
	o.uv = in.uv;
	o.pos = vp * w;
	return o;
}
'
	}
	skin := if skinned {
		'
	vec4 r0 = vec4(0.0), r1 = vec4(0.0), r2 = vec4(0.0);
	for (int i = 0; i < 4; i++) {
		int b = int(joints[i]) * 3 + ${vs_bones};
		float w = weights[i];
		r0 += vs_params[b] * w; r1 += vs_params[b + 1] * w; r2 += vs_params[b + 2] * w;
	}
	vec4 p4 = vec4(position, 1.0);
	vec4 n4 = vec4(normal, 0.0);
	vec3 pos = vec3(dot(r0, p4), dot(r1, p4), dot(r2, p4));
	vec3 nrm = vec3(dot(r0, n4), dot(r1, n4), dot(r2, n4));
'
	} else {
		'
	vec3 pos = position;
	vec3 nrm = normal;
'
	}
	return glsl_header(lang) +
		'uniform vec4 vs_params[${slots}];
layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec4 joints;
layout(location = 4) in vec4 weights;
out vec3 v_world;
out vec3 v_normal;
out vec2 v_uv;
void main() {
${skin}
	mat4 vp = mat4(vs_params[0], vs_params[1], vs_params[2], vs_params[3]);
	mat4 model = mat4(vs_params[4], vs_params[5], vs_params[6], vs_params[7]);
	vec4 w = model * vec4(pos, 1.0);
	v_world = w.xyz;
	v_normal = (model * vec4(nrm, 0.0)).xyz;
	v_uv = uv;
	gl_Position = vp * w;
}
'
}

// the lighting, shared by both languages (P = fs params array, T = sampled texel)
const light_body = '
	vec4 base = T * P[${fs_tint}];
	vec3 col;
	if (P[${fs_fog}].w > 0.5) {
		col = base.rgb + P[${fs_emissive}].rgb;
	} else {
		vec3 n = normalize(N);
		vec3 v = normalize(P[${fs_camera}].xyz - W);
		vec3 l = normalize(P[${fs_sun_dir}].xyz);
		// wrapped diffuse: the shaded side keeps some shape instead of going flat
		float ndl = dot(n, l);
		float diff = clamp((ndl + 0.35) / 1.35, 0.0, 1.0);
		vec3 h = normalize(l + v);
		float spec = pow(max(dot(n, h), 0.0), 32.0) * 0.25 * max(ndl, 0.0);
		vec3 amb = mix(P[${fs_ground}].rgb, P[${fs_sky}].rgb, n.y * 0.5 + 0.5);
		vec3 light = amb + P[${fs_sun_color}].rgb * diff;
		for (int i = 0; i < ${max_point_lights}; i++) {
			vec4 lp = P[${fs_points} + i * 2];
			if (lp.w > 0.0) {
				vec3 d = lp.xyz - W;
				float dist = length(d);
				float att = clamp(1.0 - dist / lp.w, 0.0, 1.0);
				light += P[${fs_points} + i * 2 + 1].rgb * att * att * max(dot(n, d / max(dist, 0.0001)), 0.0);
			}
		}
		float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0) * P[${fs_emissive}].w;
		col = base.rgb * light + P[${fs_sun_color}].rgb * spec + P[${fs_emissive}].rgb + vec3(rim);
		float dist = length(P[${fs_camera}].xyz - W);
		float fog = 1.0 - exp(-P[${fs_camera}].w * dist);
		col = mix(col, P[${fs_fog}].rgb, clamp(fog, 0.0, 1.0));
	}
'

fn mesh_fs(lang Lang) string {
	if lang == .msl {
		body := light_body.replace('vec4', 'float4').replace('vec3', 'float3').replace('P[', 'u.p[')
		return '#include <metal_stdlib>
using namespace metal;
struct params { float4 p[${fs_slots}]; };
struct fs_in {
	float3 world [[user(locn0)]];
	float3 normal [[user(locn1)]];
	float2 uv [[user(locn2)]];
};
fragment float4 main0(fs_in in [[stage_in]], constant params& u [[buffer(0)]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
	float3 W = in.world;
	float3 N = in.normal;
	float4 T = tex.sample(smp, in.uv * u.p[${fs_uv}].xy + u.p[${fs_uv}].zw);
${body}
	return float4(col, base.a);
}
'
	}
	body := light_body.replace('P[', 'fs_params[')
	return glsl_header(lang) +
		'uniform vec4 fs_params[${fs_slots}];
uniform sampler2D tex_smp;
in vec3 v_world;
in vec3 v_normal;
in vec2 v_uv;
layout(location = 0) out vec4 frag_color;
void main() {
	vec3 W = v_world;
	vec3 N = v_normal;
	vec4 T = texture(tex_smp, v_uv * fs_params[${fs_uv}].xy +
		fs_params[${fs_uv}].zw);
${body}
	frag_color = vec4(col, base.a);
}
'
}

fn billboard_vs(lang Lang) string {
	if lang == .msl {
		return '#include <metal_stdlib>
using namespace metal;
struct params { float4 p[4]; };
struct vs_in {
	float3 position [[attribute(0)]];
	float2 uv [[attribute(1)]];
	float4 color [[attribute(2)]];
};
struct vs_out {
	float4 pos [[position]];
	float2 uv [[user(locn0)]];
	float4 color [[user(locn1)]];
};
vertex vs_out main0(vs_in in [[stage_in]], constant params& u [[buffer(0)]]) {
	vs_out o;
	o.pos = float4x4(u.p[0], u.p[1], u.p[2], u.p[3]) * float4(in.position, 1.0);
	o.uv = in.uv;
	o.color = in.color;
	return o;
}
'
	}
	return glsl_header(lang) +
		'uniform vec4 vs_params[4];
layout(location = 0) in vec3 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 color;
out vec2 v_uv;
out vec4 v_color;
void main() {
	gl_Position = mat4(vs_params[0], vs_params[1], vs_params[2], vs_params[3]) * vec4(position, 1.0);
	v_uv = uv;
	v_color = color;
}
'
}

fn billboard_fs(lang Lang) string {
	if lang == .msl {
		return '#include <metal_stdlib>
using namespace metal;
struct fs_in {
	float2 uv [[user(locn0)]];
	float4 color [[user(locn1)]];
};
fragment float4 main0(fs_in in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
	return tex.sample(smp, in.uv) * in.color;
}
'
	}
	return glsl_header(lang) +
		'uniform sampler2D tex_smp;
in vec2 v_uv;
in vec4 v_color;
layout(location = 0) out vec4 frag_color;
void main() {
	frag_color = texture(tex_smp, v_uv) * v_color;
}
'
}

// make_shader compiles a vertex + fragment pair; `vs_slots`/`fs_slots_n` = vec4 uniforms (0 = none).
fn make_shader(lang Lang, vs string, fs string, attrs []string, vs_slots int, fs_slots_n int, label string) !gfx.Shader {
	mut desc := gfx.ShaderDesc{}
	unsafe { vmemset(&desc, 0, int(sizeof(desc))) }
	desc.label = &char(label.str)
	for i, a in attrs {
		desc.attrs[i].name = &char(a.str)
	}
	desc.vs.source = &char(vs.str)
	desc.fs.source = &char(fs.str)
	if lang == .msl {
		desc.vs.entry = c'main0'
		desc.fs.entry = c'main0'
	}
	if vs_slots > 0 {
		desc.vs.uniform_blocks[0].size = usize(vs_slots * 16)
		desc.vs.uniform_blocks[0].uniforms[0].name = c'vs_params'
		desc.vs.uniform_blocks[0].uniforms[0].@type = .float4
		desc.vs.uniform_blocks[0].uniforms[0].array_count = vs_slots
	}
	if fs_slots_n > 0 {
		desc.fs.uniform_blocks[0].size = usize(fs_slots_n * 16)
		desc.fs.uniform_blocks[0].uniforms[0].name = c'fs_params'
		desc.fs.uniform_blocks[0].uniforms[0].@type = .float4
		desc.fs.uniform_blocks[0].uniforms[0].array_count = fs_slots_n
	}
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
		return error('${label} shader does not compile (see the graphics log above)')
	}
	return shd
}
