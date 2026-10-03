module main

import os

// `velo build [desktop]`: compile, then lay the game out the way it is shipped:
//   macOS          build/desktop/<Name>.app   (Info.plist, icon.icns, Resources/assets)
//   Linux/Windows  build/desktop/<bin>/       (executable + assets/ next to it)
// `--zip` also writes <bin>-<version>-<os>.zip. The game finds its assets by itself (see runtime_assets_dir).

struct DesktopOptions {
mut:
	debug  bool // no -prod
	zip    bool
	output string // output directory (default build/desktop)
	v_args []string // anything else goes to `v`
}

fn parse_desktop_options(args []string) DesktopOptions {
	mut o := DesktopOptions{}
	mut i := 0
	for i < args.len {
		match args[i] {
			'--debug' {
				o.debug = true
			}
			'--zip' {
				o.zip = true
			}
			'--release' {} // desktop builds are optimized unless --debug
			'-o' {
				if i + 1 >= args.len {
					fail('-o needs a directory')
				}
				o.output = os.abs_path(args[i + 1])
				i++
			}
			else {
				o.v_args << args[i]
			}
		}
		i++
	}
	return o
}

// dev_only: files that are never shipped (source art, OS litter); `exclude` in velo.toml's [build] adds patterns.
const dev_only = ['*.psd', '*.ase', '*.aseprite', '*.blend', '*.xcf', '*.kra', '*.pxo', '*.afdesign', '.DS_Store',
	'Thumbs.db', '*.tmp', '*~']

// shipped_assets: packaged_assets minus the dev-only files and the project's own excludes.
fn shipped_assets(p Project) []string {
	mut patterns := dev_only.clone()
	patterns << p.exclude
	return packaged_assets(p).filter(fn [patterns] (rel string) bool {
		name := os.file_name(rel)
		return !patterns.any(rel.match_glob(it) || name.match_glob(it))
	})
}

fn copy_assets(p Project, dest string) (int, i64) {
	mut count := 0
	mut bytes := i64(0)
	root := p.assets_dir()
	for rel in shipped_assets(p) {
		dst := os.join_path(dest, rel)
		os.mkdir_all(os.dir(dst)) or { fail(err.msg()) }
		os.cp(os.join_path(root, rel), dst) or { fail('copy ${rel}: ${err}') }
		count++
		bytes += os.file_size(os.join_path(root, rel))
	}
	return count, bytes
}

fn host_os() string {
	$if macos {
		return 'macos'
	} $else $if windows {
		return 'windows'
	} $else {
		return 'linux'
	}
}

fn build_desktop(home string, dir string, rest []string) int {
	o := parse_desktop_options(rest)
	p := load_project(dir)
	step('checking assets')
	if assetdb(home, p.assets_dir(), ['check']) != 0 {
		fail('fix the asset errors above before building (see `velo assets check`)')
	}
	out := if o.output != '' { o.output } else { p.build_dir('desktop') }
	stage := os.join_path(out, '.stage')
	os.rmdir_all(stage) or {}
	os.mkdir_all(stage) or { fail(err.msg()) }
	exe_name := if host_os() == 'windows' { p.bin + '.exe' } else { p.bin }
	exe := os.join_path(stage, exe_name)

	mut flags := []string{}
	if !o.debug {
		flags << '-prod'
	}
	if uses_physics(p) {
		// a shipped game must not depend on a Box2D installed on the player's machine
		ensure_box2d(home)
		flags << ['-d', 'box2d_source']
	}
	flags << ['-o', exe]
	flags << o.v_args
	flags << p.dir
	step('compiling ${p.name} (${if o.debug { 'debug' } else { 'optimized' }})')
	code := v_cmd(home, flags, [])
	if code != 0 {
		return code
	}

	mut pkg := ''
	if host_os() == 'macos' {
		pkg = package_macos(p, out, exe)
	} else {
		pkg = package_folder(p, out, exe, exe_name)
	}
	os.rmdir_all(stage) or {}
	if o.zip {
		pkg = make_zip(p, out, pkg)
	}
	step('done: ${pkg}')
	return 0
}

