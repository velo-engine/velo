module main

import os

const usage = 'Velo Engine command-line tool

Usage:
  velo new <name>                        create a new project in ./<name>
  velo run [target] [dir] [options]      build and run the game (dir defaults to .)
  velo build [target] [dir] [options]    build the game for distribution
  velo editor [dir]                      open the scene/prefab editor
  velo assets [dir] <command>            asset tool (list, deps, users, unused, check)
  velo deps                              download sources for mobile builds (Box2D)
  velo doctor                            check the toolchains for every target
  velo home                              print the engine directory

Targets:
  desktop    (default) this computer
  android    APK/AAB, via vab (Android SDK + NDK + Java)
  ios        iPhone/iPad device, via Xcode (needs a signing identity + provisioning profile)
  ios-sim    iOS Simulator, via Xcode
  web        browser (WebAssembly), via Emscripten; `velo run web` serves it on localhost:8080
  webgl      browser (JavaScript + WebGL): the V code of the game translated to JavaScript (tools/v2js),
             on the TypeScript runtime of the engine; needs Node.js. `velo run webgl` serves it on localhost:8080

Options:
  --release          optimized build (desktop builds are always optimized)
  -o <path>          output file (build only; web: output directory)
  --device <id>      android/ios: device to deploy to (run only; default: first found)
  --aab              android: build an Android App Bundle for Google Play instead of an APK
  -v, --verbose      print the commands being run
  Desktop: any other arguments are passed to the game (run) or to `v` (build).

Examples:
  velo run                     run on this computer
  velo run ios-sim             build, install and launch in the iOS Simulator
  velo run android             build, install and launch on a connected device/emulator, show logs
  velo build android --release --aab
  velo build web --release     index.html + .js + .wasm + .data in build/web/, ready to upload
  velo run webgl               translate to JavaScript, bundle, serve on http://localhost:8080

App name, ID, version, icon and signing come from velo.toml in the project (see `velo new`).

Install (once, from the engine repo):
  v -o ~/.local/bin/velo tools/velo     (any directory on your PATH works)

The engine is found at VELO_HOME if set, otherwise at the repo velo was built from.
The repo directory must be named "velo" (it is the `velo` module: velo/core, velo/app, ...).'

// The engine repo — baked in at compile time, overridable with VELO_HOME.
const built_home = @VMODROOT

const targets = ['desktop', 'android', 'ios', 'ios-sim', 'web', 'webgl']

