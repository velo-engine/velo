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
// More: `deadzone` (the target moves in a box without moving the camera), `look_ahead` (leads the target's
// movement), several comma-separated `follow` targets with `fit_margin` (zooms to keep them all in view),
// zoom_to() to ease the zoom, and `priority` + `blend_time` to switch between several cameras with a smooth move.
//
// Nodes under a Canvas ignore the camera (HUD, menus). Convert pointer positions with scene.screen_to_world(p).
@[heap]
pub struct Camera {
	Component
pub mut:
	zoom f32 = 1 // > 1 = closer (things look bigger)
	// Path (from the scene root, e.g. "World/Player") of a node the camera moves to every frame, after all updates.
	// Several paths separated by commas: the camera follows the middle of their bounding box.
	follow        string
	follow_offset Vec2 // added to the followed node's position (look ahead, look up)
	// How fast the camera catches up with the followed node (1/s); 0 = sticks to it.
	smoothing f32
	// Size (w, h, world units) of a box around the camera in which the target can move without moving the camera.
	deadzone Vec2
	// Seconds of the target's velocity the camera leads by (looks where the target is going).
	look_ahead f32
	// With `follow` set: keep every target in view with this margin (world units) around them, zooming out down
	// to `min_zoom`; `zoom` is then the closest it gets (alone, the target gets `zoom`). 0 = off.
	fit_margin f32
	min_zoom   f32 = 0.25
	// Which camera shows when several are enabled: the highest priority (ties: the first). When the active camera
	// changes, the view moves from the old one to this one over `blend_time` seconds (0 = cut).
	priority   int
	blend_time f32 = 0.5
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
	look_velocity  Vec2 @[hide] // smoothed velocity of the target
	last_target    Vec2 @[hide]
	has_last       bool @[hide]
	fit_zoom       f32  @[hide] // 0 = not fitting; else the zoom currently used
	zoom_from      f32  @[hide]
	zoom_goal      f32  @[hide]
	zoom_time      f32  @[hide]
	zoom_duration  f32  @[hide]
	zoom_ease      Ease @[hide]
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

// ZoomOptions — how zoom_to eases.
@[params]
pub struct ZoomOptions {
pub:
	ease Ease = .sine_in_out
}

// zoom_to eases `zoom` to a new value over `seconds` (0 = at once), e.g. a close-up for a cutscene.
pub fn (mut c Camera) zoom_to(zoom f32, seconds f32, opts ZoomOptions) {
	if seconds <= 0 {
		c.zoom = zoom
		c.zoom_duration = 0
		return
	}
	c.zoom_from = c.zoom
	c.zoom_goal = zoom
	c.zoom_time = 0
	c.zoom_duration = seconds
	c.zoom_ease = opts.ease
}

// late_update runs once per frame after every component's update (the scene calls it on its camera),
// so it follows where the target ended up this frame.
pub fn (mut c Camera) late_update(dt f32) {
	if c.zoom_duration > 0 {
		c.zoom_time += dt
		k := if c.zoom_time >= c.zoom_duration { f32(1) } else { c.zoom_time / c.zoom_duration }
		c.zoom = c.zoom_from + (c.zoom_goal - c.zoom_from) * c.zoom_ease.apply(k)
		if k >= 1 {
			c.zoom_duration = 0
		}
	}
	if c.follow != '' && c.node.scene != unsafe { nil } {
		c.follow_targets(dt)
	} else {
		c.has_last = false
	}
	if c.shake_time > 0 {
		c.shake_time = math.max(c.shake_time - dt, f32(0))
		amount := c.shake_strength * c.shake_time / c.shake_duration
		c.shake_offset = vec2((rand.f32() * 2 - 1) * amount, (rand.f32() * 2 - 1) * amount)
	} else {
		c.shake_offset = Vec2{}
	}
}

// follow_targets moves the camera towards its targets: their middle, plus follow_offset and the look-ahead,
// outside the dead zone, eased by `smoothing`; and fits the zoom to them when fit_margin is set.
fn (mut c Camera) follow_targets(dt f32) {
	mut lo := Vec2{}
	mut hi := Vec2{}
	mut found := 0
	for path in c.follow.split(',') {
		target := c.node.scene.find(path.trim_space()) or { continue }
		p := target.world_position()
		if found == 0 {
			lo, hi = p, p
		} else {
			lo = vec2(math.min(lo.x, p.x), math.min(lo.y, p.y))
			hi = vec2(math.max(hi.x, p.x), math.max(hi.y, p.y))
		}
		found++
	}
	if found == 0 {
		c.has_last = false
		return
	}
	mid := lo.lerp(hi, 0.5)
	t := if c.smoothing > 0 { f32(1 - math.exp(-c.smoothing * dt)) } else { f32(1) }
	if c.look_ahead > 0 {
		if c.has_last && dt > 0 {
			v := (mid - c.last_target).mul(1 / dt)
			c.look_velocity = c.look_velocity.lerp(v, f32(1 - math.exp(-6 * dt)))
		}
		c.last_target = mid
		c.has_last = true
	} else {
		c.look_velocity = Vec2{}
		c.has_last = false
	}
	pos := c.node.world_position()
	mut goal := mid + c.follow_offset + c.look_velocity.mul(c.look_ahead)
	if c.deadzone.x > 0 || c.deadzone.y > 0 {
		goal = vec2(deadzone_axis(goal.x, pos.x, c.deadzone.x), deadzone_axis(goal.y, pos.y,
			c.deadzone.y))
	}
	c.node.set_world_position(pos.lerp(goal, t))
	if c.fit_margin > 0 {
		size := (hi - lo) + vec2(c.fit_margin * 2, c.fit_margin * 2)
		view := c.node.scene.view_size
		need := math.min(view.x / math.max(size.x, 1), view.y / math.max(size.y, 1))
		want := f32(math.clamp(need, c.min_zoom, math.max(c.zoom, c.min_zoom)))
		c.fit_zoom = if c.fit_zoom <= 0 { want } else { c.fit_zoom + (want - c.fit_zoom) * t }
	} else {
		c.fit_zoom = 0
	}
}

// deadzone_axis: where the camera's goal is once the target may roam `size` around the camera on one axis.
fn deadzone_axis(goal f32, pos f32, size f32) f32 {
	half := size / 2
	d := goal - pos
	if d > half {
		return goal - half
	}
	if d < -half {
		return goal + half
	}
	return pos
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
	z := if c.fit_zoom > 0 { c.fit_zoom } else { c.zoom }
	return if z > 0.001 { z } else { f32(1) }
}

// CameraView — what a camera shows: the world point at the screen center, the zoom and the rotation.
// Scenes blend two of them when the active camera changes.
pub struct CameraView {
pub:
	center   Vec2
	zoom     f32 = 1
	rotation f32 // degrees
}

// matrix: world -> screen for a view whose center is drawn at `mid` (the screen's middle).
pub fn (v CameraView) matrix(mid Vec2) Affine2 {
	eye := Affine2.trs(v.center, v.rotation, vec2(1 / v.zoom, 1 / v.zoom))
	return Affine2.trs(mid, 0, vec2(1, 1)).mul(eye.inverse())
}

// lerp_view: t = 0 is `a`, 1 is `b`. The zoom blends by ratio (so a zoom from 1 to 4 is halfway at 2, not 2.5)
// and the rotation takes the short way round.
pub fn lerp_view(a CameraView, b CameraView, t f32) CameraView {
	mut dr := f32(math.fmod(b.rotation - a.rotation, 360))
	if dr > 180 {
		dr -= 360
	} else if dr < -180 {
		dr += 360
	}
	return CameraView{
		center:   a.center.lerp(b.center, t)
		zoom:     f32(a.zoom * math.pow(b.zoom / a.zoom, t))
		rotation: a.rotation + dr * t
	}
}

// view: this camera's own view (limits and shake applied).
pub fn (c &Camera) view() CameraView {
	return CameraView{
		center:   c.center()
		zoom:     c.effective_zoom()
		rotation: c.node.world_matrix().rotation_deg()
	}
}

// view_matrix: world -> screen for this camera.
pub fn (c &Camera) view_matrix() Affine2 {
	mid := if c.node.scene != unsafe { nil } { c.node.scene.view_center() } else { Vec2{} }
	return c.view().matrix(mid)
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
