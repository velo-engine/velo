module model3d

import velo.core

// velo.model3d — 3D model data, GPU free: meshes, a skeleton, animation clips, embedded textures.
// Models come from FBX files (load_fbx / parse_fbx) or are built in code (primitives.v). velo.render3d draws them.

// MeshData — triangles with one vertex per corner, in model space.
pub struct MeshData {
pub mut:
	name      string
	positions []f32 // x, y, z per vertex
	normals   []f32 // x, y, z per vertex
	uvs       []f32 // u, v per vertex (v = 0 at the top of the texture)
	// Skinning (empty for a rigid mesh): four bone indices and weights per vertex, weights summing to 1.
	joints  []f32
	weights []f32
	indices []u32 // three per triangle, counter-clockwise = front
	// Index into Model.textures for the base color, -1 = none.
	texture int        = -1
	color   core.Color = core.white // material base color
}

pub fn (m &MeshData) vertex_count() int {
	return m.positions.len / 3
}

pub fn (m &MeshData) is_skinned() bool {
	return m.joints.len > 0 && m.joints.len == m.positions.len / 3 * 4
}

// Bone — one joint of the skeleton. Bones are ordered parents first.
pub struct Bone {
pub mut:
	name   string
	parent int = -1
	// Rest pose, relative to the parent.
	t core.Vec3
	r core.Quat = core.Quat.identity()
	s core.Vec3 = core.Vec3{1, 1, 1}
	// Model space -> bone space at bind time (identity for bones that skin nothing).
	inverse_bind core.Mat4 = core.Mat4.identity()
}

// Clip — an animation baked at a fixed rate: frame f holds every bone's local TRS.
pub struct Clip {
pub mut:
	name     string
	duration f32 // seconds
	fps      f32 = 30
	t        [][]core.Vec3 // [frame][bone]
	r        [][]core.Quat
	s        [][]core.Vec3
}

pub fn (c &Clip) frame_count() int {
	return c.t.len
}

// Image — an encoded texture (PNG/JPEG bytes) embedded in the model, or the file it names.
pub struct Image {
pub:
	name  string
	bytes []u8   // the encoded file; empty when only `file` is known
	file  string // the path the model names (absolute, or relative to the model file)
}

@[heap]
pub struct Model {
pub mut:
	name     string
	meshes   []MeshData
	bones    []Bone
	clips    []Clip
	textures []Image
	// Model-space bounds of the rest pose.
	min core.Vec3
	max core.Vec3
}

// clip_index: the clip named `name` ('' = the first one), -1 if none.
pub fn (m &Model) clip_index(name string) int {
	for i, c in m.clips {
		if name == '' || c.name == name {
			return i
		}
	}
	return -1
}

pub fn (m &Model) bone_index(name string) int {
	for i, b in m.bones {
		if b.name == name || b.name.all_after(':') == name {
			return i
		}
	}
	return -1
}

pub fn (m &Model) triangle_count() int {
	mut n := 0
	for me in m.meshes {
		n += me.indices.len / 3
	}
	return n
}

// compute_bounds sets min/max from the meshes' rest positions.
pub fn (mut m Model) compute_bounds() {
	mut lo := core.Vec3{1e30, 1e30, 1e30}
	mut hi := core.Vec3{-1e30, -1e30, -1e30}
	for me in m.meshes {
		for i := 0; i + 2 < me.positions.len; i += 3 {
			x, y, z := me.positions[i], me.positions[i + 1], me.positions[i + 2]
			lo = core.Vec3{f32_min(lo.x, x), f32_min(lo.y, y), f32_min(lo.z, z)}
			hi = core.Vec3{f32_max(hi.x, x), f32_max(hi.y, y), f32_max(hi.z, z)}
		}
	}
	if lo.x > hi.x {
		lo, hi = core.Vec3{}, core.Vec3{}
	}
	m.min, m.max = lo, hi
}

fn f32_min(a f32, b f32) f32 {
	return if a < b { a } else { b }
}

fn f32_max(a f32, b f32) f32 {
	return if a > b { a } else { b }
}

// ---------- Poses ----------

// Pose — every bone's local TRS at one moment (sampled from clips, blended, then turned into skin matrices).
pub struct Pose {
pub mut:
	t []core.Vec3
	r []core.Quat
	s []core.Vec3
}

// rest_pose: the skeleton's bind/rest pose.
pub fn (m &Model) rest_pose() Pose {
	return Pose{
		t: m.bones.map(it.t)
		r: m.bones.map(it.r)
		s: m.bones.map(it.s)
	}
}

// sample writes clip `ci` at `time` seconds into `pose` (wrapping when `looping`, else holding the last frame).
pub fn (m &Model) sample(ci int, time f32, looping bool, mut pose Pose) {
	if pose.t.len != m.bones.len {
		pose = m.rest_pose()
	}
	if ci < 0 || ci >= m.clips.len {
		return
	}
	c := &m.clips[ci]
	n := c.frame_count()
	if n == 0 {
		return
	}
	mut f := time * c.fps
	last := f32(n - 1)
	if looping && last > 0 {
		f = f - last * f32(int(f / last))
		if f < 0 {
			f += last
		}
	} else if f > last {
		f = last
	} else if f < 0 {
		f = 0
	}
	f0 := int(f)
	f1 := if f0 + 1 < n { f0 + 1 } else { f0 }
	k := f - f32(f0)
	for b in 0 .. m.bones.len {
		if b >= c.t[f0].len {
			break
		}
		pose.t[b] = c.t[f0][b].lerp(c.t[f1][b], k)
		pose.r[b] = c.r[f0][b].nlerp(c.r[f1][b], k)
		pose.s[b] = c.s[f0][b].lerp(c.s[f1][b], k)
	}
}

// blend moves `pose` toward `other` by `w` (0 = unchanged, 1 = other), for cross-fading clips.
pub fn (mut pose Pose) blend(other &Pose, w f32) {
	for b in 0 .. pose.t.len {
		if b >= other.t.len {
			break
		}
		pose.t[b] = pose.t[b].lerp(other.t[b], w)
		pose.r[b] = pose.r[b].nlerp(other.r[b], w)
		pose.s[b] = pose.s[b].lerp(other.s[b], w)
	}
}

// globals: each bone's model-space matrix for `pose` (into `out`, resized as needed).
pub fn (m &Model) globals(pose &Pose, mut out []core.Mat4) {
	if out.len != m.bones.len {
		out = []core.Mat4{len: m.bones.len, init: core.Mat4.identity()}
	}
	for i, b in m.bones {
		local := if i < pose.t.len {
			core.Mat4.trs(pose.t[i], pose.r[i], pose.s[i])
		} else {
			core.Mat4.trs(b.t, b.r, b.s)
		}
		out[i] = if b.parent >= 0 { out[b.parent] * local } else { local }
	}
}

// skin_matrices: model-space globals times inverse bind, what the vertex shader multiplies skinned vertices by.
pub fn (m &Model) skin_matrices(globals []core.Mat4, mut out []core.Mat4) {
	if out.len != m.bones.len {
		out = []core.Mat4{len: m.bones.len, init: core.Mat4.identity()}
	}
	for i, b in m.bones {
		out[i] = globals[i] * b.inverse_bind
	}
}
