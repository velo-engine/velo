module app

import gg
import runtime
import velo.core

// Developer tools drawn over the game: the F1 stats line, the F2 profiler (frame graph + slowest scopes) and the
// ` console with the log. All of it is off when Config.debug_tools is false.

const overlay_font = 14
const console_lines = 12

// console_event handles the keys of the console: ` opens it; while it is open it takes every key and character
// (the game sees none). Returns true when the event was used.
fn (mut a App) console_event(e &gg.Event) bool {
	mut c := a.console
	if e.typ == .key_down && e.key_code == .grave_accent && !a.keyboard_shown {
		c.open = !c.open
		return true
	}
	if !c.open {
		return false
	}
	match e.typ {
		.key_down {
			c.key(unsafe { core.Key(int(e.key_code)) })
			return true
		}
		.char {
			if e.char_code != 96 && e.char_code != 126 { // not the ` / ~ that opened it
				c.input_char(e.char_code)
			}
			return true
		}
		.key_up {
			return true
		}
		else {
			return false
		}
	}
}

fn (mut a App) setup_console() {
	mut c := a.console
	c.register('help', 'help [command]: list the commands', fn [mut a] (args []string) string {
		if args.len > 0 {
			h := a.console.help_of(args[0])
			return if h != '' { h } else { 'no command "${args[0]}"' }
		}
		return a.console.command_names().join('  ')
	})
	c.register('clear', 'clear: empty the log', fn (args []string) string {
		mut l := core.logger()
		l.clear()
		return ''
	})
	c.register('loglevel', 'loglevel debug|info|warn|error', fn (args []string) string {
		mut l := core.logger()
		if args.len == 0 {
			return 'log level ${l.min_level}'
		}
		lv := core.log_level_from_str(args[0]) or { return 'unknown level "${args[0]}"' }
		l.min_level = lv
		return 'log level ${lv}'
	})
	c.register('timescale', 'timescale <x>: game speed (1 = normal, 0.5 = slow motion)', fn [mut a] (args []string) string {
		mut sc := a.scene
		if args.len > 0 {
			sc.time_scale = args[0].f32()
		}
		return 'timescale ${sc.time_scale}'
	})
	c.register('pause', 'pause: toggle pause', fn [mut a] (args []string) string {
		mut sc := a.scene
		sc.paused = !sc.paused
		return if sc.paused { 'paused' } else { 'running' }
	})
	c.register('scene', 'scene <path>: change scene (no argument: the current one)', fn [mut a] (args []string) string {
		mut sc := a.scene
		if args.len == 0 {
			return a.db.path_of(a.scene_id) or { a.scene_id }
		}
		sc.change_scene(args[0])
		return 'changing to ${args[0]}'
	})
	c.register('reload', 'reload: restart the current scene', fn [mut a] (args []string) string {
		mut sc := a.scene
		sc.reload()
		return 'reloading'
	})
	c.register('lang', 'lang [code]: show or change the language', fn [mut a] (args []string) string {
		mut loc := a.locale
		if args.len > 0 && !loc.set_language(args[0]) {
			return 'no language "${args[0]}" (have ${loc.languages().join(', ')})'
		}
		return 'language ${loc.language()} (have ${loc.languages().join(', ')})'
	})
	c.register('stats', 'stats: nodes, assets, memory', fn [mut a] (args []string) string {
		return a.stats_text()
	})
	c.register('profiler', 'profiler [on|off]: frame timing (F2)', fn [mut a] (args []string) string {
		mut p := a.profiler
		if args.len > 0 {
			p.enabled = args[0] == 'on'
			p.reset()
		}
		return 'profiler ${if p.enabled { 'on' } else { 'off' }}'
	})
	c.register('debug', 'debug [on|off]: node bounds and colliders (F1)', fn [mut a] (args []string) string {
		mut r := a.renderer
		if args.len > 0 {
			r.debug = args[0] == 'on'
		}
		return 'debug ${if r.debug { 'on' } else { 'off' }}'
	})
	c.register('quit', 'quit: close the game', fn [mut a] (args []string) string {
		a.ctx.quit()
		return ''
	})
}

