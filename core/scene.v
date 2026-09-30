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
	s.flush_destroyed()
}

// view_center: the middle of the visible screen, in screen units (where a camera's target is shown).
pub fn (s &Scene) view_center() Vec2 {
	return s.view_origin + s.view_size.mul(0.5)
}

// active_camera: the first enabled Camera on an active node (none = world coordinates are screen coordinates).
pub fn (s &Scene) active_camera() ?&Camera {
	for c in s.cameras {
		if c.enabled && c.node != unsafe { nil } && !c.node.destroyed
			&& c.node.is_active_in_hierarchy() {
			return c
		}
	}
	return none
}

// view_matrix: world -> screen through the active camera (identity without one).
pub fn (s &Scene) view_matrix() Affine2 {
	if c := s.active_camera() {
		return c.view_matrix()
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
