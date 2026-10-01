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

fn layout_map(layout string, columns int, rows int) &render.TileMap {
	_, tm := tilemap(&render.TileMap{
		columns:   columns
		rows:      rows
		tile_size: core.vec2(64, 32)
		layout:    layout
	})
	return tm
}

// every layout: the cell under a cell's center is that cell, and so is the point just inside each corner
fn test_layouts_pick_their_own_cells() {
	for layout in ['orthogonal', 'isometric', 'staggered', 'hex_pointy', 'hex_flat'] {
		tm := layout_map(layout, 6, 5)
		for r in 0 .. 5 {
			for c in 0 .. 6 {
				poly := tm.cell_polygon(c, r)
				mut mid := core.vec2(0, 0)
				for p in poly {
					mid = mid + p
				}
				mid = mid.mul(1.0 / f32(poly.len))
				gc, gr := tm.local_to_cell(mid)
				assert gc == c && gr == r, '${layout} (${c}, ${r}) center -> (${gc}, ${gr})'
				for p in poly {
					q := p + (mid - p).mul(0.06)
					qc, qr := tm.local_to_cell(q)
					assert qc == c && qr == r, '${layout} (${c}, ${r}) corner ${p} -> (${qc}, ${qr})'
				}
			}
		}
	}
}

fn test_isometric_geometry() {
	tm := layout_map('isometric', 3, 2)
	x, y, w, h := tm.local_rect()
	assert x == 0 && y == 0 && w == 160 && h == 80 // (3 + 2) half tiles
	assert tm.cell_center(0, 0) == core.vec2(32 * 2, 16) // top of the diamond map
	assert tm.cell_center(1, 0) == core.vec2(32 * 3, 32) // col runs down-right
	assert tm.cell_center(0, 1) == core.vec2(32, 32) // row runs down-left
}

fn test_staggered_and_hex_geometry() {
	mut st := layout_map('staggered', 3, 3)
	assert st.cell_center(0, 0) == core.vec2(32, 16)
	assert st.cell_center(0, 1) == core.vec2(64, 32) // odd rows shift half a tile right, rows are half a tile apart
	assert st.cell_center(0, 2) == core.vec2(32, 48)
	st.stagger_odd = false
	assert st.cell_center(0, 0) == core.vec2(64, 16)
	assert st.cell_center(0, 1) == core.vec2(32, 32)

	hp := layout_map('hex_pointy', 3, 3) // side = h / 2 = 16: rows 24 apart
	assert hp.cell_center(0, 1) == core.vec2(64, 16 + 24)
	_, _, w, h := hp.local_rect()
	assert w == 3 * 64 + 32 && h == 2 * 24 + 32
	hf := layout_map('hex_flat', 3, 3) // side = w / 2 = 32: columns 48 apart
	assert hf.cell_center(1, 0) == core.vec2(32 + 48, 16 + 16)
	_, _, w2, h2 := hf.local_rect()
	assert w2 == 2 * 48 + 64 && h2 == 3 * 32 + 16
}

fn test_neighbors_are_symmetric() {
	for layout in ['orthogonal', 'isometric', 'staggered', 'hex_pointy', 'hex_flat'] {
		for odd in [true, false] {
			mut tm := layout_map(layout, 6, 6)
			tm.stagger_odd = odd
			for r in 1 .. 5 {
				for c in 1 .. 5 {
					nbs := tm.neighbors(c, r)
					assert nbs.len == if layout.starts_with('hex') {
						6
					} else {
						4
					}
					for n in nbs {
						assert [c, r] in tm.neighbors(n[0], n[1]), '${layout} odd=${odd}: (${c}, ${r}) -> ${n}'
					}
				}
			}
		}
	}
}

// a neighbor shares an edge: its center is one lattice step away
fn test_hex_neighbors_are_adjacent_on_screen() {
	for layout in ['hex_pointy', 'hex_flat'] {
		tm := layout_map(layout, 6, 6)
		mid := tm.cell_center(3, 3)
		for n in tm.neighbors(3, 3) {
			d := (tm.cell_center(n[0], n[1]) - mid).length()
			assert d > 30 && d <= 64.01, '${layout} ${n}: ${d}'
		}
	}
}

fn test_flood_fill_follows_layout_neighbors() {
	mut tm := layout_map('hex_pointy', 4, 4)
	tm.set(1, 1, 3) // an island: nothing else is painted
	assert tm.flood_fill(0, 0, 7) == 15
	assert tm.get(1, 1) == 3
	assert tm.count() == 16
	// staggered diamonds only touch diagonally, so a "vertical" pair is not connected
	mut st := layout_map('staggered', 3, 4)
	st.clear()
	st.set(1, 0, 1)
	st.set(1, 2, 1)
	assert st.flood_fill(1, 0, 5) == 1
}

fn test_visible_cells_cover_the_view() {
	for layout in ['orthogonal', 'isometric', 'staggered', 'hex_pointy', 'hex_flat'] {
		tm := layout_map(layout, 9, 7)
		x, y, w, h := tm.local_rect()
		// whole map: every cell exactly once
		all := tm.visible_cells(x - 5, y - 5, x + w + 5, y + h + 5)
		assert all.len == 63, '${layout}: ${all.len}'
		mut seen := map[int]bool{}
		for i in all {
			assert i !in seen
			seen[i] = true
		}
		// a window: exactly the cells whose box touches it
		wx0, wy0, wx1, wy1 := x + w * 0.3, y + h * 0.2, x + w * 0.6, y + h * 0.5
		got := tm.visible_cells(wx0, wy0, wx1, wy1)
		for r in 0 .. 7 {
			for c in 0 .. 9 {
				bx, by, bw, bh := tm.cell_local_rect(c, r)
				touches := bx < wx1 && bx + bw > wx0 && by < wy1 && by + bh > wy0
				assert (r * 9 + c in got) == touches, '${layout} (${c}, ${r}) touches=${touches}'
			}
		}
	}
}

fn test_isometric_draws_back_to_front() {
	tm := layout_map('isometric', 4, 4)
	x, y, w, h := tm.local_rect()
	mut last := -1
	for i in tm.visible_cells(x, y, x + w, y + h) {
		depth := i % 4 + i / 4 // col + row
		assert depth >= last
		last = depth
	}
}

fn test_layout_round_trips_through_the_scene_text() {
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut loader := serialize.new_loader(reg, unsafe { nil })
	mut n := core.Node.new('Hex')
	n.add_component(&render.TileMap{
		layout:      'hex_flat'
		stagger_odd: false
		hex_side:    20
	})
	text := loader.save_node(n)!
	assert text.contains('layout = "hex_flat"') || text.contains("layout = 'hex_flat'")
	assert text.contains('stagger_odd = false') && text.contains('hex_side = 20')
	// defaults stay out of the file
	mut plain := core.Node.new('P')
	plain.add_component(&render.TileMap{})
	t2 := loader.save_node(plain)!
	assert !t2.contains('layout') && !t2.contains('stagger_odd') && !t2.contains('hex_side')
}
