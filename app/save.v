module app

import os
import velo.core
import sokol.sapp

$if emscripten ? {
	#include "@VMODROOT/app/web_storage.h"
}

fn C.velo_ls_set(key &char, value &char)
fn C.velo_ls_len(key &char) int
fn C.velo_ls_get(key &char, out &char, size int)

// open_store opens the player's save data (see core.Store):
//   desktop  <config dir>/<app_id>/save.txt  (~/Library/Application Support on macOS, ~/.config on Linux, %AppData% on Windows)
//   Android  the app's internal storage       iOS  the app's Library/Application Support
//   web      the browser's localStorage (key "<app_id>/save")
// `save_file` overrides the location on desktop and phones.
fn open_store(cfg Config) &core.Store {
	id := app_id_of(cfg)
	$if emscripten ? {
		key := '${id}/save'
		n := C.velo_ls_len(&char(key.str))
		mut text := ''
		if n > 0 {
			mut buf := []u8{len: n}
			C.velo_ls_get(&char(key.str), &char(buf.data), n)
			text = unsafe { cstring_to_vstring(&char(buf.data)) }
		}
		mut st := core.Store.from_text(text) or {
			eprintln('[velo] save data in localStorage: ${err} — starting empty')
			&core.Store{}
		}
		st.writer = fn [key] (t string) ! {
			C.velo_ls_set(&char(key.str), &char(t.str))
		}
		return st
	} $else {
		path := if cfg.save_file != '' { cfg.save_file } else { default_save_file(id) }
		return core.Store.open(path)
	}
}

fn default_save_file(id string) string {
	$if android {
		activity := unsafe { &os.NativeActivity(sapp.android_get_native_activity()) }
		if !isnil(activity) && !isnil(activity.internalDataPath) {
			return os.join_path(unsafe { cstring_to_vstring(activity.internalDataPath) },
				'save.txt')
		}
		return ''
	} $else $if ios {
		return os.join_path(os.home_dir(), 'Library', 'Application Support', 'save.txt') // HOME = the app's sandbox
	} $else {
		dir := os.config_dir() or { os.home_dir() }
		return os.join_path(dir, id, 'save.txt')
	}
}

// app_id_of: Config.app_id, or one made from the title ("My Game!" -> "my-game").
fn app_id_of(cfg Config) string {
	if cfg.app_id != '' {
		return cfg.app_id
	}
	mut out := []u8{}
	for c in cfg.title.to_lower() {
		if c.is_letter() || c.is_digit() {
			out << c
		} else if out.len > 0 && out.last() != `-` {
			out << `-`
		}
	}
	id := out.bytestr().trim('-')
	return if id == '' { 'velo-game' } else { id }
}
