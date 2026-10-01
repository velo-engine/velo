import os
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render

const flash = 'vec4 effect(vec4 color, vec2 uv) {
    vec4 c = texel(uv) * color;
    return vec4(mix(c.rgb, PARAM_COLOR.rgb, PARAMS.x), c.a);
}
'

fn test_sources_wrap_the_effect_for_every_backend() {
	for lang in [render.ShaderLang.glsl410, .glsl300es, .msl] {
		vs, fs := render.shader_sources(flash, lang)!
		assert vs.contains('position') && vs.contains('psize')
		assert fs.contains(flash)
		assert fs.contains('#define TIME velo_p0.x') && fs.contains('#define PARAM_COLOR velo_p2')
		assert fs.contains('effect(')
	}
	_, es := render.shader_sources(flash, .glsl300es)!
	assert es.starts_with('#version 300 es\nprecision highp float;')
	_, msl := render.shader_sources(flash, .msl)!
	// Metal: the effect is the body of a struct, so its functions see the built-ins
	assert msl.contains('struct velo_effect {') && msl.contains('typedef float4 vec4;')
	assert msl.contains('return e.effect(in.color, in.uv.xy);')
}

fn test_sources_need_an_effect_function() {
	if _, _ := render.shader_sources('vec4 main2() { return vec4(1.0); }', .glsl410) {
		assert false
	} else {
		assert err.msg().contains('effect')
	}
}

fn test_uniforms_are_packed_column_by_column() {
	u := render.shader_uniforms(2.5, 64, 32, core.vec2(0.25, 3), core.rgba(255, 0, 51, 255), [
		f32(0.5),
		0,
		1,
		0.5,
	]!)
	assert u.len == 16
	assert u[0] == 2.5 && u[1] == 64 && u[2] == 32
	assert u[4] == 0.25 && u[5] == 3
	assert u[8] == 1 && u[9] == 0 && u[10] == 0.2 && u[11] == 1
	assert u[12..] == [f32(0.5), 0, 1, 0.5]
}

fn test_shader_time_follows_unscaled_time() {
	mut s := core.Scene.new('Main')
	mut ui := core.Node.new('UI')
	ui.unscaled_time = true
	mut button := core.Node.new('Button')
	ui.add_child(mut button)
	s.add(mut ui)
	mut world := core.Node.new('World')
	s.add(mut world)
	s.time_scale = 0.5
	s.update(1)
	assert render.shader_time(world) == 0.5
	assert render.shader_time(button) == 1
}

fn test_shader_asset_and_sprite_fields() {
	dir := os.join_path(os.temp_dir(), 'velo_shader_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'flash.glsl'), flash)!
	mut db := assets.open(dir)!
	id := db.id_of('flash.glsl')?
	assert db.entry(id)?.kind == .shader
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	info := reg.get('Sprite')?.fields.filter(it.name == 'shader')
	assert info.len == 1 && info[0].asset_kind == .shader
	mut l := serialize.new_loader(reg, db)
	mut root := l.instantiate_source('node Main {
  node Hero { Sprite { shader = @asset("${id}")  shader_params = [0.5, 2]  shader_color = [255, 255, 255, 128] } }
}',
		'main.scene')!
	mut s := l.new_scene(mut root)
	sp := root.find('Hero')?.get_component[render.Sprite]()?
	assert sp.shader_params == core.vec2(0.5, 2) && sp.shader_color.a == 128
	assert sp.shader_data != unsafe { nil } && sp.shader_data.source == flash
	assert db.entry(id)?.refs == 1
	// hot reload re-reads the source in place
	time.sleep(1100 * time.millisecond)
	os.write_file(os.join_path(dir, 'flash.glsl'), flash + '// edited\n')!
	db.poll_changes()
	assert sp.shader_data.source.ends_with('// edited\n') && sp.shader_data.version == 1
	s.unload()
	assert db.entry(id)?.refs == 0
}
