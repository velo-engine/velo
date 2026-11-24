module model3d

import os
import math
import velo.core

// FBX -> Model: meshes (triangulated, split per material), the skeleton (every non-mesh Model node: LimbNode,
// Root, Null), skin weights (Skin + Cluster deformers, 4 strongest bones per vertex), every AnimationStack baked
// to a Clip at 30 fps, and base color textures (embedded `Content`, or the file the texture names).
// Positions are converted to meters and to y-up.

const fbx_ticks_per_second = 46186158000.0
const bake_fps = 30

struct Conn {
	child  i64
	parent i64
	prop   string
}

struct FbxScene {
mut:
	objs     map[i64]&FbxNode
	parents  map[i64][]Conn // child id -> its connections to parents
	children map[i64][]Conn // parent id -> connections from its children
	unit     f32       = 1 // meters per file unit
	axis     core.Mat4 = core.Mat4.identity() // file axes -> y-up
	// build_skeleton: Model id -> bone index, and each bone's source
	bone_index map[i64]int
	bone_ids   []BoneSrc
}

// load_fbx reads a binary .fbx file; textures it names by path are looked up next to it.
pub fn load_fbx(path string) !&Model {
	data := os.read_bytes(path)!
	mut m := import_fbx(data) or { return error('${os.file_name(path)}: ${err}') }
	if m.name == '' {
		m.name = os.file_name(path).all_before_last('.')
	}
	dir := os.dir(path)
	for i, img in m.textures {
		if img.bytes.len == 0 && img.file != '' {
			for cand in [img.file, os.join_path(dir, img.file),
				os.join_path(dir, os.file_name(img.file.replace('\\', '/')))] {
				if os.is_file(cand) {
					m.textures[i] = Image{
						name:  img.name
						bytes: os.read_bytes(cand) or { []u8{} }
						file:  cand
					}
					break
				}
			}
		}
	}
	return m
}

// import_fbx builds a Model from the bytes of a binary .fbx file.
pub fn import_fbx(data []u8) !&Model {
	doc := parse_fbx(data)!
	objects := doc.node('Objects') or { return error('no Objects section') }
	mut sc := FbxScene{}
	for o in objects.children {
		sc.objs[o.id()] = o
	}
	if conns := doc.node('Connections') {
		for c in conns.children {
			if c.name != 'C' || c.props.len < 3 {
				continue
			}
			cn := Conn{
				child:  c.props[1].i
				parent: c.props[2].i
				prop:   if c.props.len > 3 { c.props[3].s } else { '' }
			}
			sc.parents[cn.child] << cn
			sc.children[cn.parent] << cn
		}
	}
	if gs := doc.node('GlobalSettings') {
		// UnitScaleFactor = centimeters per unit
		unit := gs.p70('UnitScaleFactor') or { [1.0] }
		sc.unit = f32(unit[0] / 100.0)
		up := gs.p70('UpAxis') or { [1.0] }
		up_sign := gs.p70('UpAxisSign') or { [1.0] }
		if int(up[0]) == 2 {
			// z-up -> y-up: rotate -90 degrees around x
			sc.axis = core.Mat4.rotation(core.Quat.axis_angle(core.vec3(1, 0, 0), if up_sign[0] > 0 {
				f32(-90)
			} else {
				f32(90)
			}))
		}
	}
	mut m := &Model{}
	sc.build_skeleton(mut m)
	sc.build_meshes(mut m)!
	sc.build_clips(mut m)
	m.compute_bounds()
	return m
}

fn (sc &FbxScene) obj(id i64) ?&FbxNode {
	return sc.objs[id] or { return none }
}

// class_of: 'LimbNode', 'Mesh', 'Null', ... (property 2 of an object).
fn class_of(n &FbxNode) string {
	return if n.props.len > 2 { n.props[2].s } else { '' }
}

fn name_of(n &FbxNode) string {
	if n.props.len < 2 {
		return ''
	}
	s := n.props[1].s
	return if s.contains('::') { s.all_before('::') } else { s }
}

// parent_model: the Model node a Model is attached to (0 = the scene root).
fn (sc &FbxScene) parent_model(id i64) i64 {
	for c in sc.parents[id] or { []Conn{} } {
		if c.prop == '' {
			if p := sc.obj(c.parent) {
				if p.name == 'Model' {
					return c.parent
				}
			}
		}
	}
	return 0
}

// ---------- Transforms ----------

