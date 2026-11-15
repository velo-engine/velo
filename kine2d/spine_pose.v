module kine2d

import math

// Spine 4.2 runtime subset: setup pose + one animation applied at full weight (no mixing between tracks).
//
// Applied: bone rotate / translate(x,y) / scale(x,y) / shear(x,y) timelines, slot attachment, rgba / rgb /
// alpha and draw order timelines, mesh deform (4.2 layout), linear / stepped / bezier curves, all five
// bone inherit modes, 1- and 2-bone IK constraints with their mix / bendPositive timelines, region and
// (weighted) mesh attachments, linked meshes, skins (the chosen skin, then `default`), additive blending.
// Not applied (listed in SpineData.skipped when a file uses them): transform / path / physics constraints,
// IK softness / stretch / compress, clipping, attachment sequences, tint black, events, multiply / screen
// blending (drawn normally).

pub struct SpWorld {
pub mut:
	a  f32 = 1
	b  f32
	c  f32
	d  f32 = 1
	wx f32
	wy f32
}

// SpLocal — a bone's applied local transform.
pub struct SpLocal {
pub mut:
	x   f32
	y   f32
	rot f32
	sx  f32 = 1
	sy  f32 = 1
	shx f32
	shy f32
}

// SpPiece — the triangles of one attachment, in pixels from the skeleton origin, y down; `uvs` in page pixels.
pub struct SpPiece {
pub mut:
	slot      int
	page      int
	positions []f32
	uvs       []f32
	indices   []int
	color     SpColor
	additive  bool
}

@[inline]
fn cosd(d f32) f32 {
	return f32(math.cos(f64(d) * math.pi / 180))
}

@[inline]
fn sind(d f32) f32 {
	return f32(math.sin(f64(d) * math.pi / 180))
}

const rad_deg = f32(180.0 / math.pi)

// key_eps: a time this close to a key counts as on it (JSON and caller times round differently in f32).
const key_eps = f32(0.00001)

// bezier_y: the curve value at `time` between keys (t0, v0) and (t1, v1) with control points (cx1, cy1), (cx2, cy2).
fn bezier_y(time f32, t0 f32, v0 f32, cx1 f32, cy1 f32, cx2 f32, cy2 f32, t1 f32, v1 f32) f32 {
	mut lo := f32(0)
	mut hi := f32(1)
	mut s := f32(0.5)
	for _ in 0 .. 24 {
		s = (lo + hi) * 0.5
		u := 1 - s
		x := u * u * u * t0 + 3 * u * u * s * cx1 + 3 * u * s * s * cx2 + s * s * s * t1
		if x < time {
			lo = s
		} else {
			hi = s
		}
	}
	u := 1 - s
	return u * u * u * v0 + 3 * u * u * s * cy1 + 3 * u * s * s * cy2 + s * s * s * v1
}

// sample: the timeline values at `t`, or none before the first key (the setup pose applies).
fn sample(keys []SpKey, t f32) ?[]f32 {
	if keys.len == 0 || t + key_eps < keys[0].time {
		return none
	}
	mut i := keys.len - 1
	for j in 1 .. keys.len {
		if keys[j].time > t + key_eps {
			i = j - 1
			break
		}
	}
	k := keys[i]
	if i == keys.len - 1 || k.stepped {
		return k.values
	}
	n := keys[i + 1]
	span := n.time - k.time
	mut out := []f32{len: k.values.len}
	for c in 0 .. k.values.len {
		v0 := k.values[c]
		v1 := if c < n.values.len { n.values[c] } else { v0 }
		if k.bezier.len >= (c + 1) * 4 {
			b := k.bezier[c * 4..c * 4 + 4]
			out[c] = bezier_y(t, k.time, v0, b[0], b[1], b[2], b[3], n.time, v1)
		} else {
			p := if span > 0 { (t - k.time) / span } else { 0 }
			out[c] = v0 + (v1 - v0) * p
		}
	}
	return out
}

