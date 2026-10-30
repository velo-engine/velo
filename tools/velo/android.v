module main

import os
import hash.fnv1a
import zztkm.vdotenv

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

const vactivity_template = 'package io.v.android;

import android.app.NativeActivity;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;

public class VActivity extends NativeActivity {
	static { System.loadLibrary("v"); }
	private static VActivity thiz;

	public VActivity() { thiz = this; }
	public static VActivity getVActivity() {
		return thiz;
	}

	@Override
	protected void onCreate(Bundle savedInstanceState) {
		super.onCreate(savedInstanceState);
		hideSystemUI();
	}

	@Override
	protected void onResume() {
		super.onResume();
		hideSystemUI();
	}

	@Override
	public void onWindowFocusChanged(boolean hasFocus) {
		super.onWindowFocusChanged(hasFocus);
		if (hasFocus) {
			hideSystemUI();
		}
	}

	public void hideSystemUI() {
		runOnUiThread(new Runnable() {
			@Override
			public void run() {
				Window window = getWindow();
				if (window == null) return;

				if (Build.VERSION.SDK_INT >= 28) {
					WindowManager.LayoutParams lp = window.getAttributes();
					lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
					window.setAttributes(lp);
				}

				if (Build.VERSION.SDK_INT >= 30) {
					window.setDecorFitsSystemWindows(false);
					WindowInsetsController controller = window.getInsetsController();
					if (controller != null) {
						controller.hide(WindowInsets.Type.navigationBars() | WindowInsets.Type.statusBars());
						controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
					}
				}

				View decorView = window.getDecorView();
				if (decorView != null) {
					decorView.setSystemUiVisibility(
						View.SYSTEM_UI_FLAG_LAYOUT_STABLE
						| View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
						| View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
						| View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
						| View.SYSTEM_UI_FLAG_FULLSCREEN
						| View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
					);
				}
			}
		});
	}
}
'

fn ensure_vactivity(vab_exe string) {
	vab_dir := os.dir(vab_exe)
	candidates := [
		os.join_path(vab_dir, 'platforms', 'android', 'src', 'io', 'v', 'android', 'VActivity.java'),
		os.join_path(os.vmodules_dir(), 'vab', 'platforms', 'android', 'src', 'io', 'v', 'android', 'VActivity.java'),
	]
	for path in candidates {
		if os.is_file(path) {
			src := os.read_file(path) or { continue }
			if !src.contains('hideSystemUI') {
				os.write_file(path, vactivity_template) or {}
			}
		}
	}
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

// load_android_env reads <project>/.env (variables already set in the shell win) for vab's settings such as
// AAPT2, and maps the documented VAB_KS_PASS / VAB_KS_ALIAS_PASS to the KEYSTORE_PASSWORD /
// KEYSTORE_ALIAS_PASSWORD names that vab reads. Keep the file out of version control: it holds passwords.
fn load_android_env(p Project) {
	env_file := os.join_path(p.dir, '.env')
	if os.is_file(env_file) {
		vdotenv.load(env_file) or { fail('cannot read ${env_file}: ${err.msg()}') }
	}
	for from, to in {
		'VAB_KS_PASS':       'KEYSTORE_PASSWORD'
		'VAB_KS_ALIAS_PASS': 'KEYSTORE_ALIAS_PASSWORD'
	} {
		if os.getenv(from) != '' && os.getenv(to) == '' {
			os.setenv(to, os.getenv(from), true)
		}
	}
}

fn build_android(home string, p Project, o MobileOptions) {
	vab := find_vab()
	ensure_vactivity(vab)
	load_android_env(p)
	ensure_java_home()
	prepare_mobile_build(home, p)

	build_dir := p.build_dir('android')
	extra := os.join_path(build_dir, 'apk_assets')
	os.rmdir_all(extra) or {}
	os.mkdir_all(extra) or { fail(err.msg()) }
	mut manifest := []string{}
	for rel in packaged_assets(p) {
		// the hash makes the manifest (and so the app's re-extraction check) change whenever any file does
		data := os.read_bytes(os.join_path(p.assets_dir(), rel)) or { fail(err.msg()) }
		manifest << '${data.len} ${fnv1a.sum64(data).hex()} ${rel}'
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
		'--version-name',
		p.version,
		'--package',
		ext,
		// vab runs `v` through a shell, hence the quotes around the `|`-separated path.
		'-f',
		"-path '${v_path(home)}'",
		'-a',
		extra,
		'-o',
		output,
		'-gc',
		'none',
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
	// sokol_audio uses AAudio, which the NDK only declares from API 26 (Android 8)
	min_sdk := if p.min_sdk > 26 { p.min_sdk } else { 26 }
	args << ['--min-sdk-version', min_sdk.str()]
	if p.keystore != '' {
		args << ['--keystore', p.keystore]
		if p.keystore_alias != '' {
			args << ['--keystore-alias', p.keystore_alias]
		}
	}
	if o.run {
		// `vab ... run <dir>` installs, launches and then streams the device log until Ctrl+C.
		args << ['--device', if o.device != '' { o.device } else { 'auto' }, '--log', 'run']
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
