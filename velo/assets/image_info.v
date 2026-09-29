module assets

import os

// image_size reads the image size from its header (PNG / JPEG / BMP) without decoding
// and without a GPU — so AssetDatabase works in tools and unit tests too.
pub fn image_size(path string) !(int, int) {
	mut f := os.open(path)!
	defer {
		f.close()
	}
	mut head := []u8{len: 64 * 1024}
	n := f.read(mut head) or { 0 }
	b := unsafe { head[..n] }
	if b.len >= 24 && b[0] == 0x89 && b[1] == `P` && b[2] == `N` && b[3] == `G` {
		return be32(b, 16), be32(b, 20)
	}
	if b.len >= 26 && b[0] == `B` && b[1] == `M` {
		w := int(u32(b[18]) | u32(b[19]) << 8 | u32(b[20]) << 16 | u32(b[21]) << 24)
		mut h := int(u32(b[22]) | u32(b[23]) << 8 | u32(b[24]) << 16 | u32(b[25]) << 24)
		if h < 0 {
			h = -h
		}
		return w, h
	}
	if b.len >= 4 && b[0] == 0xFF && b[1] == 0xD8 {
		mut i := 2
		for i + 9 < b.len {
			if b[i] != 0xFF {
				i++
				continue
			}
			marker := b[i + 1]
			seg_len := int(u32(b[i + 2]) << 8 | u32(b[i + 3]))
			if marker in [u8(0xC0), 0xC1, 0xC2] {
				h := int(u32(b[i + 5]) << 8 | u32(b[i + 6]))
				w := int(u32(b[i + 7]) << 8 | u32(b[i + 8]))
				return w, h
			}
			i += 2 + seg_len
		}
	}
	return error('cannot read image size: ${path}')
}

fn be32(b []u8, off int) int {
	return int(u32(b[off]) << 24 | u32(b[off + 1]) << 16 | u32(b[off + 2]) << 8 | u32(b[off + 3]))
}
