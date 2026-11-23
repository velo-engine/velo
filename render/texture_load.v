module render

import os
import gg
import stbi
import velo.assets
import velo.webp

// DecodedImage — RGBA pixels decoded off the main thread (see decode_image), waiting to be uploaded by adopt_image.
pub struct DecodedImage {
pub:
	width  int
	height int
	data   voidptr // stbi buffer, 4 bytes per pixel; adopt_image frees it
}

// decode_image reads and decodes an image file to RGBA. It touches no GPU state, so any thread may call it.
pub fn decode_image(path string) !DecodedImage {
	mut bytes := []u8{}
	if os.exists(path) {
		bytes = os.read_bytes(path)!
	} else {
		$if android {
			bytes = os.read_apk_asset(path)!
		} $else {
			return error('image file "${path}" not found')
		}
	}
	if webp.is_webp(bytes) {
		// stb_image has no WebP: decode with velo.webp (lossless VP8L) into a C buffer that free_decoded can free
		img := webp.decode(bytes)!
		buf := unsafe { malloc(isize(img.rgba.len)) } // freed by stbi (V free), see free_decoded
		if buf == unsafe { nil } {
			return error('out of memory decoding "${path}"')
		}
		unsafe { vmemcpy(buf, img.rgba.data, img.rgba.len) }
		return DecodedImage{img.width, img.height, buf}
	}
	img := stbi.load_from_memory(bytes.data, bytes.len)!
	return DecodedImage{img.width, img.height, img.data}
}

// free_decoded releases pixels that will not be uploaded after all.
pub fn free_decoded(img DecodedImage) {
	if img.data != unsafe { nil } {
		stbi.Image{
			data: img.data
		}.free()
	}
}

// has_image: the texture (at its current version) is already on the GPU.
pub fn (r &Renderer) has_image(t &assets.Texture) bool {
	if r.atlas_has(t) {
		return true
	}
	g := r.gpu[t.id] or { return false }
	return g.version == t.version
}

// adopt_image uploads pixels decoded ahead of time, so the first draw of `t` does not read and decode the file.
pub fn (mut r Renderer) adopt_image(t &assets.Texture, decoded DecodedImage) {
	if r.has_image(t) {
		free_decoded(decoded)
		return
	}
	if reg := r.atlas_match(t) {
		// preloaded from image_source: the pixels of its atlas page
		info := r.atlas.pages[reg.page].info
		if decoded.width == info.width && decoded.height == info.height {
			if r.atlas.pages[reg.page].has_gpu {
				free_decoded(decoded)
			} else {
				r.atlas_upload(reg.page, decoded)
			}
			r.atlas.pages[reg.page].users[t.id] = true
			return
		}
	}
	r.release_gpu(t.id)
	mut img := gg.Image{
		width:          decoded.width
		height:         decoded.height
		nr_channels:    4
		ok:             true
		data:           decoded.data
		path:           t.path
		texture_filter: if t.filter == 'nearest' {
			gg.TextureFilter.nearest
		} else {
			gg.TextureFilter.linear
		}
	}
	img.init_sokol_image()
	// sokol copied the pixels into the (immutable) GPU image
	free_decoded(decoded)
	img.data = unsafe { nil }
	img.id = r.ctx.cache_image(img)
	r.gpu[t.id] = GpuImage{img, t.version}
}
