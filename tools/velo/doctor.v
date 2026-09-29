module main

import os

// doctor reports which targets can be built on this machine, and what to install for the others.
fn doctor(home string) int {
	mut problems := 0
	println('Velo engine   ${home}')
	println('V             ${os.execute('${os.quoted_path(vexe())} version').output.trim_space()}')

	println('\nDesktop')
	if os.is_file('/opt/homebrew/include/box2d/box2d.h')
		|| os.is_file('/usr/local/include/box2d/box2d.h')
		|| os.is_file('/usr/include/box2d/box2d.h') {
		ok('Box2D system library (for velo.physics)')
	} else {
		warn('Box2D system library not found — only needed by games that use velo.physics: `brew install box2d`, or build with `-d box2d_source` after `velo deps`')
	}

	println('\nMobile')
	if os.is_file(os.join_path(box2d_dir(home), 'include', 'box2d', 'box2d.h')) {
		ok('Box2D sources in ${box2d_dir(home)}')
	} else {
		warn('Box2D sources not downloaded yet — done automatically by the first mobile build that uses velo.physics (or `velo deps`)')
	}

	println('\nAndroid')
	ensure_java_home()
	vab := os.find_abs_path_of_executable('vab') or {
		exe := os.join_path(os.vmodules_dir(), 'vab', 'vab')
		if os.is_file(exe) {
			exe
		} else {
			''
		}
	}
	if vab == '' {
		bad('vab not installed: `v install vab && v -prod ~/.vmodules/vab`')
		problems++
	} else {
		ok('vab ${vab}')
		res := os.execute('${os.quoted_path(vab)} doctor')
		java := os.join_path(os.getenv('JAVA_HOME'), 'bin', 'java')
		if os.getenv('JAVA_HOME') != '' && os.is_file(java) {
			ok('JDK ${os.getenv('JAVA_HOME')}')
		} else {
			bad('JDK not found — install Android Studio (it bundles one) or set JAVA_HOME')
			problems++
		}
		mut sdk := ''
		for key in ['SDK', 'NDK'] {
			section := res.output.all_after('\t${key}\n')
			path := section.all_after('Path').all_before('\n').trim_space().trim('"')
			if res.exit_code == 0 && path != '' && os.exists(path) {
				ok('${key} ${path}')
				if key == 'SDK' {
					sdk = path
				}
			} else {
				bad('${key} not found — install it with Android Studio (SDK Manager) or set ANDROID_SDK_ROOT / ANDROID_NDK_ROOT; `vab doctor` has details')
				problems++
			}
		}
		// vab builds against the highest API level both the SDK and the NDK support; packaging needs that
		// SDK platform installed.
		api := res.output.all_after('\tBuild\n').all_after('API').all_before('\n').trim_space()
		if sdk != '' && api != '' {
			if os.is_file(os.join_path(sdk, 'platforms', 'android-${api}', 'android.jar')) {
				ok('SDK platform android-${api}')
			} else {
				bad('SDK platform android-${api} (the build API level) is missing: `${os.quoted_path(vab)} install "platforms;android-${api}"`')
				problems++
			}
		}
	}

	println('\nWeb')
	if emcc := os.find_abs_path_of_executable('emcc') {
		ok('Emscripten ${os.execute('${os.quoted_path(emcc)} --version').output.all_before('\n').all_after_last(') ').trim_space()} (velo build web)')
	} else {
		warn('Emscripten not found — only needed for `velo build web`: `brew install emscripten`')
	}

	println('\niOS')
	$if macos {
		xcode := os.execute('xcodebuild -version')
		if xcode.exit_code == 0 {
			ok(xcode.output.split_into_lines()[0] or { 'Xcode' })
			sims := os.execute('xcrun simctl list devices available')
			if sims.output.contains('iPhone') {
				ok('iOS Simulator (velo run ios-sim)')
			} else {
				bad('no iPhone simulator — install an iOS runtime in Xcode (Settings > Components)')
				problems++
			}
			ids := os.execute('security find-identity -v -p codesigning')
			if ids.output.contains('Apple Development') || ids.output.contains('iPhone Developer') {
				ok('code signing identity (device builds)')
			} else {
				warn('no "Apple Development" signing identity — needed for devices only: sign in to your Apple ID in Xcode (Settings > Accounts)')
			}
		} else {
			bad('Xcode not found — install it from the App Store, then `sudo xcode-select -s /Applications/Xcode.app`')
			problems++
		}
	} $else {
		warn('iOS builds need macOS with Xcode')
	}
	return if problems > 0 { 1 } else { 0 }
}

fn ok(msg string) {
	println('  [ok]   ${msg}')
}

fn warn(msg string) {
	println('  [--]   ${msg}')
}

fn bad(msg string) {
	println('  [!!]   ${msg}')
}
