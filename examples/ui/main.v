module main

import os
import velo.app
import velo.core

// UI kit demo: rich text (BBCode), labels / bars / toggles bound to the saved data, keyboard / gamepad menu navigation.
//   v run examples/ui          C: +1 coin   H: hurt   (the saved data drives the HUD)

pub struct Demo {
	core.Component
}

pub fn (mut d Demo) start() {
	mut st := d.scene().store
	if !st.has('hp') {
		st.set_int('hp', 80)
		st.set_int('max_hp', 100)
		st.set_int('coins', 0)
	}
}

pub fn (mut d Demo) update(dt f32) {
	mut st := d.scene().store
	if d.input().was_pressed(.c) {
		st.set_int('coins', st.get_int('coins', 0) + 1)
	}
	if d.input().was_pressed(.h) {
		st.set_int('hp', st.get_int('hp', 0) - 15)
	}
}

fn main() {
	mut game := app.new(
		title:      'Velo UI kit'
		assets_dir: os.join_path(os.dir(@FILE), 'assets')
		scene:      'scenes/main.scene'
		app_id:     'velo-ui-demo'
	) or {
		eprintln(err)
		exit(1)
	}
	game.register[Demo]()
	game.run()
}
