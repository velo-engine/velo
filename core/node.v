module core

// A Node only holds a transform + the parent/child tree + a component list; all behavior lives in components.
@[heap]
pub struct Node {
pub mut:
	name     string
	position Vec2
	rotation f32 // degrees, positive = clockwise on screen
	scale    Vec2 = Vec2{1, 1}
	active   bool = true
	// Draw order: higher draws over lower, whatever the tree order. Relative to the parent (a child of a node
	// with z_index 2 and its own 1 draws at 3). Equal values keep the tree order.
	z_index int
	// Draw the children ordered by their world y (lower on screen = in front), e.g. a top-down game's
	// characters and trees. Each child moves with its whole subtree.
	y_sort bool
	// This node and its children ignore Scene.time_scale and Scene.paused: they get real time and keep
	// updating while the game is paused (pause menus, UI animations).
	unscaled_time bool
	parent        &Node = unsafe { nil }
	children      []&Node
	components    []IComponent
	scene         &Scene = unsafe { nil }
	destroyed     bool
	// ID of the prefab that created this node ('' if not an instance). Used when saving to write only the overrides.
	prefab_id string
	tweens    []&Tween // see tween()
	timers    []&Timer // see after() / every()
}

pub fn Node.new(name string) &Node {
	return &Node{
		name: name
	}
}

// ---------- Parent / child tree ----------

// add_child attaches `child` to this node. If the node is in a scene, the child's components receive on_load().
pub fn (mut n Node) add_child(mut child Node) &Node {
	return n.insert_child(mut child, n.children.len)
}

// insert_child attaches `child` at position `index` in the child list (used by the editor: drag and drop, reordering).
// Moving a node within the same scene does not call on_load() again.
pub fn (mut n Node) insert_child(mut child Node, index int) &Node {
	if child.parent != unsafe { nil } {
		child.remove_from_parent()
	}
	child.parent = n
	i := if index < 0 {
		0
	} else if index > n.children.len {
		n.children.len
	} else {
		index
	}
	n.children.insert(i, child)
	if n.scene != unsafe { nil } && child.scene != n.scene {
		child.attach_to_scene(n.scene)
	}
	return child
}

// child_index: position of the node in its parent's child list (-1 if it has no parent).
pub fn (n &Node) child_index() int {
	if n.parent == unsafe { nil } {
		return -1
	}
	for i, c in n.parent.children {
		if c == n {
			return i
		}
	}
	return -1
}

// is_ancestor_of: true if `other` is in this node's subtree (including the node itself).
pub fn (n &Node) is_ancestor_of(other &Node) bool {
	mut cur := unsafe { other }
	for cur != unsafe { nil } {
		if cur == n {
			return true
		}
		cur = cur.parent
	}
	return false
}

// child: chaining (builder) version of add_child — returns the parent node itself.
pub fn (n &Node) child(c &Node) &Node {
	mut self := unsafe { n }
	mut ch := unsafe { c }
	self.add_child(mut ch)
	return n
}

pub fn (mut n Node) remove_from_parent() {
	if n.parent == unsafe { nil } {
		return
	}
	mut p := n.parent
	for i, c in p.children {
		if c == n {
			p.children.delete(i)
			break
		}
	}
	n.parent = unsafe { nil }
}

// find looks up a child node by path 'World/Player/Weapon' (relative to this node).
pub fn (n &Node) find(path string) ?&Node {
	mut cur := unsafe { n }
	for part in path.split('/') {
		if part == '' || part == '.' {
			continue
		}
		if part == '..' {
			if cur.parent == unsafe { nil } {
				return none
			}
			cur = cur.parent
			continue
		}
		mut found := false
		for c in cur.children {
			if c.name == part && !c.destroyed {
				cur = unsafe { c }
				found = true
				break
			}
		}
		if !found {
			return none
		}
	}
	return cur
}

// path returns the full path from the scene root, e.g. 'Main/World/Player'.
pub fn (n &Node) path() string {
	if n.parent == unsafe { nil } {
		return n.name
	}
	return '${n.parent.path()}/${n.name}'
}

pub fn (n &Node) is_active_in_hierarchy() bool {
	if !n.active || n.destroyed {
		return false
	}
	if n.parent == unsafe { nil } {
		return true
	}
	return n.parent.is_active_in_hierarchy()
}

// ---------- Component ----------

// add_component attaches a component of a concrete type and returns a typed pointer for further use.
//   mut sprite := node.add_component(&render.Sprite{ texture: ref })
pub fn (mut n Node) add_component[T](c &T) &T {
	n.add_component_dyn(c)
	return unsafe { c }
}

