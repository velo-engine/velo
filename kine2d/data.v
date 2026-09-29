module kine2d

import x.json2

// Data model of a Kine2D export (the editor's BUILD button writes `<name>.skel.json`,
// `<name>.atlas.json` and `<name>.png`). Parsing needs no GPU.
//
// Coordinates follow the editor: y points down, rotations are in degrees (clockwise on screen) and,
// unlike Spine, every bone's x/y/rotation/scale is ABSOLUTE (not relative to the parent bone).
// Bone positions are in canvas units: x * canvas width / 100 and y * canvas height / 180 pixels
// from the canvas center. Attachment offsets and mesh vertices are plain pixels.

pub const default_canvas_width = f32(800) // exports without a canvasSize (and Spine imports) use 800x600
pub const default_canvas_height = f32(600)

pub struct Bone {
pub mut:
	name     string
	id       string
	parent   string
	x        f32
	y        f32
	rotation f32
	scale_x  f32 = 1
	scale_y  f32 = 1
}

pub struct Mesh {
pub mut:
	vertices   []f32 // x0, y0, x1, y1, ... (pixels, before the attachment scale)
	uvs        []f32 // u0, v0, ... in 0..1 of the region
	triangles  []int
	bind_bones []Bone           // bind pose of the weighted bones (empty: the skeleton's setup pose)
	weights    []map[string]f32 // per vertex: bone name -> weight (empty: rigid, follows the slot's bone)
	has_size   bool
	width      f32
	height     f32
}

pub struct Attachment {
pub mut:
	path     string // region path in the atlas
	has_size bool
	width    f32
	height   f32
	x        f32
	y        f32
	rotation f32
	scale_x  f32 = 1
	scale_y  f32 = 1
	mesh     ?Mesh
}

// SlotState — the attachments a slot can show and which one is shown.
pub struct SlotState {
pub mut:
	attachments   []Attachment
	display_index ?int
	// Older exports: activeAttachmentPath. `hidden_by_path` = it was null (nothing shown).
	active_path    ?string
	hidden_by_path bool
}

pub struct Slot {
pub mut:
	key   string // id, or name, or bone: what animations and skins use to name the slot
	name  string
	bone  string
	state SlotState
}

pub struct SkinEntry {
pub mut:
	hidden bool // null in the export: the skin hides this slot
	state  SlotState
}

pub struct Skin {
pub mut:
	id          string
	name        string
	attachments map[string]SkinEntry // slot key -> what the skin shows
}

pub struct Curve {
pub mut:
	x1   f32
	y1   f32
	x2   f32 = 1
	y2   f32 = 1
	kind string // '' or 'bezier' (cubic bezier), or an easing: bounce-out, elastic-in, back-out, ...
}

pub struct BoneKey {
pub mut:
	frame     f32
	x         ?f32
	y         ?f32
	rotation  ?f32
	scale_x   ?f32
	scale_y   ?f32
	pos_curve ?Curve // easing from this key to the next one
	rot_curve ?Curve
}

pub struct OrderKey {
pub mut:
	frame f32
	slots []string // slot keys in draw order
}

pub struct DisplayKey {
pub mut:
	frame  f32
	values map[string]int // slot key -> attachment index (-1 = hidden)
}

pub struct DeformKey {
pub mut:
	frame   f32
	offsets []f32 // added to the mesh vertices
}

pub struct Animation {
pub mut:
	name    string
	length  f32 = 48 // frames
	fps     f32 = 10
	bones   map[string][]BoneKey // bone name or id -> keys sorted by frame
	order   []OrderKey
	display []DisplayKey
	deforms map[string][]DeformKey // slot key -> keys sorted by frame
}

// duration in seconds.
pub fn (a &Animation) duration() f32 {
	return if a.fps > 0 { a.length / a.fps } else { 0 }
}

pub struct SkeletonData {
pub mut:
	canvas_width  f32 = default_canvas_width
	canvas_height f32 = default_canvas_height
	bones         []Bone
	slots         []Slot
	skins         []Skin
	active_skin   string
	animations    map[string]Animation
	names         []string // animation names in file order
}

pub fn (s &SkeletonData) find_skin(key string) ?Skin {
	for sk in s.skins {
		if sk.id == key || sk.name == key {
			return sk
		}
	}
	return none
}

pub struct Region {
pub mut:
	path   string
	page   int // index into Atlas.pages
	x      int
	y      int
	width  int // 0 = the whole page image (older atlases list one image per region)
	height int
}

pub struct Atlas {
pub mut:
	pages   []string // image paths, relative to the atlas file
	regions []Region
}

pub fn (a &Atlas) find(path string) ?Region {
	for r in a.regions {
		if r.path == path {
			return r
		}
	}
	return none
}

// ---------- Parsing ----------

