module render

import velo.core
import velo.assets

// load_anim_graph reads a `.anim` state machine (see core.AnimGraph) and returns it with the file's content hash
// (to notice edits). Shared by Animator and kine2d.Kine2D.
pub fn load_anim_graph(n &core.Node, r assets.AssetRef[assets.TextAsset]) !(&core.AnimGraph, u64) {
	if n == unsafe { nil } || n.scene == unsafe { nil } || n.scene.assets == unsafe { nil } {
		return error('not in a scene with assets')
	}
	mut db := n.scene.assets
	id := db.resolve(r.id) or { return error('asset "${r.id}" not found') }
	text := db.load[assets.TextAsset](id)!
	src := text.text
	db.release(id)
	path := db.path_of(id) or { r.id }
	g := core.AnimGraph.parse(src) or { return error('${path}: ${err}') }
	e := db.entry(id) or { return error('asset "${r.id}" not found') }
	return g, e.hash
}

// anim_graph_changed: the `.anim` file was edited since `hash`.
pub fn anim_graph_changed(n &core.Node, r assets.AssetRef[assets.TextAsset], hash u64) bool {
	if n == unsafe { nil } || n.scene == unsafe { nil } || n.scene.assets == unsafe { nil } {
		return false
	}
	db := n.scene.assets
	id := db.resolve(r.id) or { return false }
	e := db.entry(id) or { return false }
	return e.hash != hash
}

// placeholder_graph: what params() returns when there is no (valid) graph, so game code can call it blindly.
pub fn placeholder_graph() &core.AnimGraph {
	return core.AnimGraph.parse('state none') or { panic(err) }
}

// Animator — a state machine for the sprite sheet frames of the Sprite on the same node. The states, parameters
// and transitions are in a `.anim` file (format: core.AnimGraph). Use it instead of SpriteAnimator when a
// character has several animations (idle / run / jump ...) that switch on conditions.
//
//   Sprite { texture = @asset("hero.png") }          # frame_width / frame_height set in hero.png.meta
//   Animator { graph = @asset("hero.anim") }
//
//   mut anim := c.node.get_component[render.Animator]()!
//   anim.params().set_float('speed', velocity.length())
//   anim.params().trigger('jump')
//   for name in anim.params().take_events() { ... }     // or set on_event
pub struct Animator {
	core.Component
pub mut:
	graph assets.AssetRef[assets.TextAsset] // the .anim file
	speed f32 = 1 // time scale of every state
	// Called for each `event=` the clips pass (instead of polling take_events).
	on_event fn (name string) = unsafe { nil } @[hide]
	machine  &core.AnimGraph  = unsafe { nil }  @[hide]
	hash     u64              @[hide]
	failed   bool             @[hide]
}

pub fn (mut a Animator) on_load() {
	a.reload()
}

fn (mut a Animator) reload() {
	if !a.graph.is_set() {
		return
	}
	g, h := load_anim_graph(a.node, a.graph) or {
		if !a.failed {
			eprintln('[Animator] ${a.node.path()}: ${err}')
		}
		a.failed = true // keep the old graph (hot reload with a typo), say it once
		a.hash = 0
		return
	}
	a.failed = false
	a.hash = h
	if a.machine != unsafe { nil } {
		g.adopt_state(a.machine) // hot reload: keep the parameters and the playing state
	}
	a.machine = g
}

// params: the state machine, for set_float / set_bool / set_int / trigger / take_events / force / state_name.
// An Animator without a (valid) graph gives an inert one.
pub fn (mut a Animator) params() &core.AnimGraph {
	if a.machine == unsafe { nil } {
		a.reload()
	}
	if a.machine == unsafe { nil } {
		a.machine = placeholder_graph()
	}
	return a.machine
}

pub fn (mut a Animator) update(dt f32) {
	if a.graph.is_set() && a.hash != 0 && anim_graph_changed(a.node, a.graph, a.hash) {
		a.reload()
	}
	mut g := a.params()
	mut sprite := a.node.get_component[Sprite]() or { return }
	if sprite.tex == unsafe { nil } {
		return
	}
	st := g.current_state()
	first, n := clip_range(st, sprite.tex.frame_count())
	if n <= 0 {
		return
	}
	g.update(dt * a.speed, f32(n) / st.fps)
	// the state may have changed: show the frame of the one playing now
	cur := g.current_state()
	first2, n2 := clip_range(cur, sprite.tex.frame_count())
	if n2 > 0 {
		mut idx := int(g.state_time() * cur.fps)
		if idx >= n2 {
			idx = n2 - 1
		}
		sprite.frame = first2 + idx
	} else {
		sprite.frame = first
	}
	if a.on_event != unsafe { nil } {
		for name in g.take_events() {
			a.on_event(name)
		}
	}
}

// clip_range: the first frame and the frame count of a state, clamped to the sheet.
fn clip_range(s &core.AnimState, sheet_frames int) (int, int) {
	last := if s.last < 0 || s.last >= sheet_frames { sheet_frames - 1 } else { s.last }
	first := if s.first > last { last } else { s.first }
	return first, last - first + 1
}