fn sample_deform(keys []SpDeformKey, t f32) ?[]f32 {
	if keys.len == 0 || t + key_eps < keys[0].time {
		return none
	}
	mut i := keys.len - 1
	for j in 1 .. keys.len {
		if keys[j].time > t + key_eps {
			i = j - 1
			break
		}
	}
	k := keys[i]
	if i == keys.len - 1 || k.stepped {
		return k.offsets
	}
	n := keys[i + 1]
	span := n.time - k.time
	p := if k.bezier.len >= 4 {
		bezier_y(t, k.time, 0, k.bezier[0], k.bezier[1], k.bezier[2], k.bezier[3], n.time, 1)
	} else if span > 0 {
		(t - k.time) / span
	} else {
		0
	}
	mut out := []f32{len: k.offsets.len}
	for c in 0 .. out.len {
		v1 := if c < n.offsets.len { n.offsets[c] } else { 0 }
		out[c] = k.offsets[c] + (v1 - k.offsets[c]) * p
	}
	return out
}

// world_transform computes one bone's world matrix from its local transform (Bone.updateWorldTransformWith).
fn (d &SpineData) world_transform(i int, l SpLocal, mut w []SpWorld) {
	bone := d.bones[i]
	if bone.parent < 0 {
		ry := l.rot + 90 + l.shy
		w[i] = SpWorld{
			a:  cosd(l.rot + l.shx) * l.sx
			b:  cosd(ry) * l.sy
			c:  sind(l.rot + l.shx) * l.sx
			d:  sind(ry) * l.sy
			wx: l.x
			wy: l.y
		}
		return
	}
	p := w[bone.parent]
	mut pa, mut pb, mut pc, mut pd := p.a, p.b, p.c, p.d
	mut r := SpWorld{
		wx: pa * l.x + pb * l.y + p.wx
		wy: pc * l.x + pd * l.y + p.wy
	}
	match bone.inherit {
		.normal {
			ry := l.rot + 90 + l.shy
			la := cosd(l.rot + l.shx) * l.sx
			lb := cosd(ry) * l.sy
			lc := sind(l.rot + l.shx) * l.sx
			ld := sind(ry) * l.sy
			r.a = pa * la + pb * lc
			r.b = pa * lb + pb * ld
			r.c = pc * la + pd * lc
			r.d = pc * lb + pd * ld
		}
		.only_translation {
			ry := l.rot + 90 + l.shy
			r.a = cosd(l.rot + l.shx) * l.sx
			r.b = cosd(ry) * l.sy
			r.c = sind(l.rot + l.shx) * l.sx
			r.d = sind(ry) * l.sy
		}
		.no_rotation_or_reflection {
			mut s := pa * pa + pc * pc
			mut prx := f32(0)
			if s > 0.0001 {
				s = absf(pa * pd - pb * pc) / s
				pb = pc * s
				pd = pa * s
				prx = f32(math.atan2(f64(pc), f64(pa))) * rad_deg
			} else {
				pa = 0
				pc = 0
				prx = 90 - f32(math.atan2(f64(pd), f64(pb))) * rad_deg
			}
			rx := l.rot + l.shx - prx
			ry := l.rot + l.shy - prx + 90
			la := cosd(rx) * l.sx
			lb := cosd(ry) * l.sy
			lc := sind(rx) * l.sx
			ld := sind(ry) * l.sy
			r.a = pa * la - pb * lc
			r.b = pa * lb - pb * ld
			r.c = pc * la + pd * lc
			r.d = pc * lb + pd * ld
		}
		.no_scale, .no_scale_or_reflection {
			rot := f64(l.rot) * math.pi / 180
			cs, sn := f32(math.cos(rot)), f32(math.sin(rot))
			mut za := pa * cs + pb * sn
			mut zc := pc * cs + pd * sn
			mut s := f32(math.sqrt(f64(za * za + zc * zc)))
			if s > 0.00001 {
				s = 1 / s
			}
			za *= s
			zc *= s
			s = f32(math.sqrt(f64(za * za + zc * zc)))
			if bone.inherit == .no_scale && (pa * pd - pb * pc < 0) {
				s = -s
			}
			r2 := math.pi / 2 + math.atan2(f64(zc), f64(za))
			zb := f32(math.cos(r2)) * s
			zd := f32(math.sin(r2)) * s
			la := cosd(l.shx) * l.sx
			lb := cosd(90 + l.shy) * l.sy
			lc := sind(l.shx) * l.sx
			ld := sind(90 + l.shy) * l.sy
			r.a = za * la + zb * lc
			r.b = za * lb + zb * ld
			r.c = zc * la + zd * lc
			r.d = zc * lb + zd * ld
		}
	}
	w[i] = r
}

@[inline]
fn absf(x f32) f32 {
	return if x < 0 { -x } else { x }
}

fn wrap180(x f32) f32 {
	return if x > 180 {
		x - 360
	} else if x < -180 {
		x + 360
	} else {
		x
	}
}

