module kine2d

import math

// Sampling and geometry, ported from the Kine2D SDL runtime (safe-engine Kine2D.ts) and the editor's
// timeline math, so an export looks the same here as in the editor's PREVIEW. Needs no GPU.

// Pose — a bone's transform at some frame (absolute, canvas units like Bone).
pub struct Pose {
pub mut:
	x        f32
	y        f32
	rotation f32
	scale_x  f32 = 1
	scale_y  f32 = 1
}

pub fn (b &Bone) pose() Pose {
	return Pose{b.x, b.y, b.rotation, b.scale_x, b.scale_y}
}

// DrawPiece — the textured triangles of one slot, in pixels from the skeleton origin (the editor's
// canvas center), y down. `uvs` are pixels in the atlas page image `page`.
pub struct DrawPiece {
pub mut:
	slot      string
	page      int
	positions []f32 // x0, y0, x1, y1, ...
	uvs       []f32 // same layout, page pixels
	indices   []int
}

// bone_name maps a bone reference (a name, or an editor id in some exports) to the bone's name.
pub fn (s &SkeletonData) bone_name(key string) string {
	for b in s.bones {
		if b.name == key || (b.id != '' && b.id == key) {
			return b.name
		}
	}
	return key
}

// sample_pose returns every bone's pose at `frame` (0 .. anim.length), keyed by bone name.
pub fn (s &SkeletonData) sample_pose(anim ?Animation, frame f32) map[string]Pose {
	mut out := map[string]Pose{}
	for b in s.bones {
		mut p := b.pose()
		if a := anim {
			keys := a.bones[b.name] or { a.bones[b.id] or { []BoneKey{} } }
			if keys.len > 0 {
				p = sample_bone(b, keys, frame)
			}
		}
		out[b.name] = p
	}
	return out
}

// sample_bone: position, rotation and scale are separate tracks (a key may set only some of them).
// Before its first key a track keeps the setup value, after its last key it holds the last value.
pub fn sample_bone(b Bone, keys []BoneKey, frame f32) Pose {
	mut p := b.pose()
	// Position (x and y share one track and one curve).
	mut prev := -1
	mut next := -1
	for i, k in keys {
		if k.x == none && k.y == none {
			continue
		}
		if k.frame <= frame {
			prev = i
		}
		if k.frame >= frame && next < 0 {
			next = i
		}
	}
	if prev >= 0 {
		pk := keys[prev]
		px := pk.x or { b.x }
		py := pk.y or { b.y }
		if next >= 0 && keys[next].frame != pk.frame {
			nk := keys[next]
			t := ease((frame - pk.frame) / (nk.frame - pk.frame), pk.pos_curve)
			nx := nk.x or { px }
			ny := nk.y or { py }
			p.x = px + (nx - px) * t
			p.y = py + (ny - py) * t
		} else {
			p.x = px
			p.y = py
		}
	}
	// Rotation, along the shortest way around.
	prev, next = -1, -1
	for i, k in keys {
		if k.rotation == none {
			continue
		}
		if k.frame <= frame {
			prev = i
		}
		if k.frame >= frame && next < 0 {
			next = i
		}
	}
	if prev >= 0 {
		pk := keys[prev]
		from := pk.rotation or { b.rotation }
		p.rotation = from
		if next >= 0 && keys[next].frame != pk.frame {
			nk := keys[next]
			to := nk.rotation or { from }
			p.rotation = from + shortest_rotation(from, to) * ease((frame -
				pk.frame) / (nk.frame - pk.frame), pk.rot_curve)
		}
	}
	// Scale (linear).
	prev, next = -1, -1
	for i, k in keys {
		if k.scale_x == none && k.scale_y == none {
			continue
		}
		if k.frame <= frame {
			prev = i
		}
		if k.frame >= frame && next < 0 {
			next = i
		}
	}
	if prev >= 0 {
		pk := keys[prev]
		sx := pk.scale_x or { b.scale_x }
		sy := pk.scale_y or { b.scale_y }
		p.scale_x = sx
		p.scale_y = sy
		if next >= 0 && keys[next].frame != pk.frame {
			nk := keys[next]
			t := (frame - pk.frame) / (nk.frame - pk.frame)
			p.scale_x = sx + ((nk.scale_x or { sx }) - sx) * t
			p.scale_y = sy + ((nk.scale_y or { sy }) - sy) * t
		}
	}
	return p
}

