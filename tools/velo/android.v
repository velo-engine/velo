module main

import os

// Android builds are compiled and packaged by vab (https://github.com/vlang/vab), V's Android tool:
// it cross-compiles for every ABI with the NDK, then packages, signs and deploys the APK/AAB.
// velo adds the game settings from velo.toml, the module path for `import velo.*`, and velo_assets.txt:
// the list of files that app.new copies out of the APK on first launch (see app/platform.v).

fn find_vab() string {
	if path := os.find_abs_path_of_executable('vab') {
		return path
	}
	src := os.join_path(os.vmodules_dir(), 'vab')
	exe := os.join_path(src, 'vab')
	if os.is_file(exe) {
		return exe
	}
	if os.is_file(os.join_path(src, 'vab.v')) {
		step('building vab')
		must(vexe(), ['-prod', src, '-o', exe])
		return exe
	}
	fail('vab is not installed. Install it with:\n  v install vab && v -prod ~/.vmodules/vab\nthen check the Android setup with `velo doctor`')
}

// ensure_java_home points JAVA_HOME at a JDK for vab (keytool, jarsigner, ...), falling back to the one bundled
// with Android Studio. vab runs the JDK tools through a shell without quoting, so a path with spaces (like
// "Android Studio.app") is replaced by a space-free symlink in the user cache directory.
fn ensure_java_home() {
	mut jdk := os.getenv('JAVA_HOME')
	if jdk == '' {
		for dir in ['/Applications/Android Studio.app/Contents/jbr/Contents/Home',
			os.join_path(os.home_dir(), 'Applications', 'Android Studio.app', 'Contents', 'jbr',
				'Contents', 'Home'),
			'/opt/android-studio/jbr', os.join_path(os.home_dir(), 'android-studio', 'jbr')] {
			if os.is_dir(dir) {
				jdk = dir
				break
			}
		}
	}
	if jdk.contains(' ') {
		link := os.join_path(os.cache_dir(), 'velo', 'jdk')
		if os.real_path(link) != os.real_path(jdk) {
			os.mkdir_all(os.dir(link)) or {}
			os.rm(link) or {}
			os.symlink(jdk, link) or {}
		}
		if !link.contains(' ') && os.is_dir(link) {
			jdk = link
		}
	}
	if jdk != '' {
		os.setenv('JAVA_HOME', jdk, true)
		// vab takes javac/keytool from PATH first
		os.setenv('PATH', os.join_path(jdk, 'bin') + os.path_delimiter + os.getenv('PATH'), true)
	}
}

fn build_android(home string, p Project, o MobileOptions) {
	vab := find_vab()
	ensure_java_home()
	prepare_mobile_build(home, p)

	build_dir := p.build_dir('android')
	extra := os.join_path(build_dir, 'apk_assets')
	os.rmdir_all(extra) or {}
	os.mkdir_all(extra) or { fail(err.msg()) }
	mut manifest := []string{}
	for rel in packaged_assets(p) {
		manifest << '${os.file_size(os.join_path(p.assets_dir(), rel))} ${rel}'
	}
	os.write_file(os.join_path(extra, 'velo_assets.txt'), manifest.join('\n') + '\n') or {
		fail(err.msg())
	}

	ext := if o.aab { 'aab' } else { 'apk' }
	output := if o.output != '' { o.output } else { os.join_path(build_dir, '${p.bin}.${ext}') }
	mut args := [
		'--name',
		p.name,
		'--package-id',
		p.id,
		'--version-code',
		p.build.str(),
		'--package',
		ext,
		// vab runs `v` through a shell, hence the quotes around the `|`-separated path.
		'-f',
		"-path '${v_path(home)}'",
		'-a',
		extra,
		'-o',
		output,
	]
	if o.release {
		args << '-prod'
	}
	if verbose() {
		args << ['-v', '3']
	}
	if p.icon != '' {
		args << ['--icon', p.icon]
	}
	if p.min_sdk > 0 {
		args << ['--min-sdk-version', p.min_sdk.str()]
	}
	if p.keystore != '' {
		args << ['--keystore', p.keystore]
		if p.keystore_alias != '' {
			args << ['--keystore-alias', p.keystore_alias]
		}
	}
	if o.run {
		// vab installs, launches and then streams the device log until Ctrl+C.
		args << ['--device', if o.device != '' { o.device } else { 'auto' }, '--log']
	}
	args << p.dir
	step('building ${p.name} for Android (${if o.release { 'release' } else { 'debug' }})')
	// vab also packages an assets/ folder found in the working directory: make that the project's own.
	os.chdir(p.dir) or { fail(err.msg()) }
	if run(vab, args) != 0 {
		fail('Android build failed — `velo doctor` checks the SDK/NDK/Java setup')
	}
	if !o.run {
		step('built ${output}')
	}
}
