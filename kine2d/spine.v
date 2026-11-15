module kine2d

import x.json2

// Spine 4.2 JSON skeletons and libGDX/Spine `.atlas` files, read next to the Kine2D format.
// A Kine2D component whose `data` is a Spine 4.2 export (`"skeleton": {"spine": "4.2..."}`) and whose `atlas`
// is a Spine text atlas plays it directly (see spine_pose.v for what is applied).
//
// Coordinates stay Spine's (y up, degrees counter-clockwise, bones relative to their parent) until the
// pose is built; build() returns pieces in the Kine2D convention (y down, pixels from the skeleton origin).

pub enum SpInherit {
	normal
	only_translation
	no_rotation_or_reflection
	no_scale
	no_scale_or_reflection
}

pub struct SpColor {
pub mut:
	r f32 = 1
	g f32 = 1
	b f32 = 1
	a f32 = 1
}

pub struct SpBone {
pub mut:
	name     string
	parent   int = -1
	length   f32
	x        f32
	y        f32
	rotation f32
	scale_x  f32 = 1
	scale_y  f32 = 1
	shear_x  f32
	shear_y  f32
	inherit  SpInherit
}

pub struct SpSlot {
pub mut:
	name       string
	bone       int
	color      SpColor
	attachment string // setup attachment ('' = none)
	blend      string // normal | additive | multiply | screen
}

pub enum SpAttachmentKind {
	region
	mesh
	other // bounding boxes, points, paths, clipping: not drawn
}

pub struct SpAttachment {
pub mut:
	kind     SpAttachmentKind
	name     string
	path     string // atlas region name
	x        f32
	y        f32
	rotation f32
	scale_x  f32 = 1
	scale_y  f32 = 1
	width    f32
	height   f32
	color    SpColor
	// mesh
	uvs       []f32 // region-relative 0..1
	triangles []int
	vertices  []f32 // unweighted: x, y per vertex; weighted: x, y, weight per influence
	bones     []int // weighted: per vertex, the influence count followed by bone indices
	weighted  bool
	// linked meshes resolve to their parent's geometry after parsing
	parent_mesh string
	parent_skin string
}

pub struct SpSkin {
pub mut:
	name        string
	attachments map[string]SpAttachment // key: '<slot index>/<attachment name>'
}

// SpKey — one keyframe of a curve timeline: values, and how to reach the next key.
pub struct SpKey {
pub mut:
	time    f32
	values  []f32
	stepped bool
	bezier  []f32 // 4 numbers (cx1, cy1, cx2, cy2) per value, absolute time/value
}

pub enum SpBoneProp {
	rotate
	translate
	translate_x
	translate_y
	scale
	scale_x
	scale_y
	shear
	shear_x
	shear_y
}

pub struct SpBoneTimeline {
pub mut:
	bone int
	prop SpBoneProp
	keys []SpKey
}

pub struct SpAttachmentKey {
pub mut:
	time f32
	name string // '' = no attachment
}

pub struct SpAttachmentTimeline {
pub mut:
	slot int
	keys []SpAttachmentKey
}

pub enum SpColorProp {
	rgba
	rgb
	alpha
}

pub struct SpColorTimeline {
pub mut:
	slot int
	prop SpColorProp
	keys []SpKey
}

pub struct SpDeformKey {
pub mut:
	time    f32
	offsets []f32 // full-length vertex offsets (zeros where the key gives none)
	stepped bool
	bezier  []f32 // 4 numbers on the 0..1 mix
}

pub struct SpDeformTimeline {
pub mut:
	skin       string
	slot       int
	attachment string
	keys       []SpDeformKey
}

pub struct SpDrawOrderKey {
pub mut:
	time  f32
	order []int // slot indices in draw order; empty = setup order
}

pub struct SpIkTimeline {
pub mut:
	ik   int
	keys []SpKey // values: mix, bend direction (+1 / -1)
}

