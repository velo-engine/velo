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
		assert f.is_list == (f.name in ['tiles', 'terrain'])
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

// ---------- Terrain (auto-tiling), animated tiles, solid boxes ----------

// nums: n consecutive numbers from `base`, space separated.
fn nums(base int, n int) string {
	mut out := []string{}
	for i in 0 .. n {
		out << (base + i).str()
	}
	return out.join(' ')
}

fn rules_text() string {
	// edges: the frame is 100 + mask; blob: 200 + index in the canonical order
	edges := nums(100, 16)
	blob := nums(200, 47)
	return '# test\nterrain 1 edges ${edges}\nterrain 2 blob ${blob} border=empty\nterrain 3 edges ${edges} join=1\nanimate 7 frames=7,8,9 fps=2\n'
}

fn rules_map(cols int, rows int, text string) &render.TileMap {
	mut tm := &render.TileMap{
		columns: cols
		rows:    rows
	}
	tm.rule_set = render.TileRules.parse(text) or { panic(err) }
	tm.clear()
	return tm
}

fn test_rules_parse_and_errors() {
	r := render.TileRules.parse(rules_text())!
	assert r.terrains.len == 3 && r.terrains[2].blob && !r.terrains[2].border_same
	assert r.terrains[3].join == [1]
	assert r.anim_frame(7, 0) == 7 && r.anim_frame(7, 0.5) == 8 && r.anim_frame(7, 1.0) == 9
	assert r.anim_frame(7, 1.5) == 7 // loops
	assert r.anim_frame(3, 9) == 3 // not animated
	for bad in ['terrain 1 edges 1 2 3', 'terrain 0 edges ${nums(0, 16)}', 'animate 5 fps=3',
		'terrain 1 blob 1 2', 'nonsense', 'terrain 1 edges ${nums(0, 16)} border=maybe'] {
		render.TileRules.parse(bad) or { continue }
		assert false, 'should fail: ${bad}'
	}
	render.TileRules.parse('terrain 1 edges 1 2') or {
		assert err.msg().contains('line 1')
		return
	}
}

fn test_blob_has_47_masks_and_canonical_corners() {
	masks := render.blob_masks()
	assert masks.len == 47 && masks[0] == 0 && masks.last() == 255
	assert render.canonical_blob(2) == 0 // NE corner without N and E
	assert render.canonical_blob(2 | 1 | 4) == 7 // with both edges it counts
	assert render.canonical_blob(255) == 255
}

fn test_edges_autotile_updates_neighbors() {
	mut tm := rules_map(5, 3, rules_text())
	assert tm.set_terrain(1, 1, 1)
	// alone in the middle of the map: no terrain neighbors; out-of-map counts only at the border, not here
	assert tm.get(1, 1) == 100
	tm.set_terrain(2, 1, 1)
	// (1,1) has an east neighbor: mask E = 2; (2,1) has a west neighbor: mask W = 8
	assert tm.get(1, 1) == 102 && tm.get(2, 1) == 108
	tm.set_terrain(3, 1, 1)
	assert tm.get(2, 1) == 110 // E + W
	// erasing empties the cell and the neighbors update
	assert tm.set_terrain(3, 1, 0)
	assert tm.get(3, 1) == -1 && tm.get(2, 1) == 108
	assert !tm.set_terrain(3, 1, 0) // unchanged
	assert !tm.set_terrain(-1, 0, 1) // outside
}

fn test_border_same_vs_empty_and_join() {
	mut tm := rules_map(3, 3, rules_text())
	tm.set_terrain(0, 0, 1) // border=same (default): the outside counts as terrain at N and W
	assert tm.get(0, 0) == 100 + 1 + 8 // N + W of the mask: 1 | 8 -> 9
	mut b := rules_map(3, 3, rules_text())
	b.set_terrain(0, 0, 2) // blob with border=empty: no neighbors at all = mask 0 = the first frame
	assert b.get(0, 0) == 200
	// terrain 3 joins terrain 1: a 3 next to a 1 connects
	mut j := rules_map(4, 1, rules_text())
	j.set_terrain(1, 0, 1)
	j.set_terrain(2, 0, 3)
	assert j.get(2, 0) & 15 != 0 // it sees the 1 on its west (plus the border... N, S, E are the outside)
}

fn test_blob_autotile_picks_by_canonical_mask() {
	mut tm := rules_map(3, 3, rules_text()) // terrain 2: border=empty
	for c in 0 .. 3 {
		for r in 0 .. 3 {
			tm.set_terrain(c, r, 2)
		}
	}
	masks := render.blob_masks()
	assert tm.get(1, 1) == 200 + masks.index(255) // fully surrounded
	assert tm.get(0, 0) == 200 + masks.index(4 | 16 | 8) // E + S + the SE corner
	// punch a hole at the NE of the middle: the middle loses its NE corner
	tm.set_terrain(2, 0, 0)
	assert tm.get(1, 1) == 200 + masks.index(255 & ~2)
}

