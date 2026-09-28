import os
import time
import engine.core
import engine.assets
import engine.serialize

struct Health {
	core.Component
pub mut:
	max   int = 10
	armor f32
	tag   string
	temp  int @[hide]
}

struct Look {
	core.Component
pub mut:
	texture assets.AssetRef[assets.Texture]
	offset  core.Vec2
	tint    core.Color
	visible bool = true
}

fn setup() (string, &serialize.SceneLoader) {
	dir := os.join_path(os.temp_dir(), 'safex_ser_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	os.write_file_array(os.join_path(dir, 'tex.png'), [u8(0x89), `P`, `N`, `G`, 13, 10, 26, 10,
		0, 0, 0, 13, `I`, `H`, `D`, `R`, 0, 0, 0, 4, 0, 0, 0, 4]) or { panic(err) }
	os.write_file(os.join_path(dir, 'tex.png.meta'), 'id: tex00001\nkind: texture\n') or {
		panic(err)
	}
	// source prefab
	os.write_file(os.join_path(dir, 'enemy.scene'), '
# enemy prefab
node Enemy {
  Health { max = 20 }
  Look { texture = @asset("tex00001")  offset = [1, 2] }
  node Gun { position = [8, 0]  Health { max = 1 } }
}') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'enemy.scene.meta'), 'id: enemy001\nkind: scene\n') or {
		panic(err)
	}
	// variant: a prefab that uses `from` another prefab
	os.write_file(os.join_path(dir, 'boss.scene'), '
node Boss from @asset("enemy001") {
  scale = [2, 2]
  Health { max = 500  armor = 0.5 }
}') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'boss.scene.meta'), 'id: boss0001\nkind: scene\n') or {
		panic(err)
	}
	// scene containing instances + nested overrides
	os.write_file(os.join_path(dir, 'level.scene'), '
node Level {
  node E1 from @asset("enemy001") { position = [100, 50] }
  node E2 from @asset("enemy001") {
    Health { tag = "elite" }
    node Gun { rotation = 45 }
  }
  node TheBoss from @asset("boss0001") {}
  node "Plain Node" { active = false }
}') or {
		panic(err)
	}
	mut db := assets.open(dir) or { panic(err) }
	mut reg := serialize.new_registry()
	reg.register[Health]()
	reg.register[Look]()
	return dir, serialize.new_loader(reg, db)
}

fn test_parse_basic() {
	d := serialize.parse('node A { position = [1, -2.5]  B { s = "x\\"y"  ok = true  r = @asset("id1") } node C {} }',
		'mem')!
	assert d.name == 'A'
	assert d.props['position']!.as_vec2()! == core.vec2(1, -2.5)
	assert d.components[0].type_name == 'B'
	assert d.components[0].props['s']!.as_string()! == 'x"y'
	assert d.components[0].props['r']!.as_asset()! == 'id1'
	assert d.children[0].name == 'C'
}

fn test_parse_error_has_line() {
	serialize.parse('node A {\n  position = [1, 2]\n  Foo { x = }\n}', 'bad.scene') or {
		assert err.msg().starts_with('bad.scene:3:')
		return
	}
	assert false
}

fn test_reflection_sets_and_dumps() {
	mut h := Health{}
	serialize.set_fields(mut h, {
		'max':   serialize.Value(f64(7))
		'armor': serialize.Value(f64(0.25))
	})!
	assert h.max == 7 && h.armor == 0.25
	d := serialize.dump_fields(h)
	assert 'temp' !in d // @[hide]
	assert d['max']!.to_text() == '7'
	// nonexistent field -> clear error
	serialize.set_fields(mut h, {
		'maxx': serialize.Value(f64(1))
	}) or {
		assert err.msg().contains('"maxx"')
		return
	}
	assert false
}

fn test_prefab_instances_and_overrides() {
	dir, mut l := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	scene := l.load_scene('level.scene')!
	e1 := scene.find('E1')?
	assert e1.position == core.vec2(100, 50)
	assert e1.get_component[Health]()?.max == 20
	look := e1.get_component[Look]()?
	assert look.texture.id == 'tex00001'
	assert look.offset == core.vec2(1, 2)
	// nested overrides: only E2's Gun is rotated, other fields follow the prefab
	e2 := scene.find('E2')?
	assert e2.get_component[Health]()?.tag == 'elite'
	assert e2.get_component[Health]()?.max == 20
	assert scene.find('E2/Gun')?.rotation == 45
	assert scene.find('E1/Gun')?.rotation == 0
	// 2-level variant
	boss := scene.find('TheBoss')?
	assert boss.scale == core.vec2(2, 2)
	assert boss.get_component[Health]()?.max == 500
	assert boss.find('Gun')?.position == core.vec2(8, 0)
	assert scene.find('Plain Node')?.active == false
}

fn test_save_writes_only_overrides() {
	dir, mut l := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	mut scene := l.load_scene('level.scene')!
	// modify at runtime then save
	mut e1 := scene.find('E1')?
	if mut h := e1.get_component[Health]() {
		h.armor = 3
	}
	text := l.save_node(scene.root)!
	assert text.contains('node E1 from @asset("enemy001") {')
	assert text.contains('Health { armor = 3 }')
	assert !text.contains('max = 20') // same as prefab -> not written
	assert text.contains('node Gun {')
	assert text.contains('rotation = 45')
	assert text.contains('node "Plain Node" {')
	// after saving, reading it back must give the same result
	os.write_file(os.join_path(dir, 'level2.scene'), text)!
	l.db.poll_changes()
	s2 := l.load_scene('level2.scene')!
	assert s2.find('E1')?.get_component[Health]()?.armor == 3
	assert s2.find('E2/Gun')?.rotation == 45
	assert s2.find('TheBoss')?.get_component[Health]()?.max == 500
}

fn test_prefab_cycle_detected() {
	dir, mut l := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'a.scene'), 'node A { node B from @asset("b.scene") {} }')!
	os.write_file(os.join_path(dir, 'b.scene'), 'node B { node A from @asset("a.scene") {} }')!
	l.db.poll_changes()
	l.instantiate('a.scene') or {
		assert err.msg().contains('circular')
		return
	}
	assert false
}

fn test_runtime_instantiate_from_component() {
	dir, mut l := setup()
	defer {
		os.rmdir_all(dir) or {}
	}
	mut scene := l.load_scene('level.scene')!
	before := scene.node_count()
	mut root := scene.root
	scene.instantiate('enemy.scene', mut root)!
	assert scene.node_count() == before + 2
}
