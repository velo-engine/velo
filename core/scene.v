module core

import velo.assets

// InstantiateFn is installed into the Scene by App so components can create prefabs at runtime
// without the core module depending on the serialize module.
pub type InstantiateFn = fn (key string) !&Node

// Scene — a running node tree. In Velo, .scene files and prefabs are the SAME format:
// a scene is simply a prefab chosen as the root when running.
@[heap]
pub struct Scene {
pub mut:
	name      string
	root      &Node
	input     &Input
	assets    &assets.AssetDatabase = unsafe { nil }
	time      f64 // seconds of game time (scaled, stops while paused)
	real_time f64 // seconds since the scene started, whatever time_scale and paused say
	frame     u64
	// Game speed: 0.5 = slow motion, 2 = fast forward, 0 = frozen (components still update, with dt 0).
	time_scale f32 = 1
	// Paused: components, timers and tweens stop (physics too), except under nodes with `unscaled_time`.
	// Drawing, input and sound go on.
	paused bool
	// This frame's time step, scaled (what update(dt) receives) and real.
	dt              f32
	unscaled_dt     f32
	pending_destroy []&Node
	instantiate_fn  InstantiateFn = unsafe { nil }
	// The visible game screen, in screen units (UI Widgets without a sized parent align to it): its top-left
	// corner and size. With the default scale mode the design area (e.g. 0,0..960,540) is always inside it and
	// a wider or taller screen shows more around it (so view_origin can be negative). Set by App/editor.
	view_origin Vec2
	view_size   Vec2 = Vec2{960, 540}
	// How far in from each screen edge the safe area starts (notches, rounded corners, system bars), in world units.
	// Set by App on phones; zero on desktop. Widgets aligned to the screen stay inside it (see render.Widget.safe_area).
	safe_insets Insets
	// Cameras in the scene (they add themselves in on_load); see active_camera.
	cameras []&Camera
	// Blending between cameras (see Camera.priority): what was shown last frame and the move in progress.
	last_cam   &Camera = unsafe { nil }
	last_view  CameraView
	blend_from CameraView
	blend_t    f32
	blend_dur  f32 // 0 = not blending
	parallaxes []&Parallax
	lights     []&Light2D
	lightings  []&Lighting
	// The scene's asset ID or path (what App loaded it from); reload() loads it again.
	key string
	// The player's saved data, shared by every scene (App opens it and saves it; see Store).
	store &Store = &Store{}
	// The game's texts in the available languages, shared by every scene (App fills it from `locales/*.txt`).
	locale &Locale = &Locale{}
	// Frame timing, shared by every scene (App turns it on with F2; see Profiler).
	profiler &Profiler = &Profiler{}
	// Set by change_scene: App switches after this frame.
	next_scene  string
	next_change SceneChange
	// 0..1 while App decodes the next scene's assets during a scene change, else 1 (set by App every frame;
	// a component can show it, e.g. a progress bar in a persistent loading overlay).
	loading f32 = 1
	// Set by preload / cancel_preload: App takes them after this frame.
	preload_requests []string
	preload_cancel   bool
}

// SceneChange — how change_scene switches: a fade to `color` and back, `fade` seconds each way (0 = cut).
@[params]
pub struct SceneChange {
pub:
	fade  f32   = 0.25
	color Color = rgba(0, 0, 0, 255)
	// draw a thin progress bar at the bottom of the covered screen while the next scene's assets load
	progress bool = true
}

// change_scene switches to another scene (path or asset ID) once this frame is over; App fades out, loads it,
// and fades in. Direct children of the root with `persistent = true` move to the new scene (a node of the
// same name there is dropped for them). The Store stays. Calling it again before the switch replaces the target.
//
//   c.scene().change_scene('scenes/level2.scene')
//   c.scene().change_scene('scenes/menu.scene', fade: 0.6)
pub fn (mut s Scene) change_scene(key string, opts SceneChange) {
	s.next_scene = key
	s.next_change = opts
}

