// velo.render3d for the WebGL runtime (render3d/*.v): the 3D components (Transform3D, Camera3D, lights,
// MeshRenderer3D, SkinnedModel3D, BoneAttach3D, Particles3D, Trail3D) and the renderer that draws them with WebGL,
// between the 2D world and the HUD (Canvas nodes), like on desktop. Same shaders as the GLSL ES 3.0 desktop path
// (rewritten to GLSL ES 1.0 when the browser only has WebGL 1).

import * as V from './v.ts'
import * as core from './core.ts'
import * as assets from './assets.ts'
import * as serialize from './serialize.ts'
import * as model3d from './model3d.ts'
import { Vec2, Vec3, Quat, Mat4, Color, vec2, vec3, rgba } from './core.ts'
import type { FieldSpec } from './core.ts'
import type { App } from './app.ts'
import type { Gfx } from './gfx.ts'

// ---------- Transform3D ----------

// Transform3D — where a node is in the 3D world. Nested nodes combine their parents' Transform3D (a node without one
// passes its parent's through). Characters and models face +z when rotation.y = 0.
export class Transform3D extends core.Component {
	static __vname = 'render3d.Transform3D'
	static __fields: FieldSpec[] = [
		{ name: 'position', type: 'Vec3' },
		{ name: 'rotation', type: 'Vec3' },
		{ name: 'scale', type: 'Vec3' },
	]
	position = new Vec3()
	// Euler angles in degrees, applied z (roll), then x (pitch), then y (yaw), like Unity.
	rotation = new Vec3()
	scale = new Vec3(1, 1, 1)

	quat(): Quat {
		return Quat.yaw(this.rotation.y).mul(Quat.axis_angle(vec3(1, 0, 0), this.rotation.x)).mul(Quat.axis_angle(vec3(0, 0, 1), this.rotation.z))
	}
	local_matrix(): Mat4 {
		return Mat4.trs(this.position, this.quat(), this.scale)
	}
	world_matrix(): Mat4 {
		return world_matrix(this.node)
	}
	world_position(): Vec3 {
		return world_matrix(this.node).translation_part()
	}
	// forward: the direction the node faces (+z of its rotation), in world space.
	forward(): Vec3 {
		return world_matrix(this.node).axis(2).normalized()
	}
	// face turns the node around y toward a world direction (ignoring its height).
	face(dir: Vec3) {
		if (dir.x * dir.x + dir.z * dir.z < 1e-8) return
		this.rotation.y = (Math.atan2(dir.x, dir.z) * 180) / Math.PI
	}
	// turn_toward eases the yaw toward a direction by at most `deg` degrees.
	turn_toward(dir: Vec3, deg: number) {
		if (dir.x * dir.x + dir.z * dir.z < 1e-8) return
		const want = (Math.atan2(dir.x, dir.z) * 180) / Math.PI
		let d = want - this.rotation.y
		while (d > 180) d -= 360
		while (d < -180) d += 360
		this.rotation.y += d > deg ? deg : d < -deg ? -deg : d
	}
}

// world_matrix: the node's transform in the world (identity for a node with no Transform3D on its path).
export function world_matrix(n: core.Node): Mat4 {
	const m = Mat4.identity()
	const tmp = new Float32Array(16)
	let cur: core.Node | null = n
	while (cur !== null) {
		for (const c of cur.components) {
			if (c instanceof Transform3D) {
				core.mat4_mul_into(tmp, c.local_matrix().m, m.m)
				m.m.set(tmp)
				break
			}
		}
		cur = cur.parent
	}
	return m
}

// transform3d: the node's Transform3D, added if missing.
export function transform3d(n: core.Node): Transform3D {
	const t = n.get_component<Transform3D>(Transform3D)
	if (t !== null) return t
	return n.add_component(Transform3D, new Transform3D())
}

// ---------- Camera ----------

// Camera3D — the eye of the 3D world: the first active one in the tree is used. It looks along -z of its node;
// `target` (a node path from the scene root) makes it look at that node instead.
export class Camera3D extends core.Component {
	static __vname = 'render3d.Camera3D'
	static __fields: FieldSpec[] = [
		{ name: 'fov', type: 'f32' },
		{ name: 'near', type: 'f32' },
		{ name: 'far', type: 'f32' },
		{ name: 'target', type: 'string' },
	]
	fov = 60 // vertical, degrees
	near = 0.1
	far = 400
	target = ''
	// filled by the renderer every frame
	view = Mat4.identity()
	projection = Mat4.identity()
	eye = new Vec3()

	compute(aspect: number) {
		const m = world_matrix(this.node)
		this.eye = m.translation_part()
		let looked = false
		if (this.target !== '' && this.node.scene) {
			const n = this.node.scene.find(this.target)
			if (n !== null) {
				this.view = Mat4.look_at(this.eye, world_matrix(n).translation_part().op_add(vec3(0, 1, 0)), vec3(0, 1, 0))
				looked = true
			}
		}
		if (!looked) this.view = m.inverse()
		this.projection = Mat4.perspective(this.fov, aspect, this.near, this.far)
	}
	// world_to_screen: a world point in 0..1 screen coordinates (x right, y down) and whether it is in front.
	world_to_screen(p: Vec3): [Vec2, boolean] {
		const [ndc, w] = this.projection.op_mul(this.view).project(p)
		return [vec2((ndc.x + 1) / 2, (1 - ndc.y) / 2), w > 0]
	}
	// screen_ray: the ray from the eye through a 0..1 screen point (origin, direction).
	screen_ray(s: Vec2): [Vec3, Vec3] {
		const inv = this.projection.op_mul(this.view).inverse()
		const x = s.x * 2 - 1
		const y = 1 - s.y * 2
		const [near] = inv.project(vec3(x, y, -1))
		const [far] = inv.project(vec3(x, y, 1))
		return [near, far.op_sub(near).normalized()]
	}
}

// ---------- Lights and environment ----------

// DirectionalLight3D — the sun: parallel light from `direction` (the way the light travels).
export class DirectionalLight3D extends core.Component {
	static __vname = 'render3d.DirectionalLight3D'
	static __fields: FieldSpec[] = [
		{ name: 'direction', type: 'Vec3' },
		{ name: 'color', type: 'Color' },
		{ name: 'intensity', type: 'f32' },
	]
	direction = new Vec3(-0.4, -1, -0.3)
	color = rgba(255, 244, 228, 255)
	intensity = 1
}

// PointLight3D — light from the node's position, fading to nothing at `range`. The renderer uses the first 4.
export class PointLight3D extends core.Component {
	static __vname = 'render3d.PointLight3D'
	static __fields: FieldSpec[] = [
		{ name: 'color', type: 'Color' },
		{ name: 'intensity', type: 'f32' },
		{ name: 'range', type: 'f32' },
		{ name: 'flicker', type: 'f32' },
	]
	color = rgba(255, 170, 80, 255)
	intensity = 1.5
	range = 6
	flicker = 0 // 0..1: random flicker of the intensity (fire)
}

// Environment3D — ambient light (sky above, ground below) and distance fog.
export class Environment3D extends core.Component {
	static __vname = 'render3d.Environment3D'
	static __fields: FieldSpec[] = [
		{ name: 'sky', type: 'Color' },
		{ name: 'ground', type: 'Color' },
		{ name: 'ambient', type: 'f32' },
		{ name: 'fog_color', type: 'Color' },
		{ name: 'fog_density', type: 'f32' },
	]
	sky = rgba(150, 170, 210, 255)
	ground = rgba(80, 70, 60, 255)
	ambient = 0.45
	fog_color = rgba(150, 170, 200, 255)
	fog_density = 0.015
}

// ---------- Mesh renderer ----------

// MeshRenderer3D — draws a built-in shape or a model (rigid, rest pose) at the node's Transform3D.
export class MeshRenderer3D extends core.Component {
	static __vname = 'render3d.MeshRenderer3D'
	static __fields: FieldSpec[] = [
		{ name: 'mesh', type: 'string', choices: ['cube', 'sphere', 'cylinder', 'cone', 'capsule', 'plane', 'torus', 'ring', 'disc', 'grid'] },
		{ name: 'model', type: 'asset:model' },
		{ name: 'texture', type: 'asset:texture' },
		{ name: 'pattern', type: 'string', choices: ['none', 'checker', 'grid', 'tiles', 'noise', 'stripes'] },
		{ name: 'color', type: 'Color' },
		{ name: 'emissive', type: 'Color' },
		{ name: 'rim', type: 'f32' },
		{ name: 'blend', type: 'string', choices: ['opaque', 'alpha', 'additive'] },
		{ name: 'unlit', type: 'bool' },
		{ name: 'double_sided', type: 'bool' },
		{ name: 'uv_scale', type: 'Vec2' },
		{ name: 'uv_scroll', type: 'Vec2' },
		{ name: 'grid_cells', type: 'int' },
		{ name: 'shadow', type: 'bool' },
		{ name: 'shadow_size', type: 'f32' },
	]
	mesh = 'cube'
	model = new assets.AssetRef('', assets.Model) // draws the model's meshes instead of `mesh`
	texture = new assets.AssetRef('', assets.Texture)
	pattern = 'none' // a built-in texture
	color = core.white.clone()
	emissive = rgba(0, 0, 0, 255)
	rim = 0
	blend = 'opaque'
	unlit = false
	double_sided = false
	uv_scale = vec2(1, 1)
	uv_scroll = new Vec2() // uv offset per second
	grid_cells = 16
	shadow = false // a soft round shadow on the ground (y = 0) under the node
	shadow_size = 1
	model_data: model3d.Model | null = null
	model_ver = 0
	uv_offset = new Vec2()