// with: builder version, used when building prefabs in code.
//   enemy := core.Node.new('Enemy').with(&Sprite{...}).with(&Health{max: 3})
pub fn (n &Node) with(c IComponent) &Node {
	mut self := unsafe { n }
	self.add_component_dyn(c)
	return n
}

// add_component_dyn attaches a component whose type is not known at compile time (used by the scene loader).
pub fn (mut n Node) add_component_dyn(c IComponent) {
	n.components << c
	idx := n.components.len - 1
	n.components[idx].node = n
	if n.scene != unsafe { nil } {
		n.components[idx].on_load()
	}
}

// remove_component removes the component at index `idx` (calls on_destroy if the node is in a scene).
pub fn (mut n Node) remove_component(idx int) {
	if idx < 0 || idx >= n.components.len {
		return
	}
	if n.scene != unsafe { nil } {
		n.components[idx].on_destroy()
	}
	n.components.delete(idx)
}

// get_component returns the first component of type T.
//   if mut body := node.get_component[RigidBody]() { body.velocity.y = -300 }
pub fn (n &Node) get_component[T]() ?&T {
	for c in n.components {
		if c is T {
			return c
		}
	}
	return none
}

pub fn (n &Node) get_components[T]() []&T {
	mut out := []&T{}
	for c in n.components {
		if c is T {
			out << c
		}
	}
	return out
}

// get_component_in_children searches depth-first, starting from this node itself.
pub fn (n &Node) get_component_in_children[T]() ?&T {
	if c := n.get_component[T]() {
		return c
	}
	for ch in n.children {
		if c := ch.get_component_in_children[T]() {
			return c
		}
	}
	return none
}

// component_by_type_name is used by serialize/editor when only the type name is known as a string.
pub fn (n &Node) component_by_type_name(name string) ?IComponent {
	for c in n.components {
		if short_type_name(c.type_name()) == name {
			return c
		}
	}
	return none
}

// ---------- Transform ----------

pub fn (n &Node) local_matrix() Affine2 {
	return Affine2.trs(n.position, n.rotation, n.scale)
}

pub fn (n &Node) world_matrix() Affine2 {
	if n.parent == unsafe { nil } {
		return n.local_matrix()
	}
	return n.parent.world_matrix().mul(n.local_matrix())
}

pub fn (n &Node) world_position() Vec2 {
	return n.world_matrix().position()
}

pub fn (mut n Node) set_world_position(p Vec2) {
	if n.parent == unsafe { nil } {
		n.position = p
		return
	}
	n.position = n.parent.world_matrix().inverse().apply(p)
}

// ---------- Destruction ----------

// destroy marks the node for destruction at the end of the current frame (safe to call during update).
pub fn (mut n Node) destroy() {
	if n.destroyed {
		return
	}
	n.destroyed = true
	if n.scene != unsafe { nil } {
		mut s := n.scene
		s.pending_destroy << n
	} else {
		n.remove_from_parent()
	}
}

// ---------- Internal ----------

fn (mut n Node) attach_to_scene(s &Scene) {
	n.scene = unsafe { s }
	for i in 0 .. n.components.len {
		n.components[i].on_load()
	}
	for mut ch in n.children {
		ch.attach_to_scene(s)
	}
}

fn (mut n Node) detach_from_scene() {
	for mut ch in n.children {
		ch.detach_from_scene()
	}
	for i in 0 .. n.components.len {
		n.components[i].on_destroy()
	}
	n.scene = unsafe { nil }
}

// tick updates the node's components, timers and tweens, then its children. `dt` is scaled time (zero while
// `paused`); `real` is the unscaled frame time, used from a node with `unscaled_time` down.
fn (mut n Node) tick(dt f32, real f32, paused bool) {
	if !n.active || n.destroyed {
		return
	}
	d := if n.unscaled_time { real } else { dt }
	p := paused && !n.unscaled_time
	if !p {
		// Snapshot the counts: components/children added during this frame run starting next frame.
		count := n.components.len
		for i in 0 .. count {
			if !n.components[i].enabled {
				continue
			}
			if !n.components[i].started {
				n.components[i].started = true
				n.components[i].start()
			}
			n.components[i].update(d)
		}
		n.tick_timers(d)
		n.tick_tweens(d)
	}
	mut kids := n.children.clone()
	for mut ch in kids {
		ch.tick(d, real, p)
	}
}

// short_type_name: 'main.PlayerController' -> 'PlayerController', '&render.Sprite' -> 'Sprite'.
pub fn short_type_name(full string) string {
	return full.trim_left('&').all_after_last('.')
}