// parse_skeleton reads a `.skel.json` export.
pub fn parse_skeleton(src string) !SkeletonData {
	root := obj(json2.decode[json2.Any](src)!) or {
		return error('skeleton: expected a JSON object')
	}
	mut s := SkeletonData{}
	if cs := obj(root['canvasSize'] or { json2.null }) {
		w := num(cs, 'width', 0)
		h := num(cs, 'height', 0)
		if w > 0 && h > 0 {
			s.canvas_width = w
			s.canvas_height = h
		}
	}
	for b in arr(root, 'bones') {
		if m := obj(b) {
			s.bones << parse_bone(m)
		}
	}
	for v in arr(root, 'slots') {
		m := obj(v) or { continue }
		name := str(m, 'name')
		bone := str(m, 'bone')
		id := str(m, 'id')
		s.slots << Slot{
			key:   if id != '' {
				id
			} else if name != '' {
				name
			} else {
				bone
			}
			name:  name
			bone:  bone
			state: parse_slot_state(m)
		}
	}
	for v in arr(root, 'skins') {
		m := obj(v) or { continue }
		mut skin := Skin{
			id:   str(m, 'id')
			name: str(m, 'name')
		}
		if atts := obj(m['attachments'] or { json2.null }) {
			for key, val in atts {
				if val is json2.Null {
					skin.attachments[key] = SkinEntry{
						hidden: true
					}
				} else if sm := obj(val) {
					skin.attachments[key] = SkinEntry{
						state: if 'path' in sm {
							SlotState{
								attachments:   [parse_attachment(sm)]
								display_index: 0
							}
						} else {
							parse_slot_state(sm)
						}
					}
				}
			}
		}
		s.skins << skin
	}
	s.active_skin = str(root, 'activeSkinId')
	if anims := obj(root['animations'] or { json2.null }) {
		for name, v in anims {
			m := obj(v) or { continue }
			s.animations[name] = parse_animation(name, m)
			s.names << name
		}
	}
	return s
}

// parse_atlas reads a `.atlas.json` export: {"image", "regions": [{path, x, y, width, height}]}.
// Older exports only list whole images ({"images": [{"path"}]}); each becomes its own page.
pub fn parse_atlas(src string) !Atlas {
	root := obj(json2.decode[json2.Any](src)!) or { return error('atlas: expected a JSON object') }
	mut a := Atlas{}
	image := str(root, 'image')
	if image != '' {
		a.pages << image
		for v in arr(root, 'regions') {
			m := obj(v) or { continue }
			a.regions << Region{
				path:   str(m, 'path')
				x:      int(num(m, 'x', 0))
				y:      int(num(m, 'y', 0))
				width:  int(num(m, 'width', 0))
				height: int(num(m, 'height', 0))
			}
		}
	}
	for v in arr(root, 'images') {
		m := obj(v) or { continue }
		path := str(m, 'path')
		if path == '' {
			continue
		}
		a.regions << Region{
			path: path
			page: a.pages.len
		}
		a.pages << path
	}
	if a.pages.len == 0 {
		return error('atlas: no "image" or "images"')
	}
	return a
}

fn parse_bone(m map[string]json2.Any) Bone {
	scale := num(m, 'scale', 1)
	return Bone{
		name:     str(m, 'name')
		id:       str(m, 'id')
		parent:   str(m, 'parent')
		x:        num(m, 'x', 0)
		y:        num(m, 'y', 0)
		rotation: num(m, 'rotation', 0)
		scale_x:  num(m, 'scaleX', scale)
		scale_y:  num(m, 'scaleY', scale)
	}
}

fn parse_slot_state(m map[string]json2.Any) SlotState {
	mut st := SlotState{}
	for v in arr(m, 'attachments') {
		if am := obj(v) {
			st.attachments << parse_attachment(am)
		}
	}
	if st.attachments.len == 0 {
		if am := obj(m['attachment'] or { json2.null }) {
			st.attachments << parse_attachment(am)
		}
	}
	if 'displayIndex' in m {
		st.display_index = int(num(m, 'displayIndex', 0))
	}
	if p := m['activeAttachmentPath'] {
		if p is json2.Null {
			st.hidden_by_path = true
		} else if p is string {
			st.active_path = p
		}
	}
	return st
}

