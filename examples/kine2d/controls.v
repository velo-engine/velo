module main

import velo.core
import velo.kine2d
import velo.render

// AnimationPicker — clicking the Button on the same node plays the next animation of the Kine2D on `target`;
// the Label of the `text` child shows which one is playing.
pub struct AnimationPicker {
	core.Component
pub mut:
	target string // path of the node with the Kine2D, from the scene root
	prefix string // shown before the animation name
	text   string = 'Text'
}

pub fn (mut p AnimationPicker) start() {
	p.show()
}

pub fn (mut p AnimationPicker) update(dt f32) {
	btn := p.node.get_component[render.Button]() or { return }
	if !btn.clicked {
		return
	}
	mut k := p.kine() or { return }
	names := k.animations()
	if names.len == 0 {
		return
	}
	current := if a := k.current_animation() { a.name } else { '' }
	k.play(names[(names.index(current) + 1) % names.len], true)
	p.show()
}

fn (p &AnimationPicker) kine() ?&kine2d.Kine2D {
	node := p.scene().find(p.target)?
	return node.get_component[kine2d.Kine2D]()
}

fn (mut p AnimationPicker) show() {
	k := p.kine() or { return }
	name := if a := k.current_animation() { a.name } else { '-' }
	mut text := p.node.find(p.text) or { return }
	if mut label := text.get_component[render.Label]() {
		label.text = '${p.prefix}${name}'
	}
}

// PlayOnce — Space, or clicking the Button on the same node, plays `action` once on the Kine2D of `target`,
// then goes back to the looping animation it interrupted.
pub struct PlayOnce {
	core.Component
pub mut:
	target string
	action string = 'attack'
	back   string @[hide] // the animation to return to ('' while idle)
}

pub fn (mut p PlayOnce) update(dt f32) {
	node := p.scene().find(p.target) or { return }
	mut k := node.get_component[kine2d.Kine2D]() or { return }
	clicked := if btn := p.node.get_component[render.Button]() { btn.clicked } else { false }
	if (clicked || p.input().was_pressed(.space)) && p.back == '' {
		p.back = if a := k.current_animation() { a.name } else { '' }
		k.play(p.action, false)
	} else if p.back != '' && k.finished {
		k.play(p.back, true)
		p.back = ''
	}
}

// Patrol — walks the node back and forth between min_x and max_x, facing where it goes
// (a negative x scale mirrors the Kine2D drawing).
pub struct Patrol {
	core.Component
pub mut:
	min_x f32 = 360
	max_x f32 = 600
	speed f32 = 60
	dir   f32 = 1 @[hide]
}

pub fn (mut p Patrol) update(dt f32) {
	p.node.position.x += p.dir * p.speed * dt
	if p.node.position.x > p.max_x {
		p.node.position.x = p.max_x
		p.dir = -1
	} else if p.node.position.x < p.min_x {
		p.node.position.x = p.min_x
		p.dir = 1
	}
	sx := if p.node.scale.x < 0 { -p.node.scale.x } else { p.node.scale.x }
	// The rock's art faces left: mirror it when walking right.
	p.node.scale.x = if p.dir > 0 { -sx } else { sx }
}