fn (d &SpineData) update_all(locals []SpLocal, mut w []SpWorld) {
	for i in 0 .. d.bones.len {
		d.world_transform(i, locals[i], mut w)
	}
}

// ik1 points one bone at the target (IkConstraint.apply1, no stretch).
fn (d &SpineData) ik1(bi int, tx f32, ty f32, alpha f32, mut locals []SpLocal, w []SpWorld) {
	bone := d.bones[bi]
	if bone.parent < 0 {
		return
	}
	p := w[bone.parent]
	l := locals[bi]
	mut rot_ik := -l.shx - l.rot
	mut x := f32(0)
	mut y := f32(0)
	if bone.inherit == .only_translation {
		x = tx - w[bi].wx
		y = ty - w[bi].wy
	} else {
		dx := tx - p.wx
		dy := ty - p.wy
		det := p.a * p.d - p.b * p.c
		if absf(det) > 0.0001 {
			x = (dx * p.d - dy * p.b) / det - l.x
			y = (dy * p.a - dx * p.c) / det - l.y
		}
	}
	rot_ik += f32(math.atan2(f64(y), f64(x))) * rad_deg
	if l.sx < 0 {
		rot_ik += 180
	}
	rot_ik = wrap180(rot_ik)
	locals[bi].rot = l.rot + rot_ik * alpha
}

// ik2 bends a parent/child chain toward the target (IkConstraint.apply2, no stretch or softness).
fn (d &SpineData) ik2(pi int, ci int, tx f32, ty f32, bend int, alpha f32, mut locals []SpLocal, mut w []SpWorld) {
	parent := d.bones[pi]
	child := d.bones[ci]
	if parent.parent < 0 {
		return
	}
	pl := locals[pi]
	cl := locals[ci]
	px, py := pl.x, pl.y
	mut psx, mut psy := pl.sx, pl.sy
	mut csx := cl.sx
	mut os1 := f32(0)
	mut s2 := f32(1)
	mut os2 := f32(0)
	if psx < 0 {
		psx = -psx
		os1 = 180
		s2 = -1
	}
	if psy < 0 {
		psy = -psy
		s2 = -s2
	}
	if csx < 0 {
		csx = -csx
		os2 = 180
	}
	pw := w[pi]
	cx := cl.x
	mut cy := f32(0)
	mut cwx := f32(0)
	mut cwy := f32(0)
	u := absf(psx - psy) <= 0.0001
	if !u {
		cwx = pw.a * cx + pw.wx
		cwy = pw.c * cx + pw.wy
	} else {
		cy = cl.y
		cwx = pw.a * cx + pw.b * cy + pw.wx
		cwy = pw.c * cx + pw.d * cy + pw.wy
	}
	pp := w[parent.parent]
	mut id := pp.a * pp.d - pp.b * pp.c
	id = if absf(id) <= 0.0001 { 0 } else { 1 / id }
	mut x := cwx - pp.wx
	mut y := cwy - pp.wy
	dx := (x * pp.d - y * pp.b) * id - px
	dy := (y * pp.a - x * pp.c) * id - py
	l1 := f32(math.sqrt(f64(dx * dx + dy * dy)))
	mut l2 := child.length * csx
	if l1 < 0.0001 {
		d.ik1(pi, tx, ty, alpha, mut locals, w)
		locals[ci].rot = cl.rot
		return
	}
	x = tx - pp.wx
	y = ty - pp.wy
	ttx := (x * pp.d - y * pp.b) * id - px
	tty := (y * pp.a - x * pp.c) * id - py
	dd := ttx * ttx + tty * tty
	bd := f32(bend)
	mut a1 := f32(0)
	mut a2 := f32(0)
	if u {
		l2 *= psx
		mut cs := (dd - l1 * l1 - l2 * l2) / (2 * l1 * l2)
		if cs < -1 {
			cs = -1
			a2 = f32(math.pi) * bd
		} else if cs > 1 {
			cs = 1
			a2 = 0
		} else {
			a2 = f32(math.acos(f64(cs))) * bd
		}
		aa := l1 + l2 * cs
		bb := l2 * f32(math.sin(f64(a2)))
		a1 = f32(math.atan2(f64(tty * aa - ttx * bb), f64(ttx * aa + tty * bb)))
	} else {
		a := psx * l2
		b := psy * l2
		aa := a * a
		bb := b * b
		ta := f32(math.atan2(f64(tty), f64(ttx)))
		mut c := bb * l1 * l1 + aa * dd - aa * bb
		c1 := -2 * bb * l1
		c2 := bb - aa
		disc := c1 * c1 - 4 * c2 * c
		mut done := false
		if disc >= 0 && c2 != 0 {
			mut q := f32(math.sqrt(f64(disc)))
			if c1 < 0 {
				q = -q
			}
			q = -(c1 + q) * 0.5
			r0 := q / c2
			r1 := if q != 0 { c / q } else { r0 }
			r := if absf(r0) < absf(r1) { r0 } else { r1 }
			if r * r <= dd {
				yy := f32(math.sqrt(f64(dd - r * r))) * bd
				a1 = ta - f32(math.atan2(f64(yy), f64(r)))
				a2 = f32(math.atan2(f64(yy / psy), f64((r - l1) / psx)))
				done = true
			}
		}
		if !done {
			mut min_angle := f32(math.pi)
			mut min_x := l1 - a
			mut min_dist := min_x * min_x
			mut min_y := f32(0)
			mut max_angle := f32(0)
			mut max_x := l1 + a
			mut max_dist := max_x * max_x
			mut max_y := f32(0)
			c = -a * l1 / (aa - bb)
			if c >= -1 && c <= 1 {
				c = f32(math.acos(f64(c)))
				xx := a * f32(math.cos(f64(c))) + l1
				yy := b * f32(math.sin(f64(c)))
				dist := xx * xx + yy * yy
				if dist < min_dist {
					min_angle = c
					min_dist = dist
					min_x = xx
					min_y = yy
				}
				if dist > max_dist {
					max_angle = c
					max_dist = dist
					max_x = xx
					max_y = yy
				}
			}
			if dd <= (min_dist + max_dist) * 0.5 {
				a1 = ta - f32(math.atan2(f64(min_y * bd), f64(min_x)))
				a2 = min_angle * bd
			} else {
				a1 = ta - f32(math.atan2(f64(max_y * bd), f64(max_x)))
				a2 = max_angle * bd
			}
		}
	}
	os := f32(math.atan2(f64(cy), f64(cx))) * s2
	mut rot := pl.rot
	a1 = wrap180((a1 - os) * rad_deg + os1 - rot)
	locals[pi].rot = rot + a1 * alpha
	locals[pi].shx = 0
	locals[pi].shy = 0
	locals[ci].x = cx
	locals[ci].y = cy
	rot = cl.rot
	a2 = wrap180(((a2 + os) * rad_deg - cl.shx) * s2 + os2 - rot)
	locals[ci].rot = rot + a2 * alpha
}

