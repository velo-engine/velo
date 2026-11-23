module tests

import velo.atlas

fn overlaps(a atlas.Rect, b atlas.Rect, pad int) bool {
	return a.page == b.page && a.x - pad < b.x + b.w + pad && b.x - pad < a.x + a.w + pad
		&& a.y - pad < b.y + b.h + pad && b.y - pad < a.y + a.h + pad
}

fn test_pack_places_without_overlap_inside_pages() {
	mut items := []atlas.Item{}
	for i in 0 .. 40 {
		items << atlas.Item{'t${i}', 20 + (i * 37) % 200, 10 + (i * 53) % 150}
	}
	rects, sizes := atlas.pack(items, 512, 1)!
	assert rects.len == items.len
	assert sizes.len >= 2 // 40 images of up to 220x160 do not fit one 512 page
	for i, r in rects {
		assert r.w == items[i].w && r.h == items[i].h
		assert r.x >= 1 && r.y >= 1
		assert r.x + r.w + 1 <= sizes[r.page][0] && r.y + r.h + 1 <= sizes[r.page][1]
		for j in i + 1 .. rects.len {
			assert !overlaps(r, rects[j], 1), '${items[i].key} overlaps ${items[j].key}'
		}
	}
}

fn test_pack_trims_pages_and_rejects_oversize() {
	_, sizes := atlas.pack([atlas.Item{'a', 10, 10}, atlas.Item{'b', 10, 10}], 2048, 1)!
	assert sizes == [[24, 12]!] // 2 x (10 + 2) wide, rounded to 4
	mut failed := false
	atlas.pack([atlas.Item{'big', 2048, 10}], 2048, 1) or { failed = true }
	assert failed // no room for the padding
}

fn test_blit_copies_pixels_and_extrudes_border() {
	mut p := atlas.new_page(8, 8)
	// 2x2 RGBA: red, green / blue, white
	src := [u8(255), 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
	p.blit(src, 2, 2, 2, 2, 1)
	px := fn [p] (x int, y int) []u8 {
		i := (y * p.width + x) * 4
		return p.pixels[i..i + 4]
	}
	assert px(2, 2) == [u8(255), 0, 0, 255]
	assert px(3, 2) == [u8(0), 255, 0, 255]
	assert px(2, 3) == [u8(0), 0, 255, 255]
	assert px(3, 3) == [u8(255), 255, 255, 255]
	// border: copies of the nearest edge pixel (corner included), so filtering never reads a neighbour
	assert px(1, 1) == [u8(255), 0, 0, 255]
	assert px(1, 2) == [u8(255), 0, 0, 255]
	assert px(4, 2) == [u8(0), 255, 0, 255]
	assert px(4, 4) == [u8(255), 255, 255, 255]
	assert px(2, 4) == [u8(0), 0, 255, 255]
	// outside the border stays empty
	assert px(5, 2) == [u8(0), 0, 0, 0]
}

fn test_manifest_round_trip() {
	mut m := atlas.Manifest{}
	m.pages << atlas.PageInfo{'sprites_0.png', 256, 128, false}
	m.pages << atlas.PageInfo{'sprites_nearest_0.png', 64, 64, true}
	m.regions['7f3a91c2'] = atlas.Rect{0, 1, 1, 64, 32}
	m.regions['00c0ffee'] = atlas.Rect{1, 3, 5, 16, 16}
	back := atlas.parse_manifest(m.encode())!
	assert back.pages == m.pages
	assert back.regions == m.regions
	mut bad := false
	atlas.parse_manifest('velo-atlas 1\ntex abc 3 0 0 1 1\n') or { bad = true }
	assert bad // no page 3
}