pub struct SpAnimation {
pub mut:
	name       string
	duration   f32
	bones      []SpBoneTimeline
	attach     []SpAttachmentTimeline
	colors     []SpColorTimeline
	deforms    []SpDeformTimeline
	draw_order []SpDrawOrderKey
	iks        []SpIkTimeline
	skipped    []string // timeline kinds present in the file but not applied
}

pub struct SpIk {
pub mut:
	name   string
	order  int
	bones  []int
	target int
	mix    f32 = 1
	bend   int = 1
}

pub struct SpineData {
pub mut:
	version    string
	width      f32
	height     f32
	bones      []SpBone
	slots      []SpSlot
	skins      []SpSkin
	iks        []SpIk
	animations map[string]SpAnimation
	names      []string
	skipped    []string // features present in the file but not applied (see spine_pose.v)
}

// is_spine_json: the text is a Spine 4.2 JSON skeleton (checked from its header, without a full parse).
pub fn is_spine_json(src string) bool {
	head := if src.len > 600 { src[..600] } else { src }
	i := head.index('"spine"') or { return false }
	rest := head[i + 7..].trim_left(' \t\r\n:')
	return rest.starts_with('"4.2')
}

fn color_hex(s string) SpColor {
	if s.len < 6 {
		return SpColor{}
	}
	ch := fn [s] (i int) f32 {
		return f32(('0x' + s[i..i + 2]).parse_uint(16, 8) or { 255 }) / 255
	}
	return SpColor{ch(0), ch(2), ch(4), if s.len >= 8 { ch(6) } else { 1 }}
}

fn inherit_of(s string) SpInherit {
	return match s {
		'onlyTranslation' { .only_translation }
		'noRotationOrReflection' { .no_rotation_or_reflection }
		'noScale' { .no_scale }
		'noScaleOrReflection' { .no_scale_or_reflection }
		else { .normal }
	}
}