// SpinePose — everything build() needs for one moment of an animation.
pub struct SpinePose {
pub mut:
	world   []SpWorld
	colors  []SpColor
	attach  []string // per slot ('' = none)
	order   []int
	deforms map[string][]f32 // '<slot>/<attachment>' -> offsets
}

// pose evaluates `anim` (or the setup pose) at `t` seconds.
pub fn (d &SpineData) pose(anim ?SpAnimation, t f32) SpinePose {
	mut locals := d.bones.map(SpLocal{it.x, it.y, it.rotation, it.scale_x, it.scale_y, it.shear_x, it.shear_y})
	mut p := SpinePose{
		world:  []SpWorld{len: d.bones.len}
		colors: d.slots.map(it.color)
		attach: d.slots.map(it.attachment)
		order:  []int{len: d.slots.len, init: index}
	}
	mut ik_mix := d.iks.map(it.mix)
	mut ik_bend := d.iks.map(it.bend)
	if a := anim {
		for tl in a.bones {
			v := sample(tl.keys, t) or { continue }
			setup := d.bones[tl.bone]
			b := tl.bone
			match tl.prop {
				.rotate {
					locals[b].rot = setup.rotation + v[0]
				}
				.translate {
					locals[b].x = setup.x + v[0]
					locals[b].y = setup.y + v[1]
				}
				.translate_x {
					locals[b].x = setup.x + v[0]
				}
				.translate_y {
					locals[b].y = setup.y + v[0]
				}
				.scale {
					locals[b].sx = setup.scale_x * v[0]
					locals[b].sy = setup.scale_y * v[1]
				}
				.scale_x {
					locals[b].sx = setup.scale_x * v[0]
				}
				.scale_y {
					locals[b].sy = setup.scale_y * v[0]
				}
				.shear {
					locals[b].shx = setup.shear_x + v[0]
					locals[b].shy = setup.shear_y + v[1]
				}
				.shear_x {
					locals[b].shx = setup.shear_x + v[0]
				}
				.shear_y {
					locals[b].shy = setup.shear_y + v[0]
				}
			}
		}
		for tl in a.colors {
			v := sample(tl.keys, t) or { continue }
			si := tl.slot
			match tl.prop {
				.rgba {
					p.colors[si] = SpColor{v[0], v[1], v[2], v[3]}
				}
				.rgb {
					p.colors[si] = SpColor{v[0], v[1], v[2], p.colors[si].a}
				}
				.alpha {
					p.colors[si].a = v[0]
				}
			}
		}
		for tl in a.attach {
			if tl.keys.len == 0 || t + key_eps < tl.keys[0].time {
				continue
			}
			mut name := tl.keys[0].name
			for k in tl.keys {
				if k.time <= t + key_eps {
					name = k.name
				}
			}
			p.attach[tl.slot] = name
		}
		for tl in a.deforms {
			offs := sample_deform(tl.keys, t) or { continue }
			p.deforms['${tl.slot}/${tl.attachment}'] = offs
		}
		if a.draw_order.len > 0 && t + key_eps >= a.draw_order[0].time {
			mut ki := 0
			for i, k in a.draw_order {
				if k.time <= t + key_eps {
					ki = i
				}
			}
			if a.draw_order[ki].order.len == d.slots.len {
				p.order = a.draw_order[ki].order.clone()
			}
		}
		for tl in a.iks {
			v := sample(tl.keys, t) or { continue }
			ik_mix[tl.ik] = v[0]
			// bendPositive switches at keys (never interpolated)
			mut bend := tl.keys[0].values[1]
			for k in tl.keys {
				if k.time <= t + key_eps {
					bend = k.values[1]
				}
			}
			ik_bend[tl.ik] = if bend < 0 { -1 } else { 1 }
		}
	}
	d.update_all(locals, mut p.world)
	if d.iks.len > 0 {
		mut order := []int{len: d.iks.len, init: index}
		order.sort_with_compare(fn [d] (x &int, y &int) int {
			return d.iks[*x].order - d.iks[*y].order
		})
		for i in order {
			ik := d.iks[i]
			if ik_mix[i] <= 0 || ik.bones.len == 0 {
				continue
			}
			tw := p.world[ik.target]
			if ik.bones.len == 1 {
				d.ik1(ik.bones[0], tw.wx, tw.wy, ik_mix[i], mut locals, p.world)
			} else {
				d.ik2(ik.bones[0], ik.bones[1], tw.wx, tw.wy, ik_bend[i], ik_mix[i], mut locals, mut
					p.world)
			}
			d.update_all(locals, mut p.world)
		}
	}
	return p
}

