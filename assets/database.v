module assets

import os
import time
import hash.fnv1a

// AssetEntry — an asset known to the database (not necessarily loaded into memory).
@[heap]
pub struct AssetEntry {
pub:
	id string
pub mut:
	path  string // relative to the assets directory, always uses '/'
	kind  AssetKind
	meta  Meta
	deps  []string // asset IDs this asset references (scene/text only)
	hash  u64
	mtime i64
	refs  int // number of current holders (load/release)
mut:
	texture &Texture    = unsafe { nil }
	scene   &SceneAsset = unsafe { nil }
	text    &TextAsset  = unsafe { nil }
	audio   &AudioClip  = unsafe { nil }
	font    &Font       = unsafe { nil }
	shader  &Shader     = unsafe { nil }
}

pub fn (e &AssetEntry) is_loaded() bool {
	return e.texture != unsafe { nil } || e.scene != unsafe { nil } || e.text != unsafe { nil }
		|| e.audio != unsafe { nil } || e.font != unsafe { nil } || e.shader != unsafe { nil }
}

pub enum AssetEventKind {
	added
	modified
	moved
	removed
	unloaded
}

pub struct AssetEvent {
pub:
	kind AssetEventKind
	id   string
	path string
}

// AssetDatabase — manages all assets in a directory:
//   * assigns stable IDs via .meta files (created if missing)
//   * typed loading + reference counting (load / release)
//   * dependency graph: who uses which asset, which assets are unused
//   * detects changes on disk for hot reload
@[heap]
pub struct AssetDatabase {
pub:
	root string
mut:
	entries map[string]&AssetEntry // id -> entry
	by_path map[string]string      // relative path -> id
	events  []AssetEvent
pub mut:
	warnings []string
}

// open scans the `root` directory and imports every file found.
pub fn open(root string) !&AssetDatabase {
	if !os.is_dir(root) {
		return error('assets directory not found: ${root}')
	}
	mut db := &AssetDatabase{
		root: os.real_path(root)
	}
	db.sync()
	db.events.clear() // the initial scan does not count as "changes"
	return db
}

// ---------- Lookup ----------

pub fn (db &AssetDatabase) entry(id string) ?&AssetEntry {
	return db.entries[id] or { return none }
}

pub fn (db &AssetDatabase) id_of(path string) ?string {
	return db.by_path[normalize(path)] or { return none }
}

pub fn (db &AssetDatabase) path_of(id string) ?string {
	e := db.entries[id] or { return none }
	return e.path
}

// resolve accepts an asset ID or a relative path and returns the ID.
pub fn (db &AssetDatabase) resolve(key string) ?string {
	if key in db.entries {
		return key
	}
	return db.id_of(key)
}

pub fn (db &AssetDatabase) abs_path(e &AssetEntry) string {
	return os.join_path(db.root, e.path)
}

// all returns every asset, sorted by path.
pub fn (db &AssetDatabase) all() []&AssetEntry {
	mut out := []&AssetEntry{}
	for _, e in db.entries {
		out << e
	}
	out.sort(a.path < b.path)
	return out
}

pub fn (db &AssetDatabase) len() int {
	return db.entries.len
}

// ---------- Typed loading + reference counting ----------

// load[T] loads the asset (if not loaded yet) and increments its reference count. Every load must be paired with a release.
//   tex := db.load[assets.Texture](sprite.texture.id)!
pub fn (mut db AssetDatabase) load[T](key string) !&T {
	id := db.resolve(key) or { return error('asset "${key}" not found') }
	mut e := db.entries[id] or { return error('asset "${key}" not found') }
	$if T is Texture {
		db.expect_kind(e, .texture, 'Texture')!
		if e.texture == unsafe { nil } {
			e.texture = db.read_texture(e)!
		}
		e.refs++
		return e.texture
	} $else $if T is SceneAsset {
		db.expect_kind(e, .scene, 'SceneAsset')!
		if e.scene == unsafe { nil } {
			e.scene = &SceneAsset{
				id:     e.id
				path:   db.abs_path(e)
				source: os.read_file(db.abs_path(e))!
			}
		}
		e.refs++
		return e.scene
	} $else $if T is TextAsset {
		db.expect_kind(e, .text, 'TextAsset')!
		if e.text == unsafe { nil } {
			e.text = &TextAsset{
				id:   e.id
				path: db.abs_path(e)
				text: os.read_file(db.abs_path(e))!
			}
		}
		e.refs++
		return e.text
	} $else $if T is Font {
		db.expect_kind(e, .font, 'Font')!
		if e.font == unsafe { nil } {
			e.font = &Font{
				id:   e.id
				path: db.abs_path(e)
			}
		}
		e.refs++
		return e.font
	} $else $if T is Shader {
		db.expect_kind(e, .shader, 'Shader')!
		if e.shader == unsafe { nil } {
			e.shader = &Shader{
				id:     e.id
				path:   db.abs_path(e)
				source: os.read_file(db.abs_path(e))!
			}
		}
		e.refs++
		return e.shader
	} $else $if T is AudioClip {
		db.expect_kind(e, .audio, 'AudioClip')!
		if e.audio == unsafe { nil } {
			e.audio = db.read_audio(e)
		}
		e.refs++
		return e.audio
	} $else {
		return error('unsupported asset type: ${T.name}')
	}
}

