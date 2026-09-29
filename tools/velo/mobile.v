module main

import os

// Steps shared by the Android and iOS builds.

const box2d_version = 'v3.1.1'

fn box2d_dir(home string) string {
	return os.join_path(home, 'thirdparty', 'box2d')
}

// ensure_box2d downloads the Box2D sources that physics/box2d.v compiles into mobile builds.
fn ensure_box2d(home string) {
	dir := box2d_dir(home)
	if os.is_file(os.join_path(dir, 'include', 'box2d', 'box2d.h')) {
		return
	}
	git := os.find_abs_path_of_executable('git') or { fail('`git` is needed to download Box2D') }
	step('downloading Box2D ${box2d_version} into ${dir}')
	os.rmdir_all(dir) or {}
	must(git, ['-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1', '--branch',
		box2d_version, 'https://github.com/erincatto/box2d.git', dir])
}

// uses_physics reports whether the game imports velo.physics (which then needs the Box2D sources).
fn uses_physics(p Project) bool {
	for f in os.walk_ext(p.dir, '.v') {
		if f.contains('${os.path_separator}build${os.path_separator}') {
			continue
		}
		src := os.read_file(f) or { continue }
		if src.contains('velo.physics') {
			return true
		}
	}
	return false
}

// prepare_mobile_build runs the steps every packaged build needs before compiling.
fn prepare_mobile_build(home string, p Project) {
	// Opening the database creates any missing .meta files — the packaged copy is read-only, so the IDs
	// must exist (and be committed) before packaging. `check` also stops the build on broken references.
	step('checking assets')
	if assetdb(home, p.assets_dir(), ['check']) != 0 {
		fail('fix the asset errors above before building (see `velo assets check`)')
	}
	if uses_physics(p) {
		ensure_box2d(home)
	}
}

// packaged_assets lists the asset files to ship, relative to assets/ with '/' separators (hidden files excluded).
fn packaged_assets(p Project) []string {
	root := p.assets_dir()
	mut out := []string{}
	for f in os.walk_ext(root, '') {
		rel := f.all_after(root).trim_left('/\\').replace('\\', '/')
		if rel.split('/').any(it.starts_with('.')) || rel.starts_with('library/') {
			continue
		}
		out << rel
	}
	out.sort()
	return out
}
