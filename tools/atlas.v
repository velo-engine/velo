module main

import os
import toml
import stbi
import velo.assets
import velo.atlas
import velo.webp

const usage = 'Velo Engine texture atlas builder (run by `velo build` and `velo atlas`)

Usage:
  v run tools/atlas.v <assets dir> build <output dir>   pack every folder that has an atlas.toml
  v run tools/atlas.v <assets dir> list [folder]        show what would be packed (folder: relative to the assets dir)'

// Config — an atlas.toml. Every key is optional.
struct Config {
	dir       string // the folder, relative to the assets dir ('' = the assets dir itself)
	recursive bool = true
	exclude   []string
	max_size  int = 512
	page_size int = 2048
	padding   int = 1
}

struct Source {
	id      string
	path    string // relative to the assets dir
	abs     string
	w       int
	h       int
	nearest bool
}

struct Plan {
	cfg     Config
	name    string // file name prefix of its pages
	sources []Source
	skipped []string // why each image was left out
}

fn main() {
	args := os.args[1..]
	if args.len < 2 {
		println(usage)
		exit(1)
	}
	db := assets.open(args[0]) or { die(err.msg()) }
	plans := make_plans(db)
	match args[1] {
		'build' {
			if args.len < 3 {
				die('build needs an output directory')
			}
			build(plans, args[2])
		}
		'list' {
			folder := if args.len > 2 { norm_rel(args[2]) } else { '' }
			list(plans, folder)
		}
		else {
			die('unknown command "${args[1]}"\n\n${usage}')
		}
	}
}

@[noreturn]
fn die(msg string) {
	eprintln('velo atlas: ${msg}')
	exit(1)
}

fn norm_rel(p string) string {
	return p.replace('\\', '/').trim('/')
}

// config_dirs: every folder of the assets dir with an atlas.toml, relative, sorted (parents before children).
fn config_dirs(root string) []string {
	mut out := []string{}
	for f in os.walk_ext(root, atlas.config_file) {
		if os.file_name(f) != atlas.config_file {
			continue
		}
		rel := norm_rel(os.dir(f).all_after(root))
		if rel.split('/').any(it.starts_with('.')) || rel == 'library' || rel.starts_with('library/') {
			continue
		}
		out << rel
	}
	out.sort()
	return out
}

fn read_config(root string, dir string) Config {
	path := os.join_path(root, dir, atlas.config_file)
	doc := toml.parse_file(path) or { die('${path}: ${err}') }
	cfg := Config{
		dir:       dir
		recursive: doc.value('recursive').default_to(true).bool()
		exclude:   doc.value('exclude').default_to(toml.Any([]toml.Any{})).array().map(it.string())
		max_size:  doc.value('max_size').default_to(512).int()
		page_size: doc.value('page_size').default_to(2048).int()
		padding:   doc.value('padding').default_to(1).int()
	}
	if cfg.page_size < 64 || cfg.page_size > 8192 {
		die('${path}: page_size must be between 64 and 8192 (got ${cfg.page_size})')
	}
	if cfg.padding < 0 || cfg.padding > 16 {
		die('${path}: padding must be between 0 and 16 (got ${cfg.padding})')
	}
	if cfg.max_size < 1 || cfg.max_size + cfg.padding * 2 > cfg.page_size {
		die('${path}: max_size must be at least 1 and fit on a page with its padding (got ${cfg.max_size})')
	}
	return cfg
}

fn inside(path string, dir string) bool {
	return dir == '' || path.starts_with(dir + '/')
}