// preload decodes the textures and sounds of a scene (path or asset ID) in the background while the current one
// keeps running, so a later change_scene to it does not wait. The decoded assets are kept until the next scene
// change finishes (or cancel_preload), so call it only for a scene you are likely to switch to.
//
//   c.scene().preload('scenes/level2.scene')     // e.g. when the player enters the last room of level 1
pub fn (mut s Scene) preload(key string) {
	s.preload_cancel = false
	if key !in s.preload_requests {
		s.preload_requests << key
	}
}

// cancel_preload drops what preload decoded, for a scene that turned out not to be needed.
pub fn (mut s Scene) cancel_preload() {
	s.preload_requests.clear()
	s.preload_cancel = true
}

// reload restarts the current scene (see change_scene).
pub fn (mut s Scene) reload(opts SceneChange) {
	s.change_scene(s.key, opts)
}

// take_persistent moves the persistent root children of `from` into this scene without running any lifecycle
// method (they keep their state, timers, tweens and loaded assets). A root child of this scene with the same
// name is destroyed first. Used by App when switching scenes.
pub fn (mut s Scene) take_persistent(mut from Scene) {
	mut keep := from.root.children.filter(it.persistent && !it.destroyed)
	for mut n in keep {
		for mut other in s.root.children.filter(it.name == n.name) {
			other.destroy()
		}
		s.flush_destroyed()
		n.remove_from_parent()
		n.move_to_scene(mut from, mut s)
		s.root.children << n
		n.parent = s.root
	}
}

// move_to_scene points the subtree at `to` without on_load/on_destroy, carrying its cameras over.
fn (mut n Node) move_to_scene(mut from Scene, mut to Scene) {
	n.scene = to
	moved := from.cameras.filter(voidptr(it.node) == voidptr(n))
	if moved.len > 0 {
		from.cameras = from.cameras.filter(voidptr(it.node) != voidptr(n))
		to.cameras << moved
	}
	for mut ch in n.children {
		ch.move_to_scene(mut from, mut to)
	}
}

pub fn Scene.new(name string) &Scene {
	mut s := &Scene{
		name:  name
		root:  Node.new(name)
		input: &Input{}
	}
	s.root.scene = s
	return s
}

// set_root replaces the scene root (the scene loader calls this after building the node tree).
pub fn (mut s Scene) set_root(mut root Node) {
	root.remove_from_parent()
	s.root = root
	root.attach_to_scene(s)
}

// add attaches a node to the scene root.
pub fn (mut s Scene) add(mut n Node) &Node {
	return s.root.add_child(mut n)
}

// find looks up a node by path from the root, e.g. 'World/Player'.
pub fn (s &Scene) find(path string) ?&Node {
	return s.root.find(path)
}

// instantiate creates a node from a prefab (by path or asset ID) and attaches it to `parent`.
pub fn (mut s Scene) instantiate(key string, mut parent Node) !&Node {
	if s.instantiate_fn == unsafe { nil } {
		return error('scene "${s.name}" has no prefab loader (run it through app.App)')
	}
	mut n := s.instantiate_fn(key)!
	parent.add_child(mut n)
	return n
}

// update runs one frame: start()/update() for every component, then processes destroyed nodes.
// update runs one frame of `real_dt` seconds: time_scale and paused turn it into game time.
pub fn (mut s Scene) update(real_dt f32) {
	dt := if s.paused { f32(0) } else { real_dt * if s.time_scale > 0 {
			s.time_scale
		} else {
			f32(0)
		}
	 }
	s.dt = dt
	s.unscaled_dt = real_dt
	s.time += dt
	s.real_time += real_dt
	s.frame++
	s.root.tick(dt, real_dt, s.paused)
	if mut cam := s.active_camera() {
		cam.late_update(if cam.node.unscaled_time { real_dt } else { dt })
	}
	s.update_camera_blend(real_dt)
	for mut p in s.parallaxes {
		p.apply()
	}
	s.flush_destroyed()
}

