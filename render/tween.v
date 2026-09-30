module render

import velo.core

// Color tweens for the drawable components of a node: Sprite, Label, Panel and TileMap (the first one found
// gives the starting color; all of them are set). Children are not affected.
//
//   render.fade_to(mut node, 0, 0.4, .quad_in).call(fn [mut node] () { node.destroy() })
//   node.tween().move_by(core.vec2(0, -30), 0.4, .quad_out).also().value(render.alpha_get(node), render.alpha_set(node), 0, 0.4, .linear)
//
// A Button tints its target every frame, so tween the color of something the Button does not target.

// fade_to starts a tween of the node's alpha to `alpha` (0 = invisible, 255 = opaque).
pub fn fade_to(mut n core.Node, alpha u8, duration f32, ease core.Ease) &core.Tween {
	return n.tween().value(alpha_get(n), alpha_set(n), f32(alpha), duration, ease)
}

// color_to starts a tween of the node's color (alpha included) to `c`.
pub fn color_to(mut n core.Node, c core.Color, duration f32, ease core.Ease) &core.Tween {
	mut from := &ColorFrom{}
	node := unsafe { n }
	return n.tween().value(fn [node, mut from] () f32 {
		mut f := unsafe { from }
		f.color = color_of(node) or { core.white }
		return 0
	}, fn [node, from, c] (v f32) {
		set_color(node, from.color.lerp(c, v))
	}, 1, duration, ease)
}

@[heap]
struct ColorFrom {
mut:
	color core.Color
}

// alpha_get / alpha_set read and write the node's alpha, for `Tween.value` in a longer sequence.
pub fn alpha_get(n &core.Node) fn () f32 {
	return fn [n] () f32 {
		c := color_of(n) or { return 255 }
		return f32(c.a)
	}
}

pub fn alpha_set(n &core.Node) fn (v f32) {
	return fn [n] (v f32) {
		a := if v <= 0 {
			u8(0)
		} else if v >= 255 {
			u8(255)
		} else {
			u8(v + 0.5)
		}
		c := color_of(n) or { return }
		set_color(n, core.Color{c.r, c.g, c.b, a})
	}
}

// color_of: the color of the node's first Sprite, Label, Panel or TileMap.
pub fn color_of(n &core.Node) ?core.Color {
	for c in n.components {
		if c is Sprite {
			return c.color
		} else if c is Label {
			return c.color
		} else if c is Panel {
			return c.color
		} else if c is TileMap {
			return c.color
		}
	}
	return none
}

// set_color sets the color of every Sprite, Label, Panel and TileMap of the node.
pub fn set_color(n &core.Node, col core.Color) {
	mut node := unsafe { n }
	for mut c in node.components {
		if mut c is Sprite {
			c.color = col
		} else if mut c is Label {
			c.color = col
		} else if mut c is Panel {
			c.color = col
		} else if mut c is TileMap {
			c.color = col
		}
	}
}
