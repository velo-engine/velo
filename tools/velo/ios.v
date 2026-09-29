module main

import os
import hash.fnv1a
import x.json2

// iOS builds: V generates C for `-os ios`, then velo compiles it with the Xcode toolchain itself
// (V's own iOS compile step targets 32-bit ARM, which current SDKs no longer ship), bundles an .app
// (executable + Info.plist + assets/), signs it, and optionally installs and launches it.

struct IosBuild {
	p       Project
	sim     bool
	release bool
	sdk     string // iphonesimulator | iphoneos
	xcrun   string
	clang   string
	target  []string // -target/-isysroot flags for every clang call
	dir     string   // build/ios or build/ios-sim
}

fn build_ios(home string, p Project, o MobileOptions, sim bool) {
	$if !macos {
		fail('iOS builds need macOS with Xcode')
	}
	xcrun := os.find_abs_path_of_executable('xcrun') or {
		fail('xcrun not found — install Xcode and run `xcode-select --install`')
	}
	sdk := if sim { 'iphonesimulator' } else { 'iphoneos' }
	arch := if sim && os.uname().machine == 'x86_64' { 'x86_64' } else { 'arm64' }
	b := IosBuild{
		p:       p
		sim:     sim
		release: o.release
		sdk:     sdk
		xcrun:   xcrun
		clang:   capture(xcrun, ['--sdk', sdk, '-f', 'clang'])
		target:  ['-target', '${arch}-apple-ios${p.ios_min}${if sim { '-simulator' } else { '' }}',
			'-isysroot', capture(xcrun, ['--sdk', sdk, '--show-sdk-path'])]
		dir:     p.build_dir(if sim { 'ios-sim' } else { 'ios' })
	}
	prepare_mobile_build(home, p)
	os.mkdir_all(os.join_path(b.dir, 'obj')) or { fail(err.msg()) }

	step('building ${p.name} for ${if sim { 'the iOS Simulator' } else { 'iOS' }} (${if o.release {
		'release'
	} else {
		'debug'
	}})')
	app := if sim && o.output != '' { o.output } else { os.join_path(b.dir, '${p.bin}.app') }
	b.compile(home, os.join_path(app, p.bin))
	b.bundle(app)
	if sim {
		must('codesign', ['--force', '--sign', '-', '--timestamp=none', app])
		step('built ${app}')
		if o.run {
			b.run_simulator(app, o.device)
		}
		return
	}
	b.sign_device(app)
	ipa := if o.output != '' { o.output } else { os.join_path(b.dir, '${p.bin}.ipa') }
	make_ipa(app, ipa)
	step('built ${app}\nvelo: built ${ipa}')
	if o.run {
		b.run_device(app, o.device)
	}
}

// ---------- compile ----------

// compile turns the game into an iOS executable at `exe`.
fn (b IosBuild) compile(home string, exe string) {
	c_file := os.join_path(b.dir, '${b.p.bin}.c')
	flags_file := os.join_path(b.dir, 'cflags.txt')
	mut vflags := ['-os', 'ios', '-d', 'use_bundled_libgc']
	if b.sim {
		vflags << '-simulator'
	}
	if b.release {
		vflags << '-prod'
	}
	mut gen := vflags.clone()
	gen << ['-o', c_file, b.p.dir]
	if v_cmd(home, gen, []) != 0 {
		fail('V compilation failed')
	}
	// The C flags (#flag lines of every imported module) are only dumped when V also invokes the C compiler,
	// which fails for iOS; only the dump is needed.
	os.rm(flags_file) or {}
	mut dump_args := ['-path', v_path(home)]
	dump_args << vflags
	dump_args << ['-dump-c-flags', flags_file, '-o', os.join_path(b.dir, 'obj', 'v_dump'),
		b.p.dir]
	os.execute(shell_join(vexe(), dump_args))
	lines := os.read_lines(flags_file) or { fail('V did not dump the C flags (${flags_file})') }
	f := parse_c_flags(lines)

	patch_generated_c(c_file)

	mut common := b.target.clone()
	common << ['-std=c99', '-D_DEFAULT_SOURCE', '-Wno-incompatible-function-pointer-types',
		'-Wno-typedef-redefinition', '-Wno-int-conversion', '-w']
	common << if b.release { ['-O2', '-DNDEBUG'] } else { ['-O0', '-g'] }
	common << f.cflags

	mut objs := []string{}
	for o in f.objects {
		src, extra := object_source(o)
		mut args := common.clone()
		args << extra
		objs << b.compile_cached(src, args)
	}
	step('compiling C')
	main_o := os.join_path(b.dir, 'obj', '${b.p.bin}.o')
	mut args := common.clone()
	args << ['-fobjc-arc', '-x', 'objective-c', '-c', c_file, '-o', main_o]
	must(b.clang, args)

	os.mkdir_all(os.dir(exe)) or { fail(err.msg()) }
	mut link := b.target.clone()
	link << main_o
	link << objs
	link << f.ldflags
	link << ['-o', exe]
	must(b.clang, link)
}

