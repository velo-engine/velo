module render3d

import math
import os
import rand
import sokol.gfx
import velo.core
import velo.assets
import velo.model3d

// Renderer3D draws the 3D components of a scene (Camera3D, lights, MeshRenderer3D, SkinnedModel3D, Particles3D,
// Trail3D) into the current render pass. velo.app calls it between the 2D world and the 2D HUD (see install),
// so 2D sprites outside a Canvas are a backdrop and Canvas nodes (UI) draw on top.
@[heap]
pub struct Renderer3D {
mut:
	gpu   Gpu
	db    &assets.AssetDatabase = unsafe { nil }
	items []DrawItem
	bb    map[string][]BVertex // billboard groups: '<image key>|<blend>' -> vertices
	order []string             // billboard groups in first-use order
	fs    []f32
	vp    core.Mat4
	cam   &Camera3D = unsafe { nil }
	right core.Vec3
	up    core.Vec3
	time  f32
pub mut:
	draw_calls int
	triangles  int
	// Background drawn by the 3D pass: clear to the fog color instead of the app's background.
	clear_to_fog bool = true
}

enum ItemKind {
	mesh
	skinned
	particles
	trail
}

struct DrawItem {
	kind  ItemKind
	node  &core.Node
	world core.Mat4
	comp  voidptr
	blend Blend
	dist  f32
}

pub fn new_renderer(db &assets.AssetDatabase) &Renderer3D {
	return &Renderer3D{
		db: unsafe { db }
	}
}

// draw renders the scene's 3D world into the current pass, `width` x `height` pixels.
pub fn (mut r Renderer3D) draw(scene &core.Scene, width int, height int) {
	r.draw_calls = 0
	r.triangles = 0
	if scene == unsafe { nil } || width <= 0 || height <= 0 {
		return
	}
	r.items.clear()
	r.cam = unsafe { nil }
	mut fr := Lights{
		sun: DirectionalLight3D{
			intensity: 0
		}
	}
	r.collect(scene.root, mut fr)
	env, sun, has_sun, points := fr.env, fr.sun, fr.has_sun, fr.points
	if r.cam == unsafe { nil } {
		return
	}
	if !r.gpu.init() {
		return
	}
	r.time = f32(scene.time)
	mut cam := r.cam
	cam.compute(f32(width) / f32(height))
	mut proj := cam.projection
	if r.gpu.lang == .msl {
		// Metal clips depth to 0..1, the projection is made for OpenGL's -1..1
		mut fix := core.Mat4.identity()
		fix.m[10] = 0.5
		fix.m[14] = 0.5
		proj = fix * proj
	}
	r.vp = proj * cam.view
	for i, it in r.items {
		r.items[i] = DrawItem{
			...it
			dist: it.world.translation_part().distance(cam.eye)
		}
	}
	inv := cam.view.inverse()
	r.right = inv.axis(0).normalized()
	r.up = inv.axis(1).normalized()
	gfx.apply_viewport(0, 0, width, height, true)
	gfx.apply_scissor_rect(0, 0, width, height, true)
	if r.clear_to_fog {
		r.draw_background(env)
	}
	r.setup_fs(env, sun, has_sun, points)
	// opaque first, then the blob shadows, then transparent things far to near
	for it in r.items {
		if it.blend == .opaque && (it.kind == .mesh || it.kind == .skinned) {
			r.draw_item(it)
		}
	}
	r.bb.clear()
	r.order.clear()
	for it in r.items {
		r.add_shadow(it)
	}
	r.flush_billboards()
	mut trans := r.items.filter(it.blend != .opaque || it.kind == .particles || it.kind == .trail)
	trans.sort(a.dist > b.dist)
	for it in trans {
		match it.kind {
			.mesh, .skinned {
				r.flush_billboards()
				r.draw_item(it)
			}
			.particles {
				r.add_particles(it)
			}
			.trail {
				r.add_trail(it)
			}
		}
	}
	r.flush_billboards()
	gfx.apply_viewport(0, 0, width, height, true)
	gfx.apply_scissor_rect(0, 0, width, height, true)
}

// Lights — the camera-independent state collect gathers from the tree.
struct Lights {
mut:
	env     Environment3D
	sun     DirectionalLight3D
	has_sun bool
	points  []f32
}

