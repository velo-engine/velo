module core

// SolidRect — a rectangle in a node's space (x, y = top-left corner).
pub struct SolidRect {
pub:
	pos  Vec2
	size Vec2
}

// SolidTiles — a component that knows which parts of its node are solid, as few rectangles as possible
// (render.TileMap does). physics.TileMapCollider turns them into colliders without importing the renderer.
pub interface SolidTiles {
	solid_rects(solid []int) []SolidRect // `solid`: the tiles that block (empty = every non-empty tile)
	solid_revision() int                 // changes whenever the cells do
	solid_bounds() SolidRect             // the whole map, in the node's space
	solid_cell() Vec2                    // the size of one cell, in the node's space
}
