import os
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render

fn tilemap(tm &render.TileMap) (&core.Scene, &render.TileMap) {
	mut s := core.Scene.new('Test')
	mut n := core.Node.new('Map')
	t := n.add_component(tm)
	s.add(mut n)
	return s, t
}

fn test_get_set_and_bounds() {
	_, mut tm := tilemap(&render.TileMap{
		columns: 3
		rows:    2
	})
	assert tm.get(0, 0) == -1 // empty list = every cell empty
	assert tm.set(2, 1, 7)
	assert !tm.set(2, 1, 7) // unchanged
	assert tm.get(2, 1) == 7
	assert tm.tiles == [-1, -1, -1, -1, -1, 7]
	assert !tm.set(3, 0, 1) // outside
	assert !tm.set(-1, 0, 1)
	assert tm.get(5, 5) == -1
	assert tm.set(2, 1, -9) // any negative = erase
	assert tm.get(2, 1) == -1
	assert tm.count() == 0
}

fn test_resize_keeps_cells() {
	_, mut tm := tilemap(&render.TileMap{
		columns: 3
		rows:    2
		tiles:   [0, 1, 2, 3, 4, 5]
	})
	tm.resize(4, 3)
	assert tm.columns == 4 && tm.rows == 3
	assert tm.tiles == [0, 1, 2, -1, 3, 4, 5, -1, -1, -1, -1, -1]
	tm.resize(2, 1)
	assert tm.tiles == [0, 1]
}

fn test_fill_rect_and_flood_fill() {
	_, mut tm := tilemap(&render.TileMap{
		columns: 4
		rows:    3
	})
	tm.fill_rect(1, 0, 1, 2, 9) // a wall splitting the map
	assert tm.count() == 3
	assert tm.flood_fill(0, 0, 2) == 3 // left column only
	assert tm.get(0, 2) == 2 && tm.get(2, 0) == -1
	assert tm.flood_fill(3, 2, 5) == 6
	assert tm.flood_fill(3, 2, 5) == 0 // same tile: nothing to do
	assert tm.flood_fill(1, 1, -1) == 3 // erase the wall
	assert tm.get(1, 0) == -1
	tm.clear()
	assert tm.count() == 0 && tm.tiles.len == 12
}

fn test_cells_and_world_positions() {
	_, mut tm := tilemap(&render.TileMap{
		columns:   4
		rows:      2
		tile_size: core.vec2(10, 20)
		anchor:    core.vec2(0.5, 0.5) // map centered on the node: 40 x 40
	})
	tm.node.position = core.vec2(100, 100)
	tm.node.scale = core.vec2(2, 2)
	x, y, w, h := tm.local_rect()
	assert x == -20 && y == -20 && w == 40 && h == 40
	c, r := tm.world_to_cell(core.vec2(61, 61)) // top-left corner in world = 100 - 20 * 2
	assert c == 0 && r == 0
	c2, r2 := tm.world_to_cell(core.vec2(139, 139))
	assert c2 == 3 && r2 == 1
	c3, _ := tm.world_to_cell(core.vec2(59, 61))
	assert c3 == -1
	assert tm.cell_center(0, 0) == core.vec2(70, 80)
	tm.set(3, 1, 4)
	assert tm.tile_at(core.vec2(139, 139)) == 4
	assert tm.tile_at(core.vec2(0, 0)) == -1
}

fn test_scene_round_trip() {
	dir := os.join_path(os.temp_dir(), 'velo_tilemap_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// 32x16 PNG header = 2 frames of 16x16
	os.write_file_array(os.join_path(dir, 'tiles.png'), [u8(0x89), `P`, `N`, `G`, 13, 10, 26, 10,
		0, 0, 0, 13, `I`, `H`, `D`, `R`, 0, 0, 0, 32, 0, 0, 0, 16]) or { panic(err) }
	os.write_file(os.join_path(dir, 'tiles.png.meta'),
		'id: tiles001\nkind: texture\nframe_width: 16\nframe_height: 16\n') or { panic(err) }
	os.write_file(os.join_path(dir, 'map.scene'), 'node Level {
  node Ground {
    TileMap { tileset = @asset("tiles001")  columns = 3  rows = 2  tiles = [0, 1, -1, 1, 0, -1] }
  }
}') or {
		panic(err)
	}
	mut db := assets.open(dir) or { panic(err) }
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut loader := serialize.new_loader(reg, db)
	mut s := loader.load_scene('map.scene')!
	g := s.find('Ground') or { panic('no Ground') }
	mut tm := g.get_component[render.TileMap]() or { panic('no TileMap') }
	assert tm.tex != unsafe { nil }
	assert tm.cell_size() == core.vec2(16, 16) // from the tileset's frame size
	assert tm.get(1, 0) == 1 && tm.get(2, 1) == -1
	tm.set(2, 1, 1)
	text := loader.save_node(s.root)!
	assert text.contains('tiles = [0, 1, -1, 1, 0, 1]')
	// an untouched map writes no tiles at all
	mut empty := core.Node.new('E')
	empty.add_component(&render.TileMap{})
	assert !loader.save_node(empty)!.contains('tiles')
	// the inspector sees `tiles` as a list, not as a Vec2/Color
	info := reg.get('TileMap') or { panic('not registered') }
	for f in info.fields {
		assert f.is_list == (f.name == 'tiles')
	}
}