	on_load() {
		this.reload_model()
	}
	on_destroy() {
		if (this.model_data !== null) {
			release_model(this.model.id)
			this.model_data = null
		}
	}
	reload_model() {
		if (!this.model.is_set() || !this.node || !this.node.scene) return
		this.model_data = acquire_model(this.node.scene.assets, this.model.id)
	}
	update(dt: number) {
		let ox = this.uv_offset.x + this.uv_scroll.x * dt
		let oy = this.uv_offset.y + this.uv_scroll.y * dt
		this.uv_offset = vec2(ox - Math.trunc(ox), oy - Math.trunc(oy))
		if (this.model.is_set() && this.model_data === null) this.reload_model()
	}
}

// ---------- Skinned model + animator ----------

// SkinnedModel3D — draws an animated model and plays its clips, cross-fading when the clip changes. Its pose is
// updated in `update`, so game code can read bone positions.
export class SkinnedModel3D extends core.Component {
	static __vname = 'render3d.SkinnedModel3D'
	static __fields: FieldSpec[] = [
		{ name: 'model', type: 'asset:model' },
		{ name: 'clip', type: 'string' },
		{ name: 'speed', type: 'f32' },
		{ name: 'playing', type: 'bool' },
		{ name: 'looping', type: 'bool' },
		{ name: 'in_place', type: 'bool' },
		{ name: 'fade', type: 'f32' },
		{ name: 'color', type: 'Color' },
		{ name: 'emissive', type: 'Color' },
		{ name: 'rim', type: 'f32' },
		{ name: 'shadow', type: 'bool' },
		{ name: 'shadow_size', type: 'f32' },
	]
	model = new assets.AssetRef('', assets.Model)
	clip = '' // '' = the model's first clip
	speed = 1
	playing = true
	looping = true
	// keep the root bone over the node (drop the clip's forward/sideways motion) so game code moves the character
	in_place = true
	fade = 0.2 // seconds to blend into a new clip
	color = core.white.clone()
	emissive = rgba(0, 0, 0, 255)
	rim = 0
	shadow = true
	shadow_size = 0.9
	// state
	time = 0
	data: model3d.Model | null = null
	pose = new model3d.Pose()
	globals: Mat4[] = []
	skin: Mat4[] = []
	prev_clip = -1
	prev_time = 0
	fade_left = 0
	cur_clip = -1
	prev_pose = new model3d.Pose()
	flash = 0 // 0..1 white flash (hits), fades out by itself
	flash_rate = 4

	on_load() {
		this.load()
	}
	on_destroy() {
		if (this.data !== null) {
			release_model(this.model.id)
			this.data = null
		}
	}
	load() {
		if (this.data !== null || !this.model.is_set() || !this.node || !this.node.scene) return
		this.data = acquire_model(this.node.scene.assets, this.model.id)
		if (this.data !== null) {
			this.pose = this.data.rest_pose()
			this.cur_clip = this.data.clip_index(this.clip)
			this.evaluate()
		}
	}
	// play switches to clip `name` (blending over `fade` seconds); playing the current clip again does nothing.
	play(name: string) {
		if (this.data === null) {
			this.clip = name
			return
		}
		const ci = this.data.clip_index(name)
		if (ci < 0 || ci === this.cur_clip) return
		this.prev_clip = this.cur_clip
		this.prev_time = this.time
		this.fade_left = this.fade
		this.cur_clip = ci
		this.clip = name
		this.time = 0
		this.playing = true
	}
	clips(): string[] {
		return this.data === null ? [] : this.data.clips.map((c) => c.name)
	}
	hit_flash() {
		this.flash = 1
	}
	update(dt: number) {
		this.load()
		if (this.data === null) return
		if (this.playing) {
			this.time += dt * this.speed
			this.prev_time += dt * this.speed
		}
		if (this.fade_left > 0) this.fade_left -= dt
		if (this.flash > 0) this.flash = Math.max(0, this.flash - dt * this.flash_rate)
		this.evaluate()
	}
	evaluate() {
		const m = this.data!
		if (this.cur_clip < 0) this.cur_clip = m.clip_index(this.clip)
		m.sample(this.cur_clip, this.time, this.looping, this.pose)
		if (this.fade_left > 0 && this.prev_clip >= 0 && this.fade > 0) {
			m.sample(this.prev_clip, this.prev_time, true, this.prev_pose)
			const w = this.fade_left / this.fade // weight of the old clip
			const blended = this.prev_pose.clone()
			blended.blend(this.pose, 1 - w)
			this.pose = blended
		}
		if (this.in_place) {
			for (let i = 0; i < m.bones.length; i++) {
				const b = m.bones[i]
				if (b.parent < 0 && i < this.pose.t.length) {
					const t = this.pose.t[i].clone()
					t.x = b.t.x
					t.z = b.t.z
					this.pose.t[i] = t
				}
			}
		}
		m.globals(this.pose, this.globals)
		m.skin_matrices(this.globals, this.skin)
	}
	// bone_world: where bone `name` is in the world (null if there is no such bone).
	bone_world(name: string): Mat4 | null {
		if (this.data === null) return null
		const i = this.data.bone_index(name)
		if (i < 0 || i >= this.globals.length) return null
		return world_matrix(this.node).op_mul(this.globals[i])
	}
}

// BoneAttach3D — keeps its node at a bone of a SkinnedModel3D on a parent node (weapons, hand effects).
export class BoneAttach3D extends core.Component {
	static __vname = 'render3d.BoneAttach3D'
	static __fields: FieldSpec[] = [
		{ name: 'bone', type: 'string' },
		{ name: 'offset', type: 'Vec3' },
	]
	bone = '' // e.g. "RightHand" (the "mixamorig:" prefix is optional)
	offset = new Vec3()

	update(_dt: number) {
		const parent = this.node.parent
		if (parent === null) return
		const sk = parent.get_component<SkinnedModel3D>(SkinnedModel3D)
		if (sk === null) return
		const m = sk.bone_world(this.bone)
		if (m === null) return
		const local = world_matrix(parent).inverse().op_mul(m)
		transform3d(this.node).position = local.transform_point(this.offset)
	}
}

// ---------- Particles ----------

class Particle3D {
	pos = new Vec3()
	vel = new Vec3()
	age = 0
	life = 1
	size = 1 // size multiplier (random per particle)
	rot = 0 // degrees
	spin = 0
	shade = 0 // 0..1, picks a color between color_start and color_alt
}

const particle_fields: FieldSpec[] = [
	{ name: 'preset', type: 'string', choices: ['none', 'fire', 'smoke', 'sparkle', 'magic', 'dust', 'explosion', 'fireflies', 'portal', 'snow', 'rain', 'heal', 'embers'] },
	{ name: 'emitting', type: 'bool' },
	{ name: 'rate', type: 'f32' },
	{ name: 'burst', type: 'int' },
	{ name: 'lifetime', type: 'f32' },
	{ name: 'lifetime_spread', type: 'f32' },
	{ name: 'speed', type: 'f32' },
	{ name: 'speed_spread', type: 'f32' },
	{ name: 'direction', type: 'Vec3' },
	{ name: 'spread', type: 'f32' },
	{ name: 'gravity', type: 'Vec3' },
	{ name: 'drag', type: 'f32' },
	{ name: 'size_start', type: 'f32' },
	{ name: 'size_end', type: 'f32' },
	{ name: 'size_spread', type: 'f32' },
	{ name: 'color_start', type: 'Color' },
	{ name: 'color_alt', type: 'Color' },
	{ name: 'color_end', type: 'Color' },
	{ name: 'shape', type: 'string', choices: ['soft', 'spark', 'star', 'ring', 'smoke', 'square'] },
	{ name: 'emit_shape', type: 'string', choices: ['point', 'sphere', 'ring', 'box', 'disc'] },
	{ name: 'radius', type: 'f32' },
	{ name: 'box', type: 'Vec3' },
	{ name: 'additive', type: 'bool' },
	{ name: 'spin', type: 'f32' },
	{ name: 'max_particles', type: 'int' },
	{ name: 'local', type: 'bool' },
	{ name: 'offset', type: 'Vec3' },
]

const rnd = () => Math.random()
const rnd_sym = () => Math.random() * 2 - 1

