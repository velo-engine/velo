module render3d

import math
import velo.core
import velo.assets
import velo.model3d

// ---------- Transform3D ----------

// Transform3D — where a node is in the 3D world. Nested nodes combine their parents' Transform3D (a node without
// one passes its parent's through). Characters and models face +z when rotation.y = 0.
pub struct Transform3D {
	core.Component
pub mut:
	position core.Vec3
	// Euler angles in degrees, applied z (roll), then x (pitch), then y (yaw), like Unity.
	rotation core.Vec3
	scale    core.Vec3 = core.Vec3{1, 1, 1}
}

pub fn (t &Transform3D) quat() core.Quat {
	return core.Quat.yaw(t.rotation.y).mul(core.Quat.axis_angle(core.vec3(1, 0, 0), t.rotation.x)).mul(core.Quat.axis_angle(core.vec3(0,
		0, 1), t.rotation.z))
}

pub fn (t &Transform3D) local_matrix() core.Mat4 {
	return core.Mat4.trs(t.position, t.quat(), t.scale)
}

// world_matrix: the node's transform in the world (identity for a node with no Transform3D on its path).
pub fn world_matrix(n &core.Node) core.Mat4 {
	mut m := core.Mat4.identity()
	mut cur := unsafe { n }
	for cur != unsafe { nil } {
		if t := cur.get_component[Transform3D]() {
			m = t.local_matrix() * m
		}
		cur = cur.parent
	}
	return m
}

pub fn (t &Transform3D) world_matrix() core.Mat4 {
	return world_matrix(t.node)
}

pub fn (t &Transform3D) world_position() core.Vec3 {
	return world_matrix(t.node).translation_part()
}

// forward: the direction the node faces (+z of its rotation), in world space.
pub fn (t &Transform3D) forward() core.Vec3 {
	return world_matrix(t.node).axis(2).normalized()
}

// face turns the node around y toward a world direction (ignoring its height).
pub fn (mut t Transform3D) face(dir core.Vec3) {
	if dir.x * dir.x + dir.z * dir.z < 1e-8 {
		return
	}
	t.rotation.y = f32(math.atan2(dir.x, dir.z) * 180 / math.pi)
}

// turn_toward eases the yaw toward a direction by at most `deg` degrees (smooth turning characters).
pub fn (mut t Transform3D) turn_toward(dir core.Vec3, deg f32) {
	if dir.x * dir.x + dir.z * dir.z < 1e-8 {
		return
	}
	want := f32(math.atan2(dir.x, dir.z) * 180 / math.pi)
	mut d := want - t.rotation.y
	for d > 180 {
		d -= 360
	}
	for d < -180 {
		d += 360
	}
	t.rotation.y += if d > deg {
		deg
	} else if d < -deg {
		-deg
	} else {
		d
	}
}

// transform3d: the node's Transform3D, added if missing.
pub fn transform3d(mut n core.Node) &Transform3D {
	if t := n.get_component[Transform3D]() {
		return t
	}
	return n.add_component(&Transform3D{})
}

// ---------- Camera ----------

// Camera3D — the eye of the 3D world: the first active one in the tree is used. It looks along -z of its node;
// `target` (a node path from the scene root) makes it look at that node instead.
pub struct Camera3D {
	core.Component
pub mut:
	fov    f32 = 60 // vertical, degrees
	near   f32 = 0.1
	far    f32 = 400
	target string // node path to look at, '' = use the node's rotation
	// Filled by the renderer every frame (for world_to_screen and picking).
	view       core.Mat4 = core.Mat4.identity() @[hide]
	projection core.Mat4 = core.Mat4.identity() @[hide]
	eye        core.Vec3 @[hide]
}

fn (mut c Camera3D) compute(aspect f32) {
	m := world_matrix(c.node)
	c.eye = m.translation_part()
	mut looked := false
	if c.target != '' && c.node.scene != unsafe { nil } {
		if n := c.node.scene.find(c.target) {
			c.view = core.Mat4.look_at(c.eye, world_matrix(n).translation_part() +
				core.vec3(0, 1, 0), core.vec3(0, 1, 0))
			looked = true
		}
	}
	if !looked {
		c.view = m.inverse()
	}
	c.projection = core.Mat4.perspective(c.fov, aspect, c.near, c.far)
}

// world_to_screen: a world point in 0..1 screen coordinates (x right, y down) and whether it is in front.
pub fn (c &Camera3D) world_to_screen(p core.Vec3) (core.Vec2, bool) {
	ndc, w := (c.projection * c.view).project(p)
	return core.vec2((ndc.x + 1) / 2, (1 - ndc.y) / 2), w > 0
}

