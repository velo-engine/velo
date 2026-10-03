module kine2d

import math
import velo.core
import velo.assets
import velo.render
import velo.serialize

// register_builtins registers the Kine2D component so .scene files (and the editor) can use it.
// Like physics, it is opt-in: call it from the game's component registration.
pub fn register_builtins(mut r serialize.Registry) {
	r.register[Kine2D]()
}

// Kine2D — plays a skeletal animation exported by the Kine2D editor (BUILD writes `<name>.skel.json`,
// `<name>.atlas.json` and `<name>.png`; put all three in the assets directory).
// The node's position is where the editor's canvas center was, so a rig drawn around the middle
// of the editor canvas is drawn around the node. Node rotation, scale and flips (negative scale) apply.
//
//   Kine2D { data = @asset("hero.skel.json id")  atlas = @asset("hero.atlas.json id")  animation = "Run" }
pub struct Kine2D {
	core.Component
pub mut:
	data      assets.AssetRef[assets.TextAsset] // <name>.skel.json
	atlas     assets.AssetRef[assets.TextAsset] // <name>.atlas.json; its image is found next to it
	animation string // '' = the first animation of the export
	skin      string // skin id or name; '' = the skin that was active when exporting
	// A state machine (`.anim`, see core.AnimGraph) that picks the animation: its states name animations with
	// `clip=`, and `animation` / `looping` / `play()` are then ignored. Drive it with params().
	controller assets.AssetRef[assets.TextAsset]
	speed      f32        = 1
	playing    bool       = true
	looping    bool       = true
	color      core.Color = core.white
	// Canvas size the rig was built on (bone positions scale with it). 0 = the export's canvasSize,
	// or 800x600 for exports that have none.
	canvas_size core.Vec2
	time        f32               @[hide] // seconds into the current animation
	finished    bool              @[hide] // a non-looping animation reached its end (it then stops playing)
	skeleton    SkeletonData      @[hide]
	regions     Atlas             @[hide]
	pages       []&assets.Texture @[hide]
	held        []string          @[hide] // asset IDs this component holds a reference to
	hashes      []u64             @[hide] // skel/atlas content hashes, to reload after they change on disk
	current     string            @[hide] // the animation `time` belongs to
	source      string            @[hide] // data/atlas IDs loaded
	machine     &core.AnimGraph = unsafe { nil }   @[hide]
	ctrl_hash   u64               @[hide]
	ctrl_failed bool              @[hide]
	// Called for each `event=` the controller's clips pass (instead of polling params().take_events()).
	on_event fn (name string) = unsafe { nil } @[hide]
}

pub fn (mut k Kine2D) on_load() {
	k.reload()
}

pub fn (mut k Kine2D) on_destroy() {
	k.drop()
}

pub fn (mut k Kine2D) update(dt f32) {
	if k.source != k.data.id + k.atlas.id || k.changed_on_disk() {
		k.reload()
	}
	if k.controller.is_set() && k.drive_controller(dt) {
		return
	}
	if k.animation != k.current {
		k.restart()
	}
	if !k.playing {
		return
	}
	d := k.duration()
	if d <= 0 {
		return
	}
	k.time += dt * k.speed
	if k.looping {
		k.time = f32(math.fmod(k.time, d))
		if k.time < 0 {
			k.time += d
		}
	} else if k.time >= d || k.time < 0 {
		k.time = if k.time < 0 { 0 } else { d }
		k.finished = true
		k.playing = false
	}
}

// params: the controller's state machine, for set_float / set_bool / trigger / take_events / force / state_name.
// Without a (valid) controller it is an inert one, so game code can call it blindly.
pub fn (mut k Kine2D) params() &core.AnimGraph {
	if k.machine == unsafe { nil } {
		k.load_controller()
	}
	if k.machine == unsafe { nil } {
		k.machine = render.placeholder_graph()
	}
	return k.machine
}

fn (mut k Kine2D) load_controller() {
	g, h := render.load_anim_graph(k.node, k.controller) or {
		if !k.ctrl_failed {
			eprintln('[Kine2D] ${k.node.path()}: ${err}')
		}
		k.ctrl_failed = true // keep the old machine (a typo while hot reloading), say it once
		k.ctrl_hash = 0
		return
	}
	k.ctrl_failed = false
	k.ctrl_hash = h
	if k.machine != unsafe { nil } {
		g.adopt_state(k.machine)
	}
	k.machine = g
	k.apply_state()
}

// apply_state shows the animation of the machine's current state.
fn (mut k Kine2D) apply_state() {
	st := k.machine.current_state()
	if st.clip != '' {
		k.animation = st.clip
	}
	k.current = k.animation // the machine keeps the time, so no restart
	k.looping = st.loop
}

// drive_controller advances the state machine and poses the rig at its time. false: no controller to run.
fn (mut k Kine2D) drive_controller(dt f32) bool {
	if k.ctrl_hash != 0 && render.anim_graph_changed(k.node, k.controller, k.ctrl_hash) {
		k.load_controller()
	}
	mut g := k.params()
	if g.state_name() == 'none' && k.ctrl_failed {
		return false
	}
	g.update(dt * k.speed, k.duration())
	k.apply_state()
	k.time = g.state_time()
	k.finished = g.is_finished()
	k.playing = !k.finished
	if k.on_event != unsafe { nil } {
		for name in g.take_events() {
			k.on_event(name)
		}
	}
	return true
}

