module app

import os
import hash.fnv1a
import sokol.sapp
// On iOS, V emits the `sokol_main` entry point (instead of `main`) only when `sokol` itself is imported.
import sokol as _

// Where the game's assets live at runtime:
//   desktop  the configured assets directory (the project's assets/ folder)
//   iOS      <App>.app/assets, copied into the bundle by `velo build ios`
//   Android  the APK's assets, copied into the app's internal storage by extract_apk_assets
//            (the AssetDatabase needs real files: it scans directories and reads .meta files)

// is_mobile reports whether this build targets Android or iOS.
pub fn is_mobile() bool {
	$if android || ios {
		return true
	} $else {
		return false
	}
}

// Written next to the assets by `velo build android`: "<size> <path>" per file, packaged at the APK assets root.
const apk_manifest = 'velo_assets.txt'

fn runtime_assets_dir(configured string) !string {
	$if android {
		return extract_apk_assets()
	} $else $if ios {
		return os.join_path(ios_bundle_dir(), 'assets')
	} $else {
		return configured
	}
}

// extract_apk_assets copies the APK assets listed in velo_assets.txt to <internal storage>/assets.
// It only copies again when the manifest changed (i.e. after installing a different build).
fn extract_apk_assets() !string {
	$if android && apk {
		activity := unsafe { &os.NativeActivity(sapp.android_get_native_activity()) }
		if isnil(activity) || isnil(activity.internalDataPath) {
			return error('no Android activity, cannot locate internal storage')
		}
		data_dir := unsafe { cstring_to_vstring(activity.internalDataPath) }
		root := os.join_path(data_dir, 'assets')
		manifest := os.read_apk_asset(apk_manifest) or {
			return error('${apk_manifest} is missing from the APK — build with `velo build android`')
		}
		stamp_file := os.join_path(data_dir, 'assets.stamp')
		stamp := fnv1a.sum64(manifest).hex()
		if os.is_dir(root) && (os.read_file(stamp_file) or { '' }) == stamp {
			return root
		}
		os.rmdir_all(root) or {}
		mut count := 0
		for line in manifest.bytestr().split_into_lines() {
			size_str, rel := line.split_once(' ') or { continue }
			dst := os.join_path(root, rel)
			os.mkdir_all(os.dir(dst))!
			// read_apk_asset never returns for empty files, so they are created directly.
			data := if size_str.int() == 0 { []u8{} } else { os.read_apk_asset(rel)! }
			os.write_bytes(dst, data)!
			count++
		}
		os.write_file(stamp_file, stamp)!
		println('[velo] extracted ${count} assets to ${root}')
		return root
	} $else {
		return error('APK assets are only available in Android builds')
	}
}

$if ios {
	#include <mach-o/dyld.h>
}

fn C._NSGetExecutablePath(buf &char, size &u32) int

// ios_bundle_dir returns the .app directory (os.executable() does not work on iOS).
fn ios_bundle_dir() string {
	mut buf := [4096]u8{}
	mut size := u32(buf.len)
	if C._NSGetExecutablePath(&char(&buf[0]), &size) != 0 {
		return '.'
	}
	return os.dir(unsafe { cstring_to_vstring(&char(&buf[0])) })
}

// system_font returns a font file for text rendering on platforms where gg cannot find one by itself.
fn system_font() string {
	$if ios {
		// The simulator sees the host's file system; its iOS system files live under IPHONE_SIMULATOR_ROOT.
		root := os.getenv('IPHONE_SIMULATOR_ROOT')
		for f in ['Core/SFUI.ttf', 'CoreUI/SFUI.ttf', 'Core/CourierNew.ttf'] {
			path := root + '/System/Library/Fonts/' + f
			if os.is_file(path) {
				return path
			}
		}
	}
	return ''
}
