module assets

import os
import rand

// Meta — contents of the `<asset>.meta` file next to each asset.
// Commit .meta files together with their assets in Git: the ID inside is what scenes/prefabs reference,
// so renaming or moving a file (along with its .meta) does not break references.
pub struct Meta {
pub mut:
	id       string
	kind     string
	version  int = 1
	settings map[string]string // import settings, e.g. filter, frame_width
}

pub fn new_id() string {
	return '${rand.u32():08x}'
}

pub fn default_settings(kind AssetKind) map[string]string {
	return match kind {
		.texture {
			{
				'filter': 'linear'
			}
		}
		else { map[string]string{} }
	}
}

// .meta format: one `key: value` per line, lines starting with # are comments.
//   id: 7f3a91c2
//   kind: texture
//   version: 1
//   filter: nearest       <- every other key is an import setting
//   frame_width: 16
pub fn parse_meta(src string) !Meta {
	mut m := Meta{}
	for raw in src.split_into_lines() {
		line := raw.trim_space()
		if line == '' || line.starts_with('#') {
			continue
		}
		key := line.all_before(':').trim_space()
		val := line.all_after(':').trim_space()
		if !line.contains(':') || key == '' {
			return error('invalid line: "${line}"')
		}
		match key {
			'id' { m.id = val }
			'kind' { m.kind = val }
			'version' { m.version = val.int() }
			else { m.settings[key] = val }
		}
	}
	if m.id == '' {
		return error('missing id')
	}
	return m
}

pub fn (m Meta) encode() string {
	mut sb := []string{}
	sb << 'id: ${m.id}'
	sb << 'kind: ${m.kind}'
	sb << 'version: ${m.version}'
	mut keys := m.settings.keys()
	keys.sort()
	for k in keys {
		sb << '${k}: ${m.settings[k]}'
	}
	return sb.join('\n') + '\n'
}

pub fn read_meta(meta_path string) !Meta {
	src := os.read_file(meta_path)!
	return parse_meta(src) or { return error('corrupt meta file: ${meta_path}: ${err}') }
}

pub fn write_meta(meta_path string, m Meta) ! {
	os.write_file(meta_path, m.encode())!
}

pub fn (m Meta) setting_int(key string, def int) int {
	if v := m.settings[key] {
		return v.int()
	}
	return def
}
