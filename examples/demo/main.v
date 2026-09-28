module main

import os
import engine.app
import engine.editor
import engine.serialize

// "Coin collector" demo: move the player to collect coins; big coins (a prefab variant) are worth more.
//   v run examples/demo            run the game
//   v run examples/demo --editor   open the scene/prefab editor (has a Play button to try it right away)
fn main() {
	assets_dir := os.join_path(os.dir(@FILE), 'assets')
	if '--editor' in os.args {
		mut ed := editor.new(
			title:      'Safex Editor — coin collector demo'
			assets_dir: assets_dir
			scene:      'scenes/main.scene'
		) or {
			eprintln(err)
			exit(1)
		}
		register_components(mut ed.registry)
		ed.run()
		return
	}
	mut game := app.new(
		title:      'Safex Engine — coin collector demo'
		assets_dir: assets_dir
		scene:      'scenes/main.scene'
	) or {
		eprintln(err)
		exit(1)
	}
	register_components(mut game.registry)
	game.run()
}

// Each game component needs just one registration line to be usable in .scene files (and in the editor).
fn register_components(mut r serialize.Registry) {
	r.register[PlayerController]()
	r.register[Bob]()
	r.register[Pickup]()
	r.register[CoinSpawner]()
	r.register[ScoreBoard]()
	r.register[FadeAway]()
}
