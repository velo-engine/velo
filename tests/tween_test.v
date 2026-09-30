import os
import time
import math
import velo.core
import velo.assets
import velo.serialize
import velo.render

fn near(a f32, b f32) bool {
	return math.abs(a - b) < 0.001
}

fn near2(a core.Vec2, b core.Vec2) bool {
	return near(a.x, b.x) && near(a.y, b.y)
}

@[heap]
struct Log {
mut:
	items []string
}

fn (l &Log) add(s string) {
	mut m := unsafe { l }
	m.items << s
}

fn scene_with(name string) (&core.Scene, &core.Node) {
	mut s := core.Scene.new('Test')
	mut n := core.Node.new(name)
	s.add(mut n)
	return s, n
}

fn test_eases_start_at_0_and_end_at_1() {
	$for e in core.Ease.values {
		assert near(e.value.apply(0), 0), e.name
		assert near(e.value.apply(1), 1), e.name
	}
	assert core.Ease.quad_in.apply(0.5) < 0.5 && core.Ease.quad_out.apply(0.5) > 0.5
	assert core.Ease.back_out.apply(0.7) > 1 // overshoots
	assert core.ease_from_str('bounce_out')! == .bounce_out
}

fn test_move_scale_in_parallel_then_wait_and_call() {
	mut s, mut n := scene_with('A')
	calls := &Log{}
	n.tween().move_to(core.vec2(100, 0), 1, .linear).also().scale_to(core.vec2(3, 3), 0.5, .linear).wait(0.5).call(fn [calls] () {
		calls.add('done')
	})
	s.update(0.25)
	assert near2(n.position, core.vec2(25, 0))
	assert near2(n.scale, core.vec2(2, 2))
	s.update(0.5)
	assert near2(n.position, core.vec2(75, 0)) && near2(n.scale, core.vec2(3, 3))
	s.update(0.5) // step ends at 1.0, then 0.25 into the wait
	assert near2(n.position, core.vec2(100, 0))
	assert calls.items.len == 0
	s.update(0.5)
	assert calls.items == ['done']
	assert n.tweens.len == 0
}

fn test_relative_steps_build_on_each_other() {
	mut s, mut n := scene_with('A')
	n.position = core.vec2(10, 10)
	n.tween().move_by(core.vec2(10, 0), 0.1, .linear).move_by(core.vec2(0, 10), 0.1, .linear).rotate_by(90,
		0.1, .linear)
	for _ in 0 .. 4 {
		s.update(0.1)
	}
	assert near2(n.position, core.vec2(20, 20)) && near(n.rotation, 90)
}

fn test_repeat_restart_yoyo_and_forever() {
	mut s, mut a := scene_with('A')
	a.tween().move_to(core.vec2(10, 0), 1, .linear).repeat(2, false)
	s.update(1.5) // second pass restarts from 0
	assert near(a.position.x, 5)
	s.update(1)
	assert near(a.position.x, 10) && a.tweens.len == 0

	mut b := core.Node.new('B')
	s.add(mut b)
	b.tween().move_to(core.vec2(10, 0), 1, .linear).repeat(-1, true)
	s.update(1.25) // back on the way home
	assert near(b.position.x, 7.5)
	s.update(1)
	assert near(b.position.x, 2.5)
	assert b.tweens.len == 1
	for _ in 0 .. 50 {
		s.update(0.37)
	}
	assert b.tweens.len == 1
}

fn test_kill_finish_pause_and_on_complete() {
	mut s, mut n := scene_with('A')
	finished := &Log{}
	mut t := n.tween().move_to(core.vec2(100, 0), 1, .linear).on_complete(fn [finished] () {
		finished.add('x')
	})
	s.update(0.5)
	t.pause()
	s.update(0.5)
	assert near(n.position.x, 50) && t.is_playing()
	t.finish()
	assert near(n.position.x, 100) && !t.is_playing() && finished.items.len == 1
	mut k := n.tween().delay(0.2).move_to(core.vec2(0, 0), 1, .linear)
	s.update(0.1)
	assert near(n.position.x, 100) // still in the delay
	s.update(0.6)
	assert near(n.position.x, 50)
	k.kill()
	s.update(1)
	assert near(n.position.x, 50) && finished.items.len == 1 // killed tweens do not complete
}

