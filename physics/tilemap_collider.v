module physics

import velo.core

// TileMapCollider — solid walls for a tile map: next to a TileMap (or anything that is core.SolidTiles) it
// creates static box colliders for the solid tiles, merged into as few boxes as possible, and builds them again
// when the cells change (tm.set, set_terrain, flood fill...). Orthogonal maps only.
//
//   node Walls {
//     TileMap { tileset = ... tiles = [...] }
//     TileMapCollider { solid_tiles = [1, 2, 3] }          # tile frames that block; empty = every non-empty tile
//   }
//
// The boxes are child nodes named `_solid0`, `_solid1`, ... of the map's node (so they move and scale with it);
// like every collider they need a PhysicsWorld on the node or above it.
pub struct TileMapCollider {
	core.Component
pub mut:
	solid_tiles []int
	friction    f32 = 0.6
	restitution f32
	built       int = -1 @[hide]    // the revision the boxes were built for
	count       int @[hide]
}

pub fn (mut t TileMapCollider) on_load() {
	t.rebuild()
}

pub fn (mut t TileMapCollider) update(dt f32) {
	rev := t.revision() or { return }
	if rev != t.built {
		t.rebuild()
	}
}

// revision: the cell revision of the map on this node (get_component cannot look up an interface).
fn (t &TileMapCollider) revision() ?int {
	for c in t.node.components {
		if c is core.SolidTiles {
			return c.solid_revision()
		}
	}
	return none
}

fn (t &TileMapCollider) rects() ?([]core.SolidRect, int) {
	for c in t.node.components {
		if c is core.SolidTiles {
			return c.solid_rects(t.solid_tiles), c.solid_revision()
		}
	}
	return none
}

pub fn (mut t TileMapCollider) on_destroy() {
	t.clear_boxes()
}

fn (mut t TileMapCollider) clear_boxes() {
	for mut ch in t.node.children.clone() {
		if ch.name.starts_with('_solid') {
			ch.destroy()
		}
	}
	t.count = 0
}

// rebuild replaces the boxes with the ones for the map's current cells.
pub fn (mut t TileMapCollider) rebuild() {
	rects, rev := t.rects() or {
		eprintln('[TileMapCollider] ${t.node.path()}: no TileMap on this node')
		return
	}
	t.clear_boxes()
	for i, r in rects {
		mut n := core.Node.new('_solid${i}')
		n.position = r.pos + r.size.mul(0.5)
		n.add_component(&BoxCollider{
			size:        r.size
			friction:    t.friction
			restitution: t.restitution
		})
		t.node.add_child(mut n)
		t.count++
	}
	t.built = rev
}