// get[T] loads via a typed AssetRef (increments the reference count like load).
pub fn (mut db AssetDatabase) get[T](r AssetRef[T]) !&T {
	if !r.is_set() {
		return error('empty AssetRef')
	}
	return db.load[T](r.id)!
}

// release decrements the reference count; at 0 it frees the data from memory and emits an `unloaded` event
// (the renderer receives this event to delete the texture on the GPU).
pub fn (mut db AssetDatabase) release(id string) {
	mut e := db.entries[id] or { return }
	if e.refs <= 0 {
		return
	}
	e.refs--
	if e.refs == 0 {
		e.texture = unsafe { nil }
		e.scene = unsafe { nil }
		e.text = unsafe { nil }
		e.audio = unsafe { nil }
		e.font = unsafe { nil }
		e.shader = unsafe { nil }
		db.events << AssetEvent{.unloaded, e.id, e.path}
	}
}

// loaded_count: number of assets currently in memory.
pub fn (db &AssetDatabase) loaded_count() int {
	mut n := 0
	for _, e in db.entries {
		if e.is_loaded() {
			n++
		}
	}
	return n
}

// drain_events returns and clears the event queue (added/modified/moved/removed/unloaded).
pub fn (mut db AssetDatabase) drain_events() []AssetEvent {
	ev := db.events.clone()
	db.events.clear()
	return ev
}

// ---------- Dependency graph ----------

// dependencies: assets directly referenced by `id`.
pub fn (db &AssetDatabase) dependencies(id string) []string {
	e := db.entries[id] or { return [] }
	return e.deps.clone()
}

// dependencies_deep: dependency closure (used to know what to package when building a scene).
pub fn (db &AssetDatabase) dependencies_deep(id string) []string {
	mut seen := map[string]bool{}
	mut stack := db.dependencies(id)
	for stack.len > 0 {
		cur := stack.pop()
		if cur in seen {
			continue
		}
		seen[cur] = true
		stack << db.dependencies(cur)
	}
	mut out := seen.keys()
	out.sort()
	return out
}

// dependents: assets that reference `id` (check before deleting a file!).
pub fn (db &AssetDatabase) dependents(id string) []string {
	mut out := []string{}
	for _, e in db.entries {
		if id in e.deps {
			out << e.id
		}
	}
	out.sort()
	return out
}

// unused: assets not reachable from any root scene in `roots`.
pub fn (db &AssetDatabase) unused(roots []string) []string {
	mut reachable := map[string]bool{}
	for r in roots {
		id := db.resolve(r) or { continue }
		reachable[id] = true
		for d in db.dependencies_deep(id) {
			reachable[d] = true
		}
	}
	mut out := []string{}
	for e in db.all() {
		if e.id !in reachable {
			out << e.id
		}
	}
	return out
}

// missing_references: (asset, missing id) pairs — references to assets that do not exist.
pub fn (db &AssetDatabase) missing_references() [][]string {
	mut out := [][]string{}
	for e in db.all() {
		for d in e.deps {
			if d !in db.entries {
				out << [e.id, d]
			}
		}
	}
	return out
}

// ---------- Sync with disk (import + hot reload) ----------

// poll_changes rescans the directory, updating modified/added/removed/moved assets.
// Assets currently loaded are re-read IN PLACE (the pointer stays the same, version increments).
pub fn (mut db AssetDatabase) poll_changes() []AssetEvent {
	db.sync()
	return db.drain_events()
}

fn (mut db AssetDatabase) sync() {
	mut seen := map[string]bool{}
	mut files := os.walk_ext(db.root, '')
	files.sort()
	for abs in files {
		rel := normalize(abs.replace(db.root, '').trim_left('/\\'))
		name := os.file_name(rel)
		if name.starts_with('.') || rel.ends_with('.meta') || rel.starts_with('library/') {
			continue
		}
		id := db.import_file(rel) or {
			db.warn('import error ${rel}: ${err}')
			continue
		}
		seen[id] = true
	}
	// The file has disappeared from disk.
	for id, e in db.entries.clone() {
		if id !in seen {
			db.by_path.delete(e.path)
			db.entries.delete(id)
			db.events << AssetEvent{.removed, id, e.path}
		}
	}
}

