module main

import velo.core
import velo.physics
import velo.render

// PlayerController — moves with the keyboard or the on-screen joystick (analog: a small push walks slowly), flips the sprite by direction, plays the animation while walking.
// With a RigidBody it moves by velocity, so it pushes crates and stops at trees instead of walking through them.
pub struct PlayerController {
	core.Component
pub mut:
	speed      f32       = 220
	bounds_min core.Vec2 = core.Vec2{24, 60}
	bounds_max core.Vec2 = core.Vec2{936, 530}
	joystick   string    = 'HUD/Joystick' // node with a render.Joystick ('' = keyboard only)
}

pub fn (mut p PlayerController) update(dt f32) {
	input := p.input()
	mut dir := core.vec2(input.axis_x(), input.axis_y()).normalized()
	if dir.length() == 0 && p.joystick != '' {
		if stick_node := p.scene().find(p.joystick) {
			if stick := stick_node.get_component[render.Joystick]() {
				dir = stick.value
			}
		}
	}
	moving := dir.length() > 0

	mut pos := p.node.position
	if mut body := p.node.get_component[physics.RigidBody]() {
		body.set_velocity(dir.mul(p.speed))
	} else {
		pos = pos + dir.mul(p.speed * dt)
	}
	pos.x = clamp(pos.x, p.bounds_min.x, p.bounds_max.x)
	pos.y = clamp(pos.y, p.bounds_min.y, p.bounds_max.y)
	p.node.position = pos

	if mut sprite := p.node.get_component[render.Sprite]() {
		if dir.x < 0 {
			sprite.flip_x = true
		} else if dir.x > 0 {
			sprite.flip_x = false
		}
		if !moving {
			sprite.frame = 0
		}
	}
	if mut anim := p.node.get_component[render.SpriteAnimator]() {
		anim.playing = moving
	}
}

fn clamp(v f32, lo f32, hi f32) f32 {
	return if v < lo {
		lo
	} else if v > hi {
		hi
	} else {
		v
	}
}