fn parse_attachment(m map[string]json2.Any) Attachment {
	scale := num(m, 'scale', 1)
	mut a := Attachment{
		path:     str(m, 'path')
		x:        num(m, 'x', 0)
		y:        num(m, 'y', 0)
		rotation: num(m, 'rotation', 0)
		scale_x:  num(m, 'scaleX', scale)
		scale_y:  num(m, 'scaleY', scale)
	}
	if size := obj(m['size'] or { json2.null }) {
		a.has_size = true
		a.width = num(size, 'width', 0)
		a.height = num(size, 'height', 0)
	}
	if mm := obj(m['mesh'] or { json2.null }) {
		mut mesh := Mesh{
			vertices:  floats(mm, 'vertices')
			uvs:       floats(mm, 'uvs')
			triangles: arr(mm, 'triangles').map(it.int())
		}
		for b in arr(mm, 'bindBones') {
			if bm := obj(b) {
				mesh.bind_bones << parse_bone(bm)
			}
		}
		for w in arr(mm, 'weights') {
			mut vw := map[string]f32{}
			if wm := obj(w) {
				for bone, weight in wm {
					vw[bone] = weight.f32()
				}
			}
			mesh.weights << vw
		}
		if 'width' in mm && 'height' in mm {
			mesh.has_size = true
			mesh.width = num(mm, 'width', 0)
			mesh.height = num(mm, 'height', 0)
		}
		a.mesh = mesh
	}
	return a
}

fn parse_animation(name string, m map[string]json2.Any) Animation {
	mut a := Animation{
		name:   name
		length: num(m, 'length', 48)
		fps:    num(m, 'fps', 10)
	}
	curves := obj(m['curves'] or { json2.null }) or {
		map[string]json2.Any{}
	}
	if kf := obj(m['keyframes'] or { json2.null }) {
		for bone, frames in kf {
			fm := obj(frames) or { continue }
			bone_curves := obj(curves[bone] or { json2.null }) or {
				map[string]json2.Any{}
			}
			mut keys := []BoneKey{}
			for fkey, v in fm {
				km := obj(v) or { continue }
				mut k := BoneKey{
					frame: fkey.f32()
				}
				if 'x' in km {
					k.x = num(km, 'x', 0)
				}
				if 'y' in km {
					k.y = num(km, 'y', 0)
				}
				if 'rotation' in km {
					k.rotation = num(km, 'rotation', 0)
				}
				if 'scale' in km {
					k.scale_x = num(km, 'scale', 1)
					k.scale_y = num(km, 'scale', 1)
				}
				if 'scaleX' in km {
					k.scale_x = num(km, 'scaleX', 1)
				}
				if 'scaleY' in km {
					k.scale_y = num(km, 'scaleY', 1)
				}
				if cm := obj(bone_curves[fkey] or { json2.null }) {
					k.pos_curve = parse_curve(cm['position'] or {
						cm['x'] or { cm['y'] or { json2.null } }
					})
					k.rot_curve = parse_curve(cm['rotation'] or { json2.null })
				}
				keys << k
			}
			keys.sort(a.frame < b.frame)
			a.bones[bone] = keys
		}
	}
	if om := obj(m['slotOrderKeyframes'] or { json2.null }) {
		for fkey, v in om {
			if v is []json2.Any {
				a.order << OrderKey{
					frame: fkey.f32()
					slots: v.map(it.str())
				}
			}
		}
		a.order.sort(a.frame < b.frame)
	}
	if dm := obj(m['slotDisplayIndexKeyframes'] or { json2.null }) {
		for fkey, v in dm {
			vm := obj(v) or { continue }
			mut values := map[string]int{}
			for slot, idx in vm {
				values[slot] = idx.int()
			}
			a.display << DisplayKey{
				frame:  fkey.f32()
				values: values
			}
		}
		a.display.sort(a.frame < b.frame)
	}
	if fm := obj(m['deforms'] or { json2.null }) {
		for slot, frames in fm {
			sm := obj(frames) or { continue }
			mut keys := []DeformKey{}
			for fkey, v in sm {
				if v is []json2.Any {
					keys << DeformKey{
						frame:   fkey.f32()
						offsets: v.map(it.f32())
					}
				}
			}
			keys.sort(a.frame < b.frame)
			a.deforms[slot] = keys
		}
	}
	return a
}

fn parse_curve(v json2.Any) ?Curve {
	m := obj(v)?
	return Curve{
		x1:   num(m, 'x1', 0)
		y1:   num(m, 'y1', 0)
		x2:   num(m, 'x2', 1)
		y2:   num(m, 'y2', 1)
		kind: str(m, 'type')
	}
}

// ---------- JSON helpers ----------

fn obj(v json2.Any) ?map[string]json2.Any {
	if v is map[string]json2.Any {
		return v
	}
	return none
}

fn arr(m map[string]json2.Any, key string) []json2.Any {
	v := m[key] or { return [] }
	if v is []json2.Any {
		return v
	}
	return []
}

fn num(m map[string]json2.Any, key string, def f32) f32 {
	v := m[key] or { return def }
	return match v {
		json2.Null, string, bool, []json2.Any, map[string]json2.Any { def }
		else { v.f32() }
	}
}

fn str(m map[string]json2.Any, key string) string {
	v := m[key] or { return '' }
	if v is string {
		return v
	}
	return ''
}

fn floats(m map[string]json2.Any, key string) []f32 {
	return arr(m, key).map(it.f32())
}
