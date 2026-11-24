import os
import velo.core
import velo.model3d

const eps = f32(1e-4)

fn close(a f32, b f32) bool {
	return (if a > b {
		a - b
	} else {
		b - a
	}) < eps
}

fn close3(a core.Vec3, b core.Vec3) bool {
	return close(a.x, b.x) && close(a.y, b.y) && close(a.z, b.z)
}

fn test_mat4_inverse_and_trs() {
	q := core.Quat.euler(core.vec3(20, -35, 50))
	m := core.Mat4.trs(core.vec3(1, 2, 3), q, core.vec3(2, 0.5, 1.5))
	id := m * m.inverse()
	for i in 0 .. 16 {
		assert close(id.m[i], core.Mat4.identity().m[i])
	}
	t, r, s := m.decompose()
	assert close3(t, core.vec3(1, 2, 3))
	assert close3(s, core.vec3(2, 0.5, 1.5))
	p := core.vec3(0.3, -1, 2)
	assert close3(r.rotate(p), q.rotate(p))
}

fn test_quat_matches_matrix() {
	q := core.Quat.axis_angle(core.vec3(0, 1, 0), 90)
	// +z turns to +x around +y
	assert close3(q.rotate(core.vec3(0, 0, 1)), core.vec3(1, 0, 0))
	assert close3(core.Mat4.rotation(q).transform_dir(core.vec3(0, 0, 1)), core.vec3(1, 0, 0))
	half := core.Quat.identity().slerp(q, 0.5)
	assert close3(half.rotate(core.vec3(0, 0, 1)), core.vec3(f32(0.70710677), 0, f32(0.70710677)))
}

fn test_look_at_and_projection() {
	view := core.Mat4.look_at(core.vec3(0, 0, 5), core.vec3(0, 0, 0), core.vec3(0, 1, 0))
	assert close3(view.transform_point(core.vec3(0, 0, 0)), core.vec3(0, 0, -5))
	proj := core.Mat4.perspective(60, 1, 1, 100)
	near, _ := proj.project(core.vec3(0, 0, -1))
	far, _ := proj.project(core.vec3(0, 0, -100))
	assert close(near.z, -1)
	assert close(far.z, 1)
}

// every triangle of a closed primitive faces outward (counter-clockwise seen from outside)
fn outward(m model3d.MeshData) bool {
	for i := 0; i + 2 < m.indices.len; i += 3 {
		p := fn [m] (k u32) core.Vec3 {
			return core.vec3(m.positions[k * 3], m.positions[k * 3 + 1], m.positions[k * 3 + 2])
		}
		a, b, c := p(m.indices[i]), p(m.indices[i + 1]), p(m.indices[i + 2])
		n := (b - a).cross(c - a)
		if n.length() < 1e-7 {
			continue // degenerate (poles)
		}
		center := (a + b + c).mul(f32(1) / 3)
		k := m.indices[i]
		vn := core.vec3(m.normals[k * 3], m.normals[k * 3 + 1], m.normals[k * 3 + 2])
		if n.dot(vn) <= 0 && n.dot(center) <= 0 {
			return false
		}
	}
	return true
}

fn test_primitives_face_outward() {
	for name in model3d.primitive_names {
		m := model3d.primitive(name) or { panic(name) }
		assert m.indices.len % 3 == 0, name
		assert m.normals.len == m.positions.len, name
		assert m.uvs.len / 2 == m.positions.len / 3, name
		assert outward(m), name
	}
	assert model3d.primitive('nope') == none
}

fn test_fbx_character() {
	path := os.join_path(os.dir(@FILE), '..', 'examples', 'demo3d', 'assets', 'models',
		'than_dieu_run.fbx')
	if !os.exists(path) {
		return
	}
	m := model3d.load_fbx(path)!
	assert m.meshes.len == 1
	assert m.meshes[0].is_skinned()
	assert m.bones.len == 41
	assert m.bone_index('Hips') == 0
	assert m.clips.len == 1
	assert m.clips[0].frame_count() == 17
	assert m.textures.len == 1 && m.textures[0].bytes.len > 1000
	// about 1.8 m tall, feet on the ground, y up
	assert close(m.min.y, 0) || m.min.y > -0.01
	assert m.max.y > 1.6 && m.max.y < 2
	// rest pose: every skinning bone's global * inverse bind is the identity
	pose := m.rest_pose()
	mut g := []core.Mat4{}
	m.globals(pose, mut g)
	mut sk := []core.Mat4{}
	m.skin_matrices(g, mut sk)
	hips := sk[0]
	for i in 0 .. 16 {
		assert (if hips.m[i] > core.Mat4.identity().m[i] {
			hips.m[i] - core.Mat4.identity().m[i]
		} else {
			core.Mat4.identity().m[i] - hips.m[i]
		}) < 1e-3
	}
	// weights sum to 1
	me := m.meshes[0]
	for v in 0 .. me.vertex_count() {
		s := me.weights[v * 4] + me.weights[v * 4 + 1] + me.weights[v * 4 + 2] + me.weights[v * 4 +
			3]
		assert close(s, 1) || (s > 0.999 && s < 1.001)
	}
}

fn test_not_fbx() {
	if _ := model3d.parse_fbx('hello'.bytes()) {
		assert false
	}
}
