import os
import time
import velo.core
import velo.assets
import velo.serialize

@[heap]
struct Box {
mut:
	text  string
	count int
}

fn temp_dir(tag string) string {
	dir := os.join_path(os.temp_dir(), 'velo_${tag}_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn test_store_types_defaults_and_dirty() {
	mut s := &core.Store{}
	assert s.get_int('coins', 7) == 7 && !s.has('coins') && !s.dirty
	s.set_int('coins', 12)
	s.set_f32('volume', 0.5)
	s.set_bool('music', false)
	s.set_string('name', 'Anh "the best"\nline 2 \\ ok')
	assert s.dirty
	assert s.get_int('coins', 0) == 12
	assert s.get_f32('volume', 1) == 0.5
	assert !s.get_bool('music', true)
	assert s.get_string('name', '').contains('"the best"')
	// wrong type -> the default; numbers convert
	assert s.get_bool('coins', true) && s.get_string('coins', 'x') == 'x'
	assert s.get_f64('coins', 0) == 12 && s.get_int('volume', 0) == 0
	s.set_int('bad key!', 1) // ignored with a message
	assert !s.has('bad key!')
	assert s.keys() == ['coins', 'music', 'name', 'volume']
	s.delete('music')
	assert !s.has('music')
}

fn test_store_text_round_trip() {
	mut s := &core.Store{}
	s.set_int('level', 3)
	s.set_f64('best', 42)
	s.set_f64('tiny', 0.000125)
	s.set_int('neg', -5)
	s.set_string('name', 'Việt "Nam"\n\\')
	s.set_bool('done', true)
	text := s.encode()
	assert text.contains('best = 42.0') // stays a decimal
	t := core.Store.from_text(text)!
	for k in s.keys() {
		assert t.has(k), k
	}
	assert t.get_int('level', 0) == 3 && t.get_f64('best', 0) == 42
		&& t.get_f64('tiny', 0) == 0.000125
	assert t.get_int('neg', 0) == -5 && t.get_bool('done', false)
	assert t.get_string('name', '') == 'Việt "Nam"\n\\'
	if _ := core.Store.from_text('oops') {
		assert false
	}
	if _ := core.Store.from_text('x = [1, 2]') {
		assert false
	}
}

fn test_store_saves_and_reopens_file() {
	dir := temp_dir('store')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'my-game', 'save.txt') // folder created on save
	mut s := core.Store.open(path)
	s.set_int('coins', 99)
	s.save_if_changed()
	assert !s.dirty && os.is_file(path) && !os.exists(path + '.tmp')
	again := core.Store.open(path)
	assert again.get_int('coins', 0) == 99
	os.write_file(path, 'not a save file')!
	broken := core.Store.open(path) // reported, starts empty
	assert broken.keys().len == 0
	// a custom writer (the web uses localStorage)
	out := &Box{}
	mut w := &core.Store{}
	w.writer = fn [out] (t string) ! {
		mut b := unsafe { out }
		b.text = t
	}
	w.set_bool('ok', true)
	w.save()!
	assert out.text.contains('ok = true')
}

struct Tracker {
	core.Component
mut:
	log []string
}

fn (mut t Tracker) on_load() {
	t.log << 'load'
}

fn (mut t Tracker) on_destroy() {
	t.log << 'destroy'
}

fn test_change_scene_request_and_reload() {
	mut s := core.Scene.new('A')
	s.key = 'scenes/a.scene'
	s.change_scene('scenes/b.scene', fade: 1)
	assert s.next_scene == 'scenes/b.scene' && s.next_change.fade == 1
	s.reload()
	assert s.next_scene == 'scenes/a.scene' && s.next_change.fade == 0.25
}

fn test_persistent_nodes_move_without_lifecycle() {
	mut old := core.Scene.new('Old')
	mut music := core.Node.new('Music')
	music.persistent = true
	mut tr := music.add_component(&Tracker{})
	mut cam := core.Node.new('Cam').with(&core.Camera{})
	music.add_child(mut cam)
	fired := &Box{}
	music.after(0.5, fn [fired] () {
		mut b := unsafe { fired }
		b.count++
	})
	mut level := core.Node.new('Level')
	old.add(mut music)
	old.add(mut level)
	assert tr.log == ['load'] && old.active_camera() != none

	mut next := core.Scene.new('New')
	mut dup := core.Node.new('Music') // the new scene's own copy loses to the one already playing
	mut dup_tr := dup.add_component(&Tracker{})
	next.add(mut dup)
	next.take_persistent(mut old)
	old.unload()

	assert dup_tr.log == ['load', 'destroy']
	assert tr.log == ['load'] // moved: neither destroyed nor loaded again
	assert music.scene == next && cam.scene == next && music.parent == next.root
	assert next.root.children.len == 1 && old.root.children.len == 1
	assert next.active_camera() != none && old.active_camera() == none
	next.update(0.6) // its timer came along
	assert fired.count == 1
}

fn test_persistent_loads_and_saves() {
	dir := temp_dir('persist')
	defer {
		os.rmdir_all(dir) or {}
	}
	db := assets.open(dir)!
	mut l := serialize.new_loader(serialize.new_registry(), db)
	n := l.instantiate_source('node Main { node Music { persistent = true } }', 'main.scene')!
	assert n.find('Music')?.persistent
	assert l.save_node(n)!.contains('persistent = true')
}