fn v3(a []f64, def core.Vec3) core.Vec3 {
	if a.len < 3 {
		return def
	}
	return core.vec3(f32(a[0]), f32(a[1]), f32(a[2]))
}

// euler_quat: FBX euler angles (degrees) in the node's rotation order.
fn euler_quat(e core.Vec3, order int) core.Quat {
	qx := core.Quat.axis_angle(core.vec3(1, 0, 0), e.x)
	qy := core.Quat.axis_angle(core.vec3(0, 1, 0), e.y)
	qz := core.Quat.axis_angle(core.vec3(0, 0, 1), e.z)
	return match order {
		1 { qy.mul(qz).mul(qx) } // XZY
		2 { qx.mul(qz).mul(qy) } // YZX
		3 { qz.mul(qx).mul(qy) } // YXZ
		4 { qy.mul(qx).mul(qz) } // ZXY
		5 { qx.mul(qy).mul(qz) } // ZYX
		else { qz.mul(qy).mul(qx) } // XYZ
	}
}

// NodeXform — the parts of an FBX node transform. Animation replaces t, r (euler) and s.
struct NodeXform {
mut:
	t     core.Vec3
	r     core.Vec3
	s     core.Vec3 = core.Vec3{1, 1, 1}
	pre   core.Quat = core.Quat.identity()
	post  core.Quat = core.Quat.identity()
	roff  core.Vec3
	rpiv  core.Vec3
	soff  core.Vec3
	spiv  core.Vec3
	order int
}

fn node_xform(n &FbxNode) NodeXform {
	order := int((n.p70('RotationOrder') or { [0.0] })[0])
	return NodeXform{
		t:     v3(n.p70('Lcl Translation') or { []f64{} }, core.Vec3{})
		r:     v3(n.p70('Lcl Rotation') or { []f64{} }, core.Vec3{})
		s:     v3(n.p70('Lcl Scaling') or { []f64{} }, core.Vec3{1, 1, 1})
		pre:   euler_quat(v3(n.p70('PreRotation') or { []f64{} }, core.Vec3{}), 0)
		post:  euler_quat(v3(n.p70('PostRotation') or { []f64{} }, core.Vec3{}), 0)
		roff:  v3(n.p70('RotationOffset') or { []f64{} }, core.Vec3{})
		rpiv:  v3(n.p70('RotationPivot') or { []f64{} }, core.Vec3{})
		soff:  v3(n.p70('ScalingOffset') or { []f64{} }, core.Vec3{})
		spiv:  v3(n.p70('ScalingPivot') or { []f64{} }, core.Vec3{})
		order: order
	}
}

// matrix: T * Roff * Rp * Rpre * R * Rpost^-1 * Rp^-1 * Soff * Sp * S * Sp^-1 (FBX SDK's node transform),
// with translations converted to meters.
fn (x NodeXform) matrix(unit f32) core.Mat4 {
	tr := fn [unit] (v core.Vec3) core.Mat4 {
		return core.Mat4.translation(v.mul(unit))
	}
	rot := x.pre.mul(euler_quat(x.r, x.order)).mul(x.post.conjugate())
	return tr(x.t) * tr(x.roff) * tr(x.rpiv) * core.Mat4.rotation(rot) * tr(x.rpiv.neg()) * tr(x.soff) * tr(x.spiv) * core.Mat4.scaling(x.s) * tr(x.spiv.neg())
}

// scaled: a matrix of the file with its translation converted to meters.
fn (sc &FbxScene) scaled(m core.Mat4) core.Mat4 {
	mut r := m
	r.m[12] *= sc.unit
	r.m[13] *= sc.unit
	r.m[14] *= sc.unit
	return r
}

// ---------- Skeleton ----------

struct BoneSrc {
	id    i64
	xform NodeXform
}