// compile_cached compiles a C dependency (libgc, stb_image, ...) once per set of flags.
fn (b IosBuild) compile_cached(src string, args []string) string {
	key := fnv1a.sum64_string(src + args.join(' ')).hex()
	obj := os.join_path(b.dir, 'obj', '${os.file_name(src).all_before_last('.')}-${key}.o')
	if os.is_file(obj) && os.file_last_mod_unix(obj) >= os.file_last_mod_unix(src) {
		return obj
	}
	step('compiling ${os.file_name(src)}')
	mut all := args.clone()
	all << ['-c', src, '-o', obj]
	must(b.clang, all)
	return obj
}

struct CFlags {
mut:
	cflags  []string
	ldflags []string
	objects []string // prebuilt .o files V would link; recompiled from their sources for iOS
}

// parse_c_flags sorts V's `-dump-c-flags` output (one flag per line) into compile and link flags.
fn parse_c_flags(lines []string) CFlags {
	mut f := CFlags{}
	for raw in lines {
		line := raw.trim_space()
		plain := line.trim('"\'')
		if line == '' || line.starts_with('-isysroot') || line.starts_with('-arch')
			|| line.starts_with('-m') || line.starts_with('-o ') || line.starts_with('-x ')
			|| plain.ends_with('.tmp.c') {
			continue
		}
		if plain.ends_with('.o') {
			f.objects << plain
		} else if line.starts_with('-D') || line.starts_with('-I') {
			f.cflags << line[..2] + line[2..].trim_space().trim('"\'')
		} else if line.starts_with('-framework ') {
			f.ldflags << ['-framework', line.all_after(' ').trim_space()]
		} else if line.starts_with('-l') || line.starts_with('-L') || line.starts_with('-Wl,') {
			f.ldflags << line[..2] + line[2..].trim_space().trim('"\'')
		} else if line.starts_with('-std=') || line.starts_with('-fobjc') {
			// set per file by velo
		} else {
			f.cflags << line
		}
	}
	return f
}

// object_source finds the C source (and its own -I/-D flags) of an object file from V's cache:
// V writes `<obj>.thirdparty.description.txt` next to cached module objects, with the compile command.
fn object_source(obj string) (string, []string) {
	base := obj.all_before_last('.o')
	for desc in [base + '.thirdparty.description.txt', base + '.description.txt'] {
		text := os.read_file(desc) or { continue }
		cmd := text.all_after('CMD:')
		src := cmd.all_after(" -c '").all_before("'")
		if os.is_file(src) {
			mut extra := []string{}
			for part in cmd.split(' -') {
				if part.starts_with('I') || part.starts_with('D') {
					extra << '-' + part[..1] + part[1..].trim_space().trim('"\'')
				}
			}
			return src, extra
		}
	}
	for src in [base + '.c', base + '.m'] {
		if os.is_file(src) {
			return src, []string{}
		}
	}
	if obj.ends_with('.module.builtin.o') {
		// -d use_bundled_libgc: the garbage collector
		return os.join_path(os.dir(vexe()), 'thirdparty', 'libgc', 'gc.c'), []string{}
	}
	fail('cannot find the C source of "${obj}" for the iOS build')
}