// find_attachment looks the attachment up in `skin`, then in the default skin.
pub fn (d &SpineData) find_attachment(skin string, slot int, name string) ?SpAttachment {
	key := '${slot}/${name}'
	if skin != '' && skin != 'default' {
		for s in d.skins {
			if s.name == skin {
				if a := s.attachments[key] {
					return a
				}
			}
		}
	}
	for s in d.skins {
		if s.name == 'default' {
			if a := s.attachments[key] {
				return a
			}
		}
	}
	return none
}

// build returns the drawable pieces of `anim` at `t` seconds, in draw order (y down).
pub fn (d &SpineData) build(atlas &SpAtlas, anim ?SpAnimation, t f32, skin string) []SpPiece {
	p := d.pose(anim, t)
	mut out := []SpPiece{}
	for si in p.order {
		name := p.attach[si]
		if name == '' {
			continue
		}
		slot := d.slots[si]
		att := d.find_attachment(skin, si, name) or { continue }
		if att.kind == .other {
			continue
		}
		region := atlas.regions[att.path] or { continue }
		if region.page < 0 || region.page >= atlas.pages.len {
			continue
		}
		sc := p.colors[si]
		col := SpColor{sc.r * att.color.r, sc.g * att.color.g, sc.b * att.color.b, sc.a * att.color.a}
		if col.a <= 0 {
			continue
		}
		bw := p.world[slot.bone]
		mut piece := SpPiece{
			slot:     si
			page:     region.page
			color:    col
			additive: slot.blend == 'additive'
		}
		if att.kind == .region {
			region_geometry(att, region, bw, mut piece)
		} else {
			deform := p.deforms['${si}/${name}'] or { []f32{} }
			mesh_geometry(att, region, bw, p.world, deform, mut piece)
		}
		out << piece
	}
	return out
}