fn (mut sc FbxScene) build_skeleton(mut m Model) {
	// every Model that is not a mesh, ordered parents first
	mut ids := []i64{}
	for id, o in sc.objs {
		if o.name == 'Model' && class_of(o) != 'Mesh' {
			ids << id
		}
	}
	ids.sort(a < b)
	mut index := map[i64]int{}
	mut srcs := []BoneSrc{}
	mut placed := true
	for placed {
		placed = false
		for id in ids {
			if id in index {
				continue
			}
			p := sc.parent_model(id)
			pi := if p == 0 { -1 } else { index[p] or { -2 } }
			if pi == -2 {
				if po := sc.obj(p) {
					if class_of(po) != 'Mesh' {
						continue // parent not placed yet
					}
				}
			}
			o := sc.objs[id] or { continue }
			x := node_xform(o)
			local := x.matrix(sc.unit)
			t, r, s := local.decompose()
			parent := if pi >= 0 { pi } else { -1 }
			mut b := Bone{
				name:   name_of(o)
				parent: parent
				t:      t
				r:      r
				s:      s
			}
			if parent < 0 {
				// root bones carry the file -> y-up conversion
				ct, cr, cs := (sc.axis * local).decompose()
				b.t, b.r, b.s = ct, cr, cs
			}
			index[id] = m.bones.len
			m.bones << b
			srcs << BoneSrc{id, x}
			placed = true
		}
	}
	sc.bone_ids = srcs
	sc.bone_index = index.clone()
}

// ---------- Meshes ----------

fn (sc &FbxScene) model_global(id i64) core.Mat4 {
	mut g := core.Mat4.identity()
	mut cur := id
	for cur != 0 {
		o := sc.objs[cur] or { break }
		g = node_xform(o).matrix(sc.unit) * g
		cur = sc.parent_model(cur)
	}
	return sc.axis * g
}

// layer: per-polygon-vertex lookup of a LayerElement (normals, UVs): returns the value index for corner `pv`
// of control point `cp` in polygon `poly`.
struct LayerMap {
	mapping string
	direct  bool
	index   []i64
}

fn (l LayerMap) at(pv int, cp int, poly int) int {
	i := match l.mapping {
		'ByPolygonVertex' { pv }
		'ByControlPoint', 'ByVertice', 'ByVertex' { cp }
		'ByPolygon' { poly }
		else { 0 } // AllSame
	}

	if l.direct {
		return i
	}
	return if i < l.index.len { int(l.index[i]) } else { 0 }
}

fn layer_map(el &FbxNode, index_name string) LayerMap {
	mapping := if c := el.child('MappingInformationType') { c.props[0].s } else { 'ByPolygonVertex' }
	refr := if c := el.child('ReferenceInformationType') { c.props[0].s } else { 'Direct' }
	idx := if c := el.child(index_name) { c.props[0].int_list() } else { []i64{} }
	return LayerMap{
		mapping: mapping
		direct:  refr == 'Direct' || idx.len == 0
		index:   idx
	}
}

// child_numbers: the array in the first property of child `name` (empty if missing).
fn child_numbers(n &FbxNode, name string) []f64 {
	c := n.child(name) or { return []f64{} }
	if c.props.len == 0 {
		return []f64{}
	}
	return c.props[0].numbers()
}

struct Influence {
mut:
	bone   [4]int
	weight [4]f32
}

fn (mut inf Influence) add(bone int, w f32) {
	// keep the 4 strongest
	mut k := -1
	mut low := f32(1e30)
	for i in 0 .. 4 {
		if inf.weight[i] < low {
			low = inf.weight[i]
			k = i
		}
	}
	if w > low {
		inf.bone[k] = bone
		inf.weight[k] = w
	}
}