function random_unit(): Vec3 {
	for (;;) {
		const v = vec3(rnd_sym(), rnd_sym(), rnd_sym())
		const l = v.length()
		if (l > 0.001 && l <= 1) return v.mul(1 / l)
	}
}

// Particles3D — camera-facing sprites emitted from the node (fire, smoke, sparks, magic, dust, weather).
// `preset` fills in the look; any field set in the scene (or code) to something other than its default wins.
export class Particles3D extends core.Component {
	static __vname = 'render3d.Particles3D'
	static __fields: FieldSpec[] = particle_fields
	preset = 'none'
	emitting = true
	rate = 20 // particles per second
	burst = 0 // emitted at once when the component starts (and by `emit`)
	lifetime = 1
	lifetime_spread = 0.3
	speed = 1
	speed_spread = 0.3
	direction = new Vec3(0, 1, 0)
	spread = 25 // degrees around `direction` (180 = every way)
	gravity = new Vec3()
	drag = 0
	size_start = 0.3
	size_end = 0
	size_spread = 0.3
	color_start = core.white.clone()
	color_alt = core.white.clone()
	color_end = rgba(255, 255, 255, 0)
	shape = 'soft'
	emit_shape = 'point'
	radius = 0.5
	box = new Vec3(1, 1, 1)
	additive = true
	spin = 0
	max_particles = 400
	local = false // move with the node instead of staying where they were emitted
	offset = new Vec3() // emit from `offset` relative to the node
	particles: Particle3D[] = []
	acc = 0
	applied = false
	origin = Mat4.identity()

	on_load() {
		this.apply_preset()
	}
	start() {
		this.origin = world_matrix(this.node)
		if (this.burst > 0) this.emit(this.burst)
	}
	// emit spawns `n` particles now (explosions, pickups, hits).
	emit(n: number) {
		this.origin = world_matrix(this.node)
		for (let i = 0; i < n; i++) {
			if (this.particles.length >= this.max_particles) break
			this.particles.push(this.new_particle())
		}
	}
	new_particle(): Particle3D {
		let lp: Vec3
		switch (this.emit_shape) {
			case 'sphere':
				lp = random_unit().mul(this.radius * Math.cbrt(rnd()))
				break
			case 'ring': {
				const a = rnd() * 2 * Math.PI
				lp = vec3(Math.sin(a) * this.radius, 0, Math.cos(a) * this.radius)
				break
			}
			case 'disc': {
				const a = rnd() * 2 * Math.PI
				const r = this.radius * Math.sqrt(rnd())
				lp = vec3(Math.sin(a) * r, 0, Math.cos(a) * r)
				break
			}
			case 'box':
				lp = vec3((rnd_sym() * this.box.x) / 2, (rnd_sym() * this.box.y) / 2, (rnd_sym() * this.box.z) / 2)
				break
			default:
				lp = new Vec3()
		}
		lp = lp.op_add(this.offset)
		const d = this.direction.normalized()
		let dir = d
		if (this.spread > 0) {
			const cos_max = Math.cos((Math.min(this.spread, 180) * Math.PI) / 180)
			const z = cos_max + (1 - cos_max) * rnd()
			const a = rnd() * 2 * Math.PI
			const sr = Math.sqrt(Math.max(0, 1 - z * z))
			const up = Math.abs(d.y) < 0.99 ? vec3(0, 1, 0) : vec3(1, 0, 0)
			const t = d.cross(up).normalized()
			const b = d.cross(t)
			dir = t.mul(sr * Math.cos(a)).op_add(b.mul(sr * Math.sin(a))).op_add(d.mul(z))
		}
		const sp = this.speed * (1 + this.speed_spread * rnd_sym())
		const q = new Particle3D()
		q.pos = lp
		q.vel = dir.mul(sp)
		if (!this.local) {
			q.pos = this.origin.transform_point(lp)
			q.vel = this.origin.transform_dir(q.vel)
		}
		q.life = this.lifetime * (1 - this.lifetime_spread * rnd())
		q.size = 1 + this.size_spread * rnd_sym()
		q.rot = rnd() * 360
		q.spin = this.spin * rnd_sym()
		q.shade = rnd()
		return q
	}
	update(dt: number) {
		this.origin = world_matrix(this.node)
		if (this.emitting && this.rate > 0) {
			this.acc += this.rate * dt
			while (this.acc >= 1) {
				this.acc -= 1
				if (this.particles.length < this.max_particles) this.particles.push(this.new_particle())
			}
		}
		const damp = Math.max(0, 1 - this.drag * dt)
		const gx = this.gravity.x * dt, gy = this.gravity.y * dt, gz = this.gravity.z * dt
		let j = 0
		const ps = this.particles
		for (let i = 0; i < ps.length; i++) {
			const q = ps[i]
			q.age += dt
			if (q.age >= q.life) continue
			const v = q.vel
			v.x = (v.x + gx) * damp
			v.y = (v.y + gy) * damp
			v.z = (v.z + gz) * damp
			q.pos.x += v.x * dt
			q.pos.y += v.y * dt
			q.pos.z += v.z * dt
			q.rot += q.spin * dt
			ps[j++] = q
		}
		ps.length = j
	}
	count(): number {
		return this.particles.length
	}
	// apply_preset copies the preset's look into every field still at its default value.
	apply_preset() {
		if (this.applied || this.preset === '' || this.preset === 'none') return
		this.applied = true
		const pre = preset_particles(this.preset)
		if (pre === null) return
		const def = new Particles3D()
		const self = this as any
		for (const f of particle_fields) {
			if (f.name === 'preset') continue
			const cur = self[f.name]
			const d = (def as any)[f.name]
			const same = typeof cur === 'object' ? cur.op_eq(d) : cur === d
			if (same) {
				const p = (pre as any)[f.name]
				self[f.name] = typeof p === 'object' ? p.clone() : p
			}
		}
	}
}

// preset_particles: the look of a named preset (fields at their defaults stay untouched by apply_preset).
export function preset_particles(name: string): Particles3D | null {
	const p = (fields: Partial<Particles3D>) => V.make(Particles3D, fields)
	switch (name) {
		case 'fire':
			return p({ rate: 60, lifetime: 0.9, speed: 1.2, spread: 12, emit_shape: 'disc', radius: 0.18, size_start: 0.55, size_end: 0.05, color_start: rgba(255, 210, 90, 255), color_alt: rgba(255, 120, 30, 255), color_end: rgba(200, 30, 10, 0), gravity: vec3(0, 0.8, 0), spin: 90 })
		case 'smoke':
			return p({ rate: 12, lifetime: 2.5, speed: 0.8, spread: 15, size_start: 0.4, size_end: 1.6, shape: 'smoke', additive: false, color_start: rgba(90, 90, 95, 150), color_alt: rgba(60, 60, 65, 150), color_end: rgba(140, 140, 150, 0), drag: 0.5, spin: 40 })
		case 'sparkle':
			return p({ rate: 25, lifetime: 0.8, speed: 0.6, spread: 180, emit_shape: 'sphere', radius: 0.4, size_start: 0.25, size_end: 0, shape: 'star', color_start: rgba(255, 250, 200, 255), color_alt: rgba(255, 220, 90, 255), color_end: rgba(255, 200, 60, 0), spin: 180 })
		case 'magic':
			return p({ rate: 50, lifetime: 1.4, speed: 0.5, spread: 30, emit_shape: 'ring', radius: 0.7, size_start: 0.22, size_end: 0, shape: 'spark', color_start: rgba(120, 200, 255, 255), color_alt: rgba(200, 120, 255, 255), color_end: rgba(80, 60, 255, 0), gravity: vec3(0, 0.6, 0) })
		case 'dust':
			return p({ rate: 0, lifetime: 0.7, speed: 0.8, spread: 70, size_start: 0.25, size_end: 0.7, shape: 'smoke', additive: false, color_start: rgba(190, 170, 140, 150), color_alt: rgba(160, 140, 110, 150), color_end: rgba(200, 185, 160, 0), drag: 3, gravity: vec3(0, -0.5, 0) })
		case 'explosion':
			return p({ rate: 0, burst: 80, emitting: false, lifetime: 0.9, speed: 6, speed_spread: 0.6, spread: 180, size_start: 0.6, size_end: 0.05, shape: 'spark', color_start: rgba(255, 230, 140, 255), color_alt: rgba(255, 110, 30, 255), color_end: rgba(120, 20, 0, 0), drag: 2.5, gravity: vec3(0, -4, 0), max_particles: 200 })
		case 'fireflies':
			return p({ rate: 6, lifetime: 5, speed: 0.3, spread: 180, emit_shape: 'box', box: vec3(16, 2, 16), offset: vec3(0, 1.2, 0), size_start: 0.12, size_end: 0.12, shape: 'spark', color_start: rgba(210, 255, 120, 255), color_alt: rgba(255, 240, 120, 255), color_end: rgba(160, 255, 80, 0) })
		case 'portal':
			return p({ rate: 70, lifetime: 1.2, speed: 0.2, spread: 180, emit_shape: 'ring', radius: 1.1, size_start: 0.2, size_end: 0, shape: 'spark', color_start: rgba(255, 120, 230, 255), color_alt: rgba(140, 90, 255, 255), color_end: rgba(60, 40, 200, 0), gravity: vec3(0, 1.2, 0), local: true })
		case 'snow':
			return p({ rate: 40, lifetime: 6, speed: 0.4, spread: 20, direction: vec3(0, -1, 0), emit_shape: 'box', box: vec3(30, 0.5, 30), offset: vec3(0, 10, 0), size_start: 0.08, size_end: 0.08, additive: false, color_start: rgba(255, 255, 255, 230), color_alt: rgba(230, 240, 255, 230), color_end: rgba(255, 255, 255, 0), gravity: vec3(0, -0.6, 0), max_particles: 600 })
		case 'rain':
			return p({ rate: 300, lifetime: 0.8, speed: 14, spread: 2, direction: vec3(0.1, -1, 0), emit_shape: 'box', box: vec3(30, 0.5, 30), offset: vec3(0, 10, 0), size_start: 0.05, size_end: 0.05, shape: 'square', additive: false, color_start: rgba(170, 190, 230, 170), color_alt: rgba(150, 170, 210, 170), color_end: rgba(170, 190, 230, 0), max_particles: 1200 })
		case 'heal':
			return p({ rate: 30, lifetime: 1.2, speed: 1, spread: 10, emit_shape: 'disc', radius: 0.6, size_start: 0.25, size_end: 0, shape: 'star', color_start: rgba(150, 255, 160, 255), color_alt: rgba(230, 255, 140, 255), color_end: rgba(60, 255, 120, 0) })
		case 'embers':
			return p({ rate: 14, lifetime: 2, speed: 1.4, spread: 25, emit_shape: 'disc', radius: 0.25, size_start: 0.08, size_end: 0, shape: 'spark', color_start: rgba(255, 200, 80, 255), color_alt: rgba(255, 120, 40, 255), color_end: rgba(255, 60, 0, 0), gravity: vec3(0, 0.3, 0), drag: 0.4 })
	}
	return null
}