// play starts `name` from its first frame.
pub fn (mut k Kine2D) play(name string, looping bool) {
	k.animation = name
	k.looping = looping
	k.playing = true
	k.restart()
}

fn (mut k Kine2D) restart() {
	k.current = k.animation
	k.time = 0
	k.finished = false
}

// animations lists the export's animation names in file order.
pub fn (k &Kine2D) animations() []string {
	return k.skeleton.names
}

// skins lists the export's skins (by name).
pub fn (k &Kine2D) skins() []string {
	return k.skeleton.skins.map(if it.name != '' { it.name } else { it.id })
}

// current_animation: the animation being played (the first one when `animation` is empty).
pub fn (k &Kine2D) current_animation() ?Animation {
	name := if k.animation == '' && k.skeleton.names.len > 0 {
		k.skeleton.names[0]
	} else {
		k.animation
	}
	if name in k.skeleton.animations {
		return k.skeleton.animations[name]
	}
	return none
}

// duration of the current animation in seconds (0 if there is none).
pub fn (k &Kine2D) duration() f32 {
	a := k.current_animation() or { return 0 }
	return a.duration()
}

// frame: the current animation frame (fractional).
pub fn (k &Kine2D) frame() f32 {
	a := k.current_animation() or { return 0 }
	return k.time * a.fps
}

// meshes is what the renderer draws (render.MeshDrawable).
pub fn (k &Kine2D) meshes() []render.TexturedMesh {
	if k.pages.len == 0 {
		return []
	}
	mut out := []render.TexturedMesh{}
	for p in k.skeleton.build(k.regions, k.current_animation(), k.frame(), k.skin) {
		tex := k.pages[p.page] or { continue }
		if tex.width <= 0 || tex.height <= 0 {
			continue
		}
		mut uvs := []f32{len: p.uvs.len}
		for i := 0; i < uvs.len; i += 2 {
			uvs[i] = p.uvs[i] / tex.width
			uvs[i + 1] = p.uvs[i + 1] / tex.height
		}
		out << render.TexturedMesh{
			texture:   tex
			positions: p.positions
			uvs:       uvs
			indices:   p.indices
			color:     k.color
		}
	}
	return out
}

fn (k &Kine2D) db() ?&assets.AssetDatabase {
	if k.node == unsafe { nil } || k.node.scene == unsafe { nil }
		|| k.node.scene.assets == unsafe { nil } {
		return none
	}
	return k.node.scene.assets
}

fn (k &Kine2D) changed_on_disk() bool {
	db := k.db() or { return false }
	for i, key in [k.data.id, k.atlas.id] {
		e := db.entry(db.resolve(key) or { continue }) or { continue }
		if i < k.hashes.len && e.hash != k.hashes[i] {
			return true
		}
	}
	return false
}

// reload (re)reads the export: skeleton, atlas and the atlas image(s). On an error the old data is kept.
pub fn (mut k Kine2D) reload() {
	mut db := k.db() or { return }
	if !k.data.is_set() || !k.atlas.is_set() {
		return
	}
	k.source = k.data.id + k.atlas.id
	k.load_from(mut db) or { eprintln('[Kine2D] ${k.node.path()}: ${err}') }
}

fn (mut k Kine2D) load_from(mut db assets.AssetDatabase) ! {
	// data/atlas may hold IDs or paths.
	data_id := db.resolve(k.data.id) or { return error('asset "${k.data.id}" not found') }
	atlas_id := db.resolve(k.atlas.id) or { return error('asset "${k.atlas.id}" not found') }
	skel_text := db.load[assets.TextAsset](data_id)!
	skel_src := skel_text.text
	db.release(data_id)
	atlas_text := db.load[assets.TextAsset](atlas_id)!
	atlas_src := atlas_text.text
	db.release(atlas_id)
	mut skeleton := parse_skeleton(skel_src) or {
		return error('${db.path_of(data_id) or { '' }}: ${err}')
	}
	mut atlas := parse_atlas(atlas_src) or {
		return error('${db.path_of(atlas_id) or { '' }}: ${err}')
	}
	if k.canvas_size.x > 0 && k.canvas_size.y > 0 {
		skeleton.canvas_width = k.canvas_size.x
		skeleton.canvas_height = k.canvas_size.y
	}
	// Atlas images are named relative to the atlas file.
	atlas_path := db.path_of(atlas_id) or { '' }
	dir := if atlas_path.contains('/') { atlas_path.all_before_last('/') + '/' } else { '' }
	mut pages := []&assets.Texture{}
	mut held := []string{}
	for page in atlas.pages {
		tex := db.load[assets.Texture](dir + page) or {
			for id in held {
				db.release(id)
			}
			return error('atlas image "${dir}${page}": ${err}')
		}
		pages << tex
		held << tex.id
	}
	for mut r in atlas.regions {
		if r.width <= 0 || r.height <= 0 {
			r.width = pages[r.page].width
			r.height = pages[r.page].height
		}
	}
	k.drop()
	k.skeleton = skeleton
	k.regions = atlas
	k.pages = pages
	k.held = held
	k.hashes = [data_id, atlas_id].map(if e := db.entry(it) { e.hash } else { u64(0) })
	if k.animation != '' && k.animation !in skeleton.animations {
		eprintln('[Kine2D] ${k.node.path()}: no animation "${k.animation}" (has: ${skeleton.names.join(', ')})')
	}
}

fn (mut k Kine2D) drop() {
	if mut db := k.db() {
		for id in k.held {
			db.release(id)
		}
	}
	k.held = []
	k.pages = []
}
