module core

// Parallax — a background layer that moves slower (or faster) than the world, for depth. `factor` is how much of
// the camera's movement the node follows: 1 = moves with the world (no effect), 0.5 = half as fast (far away),
// 0 = fixed on the screen, above 1 = in front, faster.
//
//   node Mountains { Parallax { factor = [0.3, 0.1] }  Sprite { ... } }
//
// It moves the node's position (from where it was when the camera first showed it), so put it on a node of its
// own, usually a layer under the world, and let the layer's children keep their local positions.
pub struct Parallax {
	Component
pub mut:
	factor     Vec2 = Vec2{0.5, 0.5}
	origin     Vec2 @[hide] // camera center when first applied
	base       Vec2 @[hide] // node position then
	ready      bool @[hide]
	registered bool @[hide]
}

pub fn (mut p Parallax) on_load() {
	if p.node.scene != unsafe { nil } && !p.registered {
		mut s := p.node.scene
		s.parallaxes << p
		p.registered = true
	}
}

pub fn (mut p Parallax) on_destroy() {
	if p.node.scene != unsafe { nil } && p.registered {
		mut s := p.node.scene
		s.parallaxes = s.parallaxes.filter(voidptr(it) != voidptr(p))
	}
	p.registered = false
}

// apply places the node for the camera's current center (the scene calls it every frame after the camera moved).
pub fn (mut p Parallax) apply() {
	if !p.enabled || p.node == unsafe { nil } || p.node.scene == unsafe { nil } {
		return
	}
	view := p.node.scene.shown_view() or { return }
	if !p.ready {
		p.origin = view.center
		p.base = p.node.position
		p.ready = true
	}
	d := view.center - p.origin
	p.node.position = p.base + vec2(d.x * (1 - p.factor.x), d.y * (1 - p.factor.y))
}