// screen_ray: the ray from the eye through a 0..1 screen point (origin, direction).
pub fn (c &Camera3D) screen_ray(s core.Vec2) (core.Vec3, core.Vec3) {
	inv := (c.projection * c.view).inverse()
	x, y := s.x * 2 - 1, 1 - s.y * 2
	near, _ := inv.project(core.vec3(x, y, -1))
	far, _ := inv.project(core.vec3(x, y, 1))
	return near, (far - near).normalized()
}

// ---------- Lights and environment ----------

// DirectionalLight3D — the sun: parallel light from `direction` (the way the light travels).
pub struct DirectionalLight3D {
	core.Component
pub mut:
	direction core.Vec3  = core.Vec3{-0.4, -1, -0.3}
	color     core.Color = core.rgba(255, 244, 228, 255)
	intensity f32        = 1
}

// PointLight3D — light from the node's position, fading to nothing at `range` (torches, magic, explosions).
// The renderer uses the first 4 active ones.
pub struct PointLight3D {
	core.Component
pub mut:
	color     core.Color = core.rgba(255, 170, 80, 255)
	intensity f32        = 1.5
	range     f32        = 6
	flicker   f32 // 0..1: random flicker of the intensity (fire)
}

// Environment3D — ambient light (sky above, ground below) and distance fog.
pub struct Environment3D {
	core.Component
pub mut:
	sky         core.Color = core.rgba(150, 170, 210, 255)
	ground      core.Color = core.rgba(80, 70, 60, 255)
	ambient     f32        = 0.45
	fog_color   core.Color = core.rgba(150, 170, 200, 255)
	fog_density f32        = 0.015
}

// ---------- Mesh renderer ----------

// MeshRenderer3D — draws a built-in shape or a model (rigid, rest pose) at the node's Transform3D.
pub struct MeshRenderer3D {
	core.Component
pub mut:
	mesh    string = 'cube' @[choices: 'cube|sphere|cylinder|cone|capsule|plane|torus|ring|disc|grid']
	model   assets.AssetRef[assets.Model] // draws the model's meshes instead of `mesh`
	texture assets.AssetRef[assets.Texture]
	pattern string     = 'none' @[choices: 'none|checker|grid|tiles|noise|stripes']                                            // a built-in texture
	color   core.Color = core.white
	// Light the surface gives off (not affected by the sun), and the bright edge seen at grazing angles.
	emissive     core.Color = core.rgba(0, 0, 0, 255)
	rim          f32
	blend        string = 'opaque' @[choices: 'opaque|alpha|additive']
	unlit        bool
	double_sided bool
	uv_scale     core.Vec2 = core.Vec2{1, 1}
	uv_scroll    core.Vec2 // uv offset per second (water, conveyor belts, magic)
	grid_cells   int = 16 // mesh = grid: quads per side (the texture repeats per quad)
	shadow       bool // a soft round shadow on the ground (y = 0) under the node
	shadow_size  f32            = 1
	model_data   &model3d.Model = unsafe { nil } @[hide]
	model_ver    int            @[hide]
	uv_offset    core.Vec2      @[hide]
}

pub fn (mut m MeshRenderer3D) on_load() {
	m.reload_model()
}

pub fn (mut m MeshRenderer3D) on_destroy() {
	if m.model_data != unsafe { nil } {
		release_model(m.model.id)
		m.model_data = unsafe { nil }
	}
}

fn (mut m MeshRenderer3D) reload_model() {
	if !m.model.is_set() || m.node == unsafe { nil } || m.node.scene == unsafe { nil } {
		return
	}
	m.model_data = acquire_model(mut m.node.scene.assets, m.model.id)
}

pub fn (mut m MeshRenderer3D) update(dt f32) {
	m.uv_offset = m.uv_offset + m.uv_scroll.mul(dt)
	m.uv_offset = core.vec2(m.uv_offset.x - f32(int(m.uv_offset.x)),
		m.uv_offset.y - f32(int(m.uv_offset.y)))
	if m.model.is_set() && m.model_data == unsafe { nil } {
		m.reload_model()
	}
}

// ---------- Skinned model + animator ----------

// SkinnedModel3D — draws an animated model (e.g. an FBX character from Mixamo) and plays its clips,
// cross-fading when the clip changes. Its pose is updated in `update`, so game code can read bone positions.
pub struct SkinnedModel3D {
	core.Component
pub mut:
	model   assets.AssetRef[assets.Model]
	clip    string // '' = the model's first clip
	speed   f32  = 1
	playing bool = true
	looping bool = true
	// Keep the root bone over the node (drop the clip's forward/sideways motion) so game code moves the character.
	in_place    bool       = true
	fade        f32        = 0.2 // seconds to blend into a new clip
	color       core.Color = core.white
	emissive    core.Color = core.rgba(0, 0, 0, 255)
	rim         f32
	shadow      bool = true
	shadow_size f32  = 0.9
	// state
	time       f32            @[hide]
	data       &model3d.Model = unsafe { nil } @[hide]
	pose       model3d.Pose   @[hide]
	globals    []core.Mat4    @[hide]
	skin       []core.Mat4    @[hide]
	prev_clip  int = -1            @[hide]
	prev_time  f32            @[hide]
	fade_left  f32            @[hide]
	cur_clip   int = -1            @[hide]
	prev_pose  model3d.Pose   @[hide]
	flash      f32            @[hide] // 0..1 white flash (hits), fades out by itself
	flash_rate f32 = 4            @[hide]
}

