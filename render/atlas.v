module render

import gg
import velo.assets

// Texture atlas: small textures are packed into shared 2048x2048 pages so sprites that alternate between many
// textures stay on one GPU texture. Switching textures is cheap on desktop but costs a lot on phones (the bench in
// examples/bench: 20000 sprites on 16 textures took 2.7x as long as on one, on Android).
//
// Only plain sprites use it (Sprite in simple draw mode, no shader): sliced and tiled sprites, meshes and tile maps
// need the texture on its own (repeat, UVs) and keep using image_for. A texture can be in both.
//
// Packing is a shelf packer; every texture gets a 1 pixel border copied from its edge so linear filtering and
// rotation never pull in a neighbour's pixels. Space of unloaded textures is not reused; when no texture is left
// the pages are dropped, so the usual scene change cleans up.

const atlas_page_size = 2048
const atlas_max_texture = 512 // larger textures keep their own GPU image

struct AtlasSlot {
	page    int
	x       int // where the texture's own pixels start (inside the border)
	y       int
	version int
}

// AtlasPage — the pixels of one page (kept on the CPU: adding a texture uploads the page again) and its GPU image.
struct AtlasPage {
	nearest bool
mut:
	pixels  []u8
	cx      int // shelf packer: next free x on the current row
	cy      int // top of the current row
	row_h   int
	img     gg.Image
	has_gpu bool
	dirty   bool
}

fn new_page(nearest bool) AtlasPage {
	return AtlasPage{
		nearest: nearest
		pixels:  []u8{len: atlas_page_size * atlas_page_size * 4}
	}
}

// alloc reserves room for a w x h texture plus its border; returns where its own pixels start.
fn (mut p AtlasPage) alloc(w int, h int) ?(int, int) {
	bw := w + 2
	bh := h + 2
	if bw > atlas_page_size || bh > atlas_page_size {
		return none
	}
	if p.cx + bw > atlas_page_size { // next row
		p.cy += p.row_h
		p.cx = 0
		p.row_h = 0
	}
	if p.cy + bh > atlas_page_size {
		return none
	}
	x := p.cx + 1
	y := p.cy + 1
	p.cx += bw
	if bh > p.row_h {
		p.row_h = bh
	}
	return x, y
}

// blit copies RGBA pixels (w x h, `src` points at them) to (x, y) and replicates the outer pixels into the border.
fn (mut p AtlasPage) blit(src voidptr, w int, h int, x int, y int) {
	s := unsafe { &u8(src) }
	stride := atlas_page_size * 4
	for row in -1 .. h + 1 {
		sr := if row < 0 {
			0
		} else if row >= h {
			h - 1
		} else {
			row
		}
		dst := (y + row) * stride + x * 4
		unsafe {
			vmemcpy(&p.pixels[dst], &s[sr * w * 4], w * 4)
			vmemcpy(&p.pixels[dst - 4], &s[sr * w * 4], 4) // left border = first pixel
			vmemcpy(&p.pixels[dst + w * 4], &s[sr * w * 4 + (w - 1) * 4], 4) // right border = last pixel
		}
	}
	p.dirty = true
}

struct Atlas {
mut:
	pages   []AtlasPage
	slots   map[string]AtlasSlot // texture ID -> where it is
	retired []int                // GPU images replaced this frame: still used by queued draws, freed two frames later
	old     []int
	frame   u64
}

// atlas_fits: the texture is small enough, and the atlas is on.
fn (r &Renderer) atlas_fits(t &assets.Texture) bool {
	return r.atlas_on && t.width > 0 && t.height > 0 && t.width <= atlas_max_texture
		&& t.height <= atlas_max_texture
}

// atlas_begin_frame frees the GPU images replaced two frames ago (call once per drawn frame).
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