// ---------- Trail ----------

interface TrailPoint {
	pos: Vec3
	age: number
}

// Trail3D — a glowing ribbon left behind the node as it moves (dashes, swords, magic missiles).
export class Trail3D extends core.Component {
	static __vname = 'render3d.Trail3D'
	static __fields: FieldSpec[] = [
		{ name: 'duration', type: 'f32' },
		{ name: 'width', type: 'f32' },
		{ name: 'color', type: 'Color' },
		{ name: 'color_end', type: 'Color' },
		{ name: 'offset', type: 'Vec3' },
		{ name: 'min_distance', type: 'f32' },
		{ name: 'additive', type: 'bool' },
		{ name: 'emitting', type: 'bool' },
	]
	duration = 0.4 // seconds a point stays
	width = 0.35
	color = rgba(120, 200, 255, 220)
	color_end = rgba(120, 80, 255, 0)
	offset = new Vec3() // emit point relative to the node
	min_distance = 0.05
	additive = true
	emitting = true
	points: TrailPoint[] = []

	update(dt: number) {
		let j = 0
		for (let i = 0; i < this.points.length; i++) {
			const q = this.points[i]
			q.age += dt
			if (q.age < this.duration) this.points[j++] = q
		}
		this.points.length = j
		if (!this.emitting) return
		const p = world_matrix(this.node).transform_point(this.offset)
		if (this.points.length === 0 || this.points[this.points.length - 1].pos.distance(p) >= this.min_distance) this.points.push({ pos: p, age: 0 })
	}
}

// ---------- Model cache (render3d/cache.v) ----------

interface CachedModel {
	model: model3d.Model | null
	refs: number
	path: string
}

const model_cache = new Map<string, CachedModel>()

// acquire_model returns the model asset parsed at preload (null if it cannot be read; the error is printed once).
function acquire_model(db: assets.AssetDatabase, id: string): model3d.Model | null {
	const key = db.resolve(id) ?? id
	const cm = model_cache.get(key)
	if (cm) {
		cm.refs++
		return cm.model
	}
	let m: model3d.Model | null = null
	let path = ''
	try {
		const a = db.load<assets.Model>(assets.Model, key)
		path = a.path
		m = model3d.load_fbx(a.path)
		console.log(`[render3d] loaded ${a.path.slice(a.path.lastIndexOf('/') + 1)}: ${m.triangle_count()} triangles, ${m.bones.length} bones, ${m.clips.length} clips`)
	} catch (e) {
		console.error(`[render3d] model ${id}: ${V.as_error(e).message}`)
	}
	model_cache.set(key, { model: m, refs: 1, path })
	return m
}

function release_model(id: string) {
	for (const [key, cm] of model_cache) {
		if (key === id || cm.path.endsWith(id)) {
			cm.refs--
			return
		}
	}
}

// preload_model: kept for API compatibility (models are parsed before the game starts in the browser).
export function preload_model(db: assets.AssetDatabase, key: string): boolean {
	return acquire_model(db, key) !== null
}

// Before the game starts: parse every model asset (zlib needs the browser's asynchronous inflate) and decode its
// textures, embedded ones or image assets next to the model.
assets.preload_hooks.push(async (db: assets.AssetDatabase) => {
	for (const e of db.all()) {
		if (e.kind !== 'model') continue
		const bytes = db.data.bytes.get(e.id)
		if (!bytes) continue
		const path = db.abs_path(e)
		await model3d.parse_model_asset(path, bytes)
		let m: model3d.Model
		try {
			m = model3d.load_fbx(path)
		} catch {
			continue
		}
		const dir = e.path.includes('/') ? e.path.slice(0, e.path.lastIndexOf('/') + 1) : ''
		for (const img of m.textures) {
			if (img.bitmap !== null || img.file === '') continue
			const name = img.file.replace(/\\/g, '/').split('/').pop()!
			const id = db.id_of(dir + name) ?? db.id_of(img.file)
			const bmp = id === null ? undefined : db.data.images.get(id)
			if (bmp) img.bitmap = bmp as ImageBitmap
		}
	}
})

// ---------- Shaders (render3d/shaders.v) ----------

export const max_bones = 64
export const max_point_lights = 4

const vs_bones = 8 // 3 vec4 slots per bone (rows of a 3x4 matrix)
const vs_static_slots = 8
const vs_skinned_slots = 8 + 3 * max_bones

const fs_sun_dir = 0
const fs_sun_color = 1
const fs_sky = 2
const fs_ground = 3
const fs_tint = 4
const fs_emissive = 5
const fs_camera = 6
const fs_fog = 7
const fs_uv = 8
const fs_points = 9
const fs_slots = 9 + 2 * max_point_lights

const glsl_header = '#version 300 es\nprecision highp float;\nprecision highp int;\n'

function mesh_vs(skinned: boolean): string {
	const slots = skinned ? vs_skinned_slots : vs_static_slots
	const skin = skinned
		? `
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
`
		: `
	vec3 pos = position;
	vec3 nrm = normal;
`
	return (
		glsl_header +
		`uniform vec4 vs_params[${slots}];
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
`
	)
}

const light_body = `
	vec4 base = T * P[${fs_tint}];
	vec3 col;
	if (P[${fs_fog}].w > 0.5) {
		col = base.rgb + P[${fs_emissive}].rgb;
	} else {
		vec3 n = normalize(N);
		vec3 v = normalize(P[${fs_camera}].xyz - W);
		vec3 l = normalize(P[${fs_sun_dir}].xyz);
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
`