pub fn (mut s SkinnedModel3D) on_load() {
	s.load()
}

pub fn (mut s SkinnedModel3D) on_destroy() {
	if s.data != unsafe { nil } {
		release_model(s.model.id)
		s.data = unsafe { nil }
	}
}

fn (mut s SkinnedModel3D) load() {
	if s.data != unsafe { nil } || !s.model.is_set() || s.node == unsafe { nil }
		|| s.node.scene == unsafe { nil } {
		return
	}
	s.data = acquire_model(mut s.node.scene.assets, s.model.id)
	if s.data != unsafe { nil } {
		s.pose = s.data.rest_pose()
		s.cur_clip = s.data.clip_index(s.clip)
		s.evaluate()
	}
}

// play switches to clip `name` (blending over `fade` seconds); playing the current clip again does nothing.
pub fn (mut s SkinnedModel3D) play(name string) {
	if s.data == unsafe { nil } {
		s.clip = name
		return
	}
	ci := s.data.clip_index(name)
	if ci < 0 || ci == s.cur_clip {
		return
	}
	s.prev_clip = s.cur_clip
	s.prev_time = s.time
	s.fade_left = s.fade
	s.cur_clip = ci
	s.clip = name
	s.time = 0
	s.playing = true
}

// clips: the names of the model's animations.
pub fn (s &SkinnedModel3D) clips() []string {
	if s.data == unsafe { nil } {
		return []
	}
	return s.data.clips.map(it.name)
}

// hit_flash makes the model flash white for a moment.
pub fn (mut s SkinnedModel3D) hit_flash() {
	s.flash = 1
}

pub fn (mut s SkinnedModel3D) update(dt f32) {
	s.load()
	if s.data == unsafe { nil } {
		return
	}
	if s.playing {
		s.time += dt * s.speed
		s.prev_time += dt * s.speed
	}
	if s.fade_left > 0 {
		s.fade_left -= dt
	}
	if s.flash > 0 {
		s.flash = f32(math.max(f32(0), s.flash - dt * s.flash_rate))
	}
	s.evaluate()
}

fn (mut s SkinnedModel3D) evaluate() {
	m := s.data
	if s.cur_clip < 0 {
		s.cur_clip = m.clip_index(s.clip)
	}
	m.sample(s.cur_clip, s.time, s.looping, mut s.pose)
	if s.fade_left > 0 && s.prev_clip >= 0 && s.fade > 0 {
		m.sample(s.prev_clip, s.prev_time, true, mut s.prev_pose)
		w := s.fade_left / s.fade // weight of the old clip
		mut blended := s.prev_pose
		blended.blend(&s.pose, 1 - w)
		s.pose = model3d.Pose{
			t: blended.t.clone()
			r: blended.r.clone()
			s: blended.s.clone()
		}
	}
	if s.in_place {
		for i, b in m.bones {
			if b.parent < 0 && i < s.pose.t.len {
				s.pose.t[i].x = b.t.x
				s.pose.t[i].z = b.t.z
			}
		}
	}
	m.globals(s.pose, mut s.globals)
	m.skin_matrices(s.globals, mut s.skin)
}

// bone_world: where bone `name` is in the world (e.g. to attach a sword or a hand effect).
pub fn (s &SkinnedModel3D) bone_world(name string) ?core.Mat4 {
	if s.data == unsafe { nil } {
		return none
	}
	i := s.data.bone_index(name)
	if i < 0 || i >= s.globals.len {
		return none
	}
	return world_matrix(s.node) * s.globals[i]
}

// BoneAttach3D — keeps its node at a bone of a SkinnedModel3D on a parent node (weapons, hand effects).
// The node should have no Transform3D of its own position-wise: it is set every frame.
pub struct BoneAttach3D {
	core.Component
pub mut:
	bone   string // e.g. "RightHand" (the "mixamorig:" prefix is optional)
	offset core.Vec3
}

pub fn (mut b BoneAttach3D) update(dt f32) {
	if b.node.parent == unsafe { nil } {
		return
	}
	sk := b.node.parent.get_component[SkinnedModel3D]() or { return }
	m := sk.bone_world(b.bone) or { return }
	parent_inv := world_matrix(b.node.parent).inverse()
	local := parent_inv * m
	mut t := transform3d(mut b.node)
	t.position = local.transform_point(b.offset)
}
