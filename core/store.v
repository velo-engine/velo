module core

import os
import strconv

// StoreValue — what a Store holds: whole numbers, decimals, true/false and text.
pub type StoreValue = bool | f64 | int | string

// Store — the player's saved data (progress, best scores, settings), shared by every scene through
// `scene.store` and written to disk by the app: when the game quits or goes to the background, or on `save()`.
//
//   mut st := c.scene().store
//   st.set_int('coins', st.get_int('coins', 0) + 1)
//   if st.get_bool('music', true) { ... }
//
// The file is plain text, one `key = value` per line (strings quoted), so it is easy to inspect.
@[heap]
pub struct Store {
mut:
	values map[string]StoreValue
pub mut:
	path  string // the file it is saved to ('' = kept in memory only)
	dirty bool   // changed since the last save
	// Writes the text instead of the file (the web saves to the browser's localStorage).
	writer fn (text string) ! = unsafe { nil }
}

// Store.open reads the save file at `path` (a missing file is an empty store; an unreadable one is reported
// and left untouched until the next save).
pub fn Store.open(path string) &Store {
	mut s := &Store{
		path: path
	}
	if os.is_file(path) {
		text := os.read_file(path) or {
			eprintln('[velo] cannot read save data ${path}: ${err}')
			return s
		}
		s.values = parse_store(text) or {
			eprintln('[velo] save data ${path}: ${err} — starting empty')
			map[string]StoreValue{}
		}
	}
	return s
}

// Store.from_text builds a store from saved text (memory only until `path` or `writer` is set).
pub fn Store.from_text(text string) !&Store {
	return &Store{
		values: parse_store(text)!
	}
}

pub fn (s &Store) has(key string) bool {
	return key in s.values
}

pub fn (s &Store) keys() []string {
	mut k := s.values.keys()
	k.sort()
	return k
}

// get_int: the value (a decimal is rounded down), or `default` when missing or not a number.
pub fn (s &Store) get_int(key string, default int) int {
	v := s.values[key] or { return default }
	return match v {
		int { v }
		f64 { int(v) }
		else { default }
	}
}

pub fn (s &Store) get_f64(key string, default f64) f64 {
	v := s.values[key] or { return default }
	return match v {
		f64 { v }
		int { f64(v) }
		else { default }
	}
}

pub fn (s &Store) get_f32(key string, default f32) f32 {
	return f32(s.get_f64(key, default))
}

pub fn (s &Store) get_bool(key string, default bool) bool {
	v := s.values[key] or { return default }
	return if v is bool { v } else { default }
}

pub fn (s &Store) get_string(key string, default string) string {
	v := s.values[key] or { return default }
	return if v is string { v } else { default }
}

pub fn (mut s Store) set_int(key string, v int) {
	s.set(key, StoreValue(v))
}

pub fn (mut s Store) set_f64(key string, v f64) {
	s.set(key, StoreValue(v))
}

pub fn (mut s Store) set_f32(key string, v f32) {
	s.set(key, StoreValue(f64(v)))
}

pub fn (mut s Store) set_bool(key string, v bool) {
	s.set(key, StoreValue(v))
}

pub fn (mut s Store) set_string(key string, v string) {
	s.set(key, StoreValue(v))
}

fn (mut s Store) set(key string, v StoreValue) {
	if !valid_key(key) {
		eprintln('[velo] store key "${key}" must be letters, digits, _ . - (ignored)')
		return
	}
	if old := s.values[key] {
		if old == v {
			return
		}
	}
	s.values[key] = v
	s.dirty = true
}

pub fn (mut s Store) delete(key string) {
	if key in s.values {
		s.values.delete(key)
		s.dirty = true
	}
}

// clear forgets everything (saved on the next save).
pub fn (mut s Store) clear() {
	if s.values.len > 0 {
		s.values.clear()
		s.dirty = true
	}
}

// save writes the store now (the file is replaced in one step, so a crash cannot leave half a save).
pub fn (mut s Store) save() ! {
	text := s.encode()
	if s.writer != unsafe { nil } {
		s.writer(text)!
	} else if s.path != '' {
		os.mkdir_all(os.dir(s.path))!
		tmp := s.path + '.tmp'
		os.write_file(tmp, text)!
		os.mv(tmp, s.path)!
	}
	s.dirty = false
}

// save_if_changed saves when something changed since the last save (errors are printed).
pub fn (mut s Store) save_if_changed() {
	if s.dirty {
		s.save() or { eprintln('[velo] cannot save: ${err}') }
	}
}

// encode: the saved text.
pub fn (s &Store) encode() string {
	mut lines := ['# velo save data']
	for k in s.keys() {
		v := s.values[k] or { continue }
		lines << '${k} = ${encode_value(v)}'
	}
	return lines.join('\n') + '\n'
}

fn encode_value(v StoreValue) string {
	return match v {
		bool {
			v.str()
		}
		int {
			v.str()
		}
		f64 {
			t := strconv.f64_to_str_l(v)
			if t.contains('.') || t.contains('e') || t.contains('n') {
				t
			} else {
				t + '.0'
			}
		}
		string {
			'"' +
				v.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') +
				'"'
		}
	}
}

fn parse_store(text string) !map[string]StoreValue {
	mut out := map[string]StoreValue{}
	for i, raw in text.split_into_lines() {
		line := raw.trim_space()
		if line == '' || line.starts_with('#') {
			continue
		}
		if !line.contains('=') {
			return error('line ${i + 1}: expected `key = value`')
		}
		key := line.all_before('=').trim_space()
		val := line.all_after('=').trim_space()
		if !valid_key(key) {
			return error('line ${i + 1}: bad key "${key}"')
		}
		out[key] = parse_store_value(val) or { return error('line ${i + 1}: ${err}') }
	}
	return out
}

fn parse_store_value(t string) !StoreValue {
	if t == 'true' || t == 'false' {
		return StoreValue(t == 'true')
	}
	if t.len >= 2 && t.starts_with('"') && t.ends_with('"') {
		mut sb := []u8{}
		body := t[1..t.len - 1]
		mut i := 0
		for i < body.len {
			c := body[i]
			if c == `\\` && i + 1 < body.len {
				n := body[i + 1]
				sb << match n {
					`n` { `\n` }
					`r` { `\r` }
					else { n }
				}

				i += 2
				continue
			}
			sb << c
			i++
		}
		return StoreValue(sb.bytestr())
	}
	if t.contains('.') || t.contains('e') || t.contains('n') {
		return StoreValue(strconv.atof64(t) or { return error('bad number "${t}"') })
	}
	return StoreValue(strconv.atoi(t) or { return error('bad value "${t}"') })
}

fn valid_key(k string) bool {
	if k == '' {
		return false
	}
	for c in k {
		if !(c.is_letter() || c.is_digit() || c in [`_`, `.`, `-`]) {
			return false
		}
	}
	return true
}