function mesh_fs(): string {
	const body = light_body.replace(/P\[/g, 'fs_params[')
	return (
		glsl_header +
		`uniform vec4 fs_params[${fs_slots}];
uniform sampler2D tex_smp;
in vec3 v_world;
in vec3 v_normal;
in vec2 v_uv;
layout(location = 0) out vec4 frag_color;
void main() {
	vec3 W = v_world;
	vec3 N = v_normal;
	vec4 T = texture(tex_smp, v_uv * fs_params[${fs_uv}].xy + fs_params[${fs_uv}].zw);
${body}
	frag_color = vec4(col, base.a);
}
`
	)
}

const billboard_vs =
	glsl_header +
	`uniform vec4 vs_params[4];
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
`

const billboard_fs =
	glsl_header +
	`uniform sampler2D tex_smp;
in vec2 v_uv;
in vec4 v_color;
layout(location = 0) out vec4 frag_color;
void main() {
	frag_color = texture(tex_smp, v_uv) * v_color;
}
`

// to_glsl100 rewrites the GLSL ES 3.0 shaders above for WebGL 1.
function to_glsl100(src: string, vertex: boolean): string {
	let s = src.replace('#version 300 es\n', '')
	s = s.replace(/layout\(location = \d+\) in /g, 'attribute ')
	if (vertex) {
		s = s.replace(/^out /gm, 'varying ')
	} else {
		s = s.replace(/^in /gm, 'varying ')
		s = s.replace(/layout\(location = 0\) out vec4 frag_color;\n/, '')
		s = s.replace(/frag_color/g, 'gl_FragColor')
		s = s.replace(/texture\(/g, 'texture2D(')
	}
	return s
}

// ---------- GPU objects (render3d/gpu.v) ----------

type Blend = 'opaque' | 'alpha' | 'additive'

function blend_from(s: string): Blend {
	return s === 'alpha' || s === 'additive' ? s : 'opaque'
}

interface Program {
	prog: WebGLProgram
	vs_params: WebGLUniformLocation | null
	fs_params: WebGLUniformLocation | null
}

interface GpuMesh {
	vbuf: WebGLBuffer
	ibuf: WebGLBuffer
	count: number
	index_type: number
	skinned: boolean
}

const max_billboards = 16384
const BB_FLOATS = 6 // x y z u v rgba8 per vertex (24 bytes)

class Gpu {
	gl: WebGLRenderingContext
	webgl2: boolean
	ok = false
	failed = false
	mesh_prog: Program | null = null
	skin_prog: Program | null = null
	bb_prog: Program | null = null
	meshes = new Map<string, GpuMesh>()
	textures = new Map<string, WebGLTexture | null>() // null: cannot be made (not retried)
	white: WebGLTexture | null = null
	bb_vbuf: WebGLBuffer | null = null
	bb_ibuf: WebGLBuffer | null = null
	uint32_ok = false

	constructor(gl: WebGLRenderingContext) {
		this.gl = gl
		this.webgl2 = typeof WebGL2RenderingContext !== 'undefined' && gl instanceof WebGL2RenderingContext
	}

	init(): boolean {
		if (this.ok || this.failed) return this.ok
		const gl = this.gl
		this.uint32_ok = this.webgl2 || gl.getExtension('OES_element_index_uint') !== null
		try {
			const mesh_attrs = ['position', 'normal', 'uv', 'joints', 'weights']
			this.mesh_prog = this.program(mesh_vs(false), mesh_fs(), mesh_attrs, 'mesh')
			this.skin_prog = this.program(mesh_vs(true), mesh_fs(), mesh_attrs, 'skinned')
			this.bb_prog = this.program(billboard_vs, billboard_fs, ['position', 'uv', 'color'], 'billboard')
		} catch (e) {
			console.error(`[render3d] ${V.as_error(e).message}`)
			this.failed = true
			return false
		}
		this.white = this.make_texture(new Uint8Array([255, 255, 255, 255]), 1, 1, false)
		this.bb_vbuf = gl.createBuffer()
		const idx = new Uint16Array(max_billboards * 6)
		for (let q = 0; q < max_billboards; q++) {
			const b = q * 4
			idx.set([b, b + 1, b + 2, b, b + 2, b + 3], q * 6)
		}
		this.bb_ibuf = gl.createBuffer()
		gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.bb_ibuf)
		gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, idx, gl.STATIC_DRAW)
		this.ok = true
		return true
	}

	program(vs: string, fs: string, attrs: string[], label: string): Program {
		const gl = this.gl
		const compile = (type: number, src: string) => {
			const sh = gl.createShader(type)!
			gl.shaderSource(sh, this.webgl2 ? src : to_glsl100(src, type === gl.VERTEX_SHADER))
			gl.compileShader(sh)
			if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) throw new Error(`${label} shader does not compile: ${gl.getShaderInfoLog(sh)}`)
			return sh
		}
		const prog = gl.createProgram()!
		gl.attachShader(prog, compile(gl.VERTEX_SHADER, vs))
		gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, fs))
		attrs.forEach((a, i) => gl.bindAttribLocation(prog, i, a))
		gl.linkProgram(prog)
		if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(`${label} shader does not link: ${gl.getProgramInfoLog(prog)}`)
		gl.useProgram(prog)
		gl.uniform1i(gl.getUniformLocation(prog, 'tex_smp'), 0)
		return { prog, vs_params: gl.getUniformLocation(prog, 'vs_params'), fs_params: gl.getUniformLocation(prog, 'fs_params') }
	}

	make_texture(src: Uint8Array | TexImageSource, w: number, h: number, repeat: boolean): WebGLTexture {
		const gl = this.gl
		const tex = gl.createTexture()!
		gl.bindTexture(gl.TEXTURE_2D, tex)
		gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false)
		if (src instanceof Uint8Array) gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, src)
		else gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, src)
		const pot = (w & (w - 1)) === 0 && (h & (h - 1)) === 0
		const wrap = repeat && (this.webgl2 || pot) ? gl.REPEAT : gl.CLAMP_TO_EDGE
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrap)
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wrap)
		return tex
	}

	// texture_from_image uploads a decoded image once under `key`.
	texture_from_image(key: string, img: (TexImageSource & { width: number; height: number }) | null | undefined): WebGLTexture | null {
		const t = this.textures.get(key)
		if (t !== undefined) return t
		const tex = img ? this.make_texture(img, img.width, img.height, true) : null
		this.textures.set(key, tex)
		return tex
	}

	pattern(name: string): WebGLTexture {
		if (name === '' || name === 'none') return this.white!
		const key = `pattern:${name}`
		let t = this.textures.get(key)
		if (!t) {
			const [px, s] = pattern_pixels(name)
			t = this.make_texture(px, s, s, true)
			this.textures.set(key, t)
		}
		return t
	}

	shape(name: string): WebGLTexture {
		if (name === 'white') return this.white!
		const key = `shape:${name}`
		let t = this.textures.get(key)
		if (!t) {
			const [px, s] = shape_pixels(name)
			t = this.make_texture(px, s, s, false)
			this.textures.set(key, t)
		}
		return t
	}

	// mesh_for uploads `m` once under `key`.
	mesh_for(key: string, m: model3d.MeshData): GpuMesh | null {
		const cached = this.meshes.get(key)
		if (cached) return cached
		const gl = this.gl
		const n = m.vertex_count()
		const skinned = m.is_skinned()
		const has_uv = m.uvs.length >= n * 2
		const has_n = m.normals.length >= n * 3
		const v = new Float32Array(n * 16)
		for (let i = 0; i < n; i++) {
			const o = i * 16
			v[o] = m.positions[i * 3]
			v[o + 1] = m.positions[i * 3 + 1]
			v[o + 2] = m.positions[i * 3 + 2]
			if (has_n) {
				v[o + 3] = m.normals[i * 3]
				v[o + 4] = m.normals[i * 3 + 1]
				v[o + 5] = m.normals[i * 3 + 2]
			} else {
				v[o + 4] = 1
			}
			if (has_uv) {
				v[o + 6] = m.uvs[i * 2]
				v[o + 7] = m.uvs[i * 2 + 1]
			}
			if (skinned) {
				for (let k = 0; k < 4; k++) {
					v[o + 8 + k] = m.joints[i * 4 + k]
					v[o + 12 + k] = m.weights[i * 4 + k]
				}
			} else {
				v[o + 12] = 1
			}
		}
		const small = n <= 65536
		if (!small && !this.uint32_ok) {
			console.error(`[render3d] mesh ${m.name}: ${n} vertices need 32-bit indices, which this browser lacks`)
			return null
		}
		const vbuf = gl.createBuffer()!
		gl.bindBuffer(gl.ARRAY_BUFFER, vbuf)
		gl.bufferData(gl.ARRAY_BUFFER, v, gl.STATIC_DRAW)
		const ibuf = gl.createBuffer()!
		gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibuf)
		gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, small ? new Uint16Array(m.indices) : new Uint32Array(m.indices), gl.STATIC_DRAW)
		const gm: GpuMesh = { vbuf, ibuf, count: m.indices.length, index_type: small ? gl.UNSIGNED_SHORT : gl.UNSIGNED_INT, skinned }
		this.meshes.set(key, gm)
		return gm
	}
}

// ---------- Procedural textures (patterns and particle shapes) ----------

export const patterns = ['none', 'checker', 'grid', 'tiles', 'noise', 'stripes']
export const particle_shapes = ['soft', 'spark', 'star', 'ring', 'smoke', 'square']

function hash2(x: number, y: number): number {
	let h = (Math.imul(x >>> 0, 374761393) + Math.imul(y >>> 0, 668265263)) >>> 0
	h = Math.imul((h ^ (h >>> 13)) >>> 0, 1274126177) >>> 0
	return ((h ^ (h >>> 16)) >>> 0) / 4294967295
}

