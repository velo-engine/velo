module core

import math

// 2D lighting: a `Lighting` node makes the world dark (`ambient`) and every enabled `Light2D` adds light to it.
// The renderer draws the lights into a small light map and multiplies the world by it, before the Canvas (HUD) is
// drawn, so the HUD stays bright.
//
//   node Level {
//     Lighting { ambient = [40, 45, 80, 255] }              # the darkness: black = pitch dark, white = no effect
//     node Torch { position = [300, 200]  Light2D { color = [255, 180, 90, 255]  radius = 220  flicker = 0.25 } }
//     node Lamp  { position = [600, 150]  Light2D { kind = "spot"  cone = 60  radius = 300 }  rotation = 90 }
//   }
//
// A Light2D lights what is around its node (radius in world units); a "spot" shines along the node's +x axis (turn
// the node to aim it). Lights add up, and the light map cannot brighten the world beyond its own colors.
@[heap]
pub struct Lighting {
	Component
pub mut:
	ambient Color = rgba(40, 40, 60, 255)
	// The light map is 1/resolution of the screen size: 4 = quarter size (soft and cheap), 1 = full size.
	resolution int = 4
	registered bool @[hide]
}

pub fn (mut l Lighting) on_load() {
	if l.node.scene != unsafe { nil } && !l.registered {
		mut s := l.node.scene
		s.lightings << l
		l.registered = true
	}
}

pub fn (mut l Lighting) on_destroy() {
	if l.node.scene != unsafe { nil } && l.registered {
		mut s := l.node.scene
		s.lightings = s.lightings.filter(voidptr(it) != voidptr(l))
	}
	l.registered = false
}

@[heap]
pub struct Light2D {
	Component
pub mut:
	color      Color  = white
	intensity  f32    = 1   // above 1 burns brighter (the light is drawn more than once)
	radius     f32    = 200 // world units
	kind       string = 'point' @[choices: 'point|spot']
	cone       f32    = 90 // spot: the full opening angle, degrees
	flicker    f32 // 0..1: how much the intensity wobbles (torches, candles)
	registered bool @[hide]
}

pub fn (mut l Light2D) on_load() {
	if l.node.scene != unsafe { nil } && !l.registered {
		mut s := l.node.scene
		s.lights << l
		l.registered = true
	}
}

pub fn (mut l Light2D) on_destroy() {
	if l.node.scene != unsafe { nil } && l.registered {
		mut s := l.node.scene
		s.lights = s.lights.filter(voidptr(it) != voidptr(l))
	}
	l.registered = false
}

// current_intensity: `intensity` with the flicker applied at scene time `t` (a different wobble per light).
pub fn (l &Light2D) current_intensity(t f64) f32 {
	if l.flicker <= 0 {
		return l.intensity
	}
	phase := f64(u64(voidptr(l)) % 1000) * 0.37
	w := (math.sin(t * 13.1 + phase) * math.sin(t * 7.7 + phase * 1.7) + math.sin(t * 29.3 +
		phase * 0.6) * 0.35) / 1.35
	k := 1 - f64(l.flicker) * (0.5 + 0.5 * w) // 1 down to 1 - flicker
	return l.intensity * f32(k)
}

// light_falloff: how strong a light of `radius` is at `dist` from its center, 0..1 (smooth to 0 at the edge).
// The light textures are built from it, and tests check it.
pub fn light_falloff(dist f32, radius f32) f32 {
	if radius <= 0 || dist >= radius {
		return 0
	}
	a := 1 - dist / radius
	return a * a * (3 - 2 * a)
}

// spot_factor: 1 inside the cone, fading to 0 at its edge. `angle` is the direction to the point relative to the
// spot's axis, `cone` the full opening, both in degrees.
pub fn spot_factor(angle f32, cone f32) f32 {
	half := cone / 2
	diff := math.abs(angle)
	if diff >= half {
		return 0
	}
	soft := half * 0.35
	t := math.min((half - diff) / math.max(soft, 0.01), 1)
	return f32(t * t * (3 - 2 * t))
}
