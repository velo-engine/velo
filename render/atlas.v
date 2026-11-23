module render

import os
import gg
import velo.assets
import velo.atlas

// Texture atlas: sprites that alternate between many textures stay on one GPU texture when those textures were
// packed together. Switching textures is cheap on desktop but costs a lot on phones (the bench in examples/bench:
// 20000 sprites on 16 textures took 2.7x as long as on one, on Android).
//
// The atlases are built ahead of time, never at runtime: a folder of assets/ with an atlas.toml (`velo atlas`) has
// its images packed by `velo build` into pages shipped in assets/library/atlas/ with a manifest (see velo.atlas).
// new_renderer reads the manifest; a page is uploaded the first time a sprite on one of its textures is drawn (or
// preloaded) and freed when no texture drawn from it is loaded any more. Without a manifest (a game run from its
// project folder) every texture is its own GPU image.
//
// Sprites without a shader use it, sliced and tiled ones included (their pieces have their own UVs, no repeat).
// Shaded sprites, meshes and tile maps need the texture on its own (the shader's UV built-ins, the meshes' UVs)
// and keep using image_for, from the texture's own file (which is shipped too). A texture can be in both.

struct AtlasRegion {
	page int
	x    int // where the texture's own pixels start (inside the padding)
	y    int
	w    int
	h    int
mut:
	// the texture's version when it was first drawn from the page; a later version (reloaded from disk) no longer
	// matches the packed pixels and draws on its own. -1: not seen yet.
	version int = -1
}

// AtlasPage — one page file and its GPU image, uploaded while a texture drawn from it is loaded.
struct AtlasPage {
	info atlas.PageInfo
mut:
	img     gg.Image
	has_gpu bool
	users   map[string]bool // loaded textures drawn from the page
}

struct Atlas {
mut:
	dir     string                 // where the pages are
	regions map[string]AtlasRegion // texture ID -> where it is
	pages   []AtlasPage
	retired []int // GPU images freed this frame: still used by queued draws, freed two frames later
	old     []int
	frame   u64
	// Bumped whenever a page image changes: AtlasCache entries from an older generation are stale.
	gen u64
}

// AtlasCache — a sprite's last atlas lookup, so drawing does not hash the texture ID every frame. Valid while it is
// from the same renderer, the atlas has not changed since (gen), and the texture is the same at the same version.
struct AtlasCache {
	owner   voidptr
	gen     u64
	tex     voidptr
	version int
	img     int
	x       int
	y       int
}

// atlas_cached: the sprite's cached lookup, if still valid.
fn (r &Renderer) atlas_cached(s &Sprite) ?(int, int, int) {
	c := s.atlas_cache
	if r.atlas_on && c.owner == voidptr(r) && c.gen == r.atlas.gen && c.tex == voidptr(s.tex)
		&& c.version == s.tex.version {
		return c.img, c.x, c.y
	}
	return none
}

// atlas_load reads the manifest of the prebuilt atlas (new_renderer does it). No manifest: no atlas.
fn (mut r Renderer) atlas_load() {
	r.atlas.dir = os.join_path(r.db.root, atlas.out_dir)
	path := os.join_path(r.atlas.dir, atlas.manifest_file)
	if !os.is_file(path) {
		return
	}
	src := os.read_file(path) or {
		eprintln('[velo] atlas: ${err}')
		return
	}
	m := atlas.parse_manifest(src) or {
		eprintln('[velo] atlas: ${path}: ${err}')
		return
	}
	for p in m.pages {
		r.atlas.pages << AtlasPage{
			info: p
		}
	}
	for id, reg in m.regions {
		r.atlas.regions[id] = AtlasRegion{reg.page, reg.x, reg.y, reg.w, reg.h, -1}
	}
}

// atlas_match: where `t` is packed, when it is and the packed pixels are still the texture's.
fn (r &Renderer) atlas_match(t &assets.Texture) ?AtlasRegion {
	if !r.atlas_on {
		return none
	}
	reg := r.atlas.regions[t.id] or { return none }
	if reg.w != t.width || reg.h != t.height {
		return none // the file changed since the build
	}
	if reg.version >= 0 && reg.version != t.version {
		return none // reloaded from disk
	}
	return reg
}

