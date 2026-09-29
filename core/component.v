module core

import velo.assets

// IComponent — the contract every component must satisfy.
// Users do NOT need to implement it themselves: just embed `core.Component` in the struct,
// then override the lifecycle methods you need (like MonoBehaviour / cc.Component).
pub interface IComponent {
mut:
	node    &Node
	enabled bool
	started bool
	on_load()
	start()
	update(dt f32)
	on_destroy()
}

// Component — base to embed. The default lifecycle methods do nothing.
//
//   pub struct Rotator {
//       core.Component
//   pub mut:
//       speed f32 = 90
//   }
//   pub fn (mut r Rotator) update(dt f32) { r.node.rotation += r.speed * dt }
pub struct Component {
pub mut:
	node    &Node = unsafe { nil }
	enabled bool  = true
	started bool
}

// on_load: called as soon as the component enters the scene (the node already has a parent, sibling components are present).
pub fn (mut c Component) on_load() {}

// start: called once, right before the first update.
pub fn (mut c Component) start() {}

// update: called every frame while the node is active and the component is enabled.
pub fn (mut c Component) update(dt f32) {}

// on_destroy: called when the node is destroyed or the scene is unloaded.
pub fn (mut c Component) on_destroy() {}

// Quick-access helpers from inside a component.

pub fn (c &Component) scene() &Scene {
	return c.node.scene
}

pub fn (c &Component) input() &Input {
	return c.node.scene.input
}

pub fn (c &Component) assets() &assets.AssetDatabase {
	return c.node.scene.assets
}
