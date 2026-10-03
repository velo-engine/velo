module tests

import velo.render


fn test_shelf_packing_places_without_overlap() {
	mut p := render.new_atlas_page_test()
	// 3 textures of 100x50 (+2 border each): same row, next to each other
	x0, y0 := p.alloc(100, 50)?
	x1, y1 := p.alloc(100, 50)?
	assert y0 == 1 && y1 == 1
	assert x0 == 1 && x1 == 1 + 102 // second one starts after the first one's border
	// a taller one raises the row; the next row starts below the tallest
	_, y2 := p.alloc(10, 80)?
	assert y2 == 1
	// fill the row, then wrap to the next
	for _ in 0 .. 30 {
		p.alloc(100, 20) or { break }
	}
	_, ny := p.alloc(10, 10)?
	assert ny > 80 // below the first row (height 80 + 2)
}

fn test_page_full_and_oversize() {
	mut p := render.new_atlas_page_test()
	mut too_big := true
	p.alloc(3000, 10) or { too_big = false } // bigger than a page
	assert !too_big
	mut n := 0
	for {
		p.alloc(500, 500) or { break }
		n++
	}
	assert n == 16 // 4 x 4 textures of 502 px fit in 2048
}

fn test_blit_copies_pixels_and_extrudes_border() {
	mut p := render.new_atlas_page_test()
	x, y := p.alloc(2, 2)?
	// 2x2 RGBA: red, green / blue, white
	src := [u8(255), 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
	p.blit(src.data, 2, 2, x, y)
	assert p.pixel(x, y) == [u8(255), 0, 0, 255]
	assert p.pixel(x + 1, y) == [u8(0), 255, 0, 255]
	assert p.pixel(x, y + 1) == [u8(0), 0, 255, 255]
	assert p.pixel(x + 1, y + 1) == [u8(255), 255, 255, 255]
	// border: copies of the nearest edge pixel (corner included), so filtering never reads a neighbour
	assert p.pixel(x - 1, y - 1) == [u8(255), 0, 0, 255]
	assert p.pixel(x - 1, y) == [u8(255), 0, 0, 255]
	assert p.pixel(x + 2, y) == [u8(0), 255, 0, 255]
	assert p.pixel(x + 2, y + 2) == [u8(255), 255, 255, 255]
	assert p.pixel(x, y + 2) == [u8(0), 0, 255, 255]
	// outside the border stays empty
	assert p.pixel(x + 3, y) == [u8(0), 0, 0, 0]
}