// atlas_add packs decoded pixels and frees them. On false the texture does not fit and the pixels are still the
// caller's (to upload on their own, or to free).
fn (mut r Renderer) atlas_add(t &assets.Texture, decoded DecodedImage) bool {
	if decoded.width != t.width || decoded.height != t.height || decoded.width > atlas_max_texture
		|| decoded.height > atlas_max_texture {
		return false
	}
	nearest := t.filter == 'nearest'
	for i in 0 .. r.atlas.pages.len {
		if r.atlas.pages[i].nearest != nearest {
			continue
		}
		if x, y := r.atlas.pages[i].alloc(decoded.width, decoded.height) {
			r.atlas.pages[i].blit(decoded.data, decoded.width, decoded.height, x, y)
			r.atlas.slots[t.id] = AtlasSlot{i, x, y, t.version}
			free_decoded(decoded)
			return true
		}
	}
	mut page := new_page(nearest)
	x, y := page.alloc(decoded.width, decoded.height) or { return false }
	page.blit(decoded.data, decoded.width, decoded.height, x, y)
	r.atlas.pages << page
	r.atlas.slots[t.id] = AtlasSlot{r.atlas.pages.len - 1, x, y, t.version}
	free_decoded(decoded)
	return true
}

// atlas_lookup returns the page image and the texture's offset in it, packing the texture on first use.
fn (mut r Renderer) atlas_lookup(t &assets.Texture) ?(int, int, int) {
	if !r.atlas_fits(t) {
		return none
	}
	r.atlas_begin_frame()
	if s := r.atlas.slots[t.id] {
		if s.version == t.version {
			return r.atlas_page_image(s.page), s.x, s.y
		}
		r.atlas.slots.delete(t.id) // reloaded from disk: pack the new pixels
	}
	decoded := decode_image(t.path) or { return none }
	if !r.atlas_add(t, decoded) {
		free_decoded(decoded)
		return none
	}
	s := r.atlas.slots[t.id] or { return none }
	return r.atlas_page_image(s.page), s.x, s.y
}

// atlas_page_image: the page's GPU image id, uploading the page again if textures were added since.
fn (mut r Renderer) atlas_page_image(i int) int {
	mut p := &r.atlas.pages[i]
	if p.has_gpu && !p.dirty {
		return p.img.id
	}
	if p.has_gpu {
		r.atlas.retired << p.img.id
	}
	mut img := gg.Image{
		width:          atlas_page_size
		height:         atlas_page_size
		nr_channels:    4
		ok:             true
		data:           p.pixels.data
		path:           'velo atlas page ${i}'
		texture_filter: if p.nearest { gg.TextureFilter.nearest } else { gg.TextureFilter.linear }
	}
	img.init_sokol_image() // sokol copies the pixels into the GPU image
	img.data = unsafe { nil }
	img.id = r.ctx.cache_image(img)
	p.img = img
	p.has_gpu = true
	p.dirty = false
	return img.id
}

// atlas_forget: the texture was unloaded or deleted. With nothing left in the atlas the pages are dropped.
fn (mut r Renderer) atlas_forget(id string) {
	if id !in r.atlas.slots {
		return
	}
	r.atlas.slots.delete(id)
	if r.atlas.slots.len == 0 {
		for p in r.atlas.pages {
			if p.has_gpu {
				r.atlas.retired << p.img.id
			}
		}
		r.atlas.pages.clear()
	}
}

// atlas_has: the texture is packed at its current version.
fn (r &Renderer) atlas_has(t &assets.Texture) bool {
	s := r.atlas.slots[t.id] or { return false }
	return s.version == t.version
}

// AtlasPageTest — lets tests drive the packer without a GPU.
pub struct AtlasPageTest {
mut:
	page AtlasPage
}

pub fn new_atlas_page_test() AtlasPageTest {
	return AtlasPageTest{
		page: new_page(false)
	}
}

pub fn (mut t AtlasPageTest) alloc(w int, h int) ?(int, int) {
	return t.page.alloc(w, h)
}

pub fn (mut t AtlasPageTest) blit(src voidptr, w int, h int, x int, y int) {
	t.page.blit(src, w, h, x, y)
}

pub fn (t &AtlasPageTest) pixel(x int, y int) []u8 {
	i := (y * atlas_page_size + x) * 4
	return t.page.pixels[i..i + 4].clone()
}