// make_plans picks the images of every atlas: a texture belongs to the closest folder above it that has an
// atlas.toml (a subfolder with its own atlas.toml is a separate atlas).
fn make_plans(db &assets.AssetDatabase) []Plan {
	dirs := config_dirs(db.root)
	cfgs := dirs.map(read_config(db.root, it))
	mut sources := [][]Source{len: cfgs.len}
	mut skipped := [][]string{len: cfgs.len}
	for e in db.all() {
		if e.kind != .texture {
			continue
		}
		mut owner := -1
		for i, d in dirs {
			if inside(e.path, d) && (owner < 0 || d.len > dirs[owner].len) {
				owner = i
			}
		}
		if owner < 0 {
			continue
		}
		cfg := cfgs[owner]
		local := if cfg.dir == '' { e.path } else { e.path[cfg.dir.len + 1..] }
		if !cfg.recursive && local.contains('/') {
			continue
		}
		name := os.file_name(local)
		if cfg.exclude.any(local.match_glob(it) || name.match_glob(it)) {
			skipped[owner] << '${e.path}: excluded'
			continue
		}
		abs := db.abs_path(e)
		w, h := assets.image_size(abs) or {
			skipped[owner] << '${e.path}: ${err}'
			continue
		}
		if w > cfg.max_size || h > cfg.max_size {
			skipped[owner] << '${e.path}: ${w}x${h} is larger than max_size ${cfg.max_size}'
			continue
		}
		sources[owner] << Source{
			id:      e.id
			path:    e.path
			abs:     abs
			w:       w
			h:       h
			nearest: (e.meta.settings['filter'] or { 'linear' }) == 'nearest'
		}
	}
	mut plans := []Plan{}
	for i, cfg in cfgs {
		plans << Plan{
			cfg:     cfg
			name:    if cfg.dir == '' { 'assets' } else { cfg.dir.replace('/', '_') }
			sources: sources[i]
			skipped: skipped[i]
		}
	}
	return plans
}

fn list(plans []Plan, folder string) {
	mut shown := 0
	for p in plans {
		if folder != '' && p.cfg.dir != folder {
			continue
		}
		shown++
		label := if p.cfg.dir == '' { 'assets/' } else { 'assets/${p.cfg.dir}/' }
		println('${label}${atlas.config_file}: ${p.sources.len} images')
		for s in p.sources {
			println('  ${s.path} (${s.w}x${s.h}${if s.nearest { ', nearest' } else { '' }})')
		}
		for s in p.skipped {
			println('  not packed: ${s}')
		}
	}
	if shown == 0 {
		println(if folder == '' {
			'no ${atlas.config_file} in the assets directory'
		} else {
			'no ${atlas.config_file} in assets/${folder}'
		})
	}
}

fn decode(path string) ![]u8 {
	bytes := os.read_bytes(path)!
	if webp.is_webp(bytes) {
		return webp.decode(bytes)!.rgba
	}
	img := stbi.load_from_memory(bytes.data, bytes.len, desired_channels: 4)!
	defer {
		img.free()
	}
	return unsafe { (&u8(img.data)).vbytes(img.width * img.height * 4) }.clone()
}

fn build(plans []Plan, out string) {
	os.rmdir_all(out) or {}
	os.mkdir_all(out) or { die(err.msg()) }
	mut m := atlas.Manifest{}
	mut total := 0
	for p in plans {
		for s in p.skipped {
			println('velo atlas: not packed: ${s}')
		}
		// linear and nearest textures go on separate pages: a page has one filter
		for nearest in [false, true] {
			group := p.sources.filter(it.nearest == nearest)
			if group.len == 0 {
				continue
			}
			items := group.map(atlas.Item{it.path, it.w, it.h})
			rects, sizes := atlas.pack(items, p.cfg.page_size, p.cfg.padding) or { die(err.msg()) }
			mut pages := sizes.map(atlas.new_page(it[0], it[1]))
			for i, s in group {
				r := rects[i]
				pixels := decode(s.abs) or { die('${s.path}: ${err}') }
				if pixels.len != s.w * s.h * 4 {
					die('${s.path}: decoded size does not match its header')
				}
				pages[r.page].blit(pixels, s.w, s.h, r.x, r.y, p.cfg.padding)
			}
			first := m.pages.len
			for i, page in pages {
				file := '${p.name}${if nearest { '_nearest' } else { '' }}_${i}.png'
				stbi.stbi_write_png(os.join_path(out, file), page.width, page.height, 4,
					page.pixels.data, page.width * 4) or { die('writing ${file}: ${err}') }
				m.pages << atlas.PageInfo{file, page.width, page.height, nearest}
				println('velo atlas: ${file} ${page.width}x${page.height}')
			}
			for i, s in group {
				r := rects[i]
				m.regions[s.id] = atlas.Rect{first + r.page, r.x, r.y, r.w, r.h}
			}
			total += group.len
		}
	}
	os.write_file(os.join_path(out, atlas.manifest_file), m.encode()) or { die(err.msg()) }
	println('velo atlas: packed ${total} images into ${m.pages.len} pages')
}