// atlas_region: atlas_match, remembering the texture's version the first time.
fn (mut r Renderer) atlas_region(t &assets.Texture) ?AtlasRegion {
	mut reg := r.atlas_match(t)?
	if reg.version < 0 {
		reg.version = t.version
		r.atlas.regions[t.id] = reg
	}
	return reg
}

// atlas_begin_frame frees the GPU images released two frames ago (call once per drawn frame).
fn (mut r Renderer) atlas_begin_frame() {
	if r.atlas.frame == r.ctx.frame {
		return
	}
	r.atlas.frame = r.ctx.frame
	for id in r.atlas.old {
		r.ctx.remove_cached_image_by_idx(id)
	}
	r.atlas.old = r.atlas.retired.clone()
	r.atlas.retired.clear()
}

// atlas_lookup returns the page image and the texture's offset in it, uploading the page on first use.
fn (mut r Renderer) atlas_lookup(t &assets.Texture) ?(int, int, int) {
	reg := r.atlas_region(t) or { return none }
	r.atlas_begin_frame()
	if !r.atlas.pages[reg.page].has_gpu {
		decoded := decode_image(r.atlas_page_path(reg.page)) or {
			eprintln('[velo] atlas page ${r.atlas.pages[reg.page].info.file}: ${err}')
			r.atlas.regions.delete(t.id) // draw it on its own from now on
			return none
		}
		if !r.atlas_upload(reg.page, decoded) {
			free_decoded(decoded)
			r.atlas.regions.delete(t.id)
			return none
		}
	}
	mut p := &r.atlas.pages[reg.page]
	p.users[t.id] = true
	return p.img.id, reg.x, reg.y
}

fn (r &Renderer) atlas_page_path(page int) string {
	return os.join_path(r.atlas.dir, r.atlas.pages[page].info.file)
}

// atlas_upload makes the decoded pixels of page `i` its GPU image and frees them. False: not the page's size
// (the pixels are still the caller's).
fn (mut r Renderer) atlas_upload(i int, decoded DecodedImage) bool {
	mut p := &r.atlas.pages[i]
	if decoded.width != p.info.width || decoded.height != p.info.height {
		eprintln('[velo] atlas page ${p.info.file} is ${decoded.width}x${decoded.height}, the manifest says ${p.info.width}x${p.info.height}')
		return false
	}
	mut img := gg.Image{
		width:          decoded.width
		height:         decoded.height
		nr_channels:    4
		ok:             true
		data:           decoded.data
		path:           'velo atlas ${p.info.file}'
		texture_filter: if p.info.nearest {
			gg.TextureFilter.nearest
		} else {
			gg.TextureFilter.linear
		}
	}
	img.init_sokol_image() // sokol copies the pixels into the GPU image
	free_decoded(decoded)
	img.data = unsafe { nil }
	img.id = r.ctx.cache_image(img)
	p.img = img
	p.has_gpu = true
	r.atlas.gen++
	return true
}

// atlas_forget: the texture was unloaded or deleted. A page no loaded texture is drawn from is freed.
fn (mut r Renderer) atlas_forget(id string) {
	mut reg := r.atlas.regions[id] or { return }
	reg.version = -1 // loaded again later, it starts over at its new version
	r.atlas.regions[id] = reg
	mut p := &r.atlas.pages[reg.page]
	if id !in p.users {
		return
	}
	p.users.delete(id)
	if p.users.len == 0 && p.has_gpu {
		r.atlas.retired << p.img.id
		p.has_gpu = false
		r.atlas.gen++
	}
}

// atlas_has: the texture is drawn from a page that is on the GPU.
fn (r &Renderer) atlas_has(t &assets.Texture) bool {
	reg := r.atlas_match(t) or { return false }
	return r.atlas.pages[reg.page].has_gpu
}

// image_source: the file to decode ahead of time for `t` (see Preloader) — its atlas page when it is packed, so
// adopt_image gets the page.
pub fn (r &Renderer) image_source(t &assets.Texture) string {
	if reg := r.atlas_match(t) {
		return r.atlas_page_path(reg.page)
	}
	return t.path
}