fn (mut r Renderer3D) collect(n &core.Node, mut fr Lights) {
	if !n.active {
		return
	}
	world := if n.components.len > 0 { world_matrix(n) } else { core.Mat4.identity() }
	for c in n.components {
		if !c.enabled {
			continue
		}
		if c is Environment3D {
			fr.env = *c
		} else if c is DirectionalLight3D {
			if !fr.has_sun {
				fr.sun = *c
				fr.has_sun = true
			}
		} else if c is PointLight3D {
			if fr.points.len < max_point_lights * 8 {
				p := world.translation_part()
				f := if c.flicker > 0 { 1 - c.flicker * rand.f32() * 0.5 } else { f32(1) }
				k := c.intensity * f / 255
				fr.points << [p.x, p.y, p.z, c.range, f32(c.color.r) * k, f32(c.color.g) * k,
					f32(c.color.b) * k, 0]
			}
		}
	}
	if r.cam == unsafe { nil } {
		for c in n.get_components[Camera3D]() {
			if c.enabled {
				r.cam = unsafe { c }
				break
			}
		}
	}
	for c in n.get_components[MeshRenderer3D]() {
		if c.enabled {
			r.add_item(.mesh, blend_from(c.blend), n, c, world)
		}
	}
	for c in n.get_components[SkinnedModel3D]() {
		if c.enabled {
			r.add_item(.skinned, .opaque, n, c, world)
		}
	}
	for c in n.get_components[Particles3D]() {
		if c.enabled {
			r.add_item(.particles, if c.additive { Blend.additive } else { Blend.alpha }, n, c,
				world)
		}
	}
	for c in n.get_components[Trail3D]() {
		if c.enabled {
			r.add_item(.trail, if c.additive { Blend.additive } else { Blend.alpha }, n, c, world)
		}
	}
	for ch in n.children {
		r.collect(ch, mut fr)
	}
}

fn (mut r Renderer3D) add_item(kind ItemKind, blend Blend, n &core.Node, comp voidptr, world core.Mat4) {
	r.items << DrawItem{
		kind:  kind
		node:  n
		world: world
		comp:  comp
		blend: blend
	}
}

fn read_file_bytes(path string) []u8 {
	return os.read_bytes(path) or { []u8{} }
}

fn color4(c core.Color, k f32) [4]f32 {
	return [f32(c.r) / 255 * k, f32(c.g) / 255 * k, f32(c.b) / 255 * k, f32(c.a) / 255]!
}

fn (mut r Renderer3D) set_fs(slot int, v [4]f32) {
	r.fs[slot * 4] = v[0]
	r.fs[slot * 4 + 1] = v[1]
	r.fs[slot * 4 + 2] = v[2]
	r.fs[slot * 4 + 3] = v[3]
}

fn (mut r Renderer3D) setup_fs(env Environment3D, sun DirectionalLight3D, has_sun bool, points []f32) {
	if r.fs.len != fs_slots * 4 {
		r.fs = []f32{len: fs_slots * 4}
	}
	for i in 0 .. r.fs.len {
		r.fs[i] = 0
	}
	d := sun.direction.normalized().neg()
	r.set_fs(fs_sun_dir, [d.x, d.y, d.z, 0]!)
	r.set_fs(fs_sun_color, color4(sun.color, if has_sun { sun.intensity } else { 0 }))
	r.set_fs(fs_sky, color4(env.sky, env.ambient))
	r.set_fs(fs_ground, color4(env.ground, env.ambient))
	eye := r.cam.eye
	r.set_fs(fs_camera, [eye.x, eye.y, eye.z, env.fog_density]!)
	fog := color4(env.fog_color, 1)
	r.set_fs(fs_fog, [fog[0], fog[1], fog[2], 0]!)
	for i, v in points {
		r.fs[fs_points * 4 + i] = v
	}
}

// draw_background: a vertical gradient from the fog color (horizon) to a deeper sky color, behind everything.
fn (mut r Renderer3D) draw_background(env Environment3D) {
	fog := env.fog_color
	top := core.rgba(u8(f32(fog.r) * 0.62), u8(f32(fog.g) * 0.66), u8(f32(fog.b) * 0.82), 255)
	// a screen-filling quad at the far plane, in clip space through an identity matrix
	mut verts := []BVertex{cap: 4}
	z := f32(0.99999)
	verts << BVertex{-1, 1, z, 0, 0, pack_color(top)}
	verts << BVertex{-1, -1, z, 0, 1, pack_color(fog)}
	verts << BVertex{1, -1, z, 1, 1, pack_color(fog)}
	verts << BVertex{1, 1, z, 1, 0, pack_color(top)}
	r.draw_bb_vertices(verts, r.gpu.white, .opaque, core.Mat4.identity())
}