// parse_spine_skeleton reads a Spine 4.2 JSON export.
pub fn parse_spine_skeleton(src string) !SpineData {
	root := obj(json2.decode[json2.Any](src)!) or { return error('spine: expected a JSON object') }
	mut d := SpineData{}
	if sk := obj(root['skeleton'] or { json2.null }) {
		d.version = str(sk, 'spine')
		d.width = num(sk, 'width', 0)
		d.height = num(sk, 'height', 0)
	}
	if !d.version.starts_with('4.2') {
		return error('spine: version "${d.version}" is not 4.2')
	}
	mut bone_index := map[string]int{}
	for v in arr(root, 'bones') {
		m := obj(v) or { continue }
		name := str(m, 'name')
		parent := str(m, 'parent')
		bone_index[name] = d.bones.len
		inh := if 'inherit' in m { str(m, 'inherit') } else { str(m, 'transform') }
		d.bones << SpBone{
			name:     name
			parent:   if parent == '' { -1 } else { bone_index[parent] or { -1 } }
			length:   num(m, 'length', 0)
			x:        num(m, 'x', 0)
			y:        num(m, 'y', 0)
			rotation: num(m, 'rotation', 0)
			scale_x:  num(m, 'scaleX', 1)
			scale_y:  num(m, 'scaleY', 1)
			shear_x:  num(m, 'shearX', 0)
			shear_y:  num(m, 'shearY', 0)
			inherit:  inherit_of(inh)
		}
	}
	mut slot_index := map[string]int{}
	for v in arr(root, 'slots') {
		m := obj(v) or { continue }
		slot_index[str(m, 'name')] = d.slots.len
		if str(m, 'dark') != '' && 'tint black' !in d.skipped {
			d.skipped << 'tint black'
		}
		d.slots << SpSlot{
			name:       str(m, 'name')
			bone:       bone_index[str(m, 'bone')] or { 0 }
			color:      color_hex(str(m, 'color'))
			attachment: str(m, 'attachment')
			blend:      if str(m, 'blend') == '' { 'normal' } else { str(m, 'blend') }
		}
	}
	for v in arr(root, 'ik') {
		m := obj(v) or { continue }
		mut ik := SpIk{
			name:   str(m, 'name')
			order:  int(num(m, 'order', 0))
			target: bone_index[str(m, 'target')] or { 0 }
			mix:    num(m, 'mix', 1)
			bend:   if bp := m['bendPositive'] {
				if bp is bool && !bp { -1 } else { 1 }
			} else {
				1
			}
		}
		for b in arr(m, 'bones') {
			if b is string {
				ik.bones << bone_index[b] or { 0 }
			}
		}
		for k in ['softness', 'compress', 'stretch'] {
			if k in m && 'ik ${k}' !in d.skipped {
				d.skipped << 'ik ${k}'
			}
		}
		d.iks << ik
	}
	for k in ['transform', 'path', 'physics'] {
		if arr(root, k).len > 0 {
			d.skipped << '${k} constraints'
		}
	}
	for v in arr(root, 'skins') {
		m := obj(v) or { continue }
		mut skin := SpSkin{
			name: str(m, 'name')
		}
		if slots := obj(m['attachments'] or { json2.null }) {
			for slot_name, atts_v in slots {
				si := slot_index[slot_name] or { continue }
				atts := obj(atts_v) or { continue }
				for att_name, av in atts {
					am := obj(av) or { continue }
					att := parse_spine_attachment(att_name, am, mut d)
					skin.attachments['${si}/${att_name}'] = att
				}
			}
		}
		d.skins << skin
	}
	// linked meshes take their parent's geometry
	for mut skin in d.skins {
		for key, mut att in skin.attachments {
			if att.parent_mesh == '' {
				continue
			}
			slot := key.all_before('/')
			parent_skin := if att.parent_skin == '' { 'default' } else { att.parent_skin }
			for s in d.skins {
				if s.name == parent_skin {
					if p := s.attachments['${slot}/${att.parent_mesh}'] {
						att.uvs = p.uvs
						att.triangles = p.triangles
						att.vertices = p.vertices
						att.bones = p.bones
						att.weighted = p.weighted
						att.kind = .mesh
					}
				}
			}
		}
	}
	if anims := obj(root['animations'] or { json2.null }) {
		for name, v in anims {
			m := obj(v) or { continue }
			mut a := parse_spine_animation(name, m, bone_index, slot_index, d)
			for s in a.skipped {
				if s !in d.skipped {
					d.skipped << s
				}
			}
			d.animations[name] = a
			d.names << name
		}
	}
	return d
}

fn parse_spine_attachment(name string, m map[string]json2.Any, mut d SpineData) SpAttachment {
	kind := str(m, 'type')
	// the region defaults to the attachment's `name` field, then to its key in the skin
	real_name := if str(m, 'name') != '' { str(m, 'name') } else { name }
	path := str(m, 'path')
	mut a := SpAttachment{
		name:     name
		path:     if path == '' { real_name } else { path }
		x:        num(m, 'x', 0)
		y:        num(m, 'y', 0)
		rotation: num(m, 'rotation', 0)
		scale_x:  num(m, 'scaleX', 1)
		scale_y:  num(m, 'scaleY', 1)
		width:    num(m, 'width', 32)
		height:   num(m, 'height', 32)
		color:    color_hex(str(m, 'color'))
	}
	if 'sequence' in m && 'attachment sequences' !in d.skipped {
		d.skipped << 'attachment sequences'
	}
	match kind {
		'', 'region' {
			a.kind = .region
		}
		'mesh' {
			a.kind = .mesh
			a.uvs = floats(m, 'uvs')
			a.triangles = arr(m, 'triangles').map(it.int())
			verts := floats(m, 'vertices')
			if verts.len == a.uvs.len {
				a.vertices = verts
			} else {
				a.weighted = true
				mut i := 0
				for i < verts.len {
					n := int(verts[i])
					i++
					a.bones << n
					for _ in 0 .. n {
						a.bones << int(verts[i])
						a.vertices << verts[i + 1]
						a.vertices << verts[i + 2]
						a.vertices << verts[i + 3]
						i += 4
					}
				}
			}
		}
		'linkedmesh' {
			a.kind = .mesh
			a.parent_mesh = str(m, 'parent')
			a.parent_skin = str(m, 'skin')
		}
		'clipping' {
			a.kind = .other
			if 'clipping attachments' !in d.skipped {
				d.skipped << 'clipping attachments'
			}
		}
		else {
			a.kind = .other // boundingbox, point, path: not drawn
		}
	}
	return a
}

