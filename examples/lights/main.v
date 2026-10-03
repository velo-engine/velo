module main

import os
import velo.app
import velo.core
import velo.render
import velo.serialize

// Lighting demo: `Lighting` darkens the world, every `Light2D` adds light. One light follows the mouse.
//   v run examples/lights

pub struct FollowMouse {
	core.Component
}

pub fn (mut f FollowMouse) update(dt f32) {
	f.node.set_world_position(f.scene().screen_to_world(f.input().mouse))
}

fn main() {
	mut game := app.new(
		title:      'Velo lighting'
		assets_dir: os.join_path(os.dir(@FILE), 'assets')
		scene:      'scenes/main.scene'
	) or {
		eprintln(err)
		exit(1)
	}
	game.register[FollowMouse]()
	game.run()
}