// patch_generated_c works around V 0.5.2 issues with `-os ios` in the generated C:
//   * os declares posix_spawn* with void* parameters, which conflicts with <spawn.h> pulled in by UIKit;
//   * sokol.sapp only passes the Metal device and drawable to sokol_gfx on macOS (not iOS), so rendering
//     setup asserts. Each patch is skipped when the generated code no longer needs it.
fn patch_generated_c(c_file string) {
	mut src := os.read_file(c_file) or { fail(err.msg()) }
	src = src.split_into_lines().filter(!it.starts_with('extern int posix_spawn')).join('\n')
	src = insert_before_return(src, 'sokol__sapp__glue_environment(void) {', '\treturn env;',
		'\tenv.metal.device = sapp_env.metal.device;\n')
	src = insert_before_return(src, 'sokol__sapp__glue_swapchain(void) {', '\treturn swapchain;',
		'\tswapchain.metal.current_drawable = sapp_sc.metal.current_drawable;\n' +
		'\tswapchain.metal.depth_stencil_texture = sapp_sc.metal.depth_stencil_texture;\n' +
		'\tswapchain.metal.msaa_color_texture = sapp_sc.metal.msaa_color_texture;\n')
	os.write_file(c_file, src) or { fail(err.msg()) }
}

fn insert_before_return(src string, fn_head string, ret string, code string) string {
	start := src.index(fn_head) or { return src }
	end := src.index_after(ret, start) or { return src }
	if src[start..end].contains(code.all_before('=').trim_space()) {
		return src
	}
	return src[..end] + code + src[end..]
}

// ---------- bundle ----------

fn (b IosBuild) bundle(app string) {
	p := b.p
	assets := os.join_path(app, 'assets')
	os.rmdir_all(assets) or {}
	for rel in packaged_assets(p) {
		dst := os.join_path(assets, rel)
		os.mkdir_all(os.dir(dst)) or { fail(err.msg()) }
		os.cp(os.join_path(p.assets_dir(), rel), dst) or { fail(err.msg()) }
	}
	plist := os.join_path(app, 'Info.plist')
	os.write_file(plist, b.info_plist()) or { fail(err.msg()) }
	if p.icon != '' {
		b.compile_icon(app, plist)
	}
}

