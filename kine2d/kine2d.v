module kine2d

import math
import time
import velo.core
import velo.assets
import velo.render
import velo.serialize

// Stats — rendering cost of all Kine2D components, for debug overlays. Totals since the last reset_stats().
pub struct Stats {
pub mut:
	rigs     int // meshes() calls that produced geometry
	meshes   int // TexturedMesh pieces returned
	verts    int
	build_us i64 // microseconds spent posing and building geometry
	cached   int // meshes() calls answered from the per-frame cache
}

pub const stats = &Stats{}

// reset_stats returns the totals gathered so far and starts again (call once per frame from an overlay).
pub fn reset_stats() Stats {
	out := *stats
	unsafe {
		mut st := stats
		*st = Stats{}
	}
	return out
}

fn add_stats(meshes int, verts int, us i64, cached bool) {
	unsafe {
		mut st := stats
		if cached {
			st.cached++
		} else {
			st.rigs++
			st.meshes += meshes
			st.verts += verts
			st.build_us += us
		}
	}
}

// register_builtins registers the Kine2D component so .scene files (and the editor) can use it.
// Like physics, it is opt-in: call it from the game's component registration.
pub fn register_builtins(mut r serialize.Registry) {
	r.register[Kine2D]()
}

// Kine2D — plays a skeletal animation exported by the Kine2D editor (BUILD writes `<name>.skel.json`,
// `<name>.atlas.json` and `<name>.png`; put all three in the assets directory). It also plays Spine 4.2 JSON
// exports directly: point `data` at `<name>.json` and `atlas` at the Spine text `<name>.atlas` (pages in PNG
// or lossless WebP next to it); the skeleton origin is drawn at the node, see spine_pose.v for what is applied.
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
	is_spine    bool              @[hide] // `data` is a Spine 4.2 JSON export
	spine       SpineData         @[hide]
	spine_atlas SpAtlas           @[hide]
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
	return if k.is_spine { k.spine.names } else { k.skeleton.names }
}

// skins lists the export's skins (by name).
pub fn (k &Kine2D) skins() []string {
	if k.is_spine {
		return k.spine.skins.map(it.name)
	}
	return k.skeleton.skins.map(if it.name != '' { it.name } else { it.id })
}

fn (k &Kine2D) current_name() string {
	names := k.animations()
	return if k.animation == '' && names.len > 0 { names[0] } else { k.animation }
}

// current_spine_animation: the Spine animation being played (Spine exports only).
pub fn (k &Kine2D) current_spine_animation() ?SpAnimation {
	name := k.current_name()
	if name in k.spine.animations {
		return k.spine.animations[name]
	}
	return none
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
	if k.is_spine {
		sa := k.current_spine_animation() or { return 0 }
		return sa.duration
	}
	a := k.current_animation() or { return 0 }
	return a.duration()
}

// frame: the current animation frame (fractional).
pub fn (k &Kine2D) frame() f32 {
	if k.is_spine {
		return k.time * 30 // Spine keys are in seconds; 30 fps is the editor's default timeline rate
	}
	a := k.current_animation() or { return 0 }
	return k.time * a.fps
}