// pattern_pixels: a 64x64 tileable grayscale-ish pattern (multiplied with the material color).
function pattern_pixels(name: string): [Uint8Array, number] {
	const s = 64
	const px = new Uint8Array(s * s * 4)
	for (let y = 0; y < s; y++) {
		for (let x = 0; x < s; x++) {
			let v = 1
			switch (name) {
				case 'checker':
					v = (Math.trunc(x / 32) + Math.trunc(y / 32)) % 2 === 0 ? 1 : 0.72
					break
				case 'grid':
					v = x % 32 < 2 || y % 32 < 2 ? 0.55 : 1
					break
				case 'tiles': {
					const row = Math.trunc(y / 16)
					const xx = x + (row % 2 === 1 ? 16 : 0)
					v = y % 16 < 2 || xx % 32 < 2 ? 0.6 : 0.9 + 0.1 * hash2(Math.trunc(xx / 32), row)
					break
				}
				case 'noise': {
					let acc = 0
					for (const o of [8, 16]) {
						const cell = s / o
						const cx = Math.trunc(x / cell)
						const cy = Math.trunc(y / cell)
						const fx = (x % cell) / cell
						const fy = (y % cell) / cell
						const a = hash2(cx % o, cy % o)
						const b = hash2((cx + 1) % o, cy % o)
						const c = hash2(cx % o, (cy + 1) % o)
						const d = hash2((cx + 1) % o, (cy + 1) % o)
						const sx = fx * fx * (3 - 2 * fx)
						const sy = fy * fy * (3 - 2 * fy)
						acc += (a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy) * (o === 8 ? 0.65 : 0.35)
					}
					v = 0.75 + 0.25 * acc
					break
				}
				case 'stripes':
					v = (x + y) % 32 < 16 ? 1 : 0.75
					break
			}
			const c = Math.trunc(Math.min(v * 255, 255))
			const i = (y * s + x) * 4
			px[i] = px[i + 1] = px[i + 2] = c
			px[i + 3] = 255
		}
	}
	return [px, s]
}

// shape_pixels: a 64x64 white particle sprite with alpha.
function shape_pixels(name: string): [Uint8Array, number] {
	const s = 64
	const px = new Uint8Array(s * s * 4)
	for (let y = 0; y < s; y++) {
		for (let x = 0; x < s; x++) {
			const dx = ((x + 0.5) / s) * 2 - 1
			const dy = ((y + 0.5) / s) * 2 - 1
			const r = Math.sqrt(dx * dx + dy * dy)
			let a = 0
			switch (name) {
				case 'spark':
					a = Math.max(0, 1 - r) * Math.max(0, 1 - r)
					a = Math.min(1, a * 1.5 + Math.max(0, 1 - r * 4))
					break
				case 'star': {
					const arms = Math.max(0, 1 - Math.abs(dx) * 8) * Math.max(0, 1 - Math.abs(dy)) + Math.max(0, 1 - Math.abs(dy) * 8) * Math.max(0, 1 - Math.abs(dx))
					a = Math.min(1, arms + Math.max(0, 1 - r * 3))
					break
				}
				case 'ring':
					a = Math.max(0, 1 - Math.abs(r - 0.75) * 8)
					break
				case 'smoke': {
					const n = hash2(Math.trunc(x / 8), Math.trunc(y / 8)) * 0.35 + 0.65
					a = Math.max(0, 1 - r) * n
					a = a * a
					break
				}
				case 'square':
					a = Math.abs(dx) < 0.9 && Math.abs(dy) < 0.9 ? 1 : 0
					break
				default:
					a = Math.max(0, 1 - r)
					a = a * a * (3 - 2 * a)
			}
			const i = (y * s + x) * 4
			px[i] = px[i + 1] = px[i + 2] = 255
			px[i + 3] = Math.trunc(Math.min(a * 255, 255))
		}
	}
	return [px, s]
}

function pack_color(c: Color): number {
	return ((c.r & 255) | ((c.g & 255) << 8) | ((c.b & 255) << 16) | ((c.a & 255) << 24)) >>> 0
}

function lerp_color(a: Color, b: Color, t: number): Color {
	return a.lerp(b, t < 0 ? 0 : t > 1 ? 1 : t)
}

// ---------- Renderer (render3d/renderer.v) ----------

type ItemKind = 'mesh' | 'skinned' | 'particles' | 'trail'

interface DrawItem {
	kind: ItemKind
	node: core.Node
	world: Mat4
	comp: core.Component
	blend: Blend
	dist: number
}

class Lights {
	env = new Environment3D()
	sun = V.make(DirectionalLight3D, { intensity: 0 })
	has_sun = false
	points: number[] = []
}

// Renderer3D draws the 3D components of a scene into the canvas. velo.app calls it between the 2D world and the
// 2D HUD (see install), so 2D sprites outside a Canvas are a backdrop and Canvas nodes (UI) draw on top.
export class Renderer3D {
	static __vname = 'render3d.Renderer3D'
	gpu: Gpu | null = null
	db: assets.AssetDatabase
	items: DrawItem[] = []
	bb = new Map<string, number[]>() // billboard groups: '<image key>|<blend>' -> vertex floats (x y z u v color)
	order: string[] = []
	fs = new Float32Array(fs_slots * 4)
	vs = new Float32Array(vs_skinned_slots * 4)
	bb_data = new ArrayBuffer(max_billboards * 4 * BB_FLOATS * 4)
	bb_f32 = new Float32Array(this.bb_data)
	bb_u32 = new Uint32Array(this.bb_data)
	vp = Mat4.identity()
	cam: Camera3D | null = null
	right = new Vec3()
	up = new Vec3()
	time = 0
	draw_calls = 0
	triangles = 0
	// background drawn by the 3D pass: clear to the fog color instead of the app's background
	clear_to_fog = true

	constructor(db: assets.AssetDatabase) {
		this.db = db
	}

	// draw renders the scene's 3D world into the canvas (`width` x `height` pixels).
	draw(gfx: Gfx, scene: core.Scene, width: number, height: number) {
		this.draw_calls = 0
		this.triangles = 0
		if (!scene || width <= 0 || height <= 0) return
		this.items.length = 0
		this.cam = null
		const fr = new Lights()
		this.collect(scene.root, fr)
		const cam = this.cam as Camera3D | null
		if (cam === null) return
		if (this.gpu === null) this.gpu = new Gpu(gfx.gl)
		const gpu = this.gpu
		if (!gpu.init()) return
		const gl = gfx.gl
		this.time = scene.time
		cam.compute(width / height)
		this.vp = cam.projection.op_mul(cam.view)
		for (const it of this.items) it.dist = it.world.translation_part().distance(cam.eye)
		const inv = cam.view.inverse()
		this.right = inv.axis(0).normalized()
		this.up = inv.axis(1).normalized()
		// GL state for the 3D pass (restored for the 2D batcher by gfx.restore_state)
		gl.viewport(0, 0, width, height)
		gl.disable(gl.SCISSOR_TEST)
		gl.enable(gl.DEPTH_TEST)
		gl.depthFunc(gl.LEQUAL)
		gl.depthMask(true)
		gl.clear(gl.DEPTH_BUFFER_BIT)
		gl.frontFace(gl.CCW)
		gl.cullFace(gl.BACK)
		gl.activeTexture(gl.TEXTURE0)
		try {
			if (this.clear_to_fog) this.draw_background(fr.env)
			this.setup_fs(fr.env, fr.sun, fr.has_sun, fr.points)
			// opaque first, then the blob shadows, then transparent things far to near
			for (const it of this.items) if (it.blend === 'opaque' && (it.kind === 'mesh' || it.kind === 'skinned')) this.draw_item(it)
			this.bb.clear()
			this.order.length = 0
			for (const it of this.items) this.add_shadow(it)
			this.flush_billboards()
			const trans = this.items.filter((it) => it.blend !== 'opaque' || it.kind === 'particles' || it.kind === 'trail')
			trans.sort((a, b) => b.dist - a.dist)
			for (const it of trans) {
				switch (it.kind) {
					case 'mesh':
					case 'skinned':
						this.flush_billboards()
						this.draw_item(it)
						break
					case 'particles':
						this.add_particles(it)
						break
					case 'trail':
						this.add_trail(it)
						break
				}
			}
			this.flush_billboards()
		} finally {
			gl.disable(gl.DEPTH_TEST)
			gl.depthMask(true)
			gl.disable(gl.CULL_FACE)
			gfx.restore_state()
		}
	}

	collect(n: core.Node, fr: Lights) {
		if (!n.active || n.destroyed) return
		const world = n.components.length > 0 ? world_matrix(n) : Mat4.identity()
		for (const c of n.components) {
			if (!c.enabled) continue
			if (c instanceof Environment3D) {
				fr.env = c
			} else if (c instanceof DirectionalLight3D) {
				if (!fr.has_sun) {
					fr.sun = c
					fr.has_sun = true
				}
			} else if (c instanceof PointLight3D) {
				if (fr.points.length < max_point_lights * 8) {
					const p = world.translation_part()
					const f = c.flicker > 0 ? 1 - c.flicker * Math.random() * 0.5 : 1
					const k = (c.intensity * f) / 255
					fr.points.push(p.x, p.y, p.z, c.range, c.color.r * k, c.color.g * k, c.color.b * k, 0)
				}
			} else if (c instanceof Camera3D) {
				if (this.cam === null) this.cam = c
			} else if (c instanceof MeshRenderer3D) {
				this.add_item('mesh', blend_from(c.blend), n, c, world)
			} else if (c instanceof SkinnedModel3D) {
				this.add_item('skinned', 'opaque', n, c, world)
			} else if (c instanceof Particles3D) {
				this.add_item('particles', c.additive ? 'additive' : 'alpha', n, c, world)
			} else if (c instanceof Trail3D) {
				this.add_item('trail', c.additive ? 'additive' : 'alpha', n, c, world)
			}
		}
		for (const ch of n.children) this.collect(ch, fr)
	}