pub fn shortest_rotation(from f32, to f32) f32 {
	return f32(math.fmod(math.fmod(f64(to - from), 360) + 540, 360) - 180)
}

// ease maps linear progress 0..1 through a key's curve (none = linear).
pub fn ease(t f32, curve ?Curve) f32 {
	c := curve or { return t }
	x := if t < 0 {
		f32(0)
	} else if t > 1 {
		f32(1)
	} else {
		t
	}
	if c.kind != '' && c.kind != 'bezier' {
		return easing(x, c.kind)
	}
	if x == 0 || x == 1 || (c.x1 == c.y1 && c.x2 == c.y2) {
		return x
	}
	// Solve bezier_x(u) = x by bisection, then return bezier_y(u) (like CSS cubic-bezier).
	mut lo, mut hi := f32(0), f32(1)
	for _ in 0 .. 24 {
		u := (lo + hi) / 2
		if bezier(u, c.x1, c.x2) < x {
			lo = u
		} else {
			hi = u
		}
	}
	return bezier((lo + hi) / 2, c.y1, c.y2)
}

fn bezier(t f32, p1 f32, p2 f32) f32 {
	u := 1 - t
	return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
}

fn bounce_out(t f32) f32 {
	n1, d1 := f32(7.5625), f32(2.75)
	if t < 1 / d1 {
		return n1 * t * t
	} else if t < 2 / d1 {
		t2 := t - 1.5 / d1
		return n1 * t2 * t2 + 0.75
	} else if t < 2.5 / d1 {
		t2 := t - 2.25 / d1
		return n1 * t2 * t2 + 0.9375
	}
	t2 := t - 2.625 / d1
	return n1 * t2 * t2 + 0.984375
}

fn easing(t f32, kind string) f32 {
	c4 := 2 * math.pi / 3
	c1 := 1.70158
	return match kind {
		'bounce-out' {
			bounce_out(t)
		}
		'bounce-in' {
			1 - bounce_out(1 - t)
		}
		'bounce-in-out' {
			if t < 0.5 {
				(1 - bounce_out(1 - 2 * t)) / 2
			} else {
				(1 + bounce_out(2 * t - 1)) / 2
			}
		}
		'elastic-out' {
			if t == 0 || t == 1 {
				t
			} else {
				f32(math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * c4) + 1)
			}
		}
		'elastic-in' {
			if t == 0 || t == 1 {
				t
			} else {
				f32(-math.pow(2, 10 * t - 10) * math.sin((t * 10 - 10.75) * c4))
			}
		}
		'back-out' {
			f32(1 + (c1 + 1) * math.pow(t - 1, 3) + c1 * math.pow(t - 1, 2))
		}
		'back-in' {
			f32((c1 + 1) * t * t * t - c1 * t * t)
		}
		else {
			t
		}
	}
}

// slots_at: the slots in draw order at `frame` (an animation can reorder them).
pub fn (s &SkeletonData) slots_at(anim ?Animation, frame f32) []Slot {
	a := anim or { return s.slots }
	mut oi := -1
	for i, k in a.order {
		if k.frame <= frame {
			oi = i
		}
	}
	if oi < 0 {
		return s.slots
	}
	order := a.order[oi].slots
	mut used := map[string]bool{}
	mut out := []Slot{cap: s.slots.len}
	for key in order {
		for sl in s.slots {
			if sl.key == key && sl.key !in used {
				out << sl
				used[key] = true
				break
			}
		}
	}
	for sl in s.slots {
		if sl.key !in used {
			out << sl
		}
	}
	return out
}

// attachment_at: what `slot` shows at `frame` with the given skin (none = hidden).
pub fn (s &SkeletonData) attachment_at(slot &Slot, skin ?Skin, anim ?Animation, frame f32) ?Attachment {
	mut state := slot.state
	if sk := skin {
		if e := sk.attachments[slot.key] {
			if e.hidden {
				return none
			}
			state = e.state
		}
	}
	legacy := if state.hidden_by_path {
		-1
	} else if p := state.active_path {
		state.attachments.map(it.path).index(p)
	} else {
		0
	}
	mut index := state.display_index or { legacy }
	if a := anim {
		// Display keys accumulate: each key only lists the slots it changes.
		for k in a.display {
			if k.frame > frame {
				break
			}
			if v := k.values[slot.key] {
				index = v
			}
		}
	}
	if index < 0 || index >= state.attachments.len {
		return none
	}
	return state.attachments[index]
}

