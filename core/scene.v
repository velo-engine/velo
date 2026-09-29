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
	name            string
	root            &Node
	input           &Input
	assets          &assets.AssetDatabase = unsafe { nil }
	time            f64
	frame           u64
	pending_destroy []&Node
	instantiate_fn  InstantiateFn = unsafe { nil }
	// Size of the game screen, in world units (UI Widgets without a sized parent align to it). Set by App/editor.
	view_size Vec2 = Vec2{960, 540}
	// How far in from each screen edge the safe area starts (notches, rounded corners, system bars), in world units.
	// Set by App on phones; zero on desktop. Widgets aligned to the screen stay inside it (see render.Widget.safe_area).
	safe_insets Insets
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
pub fn (mut s Scene) update(dt f32) {
	s.time += dt
	s.frame++
	s.root.tick(dt)
	s.flush_destroyed()
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