fn (mut sc FbxScene) build_meshes(mut m Model) ! {
	mut tex_index := map[i64]int{} // Video/Texture id -> Model.textures index
	for gid, geo in sc.objs {
		if geo.name != 'Geometry' || class_of(geo) != 'Mesh' {
			continue
		}
		verts_p := (geo.child('Vertices') or { continue }).props[0].numbers()
		poly_idx := (geo.child('PolygonVertexIndex') or { continue }).props[0].int_list()
		// the mesh Model this geometry belongs to
		mut model_id := i64(0)
		for c in sc.parents[gid] or { []Conn{} } {
			if o := sc.obj(c.parent) {
				if o.name == 'Model' {
					model_id = c.parent
					break
				}
			}
		}
		// skin: Geometry <- Skin <- Clusters <- bone Models
		ncp := verts_p.len / 3
		mut infl := []Influence{len: ncp}
		mut skinned := false
		mut bind := core.Mat4.identity() // mesh global at bind time (Cluster.Transform)
		for c in sc.children[gid] or { []Conn{} } {
			skin := sc.obj(c.child) or { continue }
			if skin.name != 'Deformer' || class_of(skin) != 'Skin' {
				continue
			}
			for cc in sc.children[c.child] or { []Conn{} } {
				cl := sc.obj(cc.child) or { continue }
				if cl.name != 'Deformer' || class_of(cl) != 'Cluster' {
					continue
				}
				mut bone := -1
				for bc in sc.children[cc.child] or { []Conn{} } {
					if bi := sc.bone_index[bc.child] {
						bone = bi
					}
				}
				if bone < 0 {
					continue
				}
				if tl := cl.child('TransformLink') {
					link := sc.axis * sc.scaled(core.Mat4.from_f64(tl.props[0].numbers()))
					m.bones[bone].inverse_bind = link.inverse()
				}
				if tf := cl.child('Transform') {
					// the file stores Transform = TransformLink^-1 * (mesh global at bind time)
					if tl := cl.child('TransformLink') {
						link := sc.scaled(core.Mat4.from_f64(tl.props[0].numbers()))
						bind = sc.axis * link * sc.scaled(core.Mat4.from_f64(tf.props[0].numbers()))
					}
				}
				idx := if n := cl.child('Indexes') { n.props[0].int_list() } else { []i64{} }
				wts := if n := cl.child('Weights') { n.props[0].numbers() } else { []f64{} }
				for k, cp in idx {
					if int(cp) < ncp && k < wts.len && wts[k] > 0 {
						infl[int(cp)].add(bone, f32(wts[k]))
						skinned = true
					}
				}
			}
		}
		// a rigid mesh under a bone follows that bone
		mut rigid_bone := -1
		if !skinned && model_id != 0 {
			if bi := sc.bone_index[sc.parent_model(model_id)] {
				rigid_bone = bi
			}
		}
		xf := if skinned { bind } else { sc.model_global(model_id) }
		if rigid_bone >= 0 {
			// vertices stay in model space; the bone's rest global is the bind
			g := sc.model_global(sc.parent_model(model_id))
			if m.bones[rigid_bone].inverse_bind == core.Mat4.identity() {
				m.bones[rigid_bone].inverse_bind = g.inverse()
			}
		}
		nxf := xf.inverse().transposed()
		// layers
		normals_el := geo.child('LayerElementNormal')
		uv_el := geo.child('LayerElementUV')
		mat_el := geo.child('LayerElementMaterial')
		nrm := if el := normals_el { child_numbers(el, 'Normals') } else { []f64{} }
		nmap := if el := normals_el { layer_map(el, 'NormalsIndex') } else { LayerMap{} }
		uvs := if el := uv_el { child_numbers(el, 'UV') } else { []f64{} }
		umap := if el := uv_el { layer_map(el, 'UVIndex') } else { LayerMap{} }
		mats := if el := mat_el { child_numbers(el, 'Materials').map(i64(it)) } else { []i64{} }
		mat_mapping := if el := mat_el {
			if c := el.child('MappingInformationType') { c.props[0].s } else { 'AllSame' }
		} else {
			'AllSame'
		}
		// materials of the mesh Model, in connection order (the material layer indexes them)
		mut materials := []i64{}
		for c in sc.children[model_id] or { []Conn{} } {
			if o := sc.obj(c.child) {
				if o.name == 'Material' {
					materials << c.child
				}
			}
		}
		// one MeshData per material slot used
		mut parts := map[int]int{} // material slot -> index in `out`
		mut out := []MeshData{}
		mut dedupe := []map[u64]int{}
		mut poly := 0
		mut start := 0
		for i, raw in poly_idx {
			if raw >= 0 {
				continue
			}
			// polygon = poly_idx[start..i+1], the last index is ~cp
			slot := if mats.len == 0 {
				0
			} else if mat_mapping == 'AllSame' {
				int(mats[0])
			} else if poly < mats.len {
				int(mats[poly])
			} else {
				0
			}
			if slot !in parts {
				parts[slot] = out.len
				mut md := MeshData{
					name: name_of(sc.objs[model_id] or { &FbxNode{} })
				}
				if slot < materials.len {
					mat := sc.objs[materials[slot]] or { &FbxNode{} }
					if dc := mat.p70('DiffuseColor') {
						if dc.len >= 3 {
							md.color = core.rgba(u8(math.min(dc[0], 1.0) * 255),
								u8(math.min(dc[1], 1.0) * 255), u8(math.min(dc[2], 1.0) * 255), 255)
						}
					}
					md.texture = sc.material_texture(materials[slot], mut m, mut tex_index)
				}
				out << md
				dedupe << map[u64]int{}
			}
			pi := parts[slot]
			mut corners := []int{}
			for k in start .. i + 1 {
				cp := int(if poly_idx[k] < 0 { -poly_idx[k] - 1 } else { poly_idx[k] })
				if cp >= ncp {
					continue
				}
				ni := nmap.at(k, cp, poly)
				ui := umap.at(k, cp, poly)
				key := (u64(cp) << 32) | u64(u32(ui))
				mut nx, mut ny, mut nz := f32(0), f32(1), f32(0)
				if ni * 3 + 2 < nrm.len {
					n := nxf.transform_dir(core.vec3(f32(nrm[ni * 3]), f32(nrm[ni * 3 + 1]), f32(nrm[
						ni * 3 + 2]))).normalized()
					nx, ny, nz = n.x, n.y, n.z
				}
				if vi := dedupe[pi][key] {
					o := 3 * vi
					if math.abs(out[pi].normals[o] - nx) + math.abs(out[pi].normals[o + 1] - ny) +
						math.abs(out[pi].normals[o + 2] - nz) < 1e-3 {
						corners << vi
						continue
					}
				}
				vi := out[pi].positions.len / 3
				dedupe[pi][key] = vi
				p := xf.transform_point(core.vec3(f32(verts_p[cp * 3]) * sc.unit, f32(verts_p[
					cp * 3 + 1]) * sc.unit, f32(verts_p[cp * 3 + 2]) * sc.unit))
				out[pi].positions << p.x
				out[pi].positions << p.y
				out[pi].positions << p.z
				out[pi].normals << nx
				out[pi].normals << ny
				out[pi].normals << nz
				if ui * 2 + 1 < uvs.len {
					out[pi].uvs << f32(uvs[ui * 2])
					out[pi].uvs << 1 - f32(uvs[ui * 2 + 1])
				} else {
					out[pi].uvs << 0
					out[pi].uvs << 0
				}
				if skinned || rigid_bone >= 0 {
					mut inf := if skinned {
						infl[cp]
					} else {
						Influence{
							bone:   [rigid_bone, 0, 0, 0]!
							weight: [f32(1), 0, 0, 0]!
						}
					}
					mut sum := inf.weight[0] + inf.weight[1] + inf.weight[2] + inf.weight[3]
					if sum <= 0 {
						inf.weight[0], sum = 1, 1
					}
					for j in 0 .. 4 {
						out[pi].joints << f32(inf.bone[j])
						out[pi].weights << inf.weight[j] / sum
					}
				}
				corners << vi
			}
			// fan triangulation
			for k := 1; k + 1 < corners.len; k++ {
				out[pi].indices << u32(corners[0])
				out[pi].indices << u32(corners[k])
				out[pi].indices << u32(corners[k + 1])
			}
			poly++
			start = i + 1
		}
		for md in out {
			if md.indices.len > 0 {
				m.meshes << md
			}
		}
	}
	if m.meshes.len == 0 {
		return error('no meshes')
	}
}