// read_key reads one curve keyframe of `count` values with defaults `def`.
fn read_key(m map[string]json2.Any, names []string, def f32) SpKey {
	mut k := SpKey{
		time: num(m, 'time', 0)
	}
	for n in names {
		k.values << num(m, n, def)
	}
	if c := m['curve'] {
		if c is string && c == 'stepped' {
			k.stepped = true
		} else if c is []json2.Any {
			k.bezier = c.map(it.f32())
		}
	}
	return k
}

fn read_keys(v json2.Any, names []string, def f32) []SpKey {
	mut keys := []SpKey{}
	if v is []json2.Any {
		for kv in v {
			km := obj(kv) or { continue }
			keys << read_key(km, names, def)
		}
	}
	return keys
}

fn parse_spine_animation(name string, m map[string]json2.Any, bone_index map[string]int, slot_index map[string]int, d &SpineData) SpAnimation {
	mut a := SpAnimation{
		name: name
	}
	if bones := obj(m['bones'] or { json2.null }) {
		for bone_name, tv in bones {
			bi := bone_index[bone_name] or { continue }
			tls := obj(tv) or { continue }
			for kind, kv in tls {
				prop, names, def := match kind {
					'rotate' { SpBoneProp.rotate, ['value'], f32(0) }
					'translate' { SpBoneProp.translate, ['x', 'y'], f32(0) }
					'translatex' { SpBoneProp.translate_x, ['value'], f32(0) }
					'translatey' { SpBoneProp.translate_y, ['value'], f32(0) }
					'scale' { SpBoneProp.scale, ['x', 'y'], f32(1) }
					'scalex' { SpBoneProp.scale_x, ['value'], f32(1) }
					'scaley' { SpBoneProp.scale_y, ['value'], f32(1) }
					'shear' { SpBoneProp.shear, ['x', 'y'], f32(0) }
					'shearx' { SpBoneProp.shear_x, ['value'], f32(0) }
					'sheary' { SpBoneProp.shear_y, ['value'], f32(0) }
					else { SpBoneProp.rotate, []string{}, f32(0) }
				}
				if names.len == 0 {
					if 'bone ${kind} timeline' !in a.skipped {
						a.skipped << 'bone ${kind} timeline'
					}
					continue
				}
				keys := read_keys(kv, names, def)
				if keys.len > 0 {
					a.bones << SpBoneTimeline{bi, prop, keys}
					a.grow(keys.last().time)
				}
			}
		}
	}
	if slots := obj(m['slots'] or { json2.null }) {
		for slot_name, tv in slots {
			si := slot_index[slot_name] or { continue }
			tls := obj(tv) or { continue }
			for kind, kv in tls {
				match kind {
					'attachment' {
						mut tl := SpAttachmentTimeline{
							slot: si
						}
						if kv is []json2.Any {
							for e in kv {
								em := obj(e) or { continue }
								tl.keys << SpAttachmentKey{num(em, 'time', 0), str(em, 'name')}
							}
						}
						if tl.keys.len > 0 {
							a.grow(tl.keys.last().time)
							a.attach << tl
						}
					}
					'rgba', 'rgb', 'alpha' {
						mut keys := []SpKey{}
						if kv is []json2.Any {
							for e in kv {
								em := obj(e) or { continue }
								mut k := read_key(em, []string{}, 0)
								if kind == 'alpha' {
									k.values = [num(em, 'value', 1)]
								} else {
									c := color_hex(str(em, 'color'))
									k.values = if kind == 'rgba' { [c.r, c.g, c.b, c.a] } else { [c.r, c.g, c.b] }
								}
								keys << k
							}
						}
						if keys.len > 0 {
							a.grow(keys.last().time)
							a.colors << SpColorTimeline{si, match kind {
								'rgba' { SpColorProp.rgba }
								'rgb' { SpColorProp.rgb }
								else { SpColorProp.alpha }
							}, keys}
						}
					}
					else {
						if 'slot ${kind} timeline' !in a.skipped {
							a.skipped << 'slot ${kind} timeline'
						}
					}
				}
			}
		}
	}
	// 4.2 keeps deform (and sequence) keys under attachments/<skin>/<slot>/<attachment>
	if atts := obj(m['attachments'] or { json2.null }) {
		for skin_name, sv in atts {
			sm := obj(sv) or { continue }
			for slot_name, slv in sm {
				si := slot_index[slot_name] or { continue }
				am := obj(slv) or { continue }
				for att_name, tv in am {
					tm := obj(tv) or { continue }
					for kind, kv in tm {
						if kind != 'deform' {
							if 'attachment ${kind} timeline' !in a.skipped {
								a.skipped << 'attachment ${kind} timeline'
							}
							continue
						}
						mut tl := SpDeformTimeline{
							skin:       skin_name
							slot:       si
							attachment: att_name
						}
						vcount := d.deform_length(skin_name, si, att_name)
						if kv is []json2.Any {
							for e in kv {
								em := obj(e) or { continue }
								mut k := SpDeformKey{
									time:    num(em, 'time', 0)
									offsets: []f32{len: vcount}
								}
								start := int(num(em, 'offset', 0))
								for i, x in floats(em, 'vertices') {
									if start + i < vcount {
										k.offsets[start + i] = x
									}
								}
								if c := em['curve'] {
									if c is string && c == 'stepped' {
										k.stepped = true
									} else if c is []json2.Any {
										k.bezier = c.map(it.f32())
									}
								}
								tl.keys << k
							}
						}
						if tl.keys.len > 0 {
							a.grow(tl.keys.last().time)
							a.deforms << tl
						}
					}
				}
			}
		}
	}
	for v in arr(m, 'drawOrder') {
		em := obj(v) or { continue }
		mut key := SpDrawOrderKey{
			time: num(em, 'time', 0)
		}
		offsets := arr(em, 'offsets')
		if offsets.len > 0 {
			n := d.slots.len
			mut order := []int{len: n, init: -1}
			mut unchanged := []int{len: n - offsets.len}
			mut orig := 0
			mut ui := 0
			for ov in offsets {
				om := obj(ov) or { continue }
				si := slot_index[str(om, 'slot')] or { continue }
				for orig != si {
					unchanged[ui] = orig
					ui++
					orig++
				}
				order[orig + int(num(om, 'offset', 0))] = orig
				orig++
			}
			for orig < n {
				unchanged[ui] = orig
				ui++
				orig++
			}
			for i := n - 1; i >= 0; i-- {
				if order[i] == -1 {
					ui--
					order[i] = unchanged[ui]
				}
			}
			key.order = order
		}
		a.draw_order << key
		a.grow(key.time)
	}
	if iks := obj(m['ik'] or { json2.null }) {
		for ik_name, kv in iks {
			mut index := -1
			for i, ik in d.iks {
				if ik.name == ik_name {
					index = i
				}
			}
			if index < 0 {
				continue
			}
			mut keys := []SpKey{}
			if kv is []json2.Any {
				for e in kv {
					em := obj(e) or { continue }
					mut k := read_key(em, ['mix'], 1)
					bend := if bp := em['bendPositive'] {
						if bp is bool && !bp { f32(-1) } else { f32(1) }
					} else {
						f32(1)
					}
					k.values << bend
					keys << k
				}
			}
			if keys.len > 0 {
				a.grow(keys.last().time)
				a.iks << SpIkTimeline{index, keys}
			}
		}
	}
	for k in ['transform', 'path', 'physics', 'events'] {
		if k in m {
			a.skipped << if k == 'events' { 'events' } else { '${k} constraint timelines' }
		}
	}
	return a
}