fn main() {
	args := os.args[1..].filter(it !in ['-v', '--verbose'])
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
		'run', 'build' {
			target, rest := split_target(args[1..])
			dir, rest2 := split_dir(rest)
			if target == 'desktop' {
				if args[0] == 'run' {
					exit(v_cmd(home, ['run', dir], rest2))
				}
				exit(build_desktop(home, dir, rest2))
			}
			opts := parse_mobile_options(args[0], rest2)
			p := load_project(dir)
			match target {
				'android' { build_android(home, p, opts) }
				'web' { build_web(home, p, opts) }
				'webgl' { build_webgl(home, p, opts) }
				else { build_ios(home, p, opts, target == 'ios-sim') }
			}
		}
		'editor' {
			dir, rest := split_dir(args[1..])
			mut prog := ['--editor']
			prog << rest
			exit(v_cmd(home, ['run', dir], prog))
		}
		'assets' {
			dir, rest := split_dir(args[1..])
			exit(assetdb(home, os.join_path(dir, 'assets'), rest))
		}
		'deps' {
			ensure_box2d(home)
			println('Box2D sources are in ${box2d_dir(home)}')
		}
		'doctor' {
			exit(doctor(home))
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

// split_target takes an optional leading target name.
fn split_target(args []string) (string, []string) {
	if args.len > 0 && args[0] in targets {
		return args[0], args[1..]
	}
	return 'desktop', args
}

// split_dir takes an optional leading project directory (anything that is not a flag).
fn split_dir(args []string) (string, []string) {
	if args.len > 0 && !args[0].starts_with('-') && os.is_dir(args[0]) {
		return args[0], args[1..]
	}
	return '.', args
}

struct MobileOptions {
mut:
	run     bool
	release bool
	aab     bool
	output  string
	device  string
}

fn parse_mobile_options(cmd string, args []string) MobileOptions {
	mut o := MobileOptions{
		run: cmd == 'run'
	}
	mut i := 0
	for i < args.len {
		match args[i] {
			'--release', '-prod' {
				o.release = true
			}
			'--aab' {
				o.aab = true
			}
			'-o', '--device' {
				if i + 1 >= args.len {
					fail('${args[i]} needs a value')
				}
				if args[i] == '-o' {
					o.output = os.abs_path(args[i + 1])
				} else {
					o.device = args[i + 1]
				}
				i++
			}
			else {
				fail('unknown option "${args[i]}" for velo ${cmd}')
			}
		}

		i++
	}
	return o
}

fn build_desktop(home string, dir string, rest []string) int {
	mut flags := ['-prod']
	if '-o' !in rest {
		flags << ['-o', os.join_path(dir, os.file_name(os.real_path(dir)))]
	}
	flags << rest
	flags << dir
	return v_cmd(home, flags, [])
}

// v_path is the module search path that makes `import velo.*` resolve to <home>/core, <home>/app, ... without
// symlinks. @vlib comes first so sibling folders can't shadow it.
fn v_path(home string) string {
	return '@vlib|${os.dir(home)}|@vmodules'
}

// v_cmd runs `v -path <v_path> <v_args> <prog_args>`.
fn v_cmd(home string, v_args []string, prog_args []string) int {
	mut all := ['-path', v_path(home)]
	all << v_args
	all << prog_args
	return run(vexe(), all)
}

fn assetdb(home string, assets_dir string, args []string) int {
	mut prog := [assets_dir]
	prog << args
	return v_cmd(home, ['run', os.join_path(home, 'tools', 'assetdb.v')], prog)
}

fn vexe() string {
	return os.find_abs_path_of_executable('v') or { fail('`v` not found on PATH') }
}

// run runs a program with inherited stdin/stdout/stderr and returns its exit code.
fn run(exe string, args []string) int {
	if verbose() {
		println('> ${shell_join(exe, args)}')
	}
	mut p := os.new_process(os.find_abs_path_of_executable(exe) or { exe })
	p.set_args(args)
	p.run()
	p.wait()
	code := p.code
	p.close()
	return code
}

// must runs a program and stops velo if it fails.
fn must(exe string, args []string) {
	code := run(exe, args)
	if code != 0 {
		fail('`${os.file_name(exe)} ${args.join(' ')}` failed (exit code ${code})')
	}
}

// capture runs a program and returns its output, stopping velo if it fails.
fn capture(exe string, args []string) string {
	cmd := shell_join(exe, args)
	if verbose() {
		println('> ${cmd}')
	}
	res := os.execute(cmd)
	if res.exit_code != 0 {
		fail('`${cmd}` failed:\n${res.output}')
	}
	return res.output.trim_space()
}

fn shell_join(exe string, args []string) string {
	mut parts := [os.quoted_path(exe)]
	for a in args {
		parts << shell_quote(a)
	}
	return parts.join(' ')
}

fn shell_quote(s string) string {
	if s != '' && s.bytes().all(it.is_alnum()
		|| it in [`-`, `_`, `.`, `/`, `=`, `:`, `,`, `@`, `+`]) {
		return s
	}
	return "'" + s.replace("'", "'\\''") + "'"
}

fn verbose() bool {
	return '-v' in os.args || '--verbose' in os.args
}

fn step(msg string) {
	println('velo: ${msg}')
}

@[noreturn]
fn fail(msg string) {
	eprintln('velo: ${msg}')
	exit(1)
}
