module core

import math
import rand

// Steering behaviors (Reynolds): small functions that return the *force* (an acceleration) an agent wants to
// apply this moment. Add up several, weighted, then apply() them:
//
//   mut me := core.SteerAgent{pos: node.position, vel: vel, max_speed: 120, max_force: 400}
//   f := me.arrive(goal, 80).mul(1.0) + me.separate(neighbor_positions, 40).mul(1.5)
//   me.apply(f, dt)
//   node.position = me.pos
//
// All of them are pure (no scene needed), so they work on any positions: nodes, tile map cells, a server.

pub struct Circle {
pub:
	center Vec2
	radius f32
}

pub struct SteerAgent {
pub mut:
	pos          Vec2
	vel          Vec2
	max_speed    f32 = 100
	max_force    f32 = 300 // the largest acceleration one behavior may ask for
	wander_angle f32 // state of wander()
}

fn limit(v Vec2, max f32) Vec2 {
	l := v.length()
	return if l > max && l > 0.00001 { v.mul(max / l) } else { v }
}

fn set_len(v Vec2, len f32) Vec2 {
	l := v.length()
	return if l > 0.00001 { v.mul(len / l) } else { Vec2{} }
}

// apply integrates a force over dt: speed-limited velocity, then the new position.
pub fn (mut a SteerAgent) apply(force Vec2, dt f32) {
	a.vel = limit(a.vel + limit(force, a.max_force).mul(dt), a.max_speed)
	a.pos = a.pos + a.vel.mul(dt)
}

// steer_to: the force that turns the current velocity into `desired` (limited to max_force).
pub fn (a &SteerAgent) steer_to(desired Vec2) Vec2 {
	return limit(desired - a.vel, a.max_force)
}

// seek heads for `target` at full speed.
pub fn (a &SteerAgent) seek(target Vec2) Vec2 {
	return a.steer_to(set_len(target - a.pos, a.max_speed))
}

// flee runs away from `threat`.
pub fn (a &SteerAgent) flee(threat Vec2) Vec2 {
	return a.steer_to(set_len(a.pos - threat, a.max_speed))
}

// arrive heads for `target` and slows down inside `slow_radius`, stopping on it.
pub fn (a &SteerAgent) arrive(target Vec2, slow_radius f32) Vec2 {
	d := target - a.pos
	dist := d.length()
	if dist < 0.001 {
		return a.steer_to(Vec2{})
	}
	speed := if dist < slow_radius {
		a.max_speed * dist / math.max(slow_radius, 0.001)
	} else {
		a.max_speed
	}
	return a.steer_to(set_len(d, speed))
}

// pursue seeks where a moving target will be (looking ahead by the time it takes to get there).
pub fn (a &SteerAgent) pursue(target_pos Vec2, target_vel Vec2) Vec2 {
	dist := (target_pos - a.pos).length()
	t := dist / math.max(a.max_speed, 0.001)
	return a.seek(target_pos + target_vel.mul(t))
}

// evade flees from where a moving threat will be.
pub fn (a &SteerAgent) evade(threat_pos Vec2, threat_vel Vec2) Vec2 {
	dist := (threat_pos - a.pos).length()
	t := dist / math.max(a.max_speed, 0.001)
	return a.flee(threat_pos + threat_vel.mul(t))
}

// wander drifts in a smoothly changing direction: a point on a circle ahead of the agent moves a little each call.
// `jitter` is how much the angle may change per second in radians, `distance` and `radius` shape the circle.
pub fn (mut a SteerAgent) wander(dt f32, distance f32, radius f32, jitter f32) Vec2 {
	a.wander_angle += (rand.f32() * 2 - 1) * jitter * dt
	heading := if a.vel.length() > 0.001 { a.vel.normalized() } else { vec2(1, 0) }
	circle := a.pos + heading.mul(distance)
	ang := f32(math.atan2(heading.y, heading.x)) + a.wander_angle
	target := circle + vec2(f32(math.cos(ang)), f32(math.sin(ang))).mul(radius)
	return a.seek(target)
}

// separate pushes away from neighbors closer than `radius` (harder the closer they are).
pub fn (a &SteerAgent) separate(neighbors []Vec2, radius f32) Vec2 {
	mut sum := Vec2{}
	mut n := 0
	for p in neighbors {
		d := a.pos - p
		dist := d.length()
		if dist > 0.0001 && dist < radius {
			sum = sum + d.mul(1 / (dist * dist)) // away, weighted by 1/distance
			n++
		}
	}
	if n == 0 {
		return Vec2{}
	}
	return a.steer_to(set_len(sum, a.max_speed))
}

// align matches the average heading of neighbors (their velocities).
pub fn (a &SteerAgent) align(neighbor_vels []Vec2) Vec2 {
	if neighbor_vels.len == 0 {
		return Vec2{}
	}
	mut sum := Vec2{}
	for v in neighbor_vels {
		sum = sum + v
	}
	return a.steer_to(set_len(sum, a.max_speed))
}

// cohere moves toward the middle of the neighbors.
pub fn (a &SteerAgent) cohere(neighbors []Vec2) Vec2 {
	if neighbors.len == 0 {
		return Vec2{}
	}
	mut sum := Vec2{}
	for p in neighbors {
		sum = sum + p
	}
	return a.seek(sum.mul(1 / f32(neighbors.len)))
}

// avoid steers around circular obstacles in the way, looking `ahead` units along the velocity.
pub fn (a &SteerAgent) avoid(obstacles []Circle, ahead f32) Vec2 {
	if a.vel.length() < 0.001 {
		return Vec2{}
	}
	dir := a.vel.normalized()
	tip := a.pos + dir.mul(ahead)
	mid := a.pos + dir.mul(ahead * 0.5)
	mut threat := Circle{}
	mut nearest := f32(1e30)
	for o in obstacles {
		hit := (tip - o.center).length() < o.radius || (mid - o.center).length() < o.radius
		d := (o.center - a.pos).length()
		if hit && d < nearest {
			nearest = d
			threat = o
		}
	}
	if nearest > 1e29 {
		return Vec2{}
	}
	return limit(tip - threat.center, a.max_force)
}

// follow_path seeks the next waypoint of `path` (starting at index `*i`, advancing when within `reach`) and
// arrives at the last one. Returns the force; `i` is updated.
pub fn (a &SteerAgent) follow_path(path []Vec2, mut i &int, reach f32, slow_radius f32) Vec2 {
	if *i >= path.len {
		return a.steer_to(Vec2{})
	}
	for *i < path.len - 1 && (path[*i] - a.pos).length() <= reach {
		unsafe {
			*i = *i + 1
		}
	}
	if *i == path.len - 1 {
		return a.arrive(path[*i], slow_radius)
	}
	return a.seek(path[*i])
}