fn test_resize_and_clear_keep_terrain() {
	mut tm := rules_map(4, 4, rules_text())
	tm.set_terrain(1, 1, 1)
	tm.set_terrain(2, 1, 1)
	tm.resize(6, 5)
	assert tm.terrain_at(1, 1) == 1 && tm.terrain_at(2, 1) == 1 && tm.terrain_at(5, 4) == 0
	assert tm.get(1, 1) == 102
	tm.resize(2, 2) // drops (2,1)
	assert tm.get(1, 1) == 100 + 2 + 4 // now at the right/bottom corner: border = same, so E and S (outside) count; N and W are empty cells
	tm.clear()
	assert tm.terrain_at(1, 1) == 0 && tm.count() == 0
}

fn test_solid_boxes_merge() {
	mut tm := &render.TileMap{
		columns: 6
		rows:    4
	}
	tm.clear()
	// ####..      one 4x2 block, a lone cell, a vertical pair
	// ####.#
	// ......
	// .#..#.
	tm.fill_rect(0, 0, 3, 1, 5)
	tm.set(5, 1, 5)
	tm.set(1, 3, 5)
	tm.set(4, 3, 5)
	tm.set(4, 2, 5)
	boxes := tm.solid_boxes([])
	assert boxes.len == 4
	assert render.TileBox{0, 0, 4, 2} in boxes
	assert render.TileBox{5, 1, 1, 1} in boxes
	assert render.TileBox{1, 3, 1, 1} in boxes
	assert render.TileBox{4, 2, 1, 2} in boxes
	// only some tiles are solid
	tm.set(0, 0, 9)
	assert tm.solid_boxes([5]).len == 5 // the 4x2 block loses a corner: (1..3, 0) + the row below + ...
	assert tm.solid_boxes([9]) == [render.TileBox{0, 0, 1, 1}]
	x, y, w, h := tm.box_rect(render.TileBox{4, 2, 1, 2})
	cs := tm.cell_size()
	assert x == f32(4) * cs.x && y == f32(2) * cs.y && w == cs.x && h == cs.y * 2
	// other layouts give no boxes
	tm.layout = 'isometric'
	assert tm.solid_boxes([]).len == 0
}

fn test_terrain_from_scene_file_and_hot_reload() {
	dir := os.join_path(os.temp_dir(), 'velo_terrain_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file_array(os.join_path(dir, 'tiles.png'), [u8(0x89), `P`, `N`, `G`, 13, 10, 26, 10,
		0, 0, 0, 13, `I`, `H`, `D`, `R`, 0, 0, 0, 32, 0, 0, 0, 16]) or { panic(err) }
	os.write_file(os.join_path(dir, 'tiles.png.meta'),
		'id: tiles001\nkind: texture\nframe_width: 16\nframe_height: 16\n') or { panic(err) }
	os.write_file(os.join_path(dir, 'g.tilerules'), 'terrain 1 edges ${nums(10, 16)}\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'map.scene'), 'node Level {
  TileMap { tileset = @asset("tiles001")  rules = @asset("g.tilerules")  columns = 3  rows = 1  terrain = [1, 1, 0] }
}') or {
		panic(err)
	}
	mut db := assets.open(dir) or { panic(err) }
	assert db.entry(db.id_of('g.tilerules')?)?.kind == .text // .tilerules is a text asset
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut loader := serialize.new_loader(reg, db)
	mut s := loader.load_scene('map.scene')!
	mut tm := s.root.get_component[render.TileMap]() or { panic('no TileMap') }
	// loading computed the frames: (0,0) joins its east neighbor and the outside (border = same) on N, S, W: 15;
	// (1,0) has the terrain only on its west (and the outside on N and S): 1 + 4 + 8
	assert tm.get(0, 0) == 10 + 15 && tm.get(1, 0) == 10 + 13 && tm.get(2, 0) == -1
	// the rules file changes while the game runs: the map follows (after the asset database noticed)
	os.write_file(os.join_path(dir, 'g.tilerules'), 'terrain 1 edges ${nums(50, 16)}\n') or {
		panic(err)
	}
	db.poll_changes()
	s.update(0.016)
	assert tm.get(0, 0) == 50 + 15
	// a broken edit keeps the old rules
	os.write_file(os.join_path(dir, 'g.tilerules'), 'terrain 1 edges 1 2\n') or { panic(err) }
	db.poll_changes()
	s.update(0.016)
	assert tm.get(0, 0) == 50 + 15
	s.unload()
}
