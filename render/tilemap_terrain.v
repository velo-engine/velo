module render

import velo.assets

// Terrain (auto-tiling) and tile animation for TileMap; the rules come from a `.tilerules` asset (tilerules.v).
//
//   TileMap { tileset = @asset("tiles")  rules = @asset("forest.tilerules")  columns = 20  rows = 12
//             terrain = [0, 0, 1, 1, 1, ...] }                  # 0 = none, 1.. = a terrain of the rules
//
//   tm.set_terrain(3, 4, 1)      // paint terrain 1: this cell and its neighbors pick their frames again
//   tm.set_terrain(3, 4, 0)      // erase
//
// `tiles` stays what is drawn: cells with a terrain get their frame from the rules (when the map loads and on every
// set_terrain); cells without one keep their hand-painted tile.

fn (mut tm TileMap) normalize_terrain() {
	want := tm.columns * tm.rows
	if tm.terrain.len > want {
		tm.terrain.trim(want)
	}
	for tm.terrain.len < want {
		tm.terrain << 0
	}
}

// terrain_at: the terrain id at (col, row), 0 when none or outside the map.
pub fn (tm &TileMap) terrain_at(col int, row int) int {
	if !tm.in_bounds(col, row) {
		return 0
	}
	i := row * tm.columns + col
	return if i < tm.terrain.len { tm.terrain[i] } else { 0 }
}

// set_terrain paints terrain `id` (0 = erase it and empty the cell) and updates the cell and its 8 neighbors.
// Returns true if the cell changed.
pub fn (mut tm TileMap) set_terrain(col int, row int, id int) bool {
	if !tm.in_bounds(col, row) || tm.terrain_at(col, row) == id {
		return false
	}
	tm.normalize()
	tm.normalize_terrain()
	tm.terrain[row * tm.columns + col] = id
	if id == 0 {
		tm.set(col, row, no_tile)
	}
	for dr in -1 .. 2 {
		for dc in -1 .. 2 {
			tm.refresh_cell(col + dc, row + dr)
		}
	}
	return true
}

// refresh_terrain recomputes the frame of every cell that has a terrain (after the rules or `terrain` changed).
pub fn (mut tm TileMap) refresh_terrain() {
	if tm.rule_set == unsafe { nil } {
		return
	}
	tm.normalize()
	tm.normalize_terrain()
	for r in 0 .. tm.rows {
		for c in 0 .. tm.columns {
			tm.refresh_cell(c, r)
		}
	}
}

fn (mut tm TileMap) refresh_cell(col int, row int) {
	id := tm.terrain_at(col, row)
	if id <= 0 || tm.rule_set == unsafe { nil } {
		return
	}
	rule := tm.rule_set.terrains[id] or { return }
	same := fn [tm, rule] (c int, r int) bool {
		if !tm.in_bounds(c, r) {
			return rule.border_same
		}
		return tm.rule_set.joins(rule, tm.terrain_at(c, r))
	}
	n := same(col, row - 1)
	e := same(col + 1, row)
	s := same(col, row + 1)
	w := same(col - 1, row)
	mut mask := edge_mask(n, e, s, w)
	if rule.blob {
		// clockwise from north: N NE E SE S SW W NW
		flags := [n, same(col + 1, row - 1), e, same(col + 1, row + 1), s, same(col - 1, row + 1),
			w, same(col - 1, row - 1)]
		mask = 0
		for k, f in flags {
			if f {
				mask |= 1 << k
			}
		}
	}
	tm.set(col, row, rule.frame_for(mask))
}

// display_tile: the frame to draw for a stored tile (an animated tile shows its current frame).
fn (tm &TileMap) display_tile(t int) int {
	if tm.rule_set == unsafe { nil } || !tm.rule_set.has_anims() || tm.node == unsafe { nil }
		|| tm.node.scene == unsafe { nil } {
		return t
	}
	return tm.rule_set.anim_frame(t, f32(tm.node.scene.time))
}

// ---------- Loading ----------

fn (mut tm TileMap) load_rules() {
	if !tm.rules.is_set() || tm.node == unsafe { nil } || tm.node.scene == unsafe { nil }
		|| tm.node.scene.assets == unsafe { nil } {
		return
	}
	mut db := tm.node.scene.assets
	id := db.resolve(tm.rules.id) or {
		eprintln('[TileMap] ${tm.node.path()}: rules "${tm.rules.id}" not found')
		return
	}
	text := db.load[assets.TextAsset](id) or {
		eprintln('[TileMap] ${tm.node.path()}: ${err}')
		return
	}
	src := text.text
	db.release(id)
	rs := TileRules.parse(src) or {
		if !tm.rules_failed {
			eprintln('[TileMap] ${tm.node.path()}: ${db.path_of(id) or { tm.rules.id }}: ${err}')
		}
		tm.rules_failed = true // keep the old rules (a typo while hot reloading), say it once
		return
	}
	tm.rules_failed = false
	tm.rule_set = rs
	tm.rules_hash = (db.entry(id) or { return }).hash
	if tm.tile_layout() != .orthogonal && rs.terrains.len > 0 {
		eprintln('[TileMap] ${tm.node.path()}: terrains only look at orthogonal neighbors; use layout = "orthogonal"')
	}
	tm.refresh_terrain()
}

// update reloads the rules when the file changed.
pub fn (mut tm TileMap) update(dt f32) {
	if !tm.rules.is_set() || tm.node == unsafe { nil } || tm.node.scene == unsafe { nil }
		|| tm.node.scene.assets == unsafe { nil } {
		return
	}
	db := tm.node.scene.assets
	id := db.resolve(tm.rules.id) or { return }
	e := db.entry(id) or { return }
	if e.hash != tm.rules_hash {
		tm.load_rules()
	}
}