// ---------- Meshes ----------

fn (mut r Renderer3D) draw_item(it DrawItem) {
	match it.kind {
		.mesh {
			mut m := unsafe { &MeshRenderer3D(it.comp) }
			r.draw_mesh_renderer(mut m, it.world)
		}
		.skinned {
			mut s := unsafe { &SkinnedModel3D(it.comp) }
			r.draw_skinned(mut s, it.world)
		}
		else {}
	}
}

fn (mut r Renderer3D) texture_image(ref assets.AssetRef[assets.Texture]) ?gfx.Image {
	if !ref.is_set() || r.db == unsafe { nil } {
		return none
	}
	key := 'asset:${ref.id}'
	if t := r.gpu.textures[key] {
		return if t.w > 0 { t.img } else { none }
	}
	path := r.db.abs_path(r.db.entry(r.db.resolve(ref.id) or { ref.id }) or {
		r.gpu.textures[key] = GpuTexture{}
		return none
	})
	bytes := read_file_bytes(path)
	t := r.gpu.texture_from_bytes(key, bytes)?
	return t.img
}

fn (mut r Renderer3D) model_texture(m &model3d.Model, key string, i int) ?gfx.Image {
	if i < 0 || i >= m.textures.len {
		return none
	}
	t := r.gpu.texture_from_bytes('${key}:tex${i}', m.textures[i].bytes)?
	return t.img
}

fn (mut r Renderer3D) draw_mesh_renderer(mut c MeshRenderer3D, world core.Mat4) {
	blend := blend_from(c.blend)
	mut tint := color4(c.color, 1)
	fs_em := color4(c.emissive, 1)
	r.set_fs(fs_emissive, [fs_em[0], fs_em[1], fs_em[2], c.rim]!)
	r.set_fs(fs_uv, [c.uv_scale.x, c.uv_scale.y, c.uv_offset.x, c.uv_offset.y]!)
	r.fs[fs_fog * 4 + 3] = if c.unlit { f32(1) } else { f32(0) }
	user_tex := r.texture_image(c.texture) or { r.gpu.pattern(c.pattern) }
	if c.model_data != unsafe { nil } {
		m := c.model_data
		key := 'model:${voidptr(m)}'
		for i, me in m.meshes {
			gm := r.gpu.mesh_for('${key}:${i}', &me)
			img := if c.texture.is_set() { user_tex } else { r.model_texture(m, key, me.texture) or {
					user_tex} }
			mc := color4(me.color, 1)
			r.set_fs(fs_tint, [tint[0] * mc[0], tint[1] * mc[1], tint[2] * mc[2], tint[3]]!)
			r.draw_gpu_mesh(gm, img, world, blend, !c.double_sided, []core.Mat4{})
		}
	} else {
		mut key := 'prim:${c.mesh}'
		mut md := model3d.MeshData{}
		if c.mesh == 'grid' {
			key = 'prim:grid:${c.grid_cells}'
			if key !in r.gpu.meshes {
				md = model3d.grid(1, if c.grid_cells > 0 { c.grid_cells } else { 1 })
			}
		} else if key !in r.gpu.meshes {
			md = model3d.primitive(c.mesh) or { return }
		}
		gm := r.gpu.mesh_for(key, &md)
		r.set_fs(fs_tint, tint)
		flat := c.mesh in ['plane', 'grid', 'disc']
		r.draw_gpu_mesh(gm, user_tex, world, blend, !c.double_sided && !flat, []core.Mat4{})
	}
	r.fs[fs_fog * 4 + 3] = 0
}

fn (mut r Renderer3D) draw_skinned(mut s SkinnedModel3D, world core.Mat4) {
	if s.data == unsafe { nil } {
		return
	}
	m := s.data
	key := 'model:${voidptr(m)}'
	tint := color4(s.color, 1)
	em := color4(s.emissive, 1)
	r.set_fs(fs_emissive, [em[0] + s.flash, em[1] + s.flash, em[2] + s.flash, s.rim]!)
	r.set_fs(fs_uv, [f32(1), 1, 0, 0]!)
	for i, me in m.meshes {
		gm := r.gpu.mesh_for('${key}:${i}', &me)
		img := r.model_texture(m, key, me.texture) or { r.gpu.white }
		mc := color4(me.color, 1)
		r.set_fs(fs_tint, [tint[0] * mc[0], tint[1] * mc[1], tint[2] * mc[2], tint[3]]!)
		r.draw_gpu_mesh(gm, img, world, .opaque, false, if gm.skinned {
			s.skin
		} else {
			[]core.Mat4{}
		})
	}
}

