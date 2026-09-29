import os
import time
import velo.assets

// Create a fake PNG with only a header (enough for AssetDatabase to read its size).
fn fake_png(path string, w int, h int) {
	mut b := [u8(0x89), `P`, `N`, `G`, 13, 10, 26, 10, 0, 0, 0, 13, `I`, `H`, `D`, `R`]
	for v in [w, h] {
		b << [u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)]
	}
	os.write_file_array(path, b) or { panic(err) }
}

fn setup() string {
	dir := os.join_path(os.temp_dir(), 'velo_assets_test_${time.now().unix_micro()}')
	os.mkdir_all(os.join_path(dir, 'sprites')) or { panic(err) }
	os.mkdir_all(os.join_path(dir, 'prefabs')) or { panic(err) }
	fake_png(os.join_path(dir, 'sprites/hero.png'), 64, 32)
	fake_png(os.join_path(dir, 'sprites/unused.png'), 8, 8)
	os.write_file(os.join_path(dir, 'sprites/hero.png.meta'), 'id: hero0001\nkind: texture\nversion: 1\nfilter: nearest\nframe_width: 32\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'prefabs/hero.scene'), 'node Hero { Sprite { texture = @asset("hero0001") } }\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'prefabs/hero.scene.meta'), 'id: prefab01\nkind: scene\nversion: 1\n') or {
		panic(err)
	}
	return dir
}

fn test_import_creates_meta_and_ids() {
	dir := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	mut db := assets.open(dir)!
	assert db.len() == 3
	// a file missing its .meta gets one created automatically
	assert os.exists(os.join_path(dir, 'sprites/unused.png.meta'))
	assert db.id_of('sprites/hero.png')? == 'hero0001'
	assert db.resolve('prefabs/hero.scene')? == 'prefab01'
}

fn test_typed_load_and_refcount() {
	dir := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	mut db := assets.open(dir)!
	tex := db.load[assets.Texture]('hero0001')!
	assert tex.width == 64 && tex.height == 32
	assert tex.filter == 'nearest'
	assert tex.frame_count() == 2
	x, _, w, _ := tex.frame_rect(1)
	assert x == 32 && w == 32
	// a second load returns the same pointer, refs = 2
	tex2 := db.get(assets.ref[assets.Texture]('hero0001'))!
	assert tex == tex2
	assert db.entry('hero0001')?.refs == 2
	db.release('hero0001')
	assert db.loaded_count() == 1
	db.release('hero0001')
	assert db.loaded_count() == 0
	ev := db.drain_events()
	assert ev.len == 1 && ev[0].kind == .unloaded
}

fn test_wrong_kind_is_clear_error() {
	dir := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	mut db := assets.open(dir)!
	db.load[assets.SceneAsset]('hero0001') or {
		assert err.msg().contains('is texture')
		return
	}
	assert false, 'should report a wrong asset kind error'
}

fn test_dependency_graph() {
	dir := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	db := assets.open(dir)!
	assert db.dependencies('prefab01') == ['hero0001']
	assert db.dependents('hero0001') == ['prefab01']
	unused := db.unused(['prefabs/hero.scene'])
	assert unused.len == 1
	assert db.path_of(unused[0])? == 'sprites/unused.png'
	assert db.missing_references().len == 0
}

fn test_move_keeps_id_and_hot_reload() {
	dir := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	mut db := assets.open(dir)!
	tex := db.load[assets.Texture]('hero0001')!
	// Rename the file (with its .meta) -> ID unchanged, references not broken
	os.mkdir_all(os.join_path(dir, 'characters'))!
	os.mv(os.join_path(dir, 'sprites/hero.png'), os.join_path(dir, 'characters/player.png'))!
	os.mv(os.join_path(dir, 'sprites/hero.png.meta'), os.join_path(dir, 'characters/player.png.meta'))!
	mut ev := db.poll_changes()
	assert ev.any(it.kind == .moved && it.id == 'hero0001')
	assert db.path_of('hero0001')? == 'characters/player.png'
	// Edit the content -> reloaded in place, pointer unchanged, version incremented
	fake_png(os.join_path(dir, 'characters/player.png'), 128, 32)
	ev = db.poll_changes()
	assert ev.any(it.kind == .modified && it.id == 'hero0001')
	assert tex.width == 128
	assert tex.version == 1
}

fn test_duplicate_id_gets_new_id() {
	dir := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	os.cp(os.join_path(dir, 'sprites/hero.png'), os.join_path(dir, 'sprites/hero_copy.png'))!
	os.cp(os.join_path(dir, 'sprites/hero.png.meta'), os.join_path(dir, 'sprites/hero_copy.png.meta'))!
	db := assets.open(dir)!
	a := db.id_of('sprites/hero.png')?
	b := db.id_of('sprites/hero_copy.png')?
	assert a != b
	assert db.warnings.len == 1
}
