import os
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render

// a 30x30 frame with 10px borders: every band is 10 pixels wide
fn sliced(s render.Sprite) render.Sprite {
	mut sp := s
	sp.tex = &assets.Texture{
		width:  30
		height: 30
	}
	sp.anchor = core.vec2(0, 0)
	sp.border_left = 10
	sp.border_top = 10
	sp.border_right = 10
	sp.border_bottom = 10
	return sp
}

fn test_simple_is_one_quad() {
	mut sp := sliced(render.Sprite{
		size: core.vec2(90, 60)
	})
	q := sp.quads()
	assert q.len == 1
	assert q[0].w == 90 && q[0].h == 60
	assert q[0].u0 == 0 && q[0].u1 == 30
}

fn test_sliced_keeps_corners() {
	sp := sliced(render.Sprite{
		size:      core.vec2(100, 50)
		draw_mode: 'sliced'
	})
	q := sp.quads()
	assert q.len == 9
	// top-left corner: 10x10 in both spaces
	assert q[0].x == 0 && q[0].w == 10 && q[0].h == 10 && q[0].u1 == 10
	// top edge stretches the middle 10px over 80 units
	assert q[1].x == 10 && q[1].w == 80 && q[1].u0 == 10 && q[1].u1 == 20
	// bottom-right corner
	assert q[8].x == 90 && q[8].y == 40 && q[8].u0 == 20 && q[8].v1 == 30
	l, t, r, b := sp.slice_lines()
	assert l == 10 && t == 10 && r == 90 && b == 40
}

fn test_sliced_small_size_shrinks_borders() {
	sp := sliced(render.Sprite{
		size:      core.vec2(10, 30)
		draw_mode: 'sliced'
	})
	l, _, r, _ := sp.slice_lines()
	assert l == 5 && r == 5 // both borders shrink to half the width, no center column
	assert sp.quads().len == 6
}

fn test_sliced_pixel_scale_and_hollow_center() {
	sp := sliced(render.Sprite{
		size:        core.vec2(100, 100)
		draw_mode:   'sliced'
		pixel_scale: 2
		fill_center: false
	})
	q := sp.quads()
	assert q.len == 8
	assert q[0].w == 20 && q[0].h == 20
}

fn test_tiled_repeats_and_crops() {
	mut sp := sliced(render.Sprite{
		size:      core.vec2(75, 30)
		draw_mode: 'tiled'
	})
	sp.border_left, sp.border_top, sp.border_right, sp.border_bottom = 0, 0, 0, 0
	q := sp.quads()
	assert q.len == 3 // 30 + 30 + 15
	assert q[2].x == 60 && q[2].w == 15
	assert q[2].u0 == 0 && q[2].u1 == 15 // the cropped tile shows the left half of the frame
	// with borders, the corners stay and only the center band repeats
	sp.border_left, sp.border_right = 10, 10
	q2 := sp.quads()
	assert q2.len == 2 + 6 // left, 55 units of 10px tiles (6 pieces), right
	assert q2.last().x == 65 && q2.last().u0 == 20
}

fn test_flip_mirrors_pieces() {
	sp := sliced(render.Sprite{
		size:      core.vec2(100, 50)
		draw_mode: 'sliced'
		flip_x:    true
	})
	q := sp.quads()
	// the texture's left border now lands on the right edge, sampled right to left
	assert q[0].x == 90 && q[0].u0 == 10 && q[0].u1 == 0
}

fn test_borders_clamped_to_frame() {
	mut sp := sliced(render.Sprite{
		draw_mode: 'sliced'
	})
	sp.border_left = 25
	sp.border_right = 25
	sp.border_top = -5
	l, t, r, _ := sp.borders()
	assert l == 25 && r == 5 && t == 0
}

fn test_choices_checked_on_load_and_listed() {
	dir := os.join_path(os.temp_dir(), 'velo_sprite_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'ok.scene'),
		'node A { Sprite { draw_mode = "tiled"  border_left = 4  pixel_scale = 2 } }') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'bad.scene'), 'node A { Sprite { draw_mode = "stretch" } }') or {
		panic(err)
	}
	mut db := assets.open(dir) or { panic(err) }
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut loader := serialize.new_loader(reg, db)
	mut s := loader.load_scene('ok.scene')!
	sp := s.root.get_component[render.Sprite]() or { panic('no Sprite') }
	assert sp.draw_mode == 'tiled' && sp.border_left == 4 && sp.pixel_scale == 2
	text := loader.save_node(s.root)!
	assert text.contains('draw_mode = "tiled"')
	if _ := loader.load_scene('bad.scene') {
		assert false, 'an unknown draw_mode should fail to load'
	} else {
		assert err.msg().contains('simple | sliced | tiled')
	}
	info := reg.get('Sprite') or { panic('not registered') }
	for f in info.fields {
		if f.name == 'draw_mode' {
			assert f.choices == ['simple', 'sliced', 'tiled']
		} else {
			assert f.choices.len == 0
		}
	}
}

fn test_draw_order_sorted_and_unsorted_paths() {
	// z_index out of tree order forces the sort; equal z keeps tree order (the already-ordered path skips it)
	mut root := core.Node.new('R')
	mut a := core.Node.new('A')
	mut b := core.Node.new('B')
	mut c := core.Node.new('C')
	root.add_child(mut a)
	root.add_child(mut b)
	root.add_child(mut c)
	assert render.draw_order(root).map(it.name) == ['R', 'A', 'B', 'C']
	a.z_index = 5
	assert render.draw_order(root).map(it.name) == ['R', 'B', 'C', 'A']
	a.z_index = 0
	c.z_index = -1
	assert render.draw_order(root).map(it.name) == ['C', 'R', 'A', 'B']
}
