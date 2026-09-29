import math
import os
import velo.assets
import velo.core
import velo.kine2d

// Parsing, sampling and geometry need no GPU.

const skel = '{
  "canvasSize": {"width": 1000, "height": 900},
  "bones": [
    {"name": "root", "x": 0, "y": 0, "rotation": 0, "length": 0},
    {"name": "arm", "parent": "root", "x": 10, "y": 20, "rotation": 90, "length": 5, "scale": 2}
  ],
  "slots": [
    {"id": "s1", "name": "body", "bone": "root",
     "attachments": [{"path": "body.png", "size": {"width": 20, "height": 10}, "x": 0, "y": 0}], "displayIndex": 0},
    {"id": "s2", "name": "hand", "bone": "arm",
     "attachments": [{"path": "hand.png"}, {"path": "fist.png"}], "displayIndex": 0}
  ],
  "skins": [
    {"id": "default", "name": "Default", "attachments": {}},
    {"id": "skin-2", "name": "gloves", "attachments": {"s2": {"path": "glove.png"}, "s1": null}}
  ],
  "activeSkinId": "default",
  "animations": {
    "wave": {
      "name": "wave", "length": 20, "fps": 10,
      "keyframes": {
        "arm": {"10": {"rotation": 170}, "20": {"x": 30, "rotation": -170}, "0": {"x": 10}}
      },
      "curves": {"arm": {"0": {"position": {"x1": 0, "y1": 0, "x2": 1, "y2": 1, "type": "bounce-out"}}}},
      "slotOrderKeyframes": {"5": ["s2", "s1"]},
      "slotDisplayIndexKeyframes": {"4": {"s2": 1}, "8": {"s1": -1}}
    },
    "idle": {"name": "idle", "keyframes": {}}
  }
}'

const atlas = '{"image": "page.png", "width": 64, "height": 64, "regions": [
  {"path": "body.png", "x": 0, "y": 0, "width": 20, "height": 10},
  {"path": "hand.png", "x": 20, "y": 0, "width": 4, "height": 4},
  {"path": "fist.png", "x": 24, "y": 0, "width": 4, "height": 4},
  {"path": "glove.png", "x": 28, "y": 0, "width": 4, "height": 4}]}'

fn close(a f32, b f32) bool {
	return math.abs(a - b) < 0.01
}

fn test_parse_skeleton() {
	s := kine2d.parse_skeleton(skel)!
	assert s.canvas_width == 1000 && s.canvas_height == 900
	assert s.bones.len == 2
	assert s.bones[1].scale_x == 2 && s.bones[1].scale_y == 2 // "scale" is the default for scaleX/scaleY
	assert s.slots[1].key == 's2'
	assert s.names == ['wave', 'idle']
	a := s.animations['wave']
	assert a.duration() == 2
	assert a.bones['arm'].map(it.frame) == [f32(0), 10, 20] // sorted
	assert s.animations['idle'].length == 48 && s.animations['idle'].fps == 10 // editor defaults
	skin := s.find_skin('gloves') or { panic('no skin') }
	assert skin.attachments['s1'].hidden
}

fn test_old_exports_default_canvas_and_image_list() {
	s :=
		kine2d.parse_skeleton('{"bones": [], "slots": [{"bone": "root", "attachment": {"path": "a.png"}}], "animations": {}}')!
	assert s.canvas_width == 800 && s.canvas_height == 600
	assert s.slots[0].key == 'root'
	assert s.slots[0].state.attachments[0].path == 'a.png'
	a := kine2d.parse_atlas('{"images": [{"path": "a.png"}, {"path": "b.png"}]}')!
	assert a.pages == ['a.png', 'b.png']
	r := a.find('b.png') or { panic('no region') }
	assert r.page == 1 && r.width == 0
	if _ := kine2d.parse_atlas('{}') {
		assert false
	}
}

fn test_sample_tracks() {
	s := kine2d.parse_skeleton(skel)!
	a := s.animations['wave']
	arm := s.bones[1]
	keys := a.bones['arm']
	// Before the first rotation key the setup rotation is kept; rotation goes the short way around.
	assert close(kine2d.sample_bone(arm, keys, 5).rotation, 90)
	assert close(kine2d.sample_bone(arm, keys, 10).rotation, 170)
	assert close(kine2d.sample_bone(arm, keys, 15).rotation, 180) // 170 -> -170 through 180
	assert close(kine2d.sample_bone(arm, keys, 25).rotation, -170) // holds after the last key
	// Position eases with the key's curve (bounce-out), y keeps the setup value.
	p := kine2d.sample_bone(arm, keys, 10)
	assert close(p.x, 10 + 20 * kine2d.ease(0.5, kine2d.Curve{ kind: 'bounce-out' }))
	assert close(p.y, 20)
	assert close(kine2d.ease(0.3, none), 0.3)
	assert close(kine2d.ease(0.5, kine2d.Curve{ x1: 0.42, y1: 0, x2: 0.58, y2: 1 }), 0.5) // symmetric ease-in-out
	assert kine2d.ease(0.25, kine2d.Curve{ x1: 0.42, y1: 0, x2: 1, y2: 1 }) < 0.25 // ease-in starts slow
}

