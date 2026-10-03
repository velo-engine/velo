import math
import os
import time
import velo.assets
import velo.core
import velo.render
import velo.serialize

fn test_falloff_is_smooth_and_bounded() {
	assert core.light_falloff(0, 100) == 1
	assert core.light_falloff(100, 100) == 0
	assert core.light_falloff(150, 100) == 0
	assert core.light_falloff(10, 0) == 0
	mut prev := f32(1)
	for i in 0 .. 11 { // never rises with distance
		a := core.light_falloff(f32(i) * 10, 100)
		assert a <= prev + 0.0001
		prev = a
	}
	half := core.light_falloff(50, 100)
	assert half > 0.45 && half < 0.55 // smoothstep: 0.5 in the middle
}

fn test_spot_factor_cone() {
	assert core.spot_factor(0, 60) == 1 // on the axis
	assert core.spot_factor(10, 60) == 1 // inside the solid part
	assert core.spot_factor(30, 60) == 0 // the cone's edge
	assert core.spot_factor(-45, 60) == 0 // symmetric, outside
	soft := core.spot_factor(25, 60) // in the soft rim
	assert soft > 0 && soft < 1
	assert core.spot_factor(-25, 60) == soft
}

fn test_flicker_stays_in_range_and_moves() {
	mut l := &core.Light2D{
		intensity: 2
		flicker:   0.5
	}
	mut lo := f32(10)
	mut hi := f32(0)
	for i in 0 .. 400 {
		v := l.current_intensity(f64(i) * 0.05)
		assert v >= 2 * 0.5 - 0.001 && v <= 2 + 0.001 // between intensity * (1 - flicker) and intensity
		lo = math.min(lo, v)
		hi = math.max(hi, v)
	}
	assert hi - lo > 0.3 // it actually wobbles
	l.flicker = 0
	assert l.current_intensity(3.3) == 2
}

fn test_lights_register_and_the_first_enabled_lighting_wins() {
	mut s := core.Scene.new('t')
	assert s.lighting() == none
	mut a := core.Node.new('A').with(&core.Lighting{})
	s.add(mut a)
	mut torch := core.Node.new('Torch').with(&core.Light2D{})
	s.add(mut torch)
	assert s.lights.len == 1 && s.lightings.len == 1
	assert s.lighting()?.node.name == 'A'
	mut b := core.Node.new('B').with(&core.Lighting{
		ambient: core.rgba(1, 2, 3, 255)
	})
	s.add(mut b)
	assert s.lighting()?.node.name == 'A' // the first one
	a.active = false
	assert s.lighting()?.ambient == core.rgba(1, 2, 3, 255) // inactive ones are skipped
	b.get_component[core.Lighting]()?.enabled = false
	assert s.lighting() == none
	torch.destroy()
	s.update(0)
	assert s.lights.len == 0
}

fn test_light_components_load_from_a_scene_file() {
	dir := os.join_path(os.temp_dir(), 'velo_light_test_${time.now().unix_micro()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	db := assets.open(dir)!
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut loader := serialize.new_loader(reg, db)
	mut root := loader.instantiate_source('node Level {
  Lighting { ambient = [10, 20, 30, 255]  resolution = 2 }
  node Torch { Light2D { color = [255, 180, 90, 255]  radius = 150  flicker = 0.3 } }
  node Lamp { Light2D { kind = "spot"  cone = 40 } }
}',
		'lit.scene')!
	l := root.get_component[core.Lighting]()?
	assert l.ambient == core.rgba(10, 20, 30, 255) && l.resolution == 2
	t := root.find('Torch')?.get_component[core.Light2D]()?
	assert t.radius == 150 && t.flicker == f32(0.3) && t.kind == 'point'
	assert root.find('Lamp')?.get_component[core.Light2D]()?.kind == 'spot'
	// an unknown kind is rejected by the choices check
	loader.instantiate_source('node X { Light2D { kind = "area" } }', 'bad.scene') or { return }
	assert false
}