// skin_for returns the skin to use: `key` (an id or name), or the export's active skin when empty.
// The "default" skin changes nothing.
pub fn (s &SkeletonData) skin_for(key string) ?Skin {
	k := if key == '' { s.active_skin } else { key }
	if k == '' || k == 'default' {
		return none
	}
	return s.find_skin(k)
}

// build returns what to draw at `frame`: one DrawPiece per visible slot, back to front.
pub fn (s &SkeletonData) build(atlas &Atlas, anim ?Animation, frame f32, skin_key string) []DrawPiece {
	pose := s.sample_pose(anim, frame)
	skin := s.skin_for(skin_key)
	mut out := []DrawPiece{}
	for slot in s.slots_at(anim, frame) {
		att := s.attachment_at(slot, skin, anim, frame) or { continue }
		bone_name := s.bone_name(slot.bone)
		bone := pose[bone_name] or { continue }
		region := atlas.find(att.path) or { continue }
		if mesh := att.mesh {
			if piece := s.mesh_piece(slot, att, mesh, region, bone_name, pose, anim, frame) {
				out << piece
			}
		} else {
			out << s.region_piece(slot, att, region, bone)
		}
	}
	return out
}

// origin: a pose's position in pixels from the canvas center.
fn (s &SkeletonData) origin(p Pose) (f32, f32) {
	return p.x * s.canvas_width / 100, p.y * s.canvas_height / 180
}

fn rotate(x f32, y f32, deg f32) (f32, f32) {
	r := f64(deg) * math.pi / 180
	cs := f32(math.cos(r))
	sn := f32(math.sin(r))
	return x * cs - y * sn, x * sn + y * cs
}

// region_piece: a quad whose left edge's middle sits at the attachment's (x, y) in bone space.
fn (s &SkeletonData) region_piece(slot &Slot, att &Attachment, region &Region, bone Pose) DrawPiece {
	w := if att.has_size { att.width } else { f32(region.width) }
	h := if att.has_size { att.height } else { f32(region.height) }
	sx := bone.scale_x * att.scale_x
	sy := bone.scale_y * att.scale_y
	ox, oy := s.origin(bone)
	cx, cy := rotate(att.x + w * sx / 2, att.y, bone.rotation)
	rot := bone.rotation + att.rotation
	hw := w * sx / 2
	hh := h * sy / 2
	mut positions := []f32{cap: 8}
	for c in [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]] {
		dx, dy := rotate(c[0], c[1], rot)
		positions << ox + cx + dx
		positions << oy + cy + dy
	}
	u0, v0 := f32(region.x), f32(region.y)
	u1, v1 := u0 + region.width, v0 + region.height
	return DrawPiece{
		slot:      slot.key
		page:      region.page
		positions: positions
		uvs:       [u0, v0, u1, v0, u1, v1, u0, v1]
		indices:   [0, 1, 2, 0, 2, 3]
	}
}

fn (s &SkeletonData) mesh_piece(slot &Slot, att &Attachment, mesh &Mesh, region &Region, bone_name string, pose map[string]Pose, anim ?Animation, frame f32) ?DrawPiece {
	if mesh.vertices.len != mesh.uvs.len || mesh.vertices.len % 2 != 0 {
		return none
	}
	vertices := deformed(mesh.vertices, anim, slot.key, frame)
	mut bind := map[string]Pose{}
	bind_bones := if mesh.bind_bones.len > 0 { mesh.bind_bones } else { s.bones }
	for b in bind_bones {
		bind[b.name] = b.pose()
		if b.id != '' {
			bind[b.id] = b.pose()
		}
	}
	rest_bone := bind[bone_name] or { return none }
	cur_bone := pose[bone_name] or { return none }
	rest := s.mesh_positions(att, mesh, vertices, rest_bone)
	current := s.mesh_positions(att, mesh, vertices, cur_bone)
	mut positions := []f32{len: vertices.len}
	for i := 0; i < positions.len; i += 2 {
		weights := if i / 2 < mesh.weights.len {
			mesh.weights[i / 2]
		} else {
			map[string]f32{}
		}
		mut x, mut y, mut total := f32(0), f32(0), f32(0)
		for name, w in weights {
			if w <= 0 {
				continue
			}
			setup := bind[name] or { continue }
			cur := pose[s.bone_name(name)] or { continue }
			px, py := s.from_setup(rest[i], rest[i + 1], setup, cur)
			x += px * w
			y += py * w
			total += w
		}
		if total > 0 {
			positions[i] = x / total
			positions[i + 1] = y / total
		} else {
			positions[i] = current[i]
			positions[i + 1] = current[i + 1]
		}
	}
	mut uvs := []f32{len: mesh.uvs.len}
	for i := 0; i < uvs.len; i += 2 {
		uvs[i] = region.x + mesh.uvs[i] * region.width
		uvs[i + 1] = region.y + mesh.uvs[i + 1] * region.height
	}
	return DrawPiece{
		slot:      slot.key
		page:      region.page
		positions: positions
		uvs:       uvs
		indices:   mesh.triangles.clone()
	}
}