fn (b IosBuild) info_plist() string {
	p := b.p
	orientations := match p.orientation {
		'portrait' {
			['UIInterfaceOrientationPortrait']
		}
		'landscape' {
			['UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
		}
		else {
			['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
				'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
		}
	}

	platform := if b.sim { 'iPhoneSimulator' } else { 'iPhoneOS' }
	mut s := []string{}
	s << '<?xml version="1.0" encoding="UTF-8"?>'
	s << '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
	s << '<plist version="1.0">\n<dict>'
	for k, v in {
		'CFBundleExecutable':            p.bin
		'CFBundleIdentifier':            p.id
		'CFBundleName':                  p.name
		'CFBundleDisplayName':           p.name
		'CFBundlePackageType':           'APPL'
		'CFBundleShortVersionString':    p.version
		'CFBundleVersion':               p.build.str()
		'CFBundleInfoDictionaryVersion': '6.0'
		'CFBundleDevelopmentRegion':     'en'
		'MinimumOSVersion':              p.ios_min
		'DTPlatformName':                b.sdk
	} {
		s << '\t<key>${k}</key>\n\t<string>${xml_escape(v)}</string>'
	}
	s << '\t<key>CFBundleSupportedPlatforms</key>\n\t<array><string>${platform}</string></array>'
	s << '\t<key>LSRequiresIPhoneOS</key>\n\t<true/>'
	// Without a launch screen iOS runs the app in a letterboxed compatibility mode.
	s << '\t<key>UILaunchScreen</key>\n\t<dict/>'
	s << '\t<key>UIRequiresFullScreen</key>\n\t<true/>'
	s << '\t<key>UIStatusBarHidden</key>\n\t<true/>'
	s << '\t<key>UIDeviceFamily</key>\n\t<array><integer>1</integer><integer>2</integer></array>'
	s << '\t<key>UISupportedInterfaceOrientations</key>\n\t<array>' +
		orientations.map('<string>${it}</string>').join('') + '</array>'
	s << '</dict>\n</plist>\n'
	return s.join('\n')
}

// compile_icon builds the app icon from one PNG with actool (Xcode generates the other sizes).
fn (b IosBuild) compile_icon(app string, plist string) {
	set := os.join_path(b.dir, 'Assets.xcassets', 'AppIcon.appiconset')
	os.rmdir_all(os.dir(set)) or {}
	os.mkdir_all(set) or { fail(err.msg()) }
	os.cp(b.p.icon, os.join_path(set, 'icon.png')) or { fail(err.msg()) }
	os.write_file(os.join_path(set, 'Contents.json'),
		'{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"velo","version":1}}') or {
		fail(err.msg())
	}
	partial := os.join_path(b.dir, 'icon-info.plist')
	capture(b.xcrun, ['actool', os.dir(set), '--compile', app, '--platform', b.sdk,
		'--minimum-deployment-target', b.p.ios_min, '--app-icon', 'AppIcon', '--target-device',
		'iphone', '--target-device', 'ipad', '--output-partial-info-plist', partial])
	capture('/usr/libexec/PlistBuddy', ['-c', 'Merge ${partial}', plist])
}

fn xml_escape(s string) string {
	return s.replace_each(['&', '&amp;', '<', '&lt;', '>', '&gt;', '"', '&quot;'])
}

// ---------- signing (device) ----------

fn (b IosBuild) sign_device(app string) {
	identity := if b.p.ios_identity != '' { b.p.ios_identity } else { default_identity() }
	profile := if b.p.ios_profile != '' { b.p.ios_profile } else { find_profile(b.p.id) }
	decoded := os.join_path(b.dir, 'profile.plist')
	os.write_file(decoded, capture('security', ['cms', '-D', '-i', profile])) or { fail(err.msg()) }
	ents := os.join_path(b.dir, 'entitlements.plist')
	os.write_file(ents, capture('/usr/libexec/PlistBuddy', ['-x', '-c', 'Print :Entitlements',
		decoded])) or { fail(err.msg()) }
	os.cp(profile, os.join_path(app, 'embedded.mobileprovision')) or { fail(err.msg()) }
	step('signing with "${identity}" and ${os.file_name(profile)}')
	must('codesign', ['--force', '--sign', identity, '--entitlements', ents, '--timestamp=none',
		app])
}

fn default_identity() string {
	out := capture('security', ['find-identity', '-v', '-p', 'codesigning'])
	for line in out.split_into_lines() {
		if line.contains('"Apple Development') || line.contains('"iPhone Developer') {
			return line.all_after('"').all_before('"')
		}
	}
	fail('no "Apple Development" signing identity found — sign in to your Apple ID in Xcode (Settings > Accounts), or set ios.identity in velo.toml')
}

// find_profile looks for an installed provisioning profile for `id` (exact match first, then wildcards).
fn find_profile(id string) string {
	home := os.home_dir()
	mut best := ''
	mut best_len := -1
	for dir in [
		os.join_path(home, 'Library', 'Developer', 'Xcode', 'UserData', 'Provisioning Profiles'),
		os.join_path(home, 'Library', 'MobileDevice', 'Provisioning Profiles'),
	] {
		for f in os.ls(dir) or { [] } {
			if !f.ends_with('.mobileprovision') {
				continue
			}
			path := os.join_path(dir, f)
			res := os.execute('security cms -D -i ${os.quoted_path(path)}')
			if res.exit_code != 0 {
				continue
			}
			app_id :=
				res.output.all_after('<key>application-identifier</key>').all_after('<string>').all_before('</string>')
			pattern := app_id.all_after('.') // strip the team ID
			matched := if pattern.ends_with('*') {
				id.starts_with(pattern#[..-1])
			} else {
				pattern == id
			}
			// the most specific pattern wins
			if matched && pattern.len > best_len {
				best, best_len = path, pattern.len
			}
		}
	}
	if best == '' {
		fail('no provisioning profile for "${id}" found — create one in Xcode (or at developer.apple.com) and set ios.provisioning_profile in velo.toml')
	}
	return best
}

fn make_ipa(app string, ipa string) {
	staging := os.join_path(os.dir(app), 'ipa')
	os.rmdir_all(staging) or {}
	payload := os.join_path(staging, 'Payload')
	os.mkdir_all(payload) or { fail(err.msg()) }
	must('cp', ['-R', app, payload])
	os.rm(ipa) or {}
	must('ditto', ['-c', '-k', '--keepParent', payload, ipa])
	os.rmdir_all(staging) or {}
}

// ---------- run ----------

fn (b IosBuild) run_simulator(app string, device string) {
	udid := pick_simulator(if device != '' { device } else { b.p.ios_simulator })
	os.execute('xcrun simctl boot ${udid}') // fails harmlessly when already booted
	capture(b.xcrun, ['simctl', 'bootstatus', udid, '-b'])
	os.execute('open -a Simulator')
	step('installing on simulator ${udid}')
	must(b.xcrun, ['simctl', 'install', udid, app])
	step('launching ${b.p.id} (Ctrl+C to stop)')
	run(b.xcrun, ['simctl', 'launch', '--console-pty', '--terminate-running-process', udid, b.p.id])
}

// pick_simulator returns the UDID of the simulator named/identified by `want`, else a booted one,
// else the first available iPhone of the newest runtime.
fn pick_simulator(want string) string {
	out := capture('xcrun', ['simctl', 'list', 'devices', 'available', '-j'])
	root := json2.decode[json2.Any](out) or { fail('cannot parse `simctl list`: ${err}') }
	runtimes := root.as_map()['devices'] or { json2.Any(map[string]json2.Any{}) }.as_map()
	mut keys := runtimes.keys()
	keys.sort(a > b) // newest runtime first
	mut first_iphone := ''
	for k in keys {
		for d in runtimes[k] or { continue }.as_array() {
			m := d.as_map()
			name := (m['name'] or { '' }).str()
			udid := (m['udid'] or { '' }).str()
			if want != '' {
				if want == name || want == udid {
					return udid
				}
				continue
			}
			if (m['state'] or { '' }).str() == 'Booted' {
				return udid
			}
			if first_iphone == '' && name.starts_with('iPhone') {
				first_iphone = udid
			}
		}
	}
	if want != '' {
		fail('simulator "${want}" not found (see `xcrun simctl list devices available`)')
	}
	if first_iphone == '' {
		fail('no iPhone simulator found — add one in Xcode (Window > Devices and Simulators)')
	}
	return first_iphone
}

fn (b IosBuild) run_device(app string, device string) {
	id := if device != '' { device } else { pick_device(b.xcrun) }
	step('installing on device ${id}')
	must(b.xcrun, ['devicectl', 'device', 'install', 'app', '--device', id, app])
	step('launching ${b.p.id} (Ctrl+C to stop)')
	run(b.xcrun, ['devicectl', 'device', 'process', 'launch', '--console', '--terminate-existing',
		'--device', id, b.p.id])
}

fn pick_device(xcrun string) string {
	json_file := os.join_path(os.temp_dir(), 'velo-devices.json')
	capture(xcrun, ['devicectl', 'list', 'devices', '--quiet', '--json-output', json_file])
	text := os.read_file(json_file) or { fail(err.msg()) }
	os.rm(json_file) or {}
	root := json2.decode[json2.Any](text) or {
		fail('cannot parse `devicectl list devices`: ${err}')
	}
	result := (root.as_map()['result'] or { json2.Any(map[string]json2.Any{}) }).as_map()
	for d in (result['devices'] or { json2.Any([]json2.Any{}) }).as_array() {
		m := d.as_map()
		hw := (m['hardwareProperties'] or { json2.Any(map[string]json2.Any{}) }).as_map()
		if (hw['platform'] or { '' }).str() == 'iOS' {
			return (m['identifier'] or { '' }).str()
		}
	}
	fail('no iOS device found — connect one (and enable Developer Mode), or pass --device <id>')
}