fn package_folder(p Project, out string, exe string, exe_name string) string {
	dest := os.join_path(out, p.bin)
	os.rmdir_all(dest) or {}
	os.mkdir_all(dest) or { fail(err.msg()) }
	os.cp(exe, os.join_path(dest, exe_name)) or { fail(err.msg()) }
	os.chmod(os.join_path(dest, exe_name), 0o755) or {}
	n, bytes := copy_assets(p, os.join_path(dest, 'assets'))
	step('packaged ${n} assets (${bytes / 1024} KB)')
	return dest
}

fn package_macos(p Project, out string, exe string) string {
	app := os.join_path(out, '${p.name}.app')
	os.rmdir_all(app) or {}
	macos_dir := os.join_path(app, 'Contents', 'MacOS')
	res := os.join_path(app, 'Contents', 'Resources')
	os.mkdir_all(macos_dir) or { fail(err.msg()) }
	os.mkdir_all(res) or { fail(err.msg()) }
	os.cp(exe, os.join_path(macos_dir, p.bin)) or { fail(err.msg()) }
	os.chmod(os.join_path(macos_dir, p.bin), 0o755) or {}
	n, bytes := copy_assets(p, os.join_path(res, 'assets'))
	step('packaged ${n} assets (${bytes / 1024} KB)')
	icon := if p.icon != '' { make_icns(p.icon, res, out) } else { '' }
	os.write_file(os.join_path(app, 'Contents', 'Info.plist'), macos_plist(p, icon)) or { fail(err.msg()) }
	return app
}

// make_icns turns the square PNG into an AppIcon.icns with sips + iconutil (both ship with macOS).
fn make_icns(png string, res string, out string) string {
	set := os.join_path(out, '.stage', 'AppIcon.iconset')
	os.mkdir_all(set) or { fail(err.msg()) }
	for size in [16, 32, 128, 256, 512] {
		for scale in [1, 2] {
			px := size * scale
			name := if scale == 1 { 'icon_${size}x${size}.png' } else { 'icon_${size}x${size}@2x.png' }
			must('sips', ['-z', px.str(), px.str(), png, '--out', os.join_path(set, name)])
		}
	}
	must('iconutil', ['-c', 'icns', set, '-o', os.join_path(res, 'AppIcon.icns')])
	return 'AppIcon'
}

fn macos_plist(p Project, icon string) string {
	mut s := []string{}
	s << '<?xml version="1.0" encoding="UTF-8"?>'
	s << '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
	s << '<plist version="1.0">\n<dict>'
	mut keys := {
		'CFBundleExecutable':            p.bin
		'CFBundleIdentifier':            p.id
		'CFBundleName':                  p.name
		'CFBundleDisplayName':           p.name
		'CFBundlePackageType':           'APPL'
		'CFBundleShortVersionString':    p.version
		'CFBundleVersion':               p.build.str()
		'CFBundleInfoDictionaryVersion': '6.0'
		'LSMinimumSystemVersion':        '11.0'
	}
	if icon != '' {
		keys['CFBundleIconFile'] = icon
	}
	mut names := keys.keys()
	names.sort()
	for k in names {
		s << '\t<key>${k}</key>\n\t<string>${xml_escape(keys[k])}</string>'
	}
	s << '\t<key>NSHighResolutionCapable</key>\n\t<true/>'
	s << '</dict>\n</plist>\n'
	return s.join('\n')
}

fn make_zip(p Project, out string, pkg string) string {
	zip := os.join_path(out, '${p.bin}-${p.version}-${host_os()}.zip')
	os.rm(zip) or {}
	step('writing ${os.file_name(zip)}')
	match host_os() {
		'macos' {
			must('ditto', ['-c', '-k', '--keepParent', pkg, zip])
		}
		'windows' {
			must('powershell', ['-NoProfile', '-Command',
				"Compress-Archive -Path '${pkg}' -DestinationPath '${zip}' -Force"])
		}
		else {
			cwd := os.getwd()
			os.chdir(out) or { fail(err.msg()) }
			must('zip', ['-qr', zip, os.file_name(pkg)])
			os.chdir(cwd) or {}
		}
	}
	return zip
}