// meshes is what the renderer draws (render.MeshDrawable).
pub fn (k &Kine2D) meshes() []render.TexturedMesh {
	if k.pages.len == 0 {
		return []
	}
	if k.is_spine {
		t0 := time.sys_mono_now()
		out := k.spine_meshes()
		mut nv := 0
		for m in out {
			nv += m.positions.len / 2
		}
		add_stats(out.len, nv, i64(time.sys_mono_now() - t0) / 1000, false)
		return out
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

fn (k &Kine2D) spine_meshes() []render.TexturedMesh {
	// consecutive pieces on the same page with the same blending are merged into one mesh (per-vertex
	// colours carry each slot's tint), so a rig is a handful of draws instead of one per attachment
	mut out := []render.TexturedMesh{}
	mut pos := []f32{}
	mut uvs := []f32{}
	mut idx := []int{}
	mut cols := []core.Color{}
	mut cur_page := -1
	mut cur_add := false
	for p in k.spine.build(k.spine_atlas, k.current_spine_animation(), k.time, k.skin) {
		tex := k.pages[p.page] or { continue }
		if tex.width <= 0 || tex.height <= 0 {
			continue
		}
		if (p.page != cur_page || p.additive != cur_add) && idx.len > 0 {
			out << render.TexturedMesh{
				texture:   k.pages[cur_page]
				positions: pos
				uvs:       uvs
				indices:   idx
				colors:    cols
				color:     k.color
				additive:  cur_add
			}
			pos = []f32{}
			uvs = []f32{}
			idx = []int{}
			cols = []core.Color{}
		}
		cur_page = p.page
		cur_add = p.additive
		base := pos.len / 2
		c := core.rgba(u8(255 * p.color.r), u8(255 * p.color.g), u8(255 * p.color.b), u8(255 * p.color.a))
		for i := 0; i < p.uvs.len; i += 2 {
			uvs << p.uvs[i] / tex.width
			uvs << p.uvs[i + 1] / tex.height
			cols << c
		}
		pos << p.positions
		for i in p.indices {
			idx << base + i
		}
	}
	if idx.len > 0 {
		out << render.TexturedMesh{
			texture:   k.pages[cur_page]
			positions: pos
			uvs:       uvs
			indices:   idx
			colors:    cols
			color:     k.color
			additive:  cur_add
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

const default_kine_cache = &KineCache{}

pub fn kine_cache() &KineCache {
	return default_kine_cache
}

pub struct CachedSkeleton {
pub mut:
	hash u64
	data SkeletonData
}

pub struct CachedAtlas {
pub mut:
	hash  u64
	atlas Atlas
}

pub struct KineCache {
pub mut:
	skeletons map[string]&CachedSkeleton
	atlases   map[string]&CachedAtlas
}

fn (mut k Kine2D) load_from(mut db assets.AssetDatabase) ! {
	// data/atlas may hold IDs or paths.
	data_id := db.resolve(k.data.id) or { return error('asset "${k.data.id}" not found') }
	atlas_id := db.resolve(k.atlas.id) or { return error('asset "${k.atlas.id}" not found') }
	data_entry := db.entry(data_id) or { return error('asset "${data_id}" not found') }
	atlas_entry := db.entry(atlas_id) or { return error('asset "${atlas_id}" not found') }

	mut cache := kine_cache()

	mut skeleton := SkeletonData{}
	if cached := cache.skeletons[data_id] {
		if cached.hash == data_entry.hash {
			skeleton = cached.data
		}
	}
	if skeleton.names.len == 0 && skeleton.animations.len == 0 {
		skel_text := db.load[assets.TextAsset](data_id)!
		skel_src := skel_text.text
		db.release(data_id)
		if is_spine_json(skel_src) {
			// Spine 4.2 export: its own parser, atlas reader and pose code (not cached here)
			atlas_text := db.load[assets.TextAsset](atlas_id)!
			atlas_src := atlas_text.text
			db.release(atlas_id)
			return k.load_spine(mut db, data_id, atlas_id, skel_src, atlas_src)
		}
		skeleton = parse_skeleton(skel_src) or {
			return error('${db.path_of(data_id) or { '' }}: ${err}')
		}
		cache.skeletons[data_id] = &CachedSkeleton{
			hash: data_entry.hash
			data: skeleton
		}
	}

	mut atlas := Atlas{}
	if cached := cache.atlases[atlas_id] {
		if cached.hash == atlas_entry.hash {
			atlas = cached.atlas
		}
	}
	if atlas.pages.len == 0 && atlas.regions.len == 0 {
		atlas_text := db.load[assets.TextAsset](atlas_id)!
		atlas_src := atlas_text.text
		db.release(atlas_id)
		atlas = parse_atlas(atlas_src) or {
			return error('${db.path_of(atlas_id) or { '' }}: ${err}')
		}
		cache.atlases[atlas_id] = &CachedAtlas{
			hash: atlas_entry.hash
			atlas: atlas
		}
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
	k.is_spine = false
	k.skeleton = skeleton
	k.regions = atlas
	k.pages = pages
	k.held = held
	k.hashes = [data_entry.hash, atlas_entry.hash]
	if k.animation != '' && k.animation !in skeleton.animations {
		eprintln('[Kine2D] ${k.node.path()}: no animation "${k.animation}" (has: ${skeleton.names.join(', ')})')
	}
}

fn (mut k Kine2D) load_spine(mut db assets.AssetDatabase, data_id string, atlas_id string, skel_src string, atlas_src string) ! {
	data := parse_spine_skeleton(skel_src) or { return error('${db.path_of(data_id) or { '' }}: ${err}') }
	atlas := parse_spine_atlas(atlas_src) or { return error('${db.path_of(atlas_id) or { '' }}: ${err}') }
	atlas_path := db.path_of(atlas_id) or { '' }
	dir := if atlas_path.contains('/') { atlas_path.all_before_last('/') + '/' } else { '' }
	mut pages := []&assets.Texture{}
	mut held := []string{}
	for page in atlas.pages {
		tex := db.load[assets.Texture](dir + page.name) or {
			for id in held {
				db.release(id)
			}
			return error('atlas page "${dir}${page.name}": ${err}')
		}
		pages << tex
		held << tex.id
	}
	k.drop()
	k.is_spine = true
	k.spine = data
	k.spine_atlas = atlas
	k.pages = pages
	k.held = held
	k.hashes = [data_id, atlas_id].map(if e := db.entry(it) { e.hash } else { u64(0) })
	if k.animation != '' && k.animation !in data.animations {
		eprintln('[Kine2D] ${k.node.path()}: no animation "${k.animation}" (has: ${data.names.join(', ')})')
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