// import_file reads/creates the .meta and updates the entry for a file. Returns the ID.
fn (mut db AssetDatabase) import_file(rel string) !string {
	abs := os.join_path(db.root, rel)
	meta_path := abs + '.meta'
	// Combined mtime of the file and its .meta (changing import settings also requires re-importing).
	mtime := os.file_last_mod_unix(abs) * 2 + if os.exists(meta_path) {
		os.file_last_mod_unix(meta_path)
	} else {
		0
	}

	// Fast path: known file, unchanged modification time, and not modified within the last 2 seconds
	// (mtime is only accurate to the second, so recently modified files are always re-hashed to be safe).
	if known_id := db.by_path[rel] {
		if e := db.entries[known_id] {
			if e.mtime == mtime && os.file_last_mod_unix(abs) < time.now().unix() - 2 {
				return known_id
			}
		}
	}

	kind := kind_from_ext(rel)
	mut meta := Meta{}
	mut write := false
	if os.exists(meta_path) {
		meta = read_meta(meta_path)!
		// a file type added in a later engine version (e.g. .ttf fonts) was imported as unknown: upgrade it
		if meta.kind == 'unknown' && kind != .unknown {
			meta.kind = kind.str()
			write = true
		}
	} else {
		meta = Meta{
			id:       new_id()
			kind:     kind.str()
			settings: default_settings(kind)
		}
		write = true
	}
	// Two files with the same ID (usually from copying both the file and its .meta): assign a new ID to the latter.
	if other := db.entries[meta.id] {
		if other.path != rel && os.exists(os.join_path(db.root, other.path)) {
			db.warn('duplicate ID ${meta.id} between "${other.path}" and "${rel}" — assigning a new ID to "${rel}"')
			meta.id = new_id()
			write = true
		}
	}
	if write {
		write_meta(meta_path, meta)!
	}

	data := os.read_bytes(abs)!
	h := fnv1a.sum64(data) ^ fnv1a.sum64_string(meta.encode())
	id := meta.id

	if mut e := db.entries[id] {
		if e.path != rel {
			// Same ID at a new path => the file was moved/renamed.
			db.by_path.delete(e.path)
			db.events << AssetEvent{.moved, id, rel}
			e.path = rel
		}
		db.by_path[rel] = id
		e.mtime = mtime
		e.meta = meta
		e.kind = kind_from_str(meta.kind)
		if e.hash != h {
			e.hash = h
			e.deps = extract_deps(e.kind, data)
			db.reload_in_place(mut e) or { db.warn('reload error ${rel}: ${err}') }
			db.events << AssetEvent{.modified, id, rel}
		}
		return id
	}

	e := &AssetEntry{
		id:    id
		path:  rel
		kind:  kind_from_str(meta.kind)
		meta:  meta
		deps:  extract_deps(kind_from_str(meta.kind), data)
		hash:  h
		mtime: mtime
	}
	db.entries[id] = e
	db.by_path[rel] = id
	db.events << AssetEvent{.added, id, rel}
	return id
}

fn (mut db AssetDatabase) reload_in_place(mut e AssetEntry) ! {
	if e.texture != unsafe { nil } {
		fresh := db.read_texture(e)!
		v := e.texture.version
		unsafe {
			*e.texture = *fresh
		}
		e.texture.version = v + 1
	}
	if e.scene != unsafe { nil } {
		e.scene.source = os.read_file(db.abs_path(e))!
		e.scene.version++
	}
	if e.text != unsafe { nil } {
		e.text.text = os.read_file(db.abs_path(e))!
		e.text.version++
	}
	if e.font != unsafe { nil } {
		e.font.version++
	}
	if e.shader != unsafe { nil } {
		e.shader.source = os.read_file(db.abs_path(e))!
		e.shader.version++
	}
	if e.audio != unsafe { nil } {
		fresh := db.read_audio(e)
		v := e.audio.version
		unsafe {
			*e.audio = *fresh
		}
		e.audio.version = v + 1
	}
}

fn (db &AssetDatabase) read_audio(e &AssetEntry) &AudioClip {
	abs := db.abs_path(e)
	return &AudioClip{
		id:     e.id
		path:   abs
		bytes:  int(os.file_size(abs))
		stream: e.meta.settings['stream'] or { '' }
	}
}

fn (db &AssetDatabase) read_texture(e &AssetEntry) !&Texture {
	abs := db.abs_path(e)
	w, h := image_size(abs)!
	return &Texture{
		id:           e.id
		path:         abs
		width:        w
		height:       h
		frame_width:  e.meta.setting_int('frame_width', 0)
		frame_height: e.meta.setting_int('frame_height', 0)
		filter:       e.meta.settings['filter'] or { 'linear' }
	}
}

fn (db &AssetDatabase) expect_kind(e &AssetEntry, want AssetKind, type_name string) ! {
	if e.kind != want {
		return error('asset "${e.path}" (${e.id}) is ${e.kind}, cannot load it as ${type_name}')
	}
}

fn (mut db AssetDatabase) warn(msg string) {
	db.warnings << msg
	eprintln('[assets] ${msg}')
}

// extract_deps finds every `@asset("...")` in a scene/text file.
fn extract_deps(kind AssetKind, data []u8) []string {
	if kind != .scene && kind != .text {
		return []
	}
	src := data.bytestr()
	mut out := []string{}
	mut i := 0
	marker := '@asset("'
	for {
		idx := src.index_after(marker, i) or { break }
		start := idx + marker.len
		end := src.index_after('"', start) or { break }
		id := src[start..end]
		if id !in out {
			out << id
		}
		i = end + 1
	}
	return out
}

fn normalize(p string) string {
	return p.replace('\\', '/')
}
