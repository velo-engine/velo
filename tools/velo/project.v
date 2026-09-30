module main

import os
import toml

// Project — a game project and its velo.toml settings (all optional; defaults come from the directory name).
struct Project {
	dir         string // absolute project directory
	bin         string // file-safe name, used for executables and packages
	name        string // display name
	id          string // bundle ID / package ID, reverse-DNS
	version     string // user-visible version, e.g. 1.2.0
	build       int    // build number: Android versionCode / iOS CFBundleVersion, must increase for store uploads
	orientation string // landscape | portrait | any (iOS; Android follows the device)
	icon        string // absolute path to a square PNG (1024x1024 recommended), or ''
	// [android]
	keystore       string
	keystore_alias string
	min_sdk        int
	// [ios]
	ios_min       string // minimum iOS version
	ios_identity  string // codesign identity for device builds; default: the first "Apple Development" one
	ios_profile   string // .mobileprovision for device builds; default: an installed one matching `id`
	ios_simulator string // simulator name or UDID for `velo run ios-sim`; default: a booted one, else the first iPhone
}

fn (p Project) assets_dir() string {
	return os.join_path(p.dir, 'assets')
}

fn (p Project) build_dir(target string) string {
	return os.join_path(p.dir, 'build', target)
}

fn load_project(dir string) Project {
	abs := os.real_path(dir)
	if !os.is_dir(os.join_path(abs, 'assets')) {
		fail('"${abs}" is not a Velo project (no assets/ directory)')
	}
	bin := os.file_name(abs)
	cfg_path := os.join_path(abs, 'velo.toml')
	doc := if os.is_file(cfg_path) {
		toml.parse_file(cfg_path) or { fail('${cfg_path}: ${err}') }
	} else {
		toml.parse_text('') or { fail(err.msg()) }
	}
	str := fn [doc] (key string, def string) string {
		return doc.value(key).default_to(def).string()
	}
	path := fn [abs, doc] (key string) string {
		v := doc.value(key).default_to('').string()
		return if v == '' { '' } else { os.real_path(os.join_path(abs, v)) }
	}
	p := Project{
		dir:            abs
		bin:            bin
		name:           str('app.name', bin)
		id:             str('app.id', 'com.velo.' + id_segment(bin))
		version:        str('app.version', '1.0.0')
		build:          doc.value('app.build').default_to(1).int()
		orientation:    str('app.orientation', 'landscape')
		icon:           path('app.icon')
		keystore:       path('android.keystore')
		keystore_alias: str('android.keystore_alias', '')
		min_sdk:        doc.value('android.min_sdk').default_to(0).int()
		ios_min:        str('ios.min_version', '14.0')
		ios_identity:   str('ios.identity', '')
		ios_profile:    path('ios.provisioning_profile')
		ios_simulator:  str('ios.simulator', '')
	}
	if p.orientation !in ['landscape', 'portrait', 'any'] {
		fail('velo.toml: app.orientation must be landscape, portrait or any (got "${p.orientation}")')
	}
	if p.id.split('.').len < 2 || p.id.split('.').any(it == '' || !it[0].is_letter()) {
		fail('velo.toml: app.id must look like com.company.game (got "${p.id}")')
	}
	if p.icon != '' && !os.is_file(p.icon) {
		fail('velo.toml: icon "${p.icon}" not found')
	}
	return p
}

// id_segment turns a name into a valid bundle/package ID segment: lowercase letters and digits, starting with a letter.
fn id_segment(name string) string {
	mut s := name.to_lower().bytes().filter(it.is_letter() || it.is_digit()).bytestr()
	if s == '' || !s[0].is_letter() {
		s = 'game' + s
	}
	return s
}

// ---------- velo new ----------

fn new_project(name string) {
	if name.starts_with('-') || name.contains_any('/\\:*?"<>|') {
		fail('invalid project name "${name}"')
	}
	root := os.join_path(os.getwd(), name)
	if os.exists(root) && os.ls(root) or { [] }.len > 0 {
		fail('"${root}" already exists and is not empty')
	}
	for d in ['assets/scenes', 'assets/prefabs', 'assets/sprites'] {
		os.mkdir_all(os.join_path(root, d)) or { fail(err.msg()) }
	}
	files := {
		'main.v':                   main_v.replace('{{name}}', name)
		'components.v':             components_v
		'velo.toml':                velo_toml.replace('{{name}}', name).replace('{{id}}',
			id_segment(name))
		'assets/scenes/main.scene': main_scene
		'.gitignore':               gitignore.replace('{{bin}}', name)
	}
	for path, content in files {
		os.write_file(os.join_path(root, path), content) or { fail(err.msg()) }
	}
	println('Created project "${name}" in ${root}\n')
	println('  cd ${name}')
	println('  velo editor         open the editor')
	println('  velo run            run the game')
	println('  velo run ios-sim    run it in the iOS Simulator (or: android)')
}

const main_v = "module main

import os
import velo.app
import velo.editor
import velo.serialize

//   velo run      run the game
//   velo editor   open the scene/prefab editor
fn main() {
	// On Android/iOS the packaged assets are used instead (see app.new).
	assets_dir := os.join_path(os.dir(@FILE), 'assets')
	if '--editor' in os.args {
		mut ed := editor.new(
			title:      '{{name}} — Velo Editor'
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
		title:      '{{name}}'
		assets_dir: assets_dir
		scene:      'scenes/main.scene'
		width:      960 // design resolution: the screen the game is laid out for,
		height:     540 // fitted to any window or phone (see scale_mode)
		scale_mode: 'expand' // expand | fit | fill | width | height | none
	) or {
		eprintln(err)
		exit(1)
	}
	register_components(mut game.registry)
	game.run()
}

// Each game component needs one registration line to be usable in .scene files and the editor.
fn register_components(mut r serialize.Registry) {
	r.register[Rotator]()
}
"

const components_v = "module main

import velo.core

// Example component: spins its node. Add it to a node in the editor's Inspector.
pub struct Rotator {
	core.Component
pub mut:
	speed f32 = 90 // degrees per second
}

pub fn (mut r Rotator) update(dt f32) {
	r.node.rotation += r.speed * dt
}
"

const velo_toml = '# Settings for `velo build` / `velo run` on Android and iOS. Paths are relative to this file.

[app]
name = "{{name}}"                 # name shown under the app icon
id = "com.example.{{id}}"         # bundle / package ID, must be unique per app
version = "1.0.0"
build = 1                         # increase for every store upload
orientation = "landscape"         # landscape | portrait | any (iOS; Android follows the device)
# icon = "icon.png"               # square PNG, 1024x1024

[android]
# keystore = "release.keystore"   # release signing (default: a debug key); passwords come from
# keystore_alias = "release"      # the VAB_KS_PASS and VAB_KS_ALIAS_PASS environment variables
# min_sdk = 21

[ios]
# min_version = "14.0"
# identity = "Apple Development: Jane Doe (ABCDE12345)"   # default: the first development identity
# provisioning_profile = "game.mobileprovision"           # default: an installed profile matching app.id
# simulator = "iPhone 17"                                 # default: a booted simulator, else the first iPhone
'

const main_scene = 'node Main {
}
'

const gitignore = '/{{bin}}
/build/
*.exe
*.dSYM/
'