// material_texture: the base color texture of a material, added to m.textures on first use (-1 = none).
fn (sc &FbxScene) material_texture(mat_id i64, mut m Model, mut seen map[i64]int) int {
	for c in sc.children[mat_id] or { []Conn{} } {
		tex := sc.obj(c.child) or { continue }
		if tex.name != 'Texture' {
			continue
		}
		p := c.prop.to_lower()
		if !(p.contains('diffuse') || p.contains('basecolor') || p.contains('base_color') || p == '') {
			continue
		}
		if i := seen[c.child] {
			return i
		}
		mut bytes := []u8{}
		mut file := if n := tex.child('RelativeFilename') { n.props[0].s } else { '' }
		if file == '' {
			file = if n := tex.child('FileName') { n.props[0].s } else { '' }
		}
		for vc in sc.children[c.child] or { []Conn{} } {
			video := sc.obj(vc.child) or { continue }
			if video.name == 'Video' {
				if content := video.child('Content') {
					if content.props.len > 0 && content.props[0].raw.len > 0 {
						bytes = content.props[0].raw.clone()
					}
				}
			}
		}
		seen[c.child] = m.textures.len
		m.textures << Image{
			name:  name_of(tex)
			bytes: bytes
			file:  file
		}
		return m.textures.len - 1
	}
	return -1
}

// ---------- Animation ----------

struct Curve {
	times  []f64 // seconds
	values []f64
}