fn test_slots_attachments_and_skins() {
	s := kine2d.parse_skeleton(skel)!
	a := s.animations['wave']
	assert s.slots_at(a, 0).map(it.key) == ['s1', 's2']
	assert s.slots_at(a, 6).map(it.key) == ['s2', 's1']
	hand := s.slots[1]
	assert (s.attachment_at(hand, none, a, 0) or { panic('') }).path == 'hand.png'
	assert (s.attachment_at(hand, none, a, 9) or { panic('') }).path == 'fist.png' // display keys accumulate
	if _ := s.attachment_at(s.slots[0], none, a, 9) {
		assert false // hidden from frame 8
	}
	skin := s.skin_for('gloves')
	assert (s.attachment_at(hand, skin, none, 0) or { panic('') }).path == 'glove.png'
	if _ := s.attachment_at(s.slots[0], skin, none, 0) {
		assert false // the skin hides the body
	}
	if _ := s.skin_for('') {
		assert false // the active skin is "default": no changes
	}
}

fn test_region_geometry() {
	s := kine2d.parse_skeleton(skel)!
	at := kine2d.parse_atlas(atlas)!
	pieces := s.build(at, none, 0, '')
	assert pieces.len == 2
	// Body on the root bone: the attachment (x, y) is the middle of the quad's left edge.
	body := pieces[0]
	assert body.positions == [f32(0), -5, 20, -5, 20, 5, 0, 5]
	assert body.uvs == [f32(0), 0, 20, 0, 20, 10, 0, 10]
	assert body.indices == [0, 1, 2, 0, 2, 3]
	// Hand on "arm": origin (10 * 1000/100, 20 * 900/180) = (100, 100), rotated 90, scale 2,
	// region size 4x4 (no size in the attachment) -> an 8x8 quad centered 4 px along the bone (+y).
	hand := pieces[1]
	assert close(hand.positions[0], 104)
		&& close(hand.positions[1], 100) // top-left corner turned 90°
	assert close(hand.positions[4], 96) && close(hand.positions[5], 108)
	assert hand.uvs[0] == 20
}

fn test_mesh_follows_weighted_bones() {
	src := '{"canvasSize": {"width": 100, "height": 180},
	  "bones": [{"name": "a", "x": 0, "y": 0, "rotation": 0}, {"name": "b", "x": 10, "y": 0, "rotation": 0}],
	  "slots": [{"id": "m", "bone": "a", "attachments": [{"path": "p.png", "x": 0, "y": 0,
	    "mesh": {"vertices": [0, 0, 10, 0, 10, 10], "uvs": [0, 0, 1, 0, 1, 1], "triangles": [0, 1, 2],
	             "weights": [{}, {"b": 1}, {"a": 0.5, "b": 0.5}]}}]}],
	  "animations": {"move": {"length": 10, "fps": 10, "keyframes": {"b": {"0": {"x": 10}, "10": {"x": 30}}},
	    "deforms": {"m": {"0": [0, 0, 0, 0, 0, 0], "10": [2, 0, 0, 0, 0, 0]}}}}}'
	s := kine2d.parse_skeleton(src)!
	at :=
		kine2d.parse_atlas('{"image": "p.png", "regions": [{"path": "p.png", "x": 0, "y": 0, "width": 8, "height": 8}]}')!
	a := s.animations['move']
	rest := s.build(at, a, 0, '')[0].positions
	moved := s.build(at, a, 10, '')[0].positions
	assert close(moved[0] - rest[0], 2) // unweighted vertex: only the deform offset
	assert close(moved[2] - rest[2], 20) // fully on "b", which moved 20
	assert close(moved[4] - rest[4], 10) // half on "b"
	assert s.build(at, a, 10, '')[0].uvs == [f32(0), 0, 8, 0, 8, 8]
}

// The Kine2D component loads the sample's exports through the AssetDatabase and plays them.
fn test_component_plays_sample() {
	dir := os.join_path(os.dir(@FILE), '..', 'examples', 'kine2d', 'assets')
	mut db := assets.open(dir)!
	mut scene := core.Scene.new('test')
	scene.assets = db
	mut node := core.Node.new('Goblin')
	mut k := node.add_component(&kine2d.Kine2D{
		data:  assets.ref[assets.TextAsset]('characters/goblin.skel.json')
		atlas: assets.ref[assets.TextAsset]('characters/goblin.atlas.json')
	})
	scene.add(mut node)
	assert k.animations() == ['attack', 'idle', 'skill']
	assert k.pages.len == 1
	assert (k.current_animation() or { panic('') }).name == 'attack' // '' = the first one
	meshes := k.meshes()
	assert meshes.len > 0
	for m in meshes {
		assert m.texture != unsafe { nil }
		assert m.uvs.all(it >= 0 && it <= 1)
	}
	k.play('skill', false)
	d := k.duration()
	assert d > 0
	for _ in 0 .. int(d * 60) + 5 {
		scene.update(1.0 / 60.0)
	}
	assert k.finished && !k.playing
	assert close(k.time, d)
	k.play('idle', true)
	for _ in 0 .. int(k.duration() * 60) + 30 {
		scene.update(1.0 / 60.0)
	}
	assert k.playing && k.time < k.duration() // looped
	node.destroy()
	scene.update(0)
	assert db.loaded_count() == 0 // the atlas image was released
}
