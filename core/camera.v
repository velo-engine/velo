module core

import math
import rand

// Camera — what part of the world the screen shows: the camera node's world position is at the center of the
// screen, turned by its world rotation and magnified by `zoom`. The first enabled Camera on an active node is the
// scene's camera; without one, world = screen (as before cameras existed).
//
//   node Cam {
//     Camera { follow = "World/Player"  smoothing = 8  zoom = 1.5  limit_min = [0, 0]  limit_max = [3000, 1200] }
//   }
//
// Nodes under a Canvas ignore the camera (HUD, menus). Convert pointer positions with scene.screen_to_world(p).
@[heap]
pub struct Camera {
	Component
pub mut:
	zoom f32 = 1 // > 1 = closer (things look bigger)
	// Path (from the scene root, e.g. "World/Player") of a node the camera moves to every frame, after all updates.
	follow        string
	follow_offset Vec2 // added to the followed node's position (look ahead, look up)
	// How fast the camera catches up with the followed node (1/s); 0 = sticks to it.
	smoothing f32
	// World rectangle the view stays inside (when limit_max > limit_min on an axis). A view larger than the
	// rectangle is centered on it.
	limit_min Vec2
	limit_max Vec2
	// Current shake, see shake().
	shake_strength f32  @[hide]
	shake_time     f32  @[hide]
	shake_duration f32  @[hide]
	shake_offset   Vec2 @[hide]
	registered     bool @[hide]
}

pub fn (mut c Camera) on_load() {
	if c.node.scene != unsafe { nil } && !c.registered {
		mut s := c.node.scene
		s.cameras << c
		c.registered = true
	}
}

pub fn (mut c Camera) on_destroy() {
	if c.node.scene != unsafe { nil } && c.registered {
		mut s := c.node.scene
		s.cameras = s.cameras.filter(voidptr(it) != voidptr(c)) // == would compare contents
	}
	c.registered = false
}

// shake moves the view randomly by up to `strength` world units, fading out over `duration` seconds.
// A weaker shake does not cut a stronger one short.
pub fn (mut c Camera) shake(strength f32, duration f32) {
	if strength <= 0 || duration <= 0 {
		return
	}
	left := if c.shake_duration > 0 { c.shake_strength * c.shake_time / c.shake_duration } else { 0 }
	if strength < left {
		return
	}
	c.shake_strength = strength
	c.shake_time = duration
	c.shake_duration = duration
}

// late_update runs once per frame after every component's update (the scene calls it on its camera),
// so it follows where the target ended up this frame.
pub fn (mut c Camera) late_update(dt f32) {
	if c.follow != '' && c.node.scene != unsafe { nil } {
		if target := c.node.scene.find(c.follow) {
			goal := target.world_position() + c.follow_offset
			pos := c.node.world_position()
			t := if c.smoothing > 0 { f32(1 - math.exp(-c.smoothing * dt)) } else { f32(1) }
			c.node.set_world_position(pos.lerp(goal, t))
		}
	}
	if c.shake_time > 0 {
		c.shake_time = math.max(c.shake_time - dt, f32(0))
		amount := c.shake_strength * c.shake_time / c.shake_duration
		c.shake_offset = vec2((rand.f32() * 2 - 1) * amount, (rand.f32() * 2 - 1) * amount)
	} else {
		c.shake_offset = Vec2{}
	}
}

// center: the world point shown at the center of the screen (limits and shake applied).
pub fn (c &Camera) center() Vec2 {
	mut p := c.node.world_position()
	if c.node.scene != unsafe { nil } {
		half := c.node.scene.view_size.mul(0.5 / c.effective_zoom())
		p = vec2(limit_axis(p.x, half.x, c.limit_min.x, c.limit_max.x), limit_axis(p.y, half.y,
			c.limit_min.y, c.limit_max.y))
	}
	return p + c.shake_offset
}

fn limit_axis(v f32, half f32, lo f32, hi f32) f32 {
	if hi <= lo {
		return v
	}
	if hi - lo <= half * 2 {
		return (lo + hi) / 2
	}
	return f32(math.clamp(v, lo + half, hi - half))
}

fn (c &Camera) effective_zoom() f32 {
	return if c.zoom > 0.001 { c.zoom } else { f32(1) }
}

// view_matrix: world -> screen for this camera.
pub fn (c &Camera) view_matrix() Affine2 {
	z := c.effective_zoom()
	mid := if c.node.scene != unsafe { nil } { c.node.scene.view_center() } else { Vec2{} }
	eye := Affine2.trs(c.center(), c.node.world_matrix().rotation_deg(), vec2(1 / z, 1 / z))
	return Affine2.trs(mid, 0, vec2(1, 1)).mul(eye.inverse())
}

// visible_rect: the world-space bounds of what the camera shows (x, y, w, h; ignores rotation).
pub fn (c &Camera) visible_rect() (Vec2, Vec2) {
	size := if c.node.scene != unsafe { nil } { c.node.scene.view_size } else { Vec2{} }
	sz := size.mul(1 / c.effective_zoom())
	return c.center() - sz.mul(0.5), sz
}

// Canvas — its node and everything under it are drawn in screen space: the camera does not move them,
// and they draw over the world (HUD, menus, on-screen controls). UI components under it read the pointer
// in screen coordinates, as they always did.
pub struct Canvas {
	Component
}

// in_canvas: the node or one of its ancestors has a Canvas.
pub fn (n &Node) in_canvas() bool {
	mut cur := unsafe { n }
	for cur != unsafe { nil } {
		if _ := cur.get_component[Canvas]() {
			return true
		}
		cur = cur.parent
	}
	return false
}

// screen_matrix: node space -> screen (through the scene camera unless the node is under a Canvas).
pub fn (n &Node) screen_matrix() Affine2 {
	m := n.world_matrix()
	if n.scene == unsafe { nil } || n.in_canvas() {
		return m
	}
	return n.scene.view_matrix().mul(m)
}
