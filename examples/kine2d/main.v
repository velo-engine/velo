module main

import os
import velo.app
import velo.editor
import velo.kine2d
import velo.serialize

// Kine2D sample: three characters exported from the Kine2D editor (BUILD: <name>.skel.json + .atlas.json + .png).
//   v run examples/kine2d            run it
//   v run examples/kine2d --editor   open it in the editor
fn main() {
	assets_dir := os.join_path(os.dir(@FILE), 'assets')
	if '--editor' in os.args {
		mut ed := editor.new(
			title:      'Velo Editor — Kine2D sample'
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
		title:      'Velo Engine — Kine2D sample'
		assets_dir: assets_dir
		scene:      'scenes/main.scene'
	) or {
		eprintln(err)
		exit(1)
	}
	register_components(mut game.registry)
	game.run()
}

fn register_components(mut r serialize.Registry) {
	kine2d.register_builtins(mut r) // opt-in: the Kine2D component
	r.register[AnimationPicker]()
	r.register[PlayOnce]()
	r.register[Patrol]()
}
