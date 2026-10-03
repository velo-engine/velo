module core

import time

// Debug tools: a log with levels, a frame profiler and a command console. App draws them (F1 overlay, F2
// profiler, ` console; see Config.debug_tools); everything here runs without a GPU.

// ---------- Log ----------

pub enum LogLevel {
	debug
	info
	warn
	error
}

pub fn log_level_from_str(s string) ?LogLevel {
	return match s.to_lower() {
		'debug' { LogLevel.debug }
		'info' { LogLevel.info }
		'warn', 'warning' { LogLevel.warn }
		'error' { LogLevel.error }
		else { none }
	}
}

pub struct LogEntry {
pub:
	level LogLevel
	text  string
	time  f64 // seconds since the program started logging
}

// Log — the last `max_entries` messages (shown by the console) and the stdout/stderr echo. Use it from the main
// thread. `core.log_info('...')`, `core.log_warn`, `core.log_error`, `core.log_debug`.
@[heap]
pub struct Log {
mut:
	entries []LogEntry
	clock   time.StopWatch = time.new_stopwatch()
pub mut:
	min_level   LogLevel = .info // anything below is dropped
	max_entries int      = 200
	echo        bool     = true // also print to the terminal (warn and error go to stderr)
}

const default_log = &Log{}

pub fn logger() &Log {
	return default_log
}

pub fn (mut l Log) write(level LogLevel, text string) {
	if int(level) < int(l.min_level) {
		return
	}
	l.entries << LogEntry{level, text, f64(l.clock.elapsed().milliseconds()) / 1000.0}
	if l.entries.len > l.max_entries {
		l.entries.delete_many(0, l.entries.len - l.max_entries)
	}
	if l.echo {
		line := '[${level}] ${text}'
		if level in [.warn, .error] {
			eprintln(line)
		} else {
			println(line)
		}
	}
}

// tail: the last n entries.
pub fn (l &Log) tail(n int) []LogEntry {
	start := if l.entries.len > n { l.entries.len - n } else { 0 }
	return l.entries[start..].clone()
}

pub fn (mut l Log) clear() {
	l.entries.clear()
}

pub fn log_debug(text string) {
	mut l := logger()
	l.write(.debug, text)
}

pub fn log_info(text string) {
	mut l := logger()
	l.write(.info, text)
}

pub fn log_warn(text string) {
	mut l := logger()
	l.write(.warn, text)
}

pub fn log_error(text string) {
	mut l := logger()
	l.write(.error, text)
}

// ---------- Profiler ----------

pub struct ProfileRow {
pub:
	name string
	ms   f32 // smoothed over the last frames
}

const profile_history = 120

// Profiler — time spent per named scope, per frame, smoothed. Off by default (a disabled profiler costs one
// check). App times `update`, `draw`, `audio` and, per component type, `update:Type` (all instances summed).
// Your own: `p.begin('ai')` ... `p.end('ai')` (scopes of the same name do not nest).
@[heap]
pub struct Profiler {
mut:
	started map[string]u64
	current map[string]f32 // this frame, ms
	smooth  map[string]f32
	history []f32 // frame time, ms, oldest first
pub mut:
	enabled bool
}

pub fn (mut p Profiler) begin(name string) {
	if p.enabled {
		p.started[name] = time.sys_mono_now()
	}
}

pub fn (mut p Profiler) end(name string) {
	if !p.enabled {
		return
	}
	t0 := p.started[name] or { return }
	p.current[name] += f32(time.sys_mono_now() - t0) / 1_000_000.0
}

// new_frame closes the frame: `frame_ms` goes to the history, scope times into the smoothed averages.
pub fn (mut p Profiler) new_frame(frame_ms f32) {
	if !p.enabled {
		return
	}
	p.history << frame_ms
	if p.history.len > profile_history {
		p.history.delete(0)
	}
	for name, _ in p.smooth {
		if name !in p.current {
			p.smooth[name] *= 0.9
		}
	}
	for name, v in p.current {
		p.smooth[name] = if name in p.smooth { p.smooth[name] * 0.9 + v * 0.1 } else { v }
	}
	p.current.clear()
}

