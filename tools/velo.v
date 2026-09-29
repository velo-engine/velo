module main

import os

const usage = 'Velo Engine command-line tool

Usage:
  velo new <name>               create a new project in ./<name>
  velo run [dir] [args...]      run the game (dir defaults to .)
  velo editor [dir]             open the scene/prefab editor
  velo build [dir] [-o file]    build an optimized executable
  velo assets [dir] <command>   asset tool (list, deps, users, unused, check)
  velo home                     print the engine directory

Install (once, from the engine repo):
  v -o ~/.local/bin/velo tools/velo.v     (any directory on your PATH works)

The engine is found at VELO_HOME if set, otherwise at the repo velo was built from.
The repo directory must be named "velo" (it is the `velo` module: velo/core, velo/app, ...).'

// The engine repo — baked in at compile time, overridable with VELO_HOME.
const built_home = @VMODROOT

fn main() {
	args := os.args[1..]
	if args.len == 0 || args[0] in ['-h', '--help', 'help'] {
		println(usage)
		exit(if args.len == 0 { 1 } else { 0 })
	}
	home := velo_home()
	match args[0] {
		'new' {
			if args.len < 2 {
				fail('missing project name: velo new <name>')
			}
			new_project(args[1])
		}
		'run' {
			dir, rest := split_dir(args[1..])
			exit(v_cmd(home, ['run', dir], rest))
		}
		'editor' {
			dir, rest := split_dir(args[1..])
			mut prog := ['--editor']
			prog << rest
			exit(v_cmd(home, ['run', dir], prog))
		}
		'build' {
			dir, rest := split_dir(args[1..])
			mut flags := ['-prod']
			if '-o' !in rest {
				flags << ['-o', os.join_path(dir, os.file_name(os.real_path(dir)))]
			}
			flags << rest
			flags << dir
			exit(v_cmd(home, flags, []))
		}
		'assets' {
			dir, rest := split_dir(args[1..])
			tool := os.join_path(home, 'tools', 'assetdb.v')
			mut prog := [os.join_path(dir, 'assets')]
			prog << rest
			exit(v_cmd(home, ['run', tool], prog))
		}
		'home' {
			println(home)
		}
		else {
			fail('unknown command "${args[0]}"\n\n${usage}')
		}
	}
}

fn velo_home() string {
	home := os.real_path(os.getenv_opt('VELO_HOME') or { built_home })
	if !os.is_file(os.join_path(home, 'core', 'node.v')) {
		fail('engine not found in "${home}" — set VELO_HOME to the Velo repo directory')
	}
	if os.file_name(home) != 'velo' {
		fail('the engine directory must be named "velo" so `import velo.*` resolves (got "${home}")')
	}
	return home
}

// split_dir takes an optional leading project directory (anything that is not a flag).
fn split_dir(args []string) (string, []string) {
	if args.len > 0 && !args[0].starts_with('-') && os.is_dir(args[0]) {
		return args[0], args[1..]
	}
	return '.', args
}

// v_cmd runs `v -path @vlib|<parent of home>|@vmodules <v_args> <prog_args>` so `import velo.*` resolves
// to <home>/core, <home>/app, ... without symlinks. @vlib comes first so sibling folders can't shadow it.
fn v_cmd(home string, v_args []string, prog_args []string) int {
	vexe := os.find_abs_path_of_executable('v') or { fail('`v` not found on PATH') }
	mut p := os.new_process(vexe)
	mut all := ['-path', '@vlib|${os.dir(home)}|@vmodules']
	all << v_args
	all << prog_args
	p.set_args(all)
	p.run()
	p.wait()
	code := p.code
	p.close()
	return code
}

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
		'assets/scenes/main.scene': main_scene
		'.gitignore':               gitignore.replace('{{bin}}', name)
	}
	for path, content in files {
		os.write_file(os.join_path(root, path), content) or { fail(err.msg()) }
	}
	println('Created project "${name}" in ${root}\n')
	println('  cd ${name}')
	println('  velo editor     open the editor')
	println('  velo run        run the game')
}

@[noreturn]
fn fail(msg string) {
	eprintln('velo: ${msg}')
	exit(1)
}

const main_v = "module main

import os
import velo.app
import velo.editor
import velo.serialize

//   velo run      run the game
//   velo editor   open the scene/prefab editor
fn main() {
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

const main_scene = 'node Main {
}
'

const gitignore = '/{{bin}}
*.exe
*.dSYM/
'