fn (mut r Renderer3D) draw_gpu_mesh(gm GpuMesh, img gfx.Image, world core.Mat4, blend Blend, cull bool, skin []core.Mat4) {
	if gm.count == 0 {
		return
	}
	skinned := gm.skinned && skin.len > 0
	gfx.apply_pipeline(r.gpu.pipeline(if skinned { 1 } else { 0 }, blend, cull))
	mut b := gfx.Bindings{}
	b.vertex_buffers[0] = gm.vbuf
	b.index_buffer = gm.ibuf
	b.fs.images[0] = img
	b.fs.samplers[0] = r.gpu.smp
	gfx.apply_bindings(&b)
	slots := if skinned { vs_skinned_slots } else { vs_static_slots }
	mut vs := []f32{len: slots * 4}
	for i in 0 .. 16 {
		vs[i] = r.vp.m[i]
		vs[16 + i] = world.m[i]
	}
	if skinned {
		n := math.min(skin.len, max_bones)
		for bi in 0 .. n {
			m := skin[bi].m
			o := (vs_bones + bi * 3) * 4
			for row in 0 .. 3 {
				vs[o + row * 4] = m[row]
				vs[o + row * 4 + 1] = m[4 + row]
				vs[o + row * 4 + 2] = m[8 + row]
				vs[o + row * 4 + 3] = m[12 + row]
			}
		}
	}
	gfx.apply_uniforms(.vs, 0, &gfx.Range{
		ptr:  vs.data
		size: usize(vs.len * 4)
	})
	gfx.apply_uniforms(.fs, 0, &gfx.Range{
		ptr:  r.fs.data
		size: usize(r.fs.len * 4)
	})
	gfx.draw(0, gm.count, 1)
	r.draw_calls++
	r.triangles += gm.count / 3
}

// ---------- Billboards (particles, trails, shadows) ----------

fn (mut r Renderer3D) group(image_key string, blend Blend) string {
	key := '${image_key}|${int(blend)}'
	if key !in r.bb {
		r.bb[key] = []BVertex{}
		r.order << key
	}
	return key
}

fn (mut r Renderer3D) push_quad(key string, a core.Vec3, b core.Vec3, c core.Vec3, d core.Vec3, col u32) {
	r.bb[key] << BVertex{a.x, a.y, a.z, 0, 1, col}
	r.bb[key] << BVertex{b.x, b.y, b.z, 1, 1, col}
	r.bb[key] << BVertex{c.x, c.y, c.z, 1, 0, col}
	r.bb[key] << BVertex{d.x, d.y, d.z, 0, 0, col}
}

fn (mut r Renderer3D) add_shadow(it DrawItem) {
	mut size := f32(0)
	match it.kind {
		.mesh {
			c := unsafe { &MeshRenderer3D(it.comp) }
			if c.shadow {
				size = c.shadow_size
			}
		}
		.skinned {
			c := unsafe { &SkinnedModel3D(it.comp) }
			if c.shadow {
				size = c.shadow_size
			}
		}
		else {}
	}

	if size <= 0 {
		return
	}
	p := it.world.translation_part()
	// fades and grows with the height above the ground
	h := f32(math.max(f32(0), p.y))
	k := f32(math.max(f32(0), 1 - h / 4))
	if k <= 0 {
		return
	}
	s := size * (1 + h * 0.15)
	y := f32(0.015)
	key := r.group('shape:soft', .alpha)
	col := pack_color(core.rgba(0, 0, 0, u8(150 * k)))
	r.push_quad(key, core.vec3(p.x - s, y, p.z + s), core.vec3(p.x + s, y, p.z + s), core.vec3(
		p.x + s, y, p.z - s), core.vec3(p.x - s, y, p.z - s), col)
}

fn lerp_color(a core.Color, b core.Color, t f32) core.Color {
	return a.lerp(b, if t < 0 {
		f32(0)
	} else if t > 1 {
		f32(1)
	} else {
		t
	})
}

