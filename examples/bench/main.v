module main

import os
import time
import velo.app
import velo.assets
import velo.core
import velo.render

// Sprite stress test: how much does drawing many sprites cost, and does it matter that they use different textures?
// (This is what decides whether a texture atlas is worth building; see the README.)
//
//   v run examples/bench                                    10000 sprites on 16 textures
//   v run examples/bench -d bench_textures=1                the same on one texture
//   v run examples/bench -d bench_sprites=20000
//   v run examples/bench -d bench_rotate=true               every sprite rotated
//   v run examples/bench -d bench_world=4                   spread over 4x4 screens: ~1/16 on screen (culling)
//   velo run android examples/bench       `velo run/build` for phones takes no -d: edit the two constants below
//                                         (bench_textures 16 then 1) and compare the two frame times
//
// The average frame time is shown on screen and printed every 200 frames. A phone is capped at its refresh rate
// (16.7 ms at 60 Hz), so raise bench_sprites until the frame time is clearly above that.

const sprite_count = $d('bench_sprites', 10000)
const texture_count = $d('bench_textures', 16)
const rotate = $d('bench_rotate', false)
const world = $d('bench_world', 1)

pub struct Bench {
	core.Component
pub mut:
	frames int
	t0     i64
	label  &render.Label = unsafe { nil } @[hide]
}

pub fn (mut b Bench) start() {
	mut db := b.scene().assets
	mut refs := []assets.AssetRef[assets.Texture]{}
	for i in 0 .. texture_count {
		id := db.id_of('sprites/t${i}.png') or { panic('missing sprites/t${i}.png') }
		refs << assets.ref[assets.Texture](id)
	}
	for i in 0 .. sprite_count {
		mut n := core.Node.new('S${i}')
		n.position = core.vec2(f32(20 + (i * 7919) % (920 * world)), f32(60 +
			(i * 104729) % (460 * world))) // spread out, deterministic
		if rotate {
			n.rotation = f32(i % 360)
		}
		n.add_component(&render.Sprite{
			texture: refs[i % texture_count] // neighbours in draw order use different textures
			size:    core.vec2(16, 16)
		})
		b.node.add_child(mut n)
	}
	mut ln := core.Node.new('Stats')
	ln.position = core.vec2(10, 10)
	b.label = ln.add_component(&render.Label{
		text:  'warming up...'
		size:  22
		color: core.rgba(255, 255, 0, 255)
	})
	b.node.add_child(mut ln)
	// CPU time of drawing, which stays measurable when the frame time is capped by vsync
	b.scene().profiler.enabled = true
	b.t0 = time.ticks()
}

pub fn (mut b Bench) update(dt f32) {
	b.frames++
	if b.frames % 200 != 0 {
		return
	}
	now := time.ticks()
	ms := f64(now - b.t0) / 200.0
	b.t0 = now
	prof := b.scene().profiler
	line := '${sprite_count} sprites, ${texture_count} textures: ${ms:.2f} ms/frame (${1000.0 / ms:.0f} fps), CPU: render ${prof.scope_ms('render'):.2f} ms, draw ${prof.scope_ms('draw'):.2f} ms'
	eprintln('[bench] ${line}')
	b.label.text = line
}

fn main() {
	mut game := app.new(
		title:       'Velo sprite bench'
		assets_dir:  os.join_path(os.dir(@FILE), 'assets')
		scene:       'scenes/bench.scene'
		debug_tools: false
	) or {
		eprintln(err)
		exit(1)
	}
	game.register[Bench]()
	game.run()
}