fn (a &App) stats_text() string {
	if a.scene == unsafe { nil } || a.renderer == unsafe { nil } {
		return 'starting'
	}
	mem := gc_memory_use()
	mem_text := if mem > 0 { ' | mem ${f64(mem) / 1048576.0:.1} MB' } else { '' }
	return 'FPS ${int(a.fps)} | nodes ${a.scene.node_count()} | assets ${a.db.loaded_count()}/${a.db.len()} | draw calls ${a.renderer.draw_calls}${mem_text} | ${runtime.nr_cpus()} cpus'
}

fn (mut a App) draw_debug_overlay() {
	if !a.cfg.debug_tools {
		return
	}
	w := a.window_points()
	if a.renderer.debug {
		a.overlay_text(int(w.x) - 10, 10, a.stats_text(), gg.Color{255, 255, 0, 255}, .right)
	}
	if a.profiler.enabled {
		a.draw_profiler(w)
	}
	if a.console.open {
		a.draw_console(w)
	}
}

fn (mut a App) overlay_text(x int, y int, text string, color gg.Color, align gg.HorizontalAlign) {
	a.ctx.draw_text(x, y, text, size: overlay_font, color: color, align: align)
}

// draw_profiler: the frame time graph (the line is 16.7 ms = 60 FPS) and the slowest scopes.
fn (mut a App) draw_profiler(w core.Vec2) {
	hist := a.profiler.frame_history()
	gw := 240
	gh := 60
	x0 := 10
	y0 := if a.console.open { (console_lines + 1) * (overlay_font + 4) + 22 } else { 34 }
	a.ctx.draw_rect_filled(x0, y0, gw, gh + 4, gg.Color{0, 0, 0, 150})
	max_ms := f32(33.4) // the graph shows up to 30 FPS; slower frames are clipped
	for i, ms in hist {
		h := int(f32(gh) * (if ms > max_ms { max_ms } else { ms }) / max_ms)
		col := if ms > 20 {
			gg.Color{255, 90, 90, 220}
		} else if ms > 17.5 {
			gg.Color{255, 200, 60, 220}
		} else {
			gg.Color{90, 220, 120, 220}
		}
		a.ctx.draw_rect_filled(x0 + i * gw / 120, y0 + gh + 2 - h, gw / 120 + 1, h, col)
	}
	line := y0 + gh + 2 - int(f32(gh) * 16.7 / max_ms)
	a.ctx.draw_line(x0, line, x0 + gw, line, gg.Color{255, 255, 255, 120})
	mut y := y0 + gh + 10
	for row in a.profiler.top(10) {
		a.overlay_text(x0, y, '${row.name:-22} ${row.ms:5.2f} ms', gg.Color{255, 255, 255, 230}, .left)
		y += overlay_font + 3
	}
}

// draw_console: the top half of the screen, the last log lines and the input line.
fn (mut a App) draw_console(w core.Vec2) {
	lh := overlay_font + 4
	h := (console_lines + 1) * lh + 12
	a.ctx.draw_rect_filled(0, 0, int(w.x), h, gg.Color{0, 0, 0, 200})
	mut y := 6
	for en in core.logger().tail(console_lines) {
		col := match en.level {
			.error { gg.Color{255, 100, 100, 255} }
			.warn { gg.Color{255, 210, 90, 255} }
			.debug { gg.Color{150, 150, 150, 255} }
			else { gg.Color{225, 225, 225, 255} }
		}
		a.overlay_text(8, y, en.text, col, .left)
		y += lh
	}
	y = h - lh - 2
	a.ctx.draw_rect_filled(0, y - 2, int(w.x), lh + 4, gg.Color{40, 40, 60, 255})
	a.overlay_text(8, y, '> ${a.console.line}_', gg.Color{120, 255, 160, 255}, .left)
}
