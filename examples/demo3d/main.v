module main

import os
import velo.app
import velo.core
import velo.render3d

// Velo 3D demo: an FBX hero (Mixamo "Fast Run") runs around a twilight arena collecting orbs, among slimes,
// drones, a stone golem, golden and shadow "echo" runners, torches, crystals and a portal.
//   v run examples/demo3d
fn main() {
	mut game := app.new(
		title:      'Velo Engine — 3D demo'
		assets_dir: os.join_path(os.dir(@FILE), 'assets')
		scene:      'scenes/main.scene'
		width:      1280
		height:     720
		app_id:     'velo-demo3d'
		background: core.rgba(96, 104, 150, 255)
	) or {
		eprintln(err)
		exit(1)
	}
	set_renderer(render3d.install(mut game)) // 3D components + the 3D pass
	game.registry.register[HeroController]()
	game.registry.register[FollowCamera]()
	game.registry.register[PathRunner]()
	game.registry.register[SlimeHop]()
	game.registry.register[DroneHover]()
	game.registry.register[GolemWalk]()
	game.registry.register[OrbPickup]()
	game.registry.register[OrbSpawner]()
	game.registry.register[Bob3D]()
	game.registry.register[Spin3D]()
	game.registry.register[Pulse3D]()
	game.registry.register[StatsLabel]()
	game.store.set_int('orbs', 0)
	game.run()
}
