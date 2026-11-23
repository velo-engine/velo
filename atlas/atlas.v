module atlas

import strings

// Prebuilt texture atlases. A folder inside assets/ with an `atlas.toml` (made by `velo atlas`) has its images packed
// into shared pages by `velo build`; the pages and a manifest are shipped in assets/library/atlas/ and the
// renderer draws plain sprites from them (see render/atlas.v). Nothing is packed at runtime.
//
// This module is the part shared by the build tool (tools/atlas.v) and the runtime: the packer, the pixel copy with
// its edge border, and the manifest format. It needs no GPU.

// config_file: the file that marks a folder as an atlas (its images, and those of its subfolders).
pub const config_file = 'atlas.toml'

// out_dir: where the pages and the manifest go, relative to the assets directory (library/ is never scanned as assets).
pub const out_dir = 'library/atlas'

// manifest_file: the manifest's name inside out_dir.
pub const manifest_file = 'atlas.txt'

const manifest_header = 'velo-atlas 1'

// Rect — a placed image: where its own pixels start (inside the padding) on page `page`.
pub struct Rect {
pub mut:
	page int
	x    int
	y    int
	w    int
	h    int
}

// Item — an image to pack.
pub struct Item {
pub:
	key string
	w   int
	h   int
}

// pack places every item on pages of at most page_size x page_size, with `padding` pixels around each one. Larger
// items first, rows (shelves) filled left to right; a new page starts when one is full. Returns one Rect per item
// (same order) and the used size of every page (pages are trimmed to what they hold, rounded up to 4 pixels).
pub fn pack(items []Item, page_size int, padding int) !([]Rect, [][2]int) {
	mut order := []int{len: items.len, init: index}
	order.sort_with_compare(fn [items] (a &int, b &int) int {
		ia, ib := items[*a], items[*b]
		if ia.h != ib.h {
			return if ia.h > ib.h { -1 } else { 1 }
		}
		if ia.w != ib.w {
			return if ia.w > ib.w { -1 } else { 1 }
		}
		return if ia.key < ib.key {
			-1
		} else if ia.key > ib.key {
			1
		} else {
			0
		}
	})
	mut out := []Rect{len: items.len}
	mut sizes := [][2]int{}
	mut shelves := []Shelf{} // of the current page
	mut page := -1
	mut used_w := 0
	mut used_h := 0
	for i in order {
		it := items[i]
		bw := it.w + padding * 2
		bh := it.h + padding * 2
		if it.w <= 0 || it.h <= 0 || bw > page_size || bh > page_size {
			return error('"${it.key}" (${it.w}x${it.h}) does not fit on a ${page_size}x${page_size} page')
		}
		mut placed := false
		if page >= 0 {
			// the first shelf tall enough with room left; sorted by height, so earlier shelves are the taller ones
			for mut s in shelves {
				if bh <= s.h && s.x + bw <= page_size {
					out[i] = Rect{page, s.x + padding, s.y + padding, it.w, it.h}
					s.x += bw
					if s.x > used_w {
						used_w = s.x
					}
					placed = true
					break
				}
			}
			if !placed {
				top := if shelves.len > 0 { shelves.last().y + shelves.last().h } else { 0 }
				if top + bh <= page_size {
					shelves << Shelf{bw, top, bh}
					out[i] = Rect{page, padding, top + padding, it.w, it.h}
					if bw > used_w {
						used_w = bw
					}
					used_h = top + bh
					placed = true
				}
			}
		}
		if !placed { // a new page
			if page >= 0 {
				sizes << [round4(used_w), round4(used_h)]!
			}
			page++
			shelves = [Shelf{bw, 0, bh}]
			out[i] = Rect{page, padding, padding, it.w, it.h}
			used_w = bw
			used_h = bh
		}
	}
	if page >= 0 {
		sizes << [round4(used_w), round4(used_h)]!
	}
	return out, sizes
}

struct Shelf {
mut:
	x int // next free x
	y int
	h int
}

fn round4(v int) int {
	return (v + 3) / 4 * 4
}

// Page — the RGBA pixels of one page.
pub struct Page {
pub:
	width  int
	height int
pub mut:
	pixels []u8
}

pub fn new_page(width int, height int) Page {
	return Page{
		width:  width
		height: height
		pixels: []u8{len: width * height * 4}
	}
}

// blit copies RGBA pixels (w x h) to (x, y) and repeats the outer pixels `padding` times around them, so linear
// filtering and rotation never pull in a neighbour's pixels.
pub fn (mut p Page) blit(src []u8, w int, h int, x int, y int, padding int) {
	stride := p.width * 4
	for row in -padding .. h + padding {
		sr := clamp(row, 0, h - 1)
		dy := y + row
		if dy < 0 || dy >= p.height {
			continue
		}
		for col in -padding .. w + padding {
			dx := x + col
			if dx < 0 || dx >= p.width {
				continue
			}
			sc := clamp(col, 0, w - 1)
			s := (sr * w + sc) * 4
			d := dy * stride + dx * 4
			p.pixels[d] = src[s]
			p.pixels[d + 1] = src[s + 1]
			p.pixels[d + 2] = src[s + 2]
			p.pixels[d + 3] = src[s + 3]
		}
	}
}

fn clamp(v int, lo int, hi int) int {
	return if v < lo {
		lo
	} else if v > hi {
		hi
	} else {
		v
	}
}

// ---------- Manifest ----------

// PageInfo — one page file of the manifest.
pub struct PageInfo {
pub:
	file    string // relative to out_dir
	width   int
	height  int
	nearest bool // the textures on it use the 'nearest' filter
}

// Manifest — every page, and where each texture (by asset ID) is.
//   velo-atlas 1
//   page sprites_0.png 1024 512 linear
//   tex 7f3a91c2 0 1 1 64 64      <- asset ID, page, x, y, width, height
pub struct Manifest {
pub mut:
	pages   []PageInfo
	regions map[string]Rect
}

pub fn (m Manifest) encode() string {
	mut sb := strings.new_builder(256)
	sb.writeln(manifest_header)
	for p in m.pages {
		sb.writeln('page ${p.file} ${p.width} ${p.height} ${if p.nearest {
			'nearest'
		} else {
			'linear'
		}}')
	}
	mut ids := m.regions.keys()
	ids.sort()
	for id in ids {
		r := m.regions[id]
		sb.writeln('tex ${id} ${r.page} ${r.x} ${r.y} ${r.w} ${r.h}')
	}
	return sb.str()
}

pub fn parse_manifest(src string) !Manifest {
	mut m := Manifest{}
	lines := src.split_into_lines()
	if lines.len == 0 || lines[0].trim_space() != manifest_header {
		return error('not a velo atlas manifest')
	}
	for n, raw in lines[1..] {
		line := raw.trim_space()
		if line == '' || line.starts_with('#') {
			continue
		}
		f := line.fields()
		match f[0] {
			'page' {
				if f.len != 5 {
					return error('line ${n + 2}: expected `page <file> <width> <height> <filter>`')
				}
				m.pages << PageInfo{f[1], f[2].int(), f[3].int(), f[4] == 'nearest'}
			}
			'tex' {
				if f.len != 7 {
					return error('line ${n + 2}: expected `tex <id> <page> <x> <y> <width> <height>`')
				}
				r := Rect{f[2].int(), f[3].int(), f[4].int(), f[5].int(), f[6].int()}
				if r.page < 0 || r.page >= m.pages.len {
					return error('line ${n + 2}: no page ${r.page}')
				}
				m.regions[f[1]] = r
			}
			else {
				return error('line ${n + 2}: unknown entry "${f[0]}"')
			}
		}
	}
	return m
}
