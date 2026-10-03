import os
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render

const hero_anim = 'default = idle
state idle frames=0-3 fps=4
state run  frames=4-9 fps=10
state hit  frames=2-2 once event=0:ouch
any  -> hit  when trigger hit
idle -> run  when speed > 0.5
run  -> idle when speed <= 0.5
hit  -> idle when finished
'

@[heap]
struct Collected {
mut:
	names []string
}

fn setup(anim string) (string, &core.Scene) {
	dir := os.join_path(os.temp_dir(), 'velo_animator_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	// 160x16 PNG header = 10 frames of 16x16
	os.write_file_array(os.join_path(dir, 'hero.png'), [u8(0x89), `P`, `N`, `G`, 13, 10, 26, 10,
		0, 0, 0, 13, `I`, `H`, `D`, `R`, 0, 0, 0, 160, 0, 0, 0, 16]) or { panic(err) }
	os.write_file(os.join_path(dir, 'hero.png.meta'),
		'id: hero0001\nkind: texture\nframe_width: 16\nframe_height: 16\n') or { panic(err) }
	os.write_file(os.join_path(dir, 'hero.anim'), anim) or { panic(err) }
	os.write_file(os.join_path(dir, 'main.scene'), 'node Hero {
  Sprite { texture = @asset("hero0001") }
  Animator { graph = @asset("hero.anim") }
}') or {
		panic(err)
	}
	mut db := assets.open(dir) or { panic(err) }
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut loader := serialize.new_loader(reg, db)
	return dir, loader.load_scene('main.scene') or { panic(err) }
}

fn parts(s &core.Scene) (&render.Sprite, &render.Animator) {
	sp := s.root
	return sp.get_component[render.Sprite]() or { panic('no Sprite') }, sp.get_component[render.Animator]() or {
		panic('no Animator')
	}
}

fn test_animator_plays_and_switches_states() {
	dir, mut s := setup(hero_anim)
	defer {
		os.rmdir_all(dir) or {}
	}
	sprite, mut anim := parts(s)
	s.update(0.01)
	assert sprite.frame == 0 && anim.params().state_name() == 'idle'
	s.update(0.3) // 4 fps: 0.31 s = frame 1
	assert sprite.frame == 1
	anim.params().set_float('speed', 1)
	s.update(0.01)
	assert anim.params().state_name() == 'run'
	s.update(0.25) // 10 fps: frame 4 + 2
	assert sprite.frame == 4 + 2
	// a trigger from any state; the once-clip of one frame finishes and returns to idle
	anim.params().set_float('speed', 0)
	anim.params().trigger('hit')
	s.update(0.01)
	assert anim.params().state_name() == 'hit' && sprite.frame == 2
	assert anim.params().take_events().len == 0 // frame-0 events fire on the update after entering
	s.update(0.01)
	assert anim.params().take_events() == ['ouch']
	s.update(0.1)
	s.update(0.01)
	assert anim.params().state_name() == 'idle'
}

fn test_on_event_callback_and_speed() {
	dir, mut s := setup(hero_anim)
	defer {
		os.rmdir_all(dir) or {}
	}
	_, mut anim := parts(s)
	mut got := &Collected{}
	anim.on_event = fn [mut got] (name string) {
		got.names << name
	}
	anim.params().force('hit')
	s.update(0.01)
	assert got.names == ['ouch']
	anim.speed = 0
	anim.params().set_float('speed', 1) // keeps the run state
	anim.params().force('run')
	s.update(1)
	sprite, _ := parts(s)
	assert sprite.frame == 4 // speed 0: frozen on the first frame
}

fn test_hot_reload_keeps_state_and_params_and_survives_errors() {
	dir, mut s := setup(hero_anim)
	defer {
		os.rmdir_all(dir) or {}
	}
	sprite, mut anim := parts(s)
	anim.params().set_float('speed', 1)
	s.update(0.01)
	assert anim.params().state_name() == 'run'
	mut db := s.assets
	// edit: run gets slower (fps 2); the machine keeps running, speed stays 1
	os.write_file(os.join_path(dir, 'hero.anim'), hero_anim.replace('fps=10', 'fps=2')) or {
		panic(err)
	}
	db.poll_changes()
	s.update(0.01)
	assert anim.params().state_name() == 'run' && anim.params().get_float('speed') == 1
	assert anim.params().current_state().fps == 2
	// a broken edit keeps the old graph
	os.write_file(os.join_path(dir, 'hero.anim'), 'state a\na -> nowhere\n') or { panic(err) }
	db.poll_changes()
	s.update(0.01)
	assert anim.params().state_name() == 'run'
	assert sprite.frame >= 4
}