fn region_geometry(att SpAttachment, r SpRegion, w SpWorld, mut piece SpPiece) {
	rsx := att.width / r.orig_w * att.scale_x
	rsy := att.height / r.orig_h * att.scale_y
	lx := -att.width / 2 * att.scale_x + r.offset_x * rsx
	ly := -att.height / 2 * att.scale_y + r.offset_y * rsy
	lx2 := lx + f32(r.width) * rsx
	ly2 := ly + f32(r.height) * rsy
	cs := cosd(att.rotation)
	sn := sind(att.rotation)
	lxc := lx * cs + att.x
	lxs := lx * sn
	lyc := ly * cs + att.y
	lys := ly * sn
	lx2c := lx2 * cs + att.x
	lx2s := lx2 * sn
	ly2c := ly2 * cs + att.y
	ly2s := ly2 * sn
	// corners: BL, UL, UR, BR (attachment space, y up)
	corners := [lxc - lys, lyc + lxs, lxc - ly2s, ly2c + lxs, lx2c - ly2s, ly2c + lx2s, lx2c - lys,
		lyc + lx2s]
	for i := 0; i < 8; i += 2 {
		ox, oy := corners[i], corners[i + 1]
		piece.positions << ox * w.a + oy * w.b + w.wx
		piece.positions << -(ox * w.c + oy * w.d + w.wy)
	}
	x, y := f32(r.x), f32(r.y)
	if r.degrees == 90 {
		x2 := x + f32(r.height)
		y2 := y + f32(r.width)
		piece.uvs = [x2, y2, x, y2, x, y, x2, y]
	} else {
		x2 := x + f32(r.width)
		y2 := y + f32(r.height)
		piece.uvs = [x, y2, x, y, x2, y, x2, y2]
	}
	piece.indices = [0, 1, 2, 2, 3, 0]
}

fn mesh_geometry(att SpAttachment, r SpRegion, bw SpWorld, world []SpWorld, deform []f32, mut piece SpPiece) {
	n := att.uvs.len / 2
	if !att.weighted {
		for i in 0 .. n {
			mut vx := att.vertices[i * 2]
			mut vy := att.vertices[i * 2 + 1]
			if deform.len >= (i + 1) * 2 {
				vx += deform[i * 2]
				vy += deform[i * 2 + 1]
			}
			piece.positions << vx * bw.a + vy * bw.b + bw.wx
			piece.positions << -(vx * bw.c + vy * bw.d + bw.wy)
		}
	} else {
		mut bi := 0 // into att.bones
		mut vi := 0 // influence index (3 floats each in vertices, 2 in deform)
		for _ in 0 .. n {
			count := att.bones[bi]
			bi++
			mut wx := f32(0)
			mut wy := f32(0)
			for _ in 0 .. count {
				b := world[att.bones[bi]]
				bi++
				mut vx := att.vertices[vi * 3]
				mut vy := att.vertices[vi * 3 + 1]
				weight := att.vertices[vi * 3 + 2]
				if deform.len >= (vi + 1) * 2 {
					vx += deform[vi * 2]
					vy += deform[vi * 2 + 1]
				}
				wx += (vx * b.a + vy * b.b + b.wx) * weight
				wy += (vx * b.c + vy * b.d + b.wy) * weight
				vi++
			}
			piece.positions << wx
			piece.positions << -wy
		}
	}
	// region-relative uvs -> page pixels (MeshAttachment.updateRegion)
	mut u := f32(r.x)
	mut v := f32(r.y)
	if r.degrees == 90 {
		u -= r.orig_h - r.offset_y - f32(r.height)
		v -= r.orig_w - r.offset_x - f32(r.width)
		for i in 0 .. n {
			piece.uvs << u + att.uvs[i * 2 + 1] * r.orig_h
			piece.uvs << v + (1 - att.uvs[i * 2]) * r.orig_w
		}
	} else {
		u -= r.offset_x
		v -= r.orig_h - r.offset_y - f32(r.height)
		for i in 0 .. n {
			piece.uvs << u + att.uvs[i * 2] * r.orig_w
			piece.uvs << v + att.uvs[i * 2 + 1] * r.orig_h
		}
	}
	piece.indices = att.triangles.clone()
}