	add_item(kind: ItemKind, blend: Blend, node: core.Node, comp: core.Component, world: Mat4) {
		this.items.push({ kind, node, world, comp, blend, dist: 0 })
	}

	set_fs(slot: number, a: number, b: number, c: number, d: number) {
		const o = slot * 4
		this.fs[o] = a
		this.fs[o + 1] = b
		this.fs[o + 2] = c
		this.fs[o + 3] = d
	}

	set_fs_color(slot: number, c: Color, k: number) {
		this.set_fs(slot, (c.r / 255) * k, (c.g / 255) * k, (c.b / 255) * k, c.a / 255)
	}

	setup_fs(env: Environment3D, sun: DirectionalLight3D, has_sun: boolean, points: number[]) {
		this.fs.fill(0)
		const d = sun.direction.normalized().neg()
		this.set_fs(fs_sun_dir, d.x, d.y, d.z, 0)
		this.set_fs_color(fs_sun_color, sun.color, has_sun ? sun.intensity : 0)
		this.set_fs_color(fs_sky, env.sky, env.ambient)
		this.set_fs_color(fs_ground, env.ground, env.ambient)
		const eye = this.cam!.eye
		this.set_fs(fs_camera, eye.x, eye.y, eye.z, env.fog_density)
		const fog = env.fog_color
		this.set_fs(fs_fog, fog.r / 255, fog.g / 255, fog.b / 255, 0)
		for (let i = 0; i < points.length; i++) this.fs[fs_points * 4 + i] = points[i]
	}

	// draw_background: a vertical gradient from the fog color (horizon) to a deeper sky color, behind everything.
	draw_background(env: Environment3D) {
		const fog = env.fog_color
		const top = rgba(Math.trunc(fog.r * 0.62), Math.trunc(fog.g * 0.66), Math.trunc(fog.b * 0.82), 255)
		const z = 0.99999
		const ct = pack_color(top)
		const cf = pack_color(rgba(fog.r, fog.g, fog.b, 255))
		const verts = [-1, 1, z, 0, 0, ct, -1, -1, z, 0, 1, cf, 1, -1, z, 1, 1, cf, 1, 1, z, 1, 0, ct]
		this.draw_bb_vertices(verts, this.gpu!.white!, 'opaque', Mat4.identity())
	}

	// ---------- Meshes ----------

	draw_item(it: DrawItem) {
		if (it.kind === 'mesh') this.draw_mesh_renderer(it.comp as MeshRenderer3D, it.world)
		else if (it.kind === 'skinned') this.draw_skinned(it.comp as SkinnedModel3D, it.world)
	}

	texture_image(ref: assets.AssetRef): WebGLTexture | null {
		if (!ref.is_set()) return null
		const id = this.db.resolve(ref.id) ?? ref.id
		const key = `asset:${id}`
		const gpu = this.gpu!
		if (gpu.textures.has(key)) return gpu.textures.get(key)!
		const img = this.db.data.images.get(id)
		return gpu.texture_from_image(key, img)
	}

	model_texture(m: model3d.Model, key: string, i: number): WebGLTexture | null {
		if (i < 0 || i >= m.textures.length) return null
		return this.gpu!.texture_from_image(`${key}:tex${i}`, m.textures[i].bitmap)
	}

	draw_mesh_renderer(c: MeshRenderer3D, world: Mat4) {
		const gpu = this.gpu!
		const blend = blend_from(c.blend)
		const ck = 1 / 255
		this.set_fs(fs_emissive, c.emissive.r * ck, c.emissive.g * ck, c.emissive.b * ck, c.rim)
		this.set_fs(fs_uv, c.uv_scale.x, c.uv_scale.y, c.uv_offset.x, c.uv_offset.y)
		this.fs[fs_fog * 4 + 3] = c.unlit ? 1 : 0
		const user_tex = this.texture_image(c.texture) ?? gpu.pattern(c.pattern)
		const tint = c.color
		if (c.model_data !== null) {
			const m = c.model_data
			const key = model_key(m)
			for (let i = 0; i < m.meshes.length; i++) {
				const me = m.meshes[i]
				const gm = gpu.mesh_for(`${key}:${i}`, me)
				if (gm === null) continue
				const img = c.texture.is_set() ? user_tex : this.model_texture(m, key, me.texture) ?? user_tex
				const mc = me.color
				this.set_fs(fs_tint, (tint.r / 255) * (mc.r / 255), (tint.g / 255) * (mc.g / 255), (tint.b / 255) * (mc.b / 255), tint.a / 255)
				this.draw_gpu_mesh(gm, img, world, blend, !c.double_sided, null)
			}
		} else {
			let key = `prim:${c.mesh}`
			let gm = gpu.meshes.get(key) ?? null
			if (gm === null) {
				let md: model3d.MeshData | null
				if (c.mesh === 'grid') {
					const cells = c.grid_cells > 0 ? c.grid_cells : 1
					key = `prim:grid:${cells}`
					gm = gpu.meshes.get(key) ?? null
					md = gm === null ? model3d.grid(1, cells) : null
				} else {
					md = model3d.primitive(c.mesh)
				}
				if (gm === null) {
					if (md === null) return
					gm = gpu.mesh_for(key, md)
				}
			}
			if (gm === null) return
			this.set_fs_color(fs_tint, tint, 1)
			const flat = c.mesh === 'plane' || c.mesh === 'grid' || c.mesh === 'disc'
			this.draw_gpu_mesh(gm, user_tex, world, blend, !c.double_sided && !flat, null)
		}
		this.fs[fs_fog * 4 + 3] = 0
	}

	draw_skinned(s: SkinnedModel3D, world: Mat4) {
		if (s.data === null) return
		const gpu = this.gpu!
		const m = s.data
		const key = model_key(m)
		const ck = 1 / 255
		const em = s.emissive
		this.set_fs(fs_emissive, em.r * ck + s.flash, em.g * ck + s.flash, em.b * ck + s.flash, s.rim)
		this.set_fs(fs_uv, 1, 1, 0, 0)
		const tint = s.color
		for (let i = 0; i < m.meshes.length; i++) {
			const me = m.meshes[i]
			const gm = gpu.mesh_for(`${key}:${i}`, me)
			if (gm === null) continue
			const img = this.model_texture(m, key, me.texture) ?? gpu.white!
			const mc = me.color
			this.set_fs(fs_tint, (tint.r / 255) * (mc.r / 255), (tint.g / 255) * (mc.g / 255), (tint.b / 255) * (mc.b / 255), tint.a / 255)
			this.draw_gpu_mesh(gm, img, world, 'opaque', false, gm.skinned ? s.skin : null)
		}
	}

