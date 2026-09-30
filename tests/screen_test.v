import math
import velo.core
import velo.render

fn same(a core.Vec2, b core.Vec2) bool {
	return math.abs(a.x - b.x) < 0.01 && math.abs(a.y - b.y) < 0.01
}

const design = core.vec2(960, 540)

fn test_same_aspect_scales_uniformly_in_every_mode() {
	for mode in [core.ScaleMode.expand, .fit, .fill, .width, .height] {
		f := core.fit_screen(core.vec2(1920, 1080), design, mode)
		assert f.scale == 2
		assert same(f.view_size, design) && same(f.view_origin, core.Vec2{})
		assert same(f.to_window().apply(core.vec2(960, 540)), core.vec2(1920, 1080))
	}
}

fn test_expand_shows_more_around_the_centered_design_area() {
	// a 4:3 window: the design width fits, 180 more units are visible vertically (90 above, 90 below)
	f := core.fit_screen(core.vec2(1024, 768), design, .expand)
	assert same(f.view_size, core.vec2(960, 720))
	assert same(f.view_origin, core.vec2(0, -90))
	assert same(f.to_window().apply(core.vec2(0, 0)), core.vec2(0, 96))
	assert same(f.from_window(core.vec2(512, 384)), core.vec2(480, 270)) // window center = design center
	// a phone wider than 16:9: more visible horizontally
	g := core.fit_screen(core.vec2(2340, 1080), design, .expand)
	assert g.scale == 2 && same(g.view_size, core.vec2(1170, 540))
	assert same(g.view_origin, core.vec2(-105, 0))
}

fn test_fit_letterboxes() {
	f := core.fit_screen(core.vec2(1024, 768), design, .fit)
	assert same(f.view_size, design) && same(f.view_origin, core.Vec2{})
	assert same(f.area_pos, core.vec2(0, 96)) && same(f.area_size, core.vec2(1024, 576))
	assert same(f.from_window(core.vec2(0, 96)), core.Vec2{})
	assert same(f.to_window().apply(design), core.vec2(1024, 672))
}

fn test_fill_crops_and_width_height_match_one_side() {
	f := core.fit_screen(core.vec2(1024, 768), design, .fill)
	assert f.view_size.y == 540 && f.view_size.x < 960 // cropped left and right
	assert same(fit_center(f), core.vec2(480, 270))
	w := core.fit_screen(core.vec2(540, 960), design, .width) // portrait phone, landscape design
	assert w.scale == 0.5625 && w.view_size.x == 960 && w.view_size.y > 540
	h := core.fit_screen(core.vec2(540, 960), design, .height)
	assert same(h.view_size, core.vec2(303.75, 540))
}

fn fit_center(f core.ScreenFit) core.Vec2 {
	return f.view_origin + f.view_size.mul(0.5)
}

fn test_none_is_one_unit_per_point() {
	f := core.fit_screen(core.vec2(1280, 720), design, .none)
	assert f.scale == 1 && same(f.view_size, core.vec2(1280, 720))
		&& same(f.view_origin, core.Vec2{})
	if _ := core.scale_mode_from_str('stretch') {
		assert false
	}
	assert core.scale_mode_from_str('')! == .expand
}

fn test_safe_insets_follow_scale_and_bars() {
	f := core.fit_screen(core.vec2(1920, 1080), design, .expand)
	ins := f.insets_from_window(core.vec2(1920, 1080), core.Insets{88, 0, 88, 42})
	assert same(core.vec2(ins.left, ins.bottom), core.vec2(44, 21))
	// letterbox bars already keep the game clear of a notch that is thinner than the bar
	g := core.fit_screen(core.vec2(2340, 1080), design, .fit)
	bar := g.area_pos.x
	gi := g.insets_from_window(core.vec2(2340, 1080), core.Insets{bar - 10, 0, bar + 20, 0})
	assert gi.left == 0 && same(core.vec2(gi.right, 0), core.vec2(10, 0))
}

fn test_widget_and_camera_use_the_visible_area() {
	mut s := core.Scene.new('Test')
	s.view_origin = core.vec2(-40, 0)
	s.view_size = core.vec2(1040, 540)
	mut n := core.Node.new('Corner').with(&render.UITransform{
		size: core.vec2(100, 20)
	}).with(&render.Widget{
		align_right: true
		right:       10
		align_top:   true
		top:         10
	})
	s.add(mut n)
	s.update(0.016)
	assert same(n.position, core.vec2(1000 - 10 - 50, 20)) // right edge of the view is x = 1000
	mut cam := core.Node.new('Cam').with(&core.Camera{})
	cam.position = core.vec2(100, 100)
	s.add(mut cam)
	assert same(s.world_to_screen(core.vec2(100, 100)), core.vec2(480, 270)) // view center
}