fn (mut a SpAnimation) grow(t f32) {
	if t > a.duration {
		a.duration = t
	}
}

// deform_length: number of floats in a mesh's deform array (2 per vertex, or 2 per weighted influence).
fn (d &SpineData) deform_length(skin string, slot int, att string) int {
	for s in d.skins {
		if s.name == skin {
			a := s.attachments['${slot}/${att}'] or { return 0 }
			return if a.weighted { a.vertices.len / 3 * 2 } else { a.vertices.len }
		}
	}
	return 0
}

// ---------------------------------------------------------------- atlas

pub struct SpPage {
pub mut:
	name   string
	width  int
	height int
	pma    bool
}

pub struct SpRegion {
pub mut:
	name     string
	page     int
	x        int
	y        int
	width    int // as drawn (before packing rotation)
	height   int
	degrees  int // 0 or 90 (rotated on the page)
	offset_x f32
	offset_y f32
	orig_w   f32
	orig_h   f32
}

pub struct SpAtlas {
pub mut:
	pages   []SpPage
	regions map[string]SpRegion
}

fn ints_of(v string) []int {
	return v.split(',').map(it.trim_space().int())
}

// parse_spine_atlas reads a libGDX/Spine text atlas (old `xy`/`size`/`orig`/`offset` and 4.x
// `bounds`/`offsets` forms, `rotate` true/false/90, several pages).
pub fn parse_spine_atlas(src string) !SpAtlas {
	mut a := SpAtlas{}
	mut page := -1
	mut region := ''
	mut new_page := true
	for raw in src.split_into_lines() {
		line := raw.trim_space()
		if line == '' {
			new_page = true
			region = ''
			continue
		}
		colon := line.index(':') or { -1 }
		if colon < 0 {
			if new_page {
				a.pages << SpPage{
					name: line
				}
				page = a.pages.len - 1
				new_page = false
				region = ''
			} else {
				region = line
				a.regions[region] = SpRegion{
					name: line
					page: page
				}
			}
			continue
		}
		new_page = false
		key := line[..colon].trim_space()
		val := line[colon + 1..].trim_space()
		if page < 0 {
			continue
		}
		if region == '' {
			match key {
				'size' {
					v := ints_of(val)
					if v.len >= 2 {
						a.pages[page].width = v[0]
						a.pages[page].height = v[1]
					}
				}
				'pma' {
					a.pages[page].pma = val == 'true'
				}
				else {}
			}
			continue
		}
		mut r := a.regions[region] or { continue }
		v := ints_of(val)
		match key {
			'xy' {
				r.x, r.y = v[0], v[1]
			}
			'size' {
				r.width, r.height = v[0], v[1]
			}
			'bounds' {
				r.x, r.y, r.width, r.height = v[0], v[1], v[2], v[3]
			}
			'orig' {
				r.orig_w, r.orig_h = f32(v[0]), f32(v[1])
			}
			'offset' {
				r.offset_x, r.offset_y = f32(v[0]), f32(v[1])
			}
			'offsets' {
				r.offset_x, r.offset_y = f32(v[0]), f32(v[1])
				r.orig_w, r.orig_h = f32(v[2]), f32(v[3])
			}
			'rotate' {
				r.degrees = if val == 'true' {
					90
				} else if val == 'false' {
					0
				} else {
					val.int()
				}
			}
			else {}
		}
		a.regions[region] = r
	}
	for name, mut r in a.regions {
		if r.orig_w <= 0 {
			r.orig_w = f32(r.width)
		}
		if r.orig_h <= 0 {
			r.orig_h = f32(r.height)
		}
		_ = name
	}
	if a.pages.len == 0 {
		return error('atlas: no pages')
	}
	return a
}