// top: the n most expensive scopes, slowest first.
pub fn (p &Profiler) top(n int) []ProfileRow {
	mut rows := []ProfileRow{}
	for name, ms in p.smooth {
		if ms >= 0.005 {
			rows << ProfileRow{name, ms}
		}
	}
	rows.sort(a.ms > b.ms)
	return if rows.len > n { rows[..n].clone() } else { rows }
}

pub fn (p &Profiler) scope_ms(name string) f32 {
	return p.smooth[name] or { 0 }
}

// frame_history: recent frame times in ms, oldest first (for a graph).
pub fn (p &Profiler) frame_history() []f32 {
	return p.history
}

pub fn (mut p Profiler) reset() {
	p.started.clear()
	p.current.clear()
	p.smooth.clear()
	p.history.clear()
}

// ---------- Console ----------

pub type ConsoleCommand = fn (args []string) string

// Console — a command line: `name arg arg`. Output goes to the log (so the overlay shows it). Register commands
// with `console.register('give', 'give <n> coins', fn (args []string) string { ... })`; a returned text is logged.
@[heap]
pub struct Console {
mut:
	commands map[string]ConsoleCommand
	helps    map[string]string
	history  []string
	hist_pos int
pub mut:
	open bool
	line string
}

pub fn (mut c Console) register(name string, help string, f ConsoleCommand) {
	c.commands[name] = f
	c.helps[name] = help
}

pub fn (c &Console) command_names() []string {
	mut names := c.commands.keys()
	names.sort()
	return names
}

pub fn (c &Console) help_of(name string) string {
	return c.helps[name] or { '' }
}

// execute runs one line; the result (or the error text) is logged and returned.
pub fn (mut c Console) execute(line string) string {
	parts := line.trim_space().split(' ').filter(it != '')
	if parts.len == 0 {
		return ''
	}
	f := c.commands[parts[0]] or {
		msg := 'unknown command "${parts[0]}" (try help)'
		log_warn(msg)
		return msg
	}
	out := f(parts[1..])
	if out != '' {
		for l in out.split_into_lines() {
			log_info(l)
		}
	}
	return out
}

// complete finishes a command name from what is typed (when exactly one command starts with it).
pub fn (mut c Console) complete() {
	if c.line.contains(' ') || c.line == '' {
		return
	}
	matches := c.command_names().filter(it.starts_with(c.line))
	if matches.len == 1 {
		c.line = matches[0] + ' '
	} else if matches.len > 1 {
		log_info(matches.join('  '))
	}
}

// type_text appends typed characters to the input line.
pub fn (mut c Console) type_text(s string) {
	c.line += s
}

// input_char appends one typed character (a Unicode code point); control characters are ignored.
pub fn (mut c Console) input_char(code u32) {
	if code >= 32 && code != 127 {
		c.line += utf32_to_str(code)
	}
}

// key handles an editing key while the console is open; returns true when it used the key.
pub fn (mut c Console) key(k Key) bool {
	match k {
		.enter {
			if c.line.trim_space() != '' {
				log_info('> ${c.line}')
				c.history << c.line
				c.hist_pos = c.history.len
				line := c.line
				c.line = ''
				c.execute(line)
			}
		}
		.backspace {
			if c.line.len > 0 {
				runes := c.line.runes()
				c.line = runes[..runes.len - 1].string()
			}
		}
		.up {
			if c.hist_pos > 0 {
				c.hist_pos--
				c.line = c.history[c.hist_pos]
			}
		}
		.down {
			if c.hist_pos < c.history.len - 1 {
				c.hist_pos++
				c.line = c.history[c.hist_pos]
			} else {
				c.hist_pos = c.history.len
				c.line = ''
			}
		}
		.tab {
			c.complete()
		}
		.escape {
			c.open = false
		}
		else {
			return false
		}
	}
	return true
}
