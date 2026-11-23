module main

import os

// Prebuilt texture atlases (see velo.atlas): `velo atlas [dir]` marks a folder of assets/ with an atlas.toml, and
// every packaged build packs those folders (tools/atlas.v) into build/atlas/, shipped as assets/library/atlas/.

const atlas_config = 'atlas.toml'

const atlas_template = '# Texture atlas: `velo build` / `velo run <mobile or web target>` pack the images of this folder into shared
# pages, so sprites that alternate between them draw in one batch (much faster on phones). Packed images are
# drawn from the pages by plain sprites; shaders, meshes and tile maps still use the image files, which are shipped
# too. A subfolder with its own atlas.toml is a separate atlas. `velo atlas` shows what gets packed.

recursive = true       # also pack the images of subfolders
exclude = []           # glob patterns (path relative to this folder, or file name), e.g. ["backgrounds/*", "*_big.png"]
max_size = 512         # images wider or taller than this keep their own texture
page_size = 2048       # largest page (pages are trimmed to what they hold); 2048 is safe on every phone
padding = 1            # edge pixels repeated around each image, so filtering never pulls in a neighbour
'

// GenFile — a file made by the build to ship with the assets.
struct GenFile {
	rel string // where it goes, relative to the shipped assets directory
	src string // the file on disk
}

// atlas_cmd: `velo atlas [dir]` — creates the atlas.toml of a folder inside assets/ (the current one by default;
// a project folder means its whole assets/), then lists the images it packs.
fn atlas_cmd(home string, args []string) int {
	mut dir := '.'
	for a in args {
		if a.starts_with('-') {
			fail('unknown option "${a}" for velo atlas')
		}
		dir = a
	}
	if !os.is_dir(dir) {
		fail('"${dir}" is not a directory')
	}
	mut folder := os.real_path(dir)
	mut root := assets_root_of(folder)
	if root == '' && os.is_dir(os.join_path(folder, 'assets')) {
		folder = os.real_path(os.join_path(folder, 'assets'))
		root = folder
	}
	if root == '' {
		fail('"${folder}" is not inside the assets/ folder of a Velo project')
	}
	rel := folder.all_after(root).replace('\\', '/').trim('/')
	if rel == 'library' || rel.starts_with('library/') || rel.split('/').any(it.starts_with('.')) {
		fail('assets/${rel} is never shipped: choose another folder')
	}
	cfg := os.join_path(folder, atlas_config)
	shown := if rel == '' { 'assets/${atlas_config}' } else { 'assets/${rel}/${atlas_config}' }
	if os.is_file(cfg) {
		step('${shown} already exists')
	} else {
		os.write_file(cfg, atlas_template) or { fail(err.msg()) }
		step('created ${shown}')
	}
	return v_cmd(home, ['run', os.join_path(home, 'tools', 'atlas.v')], [root, 'list', rel])
}

// assets_root_of: the nearest folder named assets/ that contains `dir` (or is it), or ''.
fn assets_root_of(dir string) string {
	mut cur := dir
	for {
		if os.file_name(cur) == 'assets' {
			return cur
		}
		parent := os.dir(cur)
		if parent == cur || parent == '' || parent == '.' {
			return ''
		}
		cur = parent
	}
	return ''
}

fn has_atlas_config(p Project) bool {
	for f in os.walk_ext(p.assets_dir(), atlas_config) {
		if os.file_name(f) == atlas_config {
			return true
		}
	}
	return false
}

// build_atlases packs every folder with an atlas.toml into build/atlas/ and returns the files to ship (none when
// the project has no atlas).
fn build_atlases(home string, p Project) []GenFile {
	out := p.build_dir('atlas')
	if !has_atlas_config(p) {
		os.rmdir_all(out) or {}
		return []
	}
	step('packing texture atlases')
	if v_cmd(home, ['run', os.join_path(home, 'tools', 'atlas.v')], [p.assets_dir(), 'build', out]) != 0 {
		fail('packing the texture atlases failed (see the errors above)')
	}
	mut files := os.ls(out) or { fail(err.msg()) }
	files.sort()
	return files.map(GenFile{'library/atlas/${it}', os.join_path(out, it)})
}

// copy_gen_files copies the generated files into a shipped assets directory.
fn copy_gen_files(gen []GenFile, dest string) {
	for g in gen {
		dst := os.join_path(dest, g.rel)
		os.mkdir_all(os.dir(dst)) or { fail(err.msg()) }
		os.cp(g.src, dst) or { fail('copy ${g.rel}: ${err}') }
	}
}