// mesh_positions places the vertices on `bone`: scaled from the attachment's (x, y), turned by the
// attachment rotation around the mesh center, then by the bone.
fn (s &SkeletonData) mesh_positions(att &Attachment, mesh &Mesh, vertices []f32, bone Pose) []f32 {
	sx := bone.scale_x * att.scale_x
	sy := bone.scale_y * att.scale_y
	mut local := []f32{len: vertices.len}
	mut min_x, mut min_y := f32(math.max_f32), f32(math.max_f32)
	mut max_x, mut max_y := -f32(math.max_f32), -f32(math.max_f32)
	for i := 0; i < vertices.len; i += 2 {
		x := att.x + vertices[i] * sx
		y := att.y + vertices[i + 1] * sy
		local[i] = x
		local[i + 1] = y
		min_x = if x < min_x { x } else { min_x }
		max_x = if x > max_x { x } else { max_x }
		min_y = if y < min_y { y } else { min_y }
		max_y = if y > max_y { y } else { max_y }
	}
	cx := if mesh.has_size { att.x + mesh.width * sx / 2 } else { (min_x + max_x) / 2 }
	cy := if mesh.has_size { att.y } else { (min_y + max_y) / 2 }
	ox, oy := s.origin(bone)
	mut out := []f32{len: vertices.len}
	for i := 0; i < local.len; i += 2 {
		ax, ay := rotate(local[i] - cx, local[i + 1] - cy, att.rotation)
		bx, by := rotate(cx + ax, cy + ay, bone.rotation)
		out[i] = ox + bx
		out[i + 1] = oy + by
	}
	return out
}

// from_setup moves a point that sits on bone `setup` (bind pose) along with the bone to `cur`.
fn (s &SkeletonData) from_setup(x f32, y f32, setup Pose, cur Pose) (f32, f32) {
	sox, soy := s.origin(setup)
	mut lx, mut ly := rotate(x - sox, y - soy, -setup.rotation)
	lx /= if math.abs(setup.scale_x) > 1e-6 { setup.scale_x } else { 1 }
	ly /= if math.abs(setup.scale_y) > 1e-6 { setup.scale_y } else { 1 }
	cox, coy := s.origin(cur)
	rx, ry := rotate(lx * cur.scale_x, ly * cur.scale_y, cur.rotation)
	return cox + rx, coy + ry
}

// deformed adds the slot's mesh deform offsets at `frame` (linear between keys).
fn deformed(vertices []f32, anim ?Animation, slot string, frame f32) []f32 {
	a := anim or { return vertices }
	keys := a.deforms[slot] or { return vertices }
	mut prev := -1
	mut next := -1
	for i, k in keys {
		if k.offsets.len != vertices.len {
			continue
		}
		if k.frame <= frame {
			prev = i
		}
		if k.frame >= frame && next < 0 {
			next = i
		}
	}
	if prev < 0 {
		return vertices
	}
	from := keys[prev].offsets
	to := if next >= 0 { keys[next].offsets } else { from }
	t := if next >= 0 && keys[next].frame != keys[prev].frame {
		(frame - keys[prev].frame) / (keys[next].frame - keys[prev].frame)
	} else {
		f32(0)
	}
	mut out := []f32{len: vertices.len}
	for i in 0 .. vertices.len {
		out[i] = vertices[i] + from[i] + (to[i] - from[i]) * t
	}
	return out
}