fn test_tween_stops_when_its_node_is_destroyed() {
	mut s, mut n := scene_with('A')
	node := n

	n.tween().move_to(core.vec2(10, 0), 0.1, .linear).call(fn [node] () {
		mut m := unsafe { node }
		m.destroy()
	}).move_to(core.vec2(99, 0), 0.1, .linear)
	s.update(0.15)
	s.update(0.15)
	assert s.node_count() == 1
	assert near(n.position.x, 10)
}

fn test_tween_created_before_entering_the_scene() {
	mut n := core.Node.new('Fx')
	n.tween().scale_to(core.vec2(2, 2), 1, .linear)
	mut s := core.Scene.new('Test')
	s.add(mut n)
	s.update(0.5)
	assert near(n.scale.x, 1.5)
}

fn test_timers_after_every_cancel() {
	mut s, mut n := scene_with('A')
	log := &Log{}
	n.after(0.5, fn [log] () {
		log.add('once')
	})
	mut tick := n.every(0.2, fn [log] () {
		log.add('tick')
	})
	s.update(0.3)
	assert log.items == ['tick']
	s.update(0.25) // 0.55: tick at 0.4, once at 0.5 (in one frame, timers run in the order they were made)
	assert log.items == ['tick', 'once', 'tick']
	s.update(0.5) // a long frame owes three ticks (0.6, 0.8, 1.0)
	assert log.items.filter(it == 'tick').len == 5
	tick.cancel()
	s.update(1)
	assert log.items.len == 6 && !tick.is_pending()
	mut later := s.after(1, fn [log] () {
		log.add('scene')
	})
	assert near(later.time_left(), 1)
	s.update(1)
	assert log.items.last() == 'scene'
}

fn test_time_scale_pause_and_unscaled_nodes() {
	mut s, mut game := scene_with('Game')
	mut menu := core.Node.new('Menu')
	menu.unscaled_time = true
	mut button := core.Node.new('Button')
	menu.add_child(mut button)
	s.add(mut menu)
	game.tween().move_to(core.vec2(100, 0), 1, .linear)
	button.tween().move_to(core.vec2(100, 0), 1, .linear)
	s.time_scale = 0.5
	s.update(0.4)
	assert near(game.position.x, 20) && near(button.position.x, 40)
	assert near(f32(s.time), 0.2) && near(f32(s.real_time), 0.4) && near(s.dt, 0.2)
	s.paused = true
	s.update(0.4)
	assert near(game.position.x, 20) // frozen
	assert near(button.position.x, 80) // the menu keeps going
	assert near(s.dt, 0)
	s.paused = false
	s.time_scale = 1
	s.update(0.2)
	assert near(game.position.x, 40)
}

fn test_fade_and_color_tweens() {
	mut s, mut n := scene_with('Sprite')
	n.add_component(&render.Sprite{})
	n.add_component(&render.Label{
		text: 'hi'
	})
	render.fade_to(mut n, 0, 1, .linear)
	s.update(0.5)
	assert n.get_component[render.Sprite]()?.color.a == 128
	assert n.get_component[render.Label]()?.color.a == 128
	s.update(0.6)
	assert n.get_component[render.Sprite]()?.color.a == 0
	render.color_to(mut n, core.rgba(255, 0, 0, 255), 1, .linear)
	s.update(0.5)
	c := n.get_component[render.Label]()?.color
	assert c == core.rgba(255, 128, 128, 128)
	assert core.rgba(0, 0, 0, 0).lerp(core.rgba(255, 255, 255, 255), 1) == core.white
}

fn test_unscaled_time_loads_and_saves() {
	dir := os.join_path(os.temp_dir(), 'velo_tween_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	db := assets.open(dir)!
	mut reg := serialize.new_registry()
	mut l := serialize.new_loader(reg, db)
	n := l.instantiate_source('node Main { node Pause { unscaled_time = true } }', 'main.scene')!
	assert n.find('Pause')?.unscaled_time
	assert l.save_node(n)!.contains('unscaled_time = true')
}