	apply_blend(gl: WebGLRenderingContext, blend: Blend) {
		gl.depthMask(blend === 'opaque')
		if (blend === 'opaque') {
			gl.disable(gl.BLEND)
		} else if (blend === 'alpha') {
			gl.enable(gl.BLEND)
			gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
		} else {
			gl.enable(gl.BLEND)
			gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE, gl.ZERO, gl.ONE)
		}
	}

	draw_gpu_mesh(gm: GpuMesh, img: WebGLTexture, world: Mat4, blend: Blend, cull: boolean, skin: Mat4[] | null) {
		if (gm.count === 0) return
		const gpu = this.gpu!
		const gl = gpu.gl
		const skinned = gm.skinned && skin !== null && skin.length > 0
		const p = skinned ? gpu.skin_prog! : gpu.mesh_prog!
		gl.useProgram(p.prog)
		this.apply_blend(gl, blend)
		if (cull) gl.enable(gl.CULL_FACE)
		else gl.disable(gl.CULL_FACE)
		gl.bindBuffer(gl.ARRAY_BUFFER, gm.vbuf)
		const stride = 64
		gl.enableVertexAttribArray(0)
		gl.vertexAttribPointer(0, 3, gl.FLOAT, false, stride, 0)
		gl.enableVertexAttribArray(1)
		gl.vertexAttribPointer(1, 3, gl.FLOAT, false, stride, 12)
		gl.enableVertexAttribArray(2)
		gl.vertexAttribPointer(2, 2, gl.FLOAT, false, stride, 24)
		gl.enableVertexAttribArray(3)
		gl.vertexAttribPointer(3, 4, gl.FLOAT, false, stride, 32)
		gl.enableVertexAttribArray(4)
		gl.vertexAttribPointer(4, 4, gl.FLOAT, false, stride, 48)
		gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, gm.ibuf)
		gl.bindTexture(gl.TEXTURE_2D, img)
		const vs = this.vs
		vs.set(this.vp.m, 0)
		vs.set(world.m, 16)
		let slots = vs_static_slots
		if (skinned) {
			slots = vs_skinned_slots
			const n = Math.min(skin!.length, max_bones)
			for (let bi = 0; bi < n; bi++) {
				const m = skin![bi].m
				const o = (vs_bones + bi * 3) * 4
				for (let row = 0; row < 3; row++) {
					vs[o + row * 4] = m[row]
					vs[o + row * 4 + 1] = m[4 + row]
					vs[o + row * 4 + 2] = m[8 + row]
					vs[o + row * 4 + 3] = m[12 + row]
				}
			}
		}
		gl.uniform4fv(p.vs_params, vs.subarray(0, slots * 4))
		gl.uniform4fv(p.fs_params, this.fs)
		gl.drawElements(gl.TRIANGLES, gm.count, gm.index_type, 0)
		this.draw_calls++
		this.triangles += Math.trunc(gm.count / 3)
	}

	// ---------- Billboards (particles, trails, shadows) ----------

	group(image_key: string, blend: Blend): number[] {
		const key = `${image_key}|${blend}`
		let g = this.bb.get(key)
		if (!g) {
			g = []
			this.bb.set(key, g)
			this.order.push(key)
		}
		return g
	}

	push_quad(g: number[], a: Vec3, b: Vec3, c: Vec3, d: Vec3, col: number) {
		g.push(a.x, a.y, a.z, 0, 1, col, b.x, b.y, b.z, 1, 1, col, c.x, c.y, c.z, 1, 0, col, d.x, d.y, d.z, 0, 0, col)
	}

	add_shadow(it: DrawItem) {
		let size = 0
		if (it.kind === 'mesh') {
			const c = it.comp as MeshRenderer3D
			if (c.shadow) size = c.shadow_size
		} else if (it.kind === 'skinned') {
			const c = it.comp as SkinnedModel3D
			if (c.shadow) size = c.shadow_size
		}
		if (size <= 0) return
		const p = it.world.translation_part()
		// fades and grows with the height above the ground
		const h = Math.max(0, p.y)
		const k = Math.max(0, 1 - h / 4)
		if (k <= 0) return
		const s = size * (1 + h * 0.15)
		const y = 0.015
		const g = this.group('shape:soft', 'alpha')
		const col = pack_color(rgba(0, 0, 0, Math.trunc(150 * k)))
		this.push_quad(g, vec3(p.x - s, y, p.z + s), vec3(p.x + s, y, p.z + s), vec3(p.x + s, y, p.z - s), vec3(p.x - s, y, p.z - s), col)
	}

	add_particles(it: DrawItem) {
		const p = it.comp as Particles3D
		if (p.particles.length === 0) return
		const g = this.group(`shape:${p.shape}`, p.additive ? 'additive' : 'alpha')
		const right = this.right
		const up = this.up
		for (const q of p.particles) {
			const t = q.age / q.life
			const size = (p.size_start + (p.size_end - p.size_start) * t) * q.size * 0.5
			if (size <= 0) continue
			const c0 = lerp_color(p.color_start, p.color_alt, q.shade)
			const col = pack_color(lerp_color(c0, p.color_end, t))
			const pos = p.local ? it.world.transform_point(q.pos) : q.pos
			const a = (q.rot * Math.PI) / 180
			const ca = Math.cos(a) * size
			const sa = Math.sin(a) * size
			const rx = right.mul(ca).op_add(up.mul(sa))
			const ry = up.mul(ca).op_sub(right.mul(sa))
			this.push_quad(g, pos.op_sub(rx).op_sub(ry), pos.op_add(rx).op_sub(ry), pos.op_add(rx).op_add(ry), pos.op_sub(rx).op_add(ry), col)
		}
	}

	add_trail(it: DrawItem) {
		const t = it.comp as Trail3D
		const n = t.points.length
		if (n < 2) return
		const g = this.group('shape:white', t.additive ? 'additive' : 'alpha')
		const eye = this.cam!.eye
		const sides: Vec3[] = new Array(n)
		for (let i = 0; i < n; i++) {
			const a = t.points[i > 0 ? i - 1 : 0].pos
			const b = t.points[i + 1 < n ? i + 1 : n - 1].pos
			const dir = b.op_sub(a).normalized()
			const to_eye = eye.op_sub(t.points[i].pos).normalized()
			const k = 1 - t.points[i].age / t.duration
			sides[i] = dir.cross(to_eye).normalized().mul(t.width * 0.5 * k)
		}
		for (let i = 0; i < n - 1; i++) {
			const p0 = t.points[i].pos
			const p1 = t.points[i + 1].pos
			const k = t.points[i].age / t.duration
			const col = pack_color(lerp_color(t.color, t.color_end, k))
			this.push_quad(g, p0.op_sub(sides[i]), p0.op_add(sides[i]), p1.op_add(sides[i + 1]), p1.op_sub(sides[i + 1]), col)
		}
	}

	flush_billboards() {
		for (const key of this.order) {
			const verts = this.bb.get(key)
			if (!verts || verts.length === 0) continue
			const bar = key.lastIndexOf('|')
			const blend = key.slice(bar + 1) as Blend
			const img = this.gpu!.shape(key.slice(0, bar).slice('shape:'.length))
			this.draw_bb_vertices(verts, img, blend, this.vp)
		}
		this.order.length = 0
		this.bb.clear()
	}

	draw_bb_vertices(verts: number[], img: WebGLTexture, blend: Blend, mvp: Mat4) {
		const quads = Math.min(Math.trunc(verts.length / (4 * BB_FLOATS)), max_billboards)
		if (quads === 0) return
		const gpu = this.gpu!
		const gl = gpu.gl
		const f = this.bb_f32
		const u = this.bb_u32
		const nf = quads * 4 * BB_FLOATS
		for (let i = 0; i < nf; i += BB_FLOATS) {
			f[i] = verts[i]
			f[i + 1] = verts[i + 1]
			f[i + 2] = verts[i + 2]
			f[i + 3] = verts[i + 3]
			f[i + 4] = verts[i + 4]
			u[i + 5] = verts[i + 5]
		}
		const p = gpu.bb_prog!
		gl.useProgram(p.prog)
		this.apply_blend(gl, blend)
		gl.disable(gl.CULL_FACE)
		gl.bindBuffer(gl.ARRAY_BUFFER, gpu.bb_vbuf)
		gl.bufferData(gl.ARRAY_BUFFER, new Uint8Array(this.bb_data, 0, nf * 4), gl.STREAM_DRAW)
		const stride = BB_FLOATS * 4
		gl.enableVertexAttribArray(0)
		gl.vertexAttribPointer(0, 3, gl.FLOAT, false, stride, 0)
		gl.enableVertexAttribArray(1)
		gl.vertexAttribPointer(1, 2, gl.FLOAT, false, stride, 12)
		gl.enableVertexAttribArray(2)
		gl.vertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, stride, 20)
		gl.disableVertexAttribArray(3)
		gl.disableVertexAttribArray(4)
		gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, gpu.bb_ibuf)
		gl.bindTexture(gl.TEXTURE_2D, img)
		gl.uniform4fv(p.vs_params, mvp.m)
		gl.drawElements(gl.TRIANGLES, quads * 6, gl.UNSIGNED_SHORT, 0)
		this.draw_calls++
		this.triangles += quads * 2
	}
}

// model_key: one key per parsed model (its meshes and textures are uploaded once).
const model_ids = new WeakMap<model3d.Model, number>()
let next_model_id = 1
function model_key(m: model3d.Model): string {
	let id = model_ids.get(m)
	if (id === undefined) {
		id = next_model_id++
		model_ids.set(m, id)
	}
	return `model:${id}`
}

export function new_renderer(db: assets.AssetDatabase): Renderer3D {
	return new Renderer3D(db)
}

// ---------- Install (render3d/install.v) ----------

// register_builtins registers the 3D components for .scene files.
export function register_builtins(r: serialize.Registry) {
	r.register(Transform3D)
	r.register(Camera3D)
	r.register(DirectionalLight3D)
	r.register(PointLight3D)
	r.register(Environment3D)
	r.register(MeshRenderer3D)
	r.register(SkinnedModel3D)
	r.register(BoneAttach3D)
	r.register(Particles3D)
	r.register(Trail3D)
}

// install adds 3D to a game: registers the components and draws the 3D world every frame.
export function install(a: App): Renderer3D {
	register_builtins(a.registry)
	const r = new_renderer(a.db)
	a.world_data = r
	a.world_draw = (data: unknown, scene: core.Scene, width: number, height: number) => {
		;(data as Renderer3D).draw(a.gfx!, scene, width, height)
	}
	return r
}