// view_center: the middle of the visible screen, in screen units (where a camera's target is shown).
pub fn (s &Scene) view_center() Vec2 {
	return s.view_origin + s.view_size.mul(0.5)
}

// active_camera: the enabled Camera on an active node with the highest `priority` (ties: the first one added);
// none = world coordinates are screen coordinates.
pub fn (s &Scene) active_camera() ?&Camera {
	mut best := unsafe { &Camera(nil) }
	for c in s.cameras {
		if c.enabled && c.node != unsafe { nil } && !c.node.destroyed
			&& c.node.is_active_in_hierarchy() {
			if best == unsafe { nil } || c.priority > best.priority {
				unsafe {
					best = c
				}
			}
		}
	}
	if best == unsafe { nil } {
		return none
	}
	return best
}

// lighting: the first enabled Lighting on an active node (none = the world is drawn unlit).
pub fn (s &Scene) lighting() ?&Lighting {
	for l in s.lightings {
		if l.enabled && l.node != unsafe { nil } && !l.node.destroyed
			&& l.node.is_active_in_hierarchy() {
			return l
		}
	}
	return none
}

// shown_view: what is on screen now: the active camera's view, or the blend from the previous camera's.
pub fn (s &Scene) shown_view() ?CameraView {
	c := s.active_camera() or { return none }
	if s.blend_dur > 0 && s.blend_t < s.blend_dur {
		k := Ease.sine_in_out.apply(s.blend_t / s.blend_dur)
		return lerp_view(s.blend_from, c.view(), k)
	}
	return c.view()
}

// camera_center: the world point at the middle of the screen (blending included); the origin without a camera.
pub fn (s &Scene) camera_center() Vec2 {
	v := s.shown_view() or { return Vec2{} }
	return v.center
}

// update_camera_blend starts a blend when the active camera changed and moves it along (called by update).
fn (mut s Scene) update_camera_blend(real_dt f32) {
	cam := s.active_camera() or {
		s.last_cam = unsafe { nil }
		s.blend_dur = 0
		return
	}
	if voidptr(cam) != voidptr(s.last_cam) {
		if s.last_cam != unsafe { nil } && cam.blend_time > 0 {
			s.blend_from = s.last_view
			s.blend_t = 0
			s.blend_dur = cam.blend_time
		} else {
			s.blend_dur = 0
		}
		s.last_cam = cam
	}
	if s.blend_dur > 0 {
		s.blend_t += real_dt
		if s.blend_t >= s.blend_dur {
			s.blend_dur = 0
		}
	}
	s.last_view = s.shown_view() or { return }
}

// view_matrix: world -> screen through the active camera (identity without one).
pub fn (s &Scene) view_matrix() Affine2 {
	if v := s.shown_view() {
		return v.matrix(s.view_center())
	}
	return Affine2.identity()
}

// screen_to_world converts a screen point (input.mouse, a touch) to world coordinates.
pub fn (s &Scene) screen_to_world(p Vec2) Vec2 {
	return s.view_matrix().inverse().apply(p)
}

// world_to_screen converts a world point to screen coordinates.
pub fn (s &Scene) world_to_screen(p Vec2) Vec2 {
	return s.view_matrix().apply(p)
}

pub fn (mut s Scene) flush_destroyed() {
	for s.pending_destroy.len > 0 {
		mut batch := s.pending_destroy.clone()
		s.pending_destroy.clear()
		for mut n in batch {
			n.detach_from_scene()
			n.remove_from_parent()
		}
	}
}

// unload calls on_destroy on the whole tree (releasing asset references).
pub fn (mut s Scene) unload() {
	s.root.detach_from_scene()
	s.pending_destroy.clear()
}

// node_count counts live nodes (handy for debugging/tests).
pub fn (s &Scene) node_count() int {
	return count_nodes(s.root)
}

fn count_nodes(n &Node) int {
	mut total := 1
	for c in n.children {
		total += count_nodes(c)
	}
	return total
}