fn (c &Curve) eval(t f64) f64 {
	n := c.times.len
	if n == 0 {
		return 0
	}
	if t <= c.times[0] {
		return c.values[0]
	}
	if t >= c.times[n - 1] {
		return c.values[n - 1]
	}
	// binary search for the key before t
	mut lo, mut hi := 0, n - 1
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if c.times[mid] <= t {
			lo = mid
		} else {
			hi = mid
		}
	}
	span := c.times[hi] - c.times[lo]
	k := if span > 0 { (t - c.times[lo]) / span } else { 0 }
	return c.values[lo] + (c.values[hi] - c.values[lo]) * k
}

// Channel — the animated T, R or S of one bone: a curve (or a constant) per axis.
struct Channel {
mut:
	curves [3]Curve // empty times = the axis is not animated
}

fn (ch &Channel) at(t f64, def core.Vec3) core.Vec3 {
	mut out := [def.x, def.y, def.z]
	for i in 0 .. 3 {
		if ch.curves[i].times.len > 0 {
			out[i] = f32(ch.curves[i].eval(t))
		}
	}
	return core.vec3(out[0], out[1], out[2])
}

fn (sc &FbxScene) build_clips(mut m Model) {
	for sid, stack in sc.objs {
		if stack.name != 'AnimationStack' {
			continue
		}
		// stack <- layers <- curve nodes
		mut chans := map[string]Channel{} // '<bone>|T' etc.
		mut tmax := 0.0
		for lc in sc.children[sid] or { []Conn{} } {
			layer := sc.obj(lc.child) or { continue }
			if layer.name != 'AnimationLayer' {
				continue
			}
			for cc in sc.children[lc.child] or { []Conn{} } {
				cn := sc.obj(cc.child) or { continue }
				if cn.name != 'AnimationCurveNode' {
					continue
				}
				// curve node -> (bone, property)
				mut bone := -1
				mut what := ''
				for pc in sc.parents[cc.child] or { []Conn{} } {
					if bi := sc.bone_index[pc.parent] {
						what = match pc.prop {
							'Lcl Translation' { 'T' }
							'Lcl Rotation' { 'R' }
							'Lcl Scaling' { 'S' }
							else { '' }
						}

						if what != '' {
							bone = bi
						}
					}
				}
				if bone < 0 {
					continue
				}
				mut ch := Channel{}
				for k, axis in ['d|X', 'd|Y', 'd|Z'] {
					for vc in sc.children[cc.child] or { []Conn{} } {
						if vc.prop != axis {
							continue
						}
						curve := sc.obj(vc.child) or { continue }
						times := if n := curve.child('KeyTime') {
							n.props[0].int_list()
						} else {
							[]i64{}
						}
						vals := if n := curve.child('KeyValueFloat') {
							n.props[0].numbers()
						} else {
							[]f64{}
						}
						if times.len == 0 || times.len != vals.len {
							continue
						}
						secs := times.map(f64(it) / fbx_ticks_per_second)
						if secs.last() > tmax {
							tmax = secs.last()
						}
						ch.curves[k] = Curve{secs, vals}
					}
				}
				chans['${bone}|${what}'] = ch
			}
		}
		if chans.len == 0 {
			continue
		}
		mut dur := tmax
		if stop := stack.p70('LocalStop') {
			start := (stack.p70('LocalStart') or { [0.0] })[0]
			d := (stop[0] - start) / fbx_ticks_per_second
			if d > 0 {
				dur = d
			}
		}
		frames := int(math.round(dur * bake_fps)) + 1
		mut clip := Clip{
			name:     name_of(stack)
			duration: f32(dur)
			fps:      bake_fps
		}
		for f in 0 .. frames {
			t := f64(f) / bake_fps
			mut ft := []core.Vec3{len: m.bones.len}
			mut fr := []core.Quat{len: m.bones.len}
			mut fs := []core.Vec3{len: m.bones.len}
			for b in 0 .. m.bones.len {
				src := sc.bone_ids[b]
				mut x := src.xform
				if ch := chans['${b}|T'] {
					x.t = ch.at(t, x.t)
				}
				if ch := chans['${b}|R'] {
					x.r = ch.at(t, x.r)
				}
				if ch := chans['${b}|S'] {
					x.s = ch.at(t, x.s)
				}
				mut local := x.matrix(sc.unit)
				if m.bones[b].parent < 0 {
					local = sc.axis * local
				}
				ft[b], fr[b], fs[b] = local.decompose()
			}
			clip.t << ft
			clip.r << fr
			clip.s << fs
		}
		m.clips << clip
	}
	m.clips.sort(a.name < b.name)
}