fn (mut r Renderer3D) add_particles(it DrawItem) {
	p := unsafe { &Particles3D(it.comp) }
	if p.particles.len == 0 {
		return
	}
	blend := if p.additive { Blend.additive } else { Blend.alpha }
	key := r.group('shape:${p.shape}', blend)
	for q in p.particles {
		t := q.age / q.life
		size := (p.size_start + (p.size_end - p.size_start) * t) * q.size * 0.5
		if size <= 0 {
			continue
		}
		c0 := lerp_color(p.color_start, p.color_alt, q.shade)
		col := pack_color(lerp_color(c0, p.color_end, t))
		pos := if p.local { it.world.transform_point(q.pos) } else { q.pos }
		a := q.rot * math.pi / 180
		ca, sa := f32(math.cos(a)) * size, f32(math.sin(a)) * size
		rx := r.right.mul(ca) + r.up.mul(sa)
		ry := r.up.mul(ca) - r.right.mul(sa)
		r.push_quad(key, pos - rx - ry, pos + rx - ry, pos + rx + ry, pos - rx + ry, col)
	}
}

fn (mut r Renderer3D) add_trail(it DrawItem) {
	t := unsafe { &Trail3D(it.comp) }
	n := t.points.len
	if n < 2 {
		return
	}
	blend := if t.additive { Blend.additive } else { Blend.alpha }
	key := r.group('shape:white', blend)
	eye := r.cam.eye
	mut sides := []core.Vec3{len: n}
	for i in 0 .. n {
		a := t.points[if i > 0 { i - 1 } else { 0 }].pos
		b := t.points[if i + 1 < n { i + 1 } else { n - 1 }].pos
		dir := (b - a).normalized()
		to_eye := (eye - t.points[i].pos).normalized()
		k := 1 - t.points[i].age / t.duration
		sides[i] = dir.cross(to_eye).normalized().mul(t.width * 0.5 * k)
	}
	for i in 0 .. n - 1 {
		p0, p1 := t.points[i].pos, t.points[i + 1].pos
		k := t.points[i].age / t.duration
		col := pack_color(lerp_color(t.color, t.color_end, k))
		r.push_quad(key, p0 - sides[i], p0 + sides[i], p1 + sides[i + 1], p1 - sides[i + 1], col)
	}
}

fn (mut r Renderer3D) image_for_key(key string) gfx.Image {
	name := key.all_after('shape:')
	if name == 'white' {
		return r.gpu.white
	}
	return r.gpu.shape(name)
}

fn (mut r Renderer3D) flush_billboards() {
	for key in r.order {
		verts := r.bb[key] or { continue }
		if verts.len == 0 {
			continue
		}
		blend := unsafe { Blend(key.all_after_last('|').int()) }
		img := r.image_for_key(key.all_before_last('|'))
		r.draw_bb_vertices(verts, img, blend, r.vp)
		r.bb[key] = []BVertex{}
	}
	r.order.clear()
	r.bb.clear()
}

fn (mut r Renderer3D) draw_bb_vertices(verts []BVertex, img gfx.Image, blend Blend, mvp core.Mat4) {
	quads := math.min(verts.len / 4, max_billboards)
	if quads == 0 {
		return
	}
	if gfx.query_buffer_overflow(r.gpu.bb_vbuf) {
		return
	}
	off := gfx.append_buffer(r.gpu.bb_vbuf, &gfx.Range{
		ptr:  verts.data
		size: usize(quads * 4 * int(sizeof(BVertex)))
	})
	if gfx.query_buffer_overflow(r.gpu.bb_vbuf) {
		return
	}
	gfx.apply_pipeline(r.gpu.pipeline(2, blend, false))
	mut b := gfx.Bindings{}
	b.vertex_buffers[0] = r.gpu.bb_vbuf
	b.vertex_buffer_offsets[0] = off
	b.index_buffer = r.gpu.bb_ibuf
	b.fs.images[0] = img
	b.fs.samplers[0] = r.gpu.smp_clamp
	gfx.apply_bindings(&b)
	gfx.apply_uniforms(.vs, 0, &gfx.Range{
		ptr:  &mvp.m[0]
		size: 64
	})
	gfx.draw(0, quads * 6, 1)
	r.draw_calls++
	r.triangles += quads * 2
}
