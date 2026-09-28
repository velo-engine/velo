import os
import time
import engine.core
import engine.assets
import engine.serialize
import engine.scenedoc

struct Hp {
	core.Component
pub mut:
	max int = 10
	tag string
}

struct Skin {
	core.Component
pub mut:
	texture assets.AssetRef[assets.Texture]
	tint    core.Color
}

fn setup_doc() (string, &serialize.SceneLoader) {
	dir := os.join_path(os.temp_dir(), 'safex_doc_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	os.write_file_array(os.join_path(dir, 'tex.png'), [u8(0x89), `P`, `N`, `G`, 13, 10, 26, 10,
		0, 0, 0, 13, `I`, `H`, `D`, `R`, 0, 0, 0, 4, 0, 0, 0, 4]) or { panic(err) }
	os.write_file(os.join_path(dir, 'tex.png.meta'), 'id: tex00001\nkind: texture\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'enemy.scene'), 'node Enemy {
  Hp { max = 20 }
  node Gun { position = [8, 0]  Hp { max = 1 } }
}') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'enemy.scene.meta'), 'id: enemy001\nkind: scene\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'boss.scene'), 'node Boss from @asset("enemy001") {
  scale = [2, 2]
  Hp { max = 500 }
}') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'boss.scene.meta'), 'id: boss0001\nkind: scene\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'level.scene'), 'node Level {
  node E1 from @asset("enemy001") { position = [100, 50] }
  node E2 from @asset("enemy001") {
    Hp { tag = "elite" }
    node Gun { rotation = 45 }
  }
  node Group { position = [10, 10] }
}') or {
		panic(err)
	}
	mut db := assets.open(dir) or { panic(err) }
	mut reg := serialize.new_registry()
	reg.register[Hp]()
	reg.register[Skin]()
	return dir, serialize.new_loader(reg, db)
}

fn hp(n &core.Node) &Hp {
	return n.get_component[Hp]() or { panic('no Hp on ${n.name}') }
}

fn test_edit_save_reopen() {
	dir, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'level.scene')!
	mut e1 := d.find('E1')?
	d.set_node_prop(mut e1, 'position', serialize.parse_value_text('[7, 8]')!, true)!
	assert d.dirty
	d.save()!
	assert !d.dirty
	text := os.read_file(os.join_path(dir, 'level.scene'))!
	// the instance still only writes what differs from the prefab
	assert text.contains('node E1 from @asset("enemy001") {\n    position = [7, 8]\n  }')
	assert !text.contains('max = 20')

	mut again := scenedoc.open(mut l, 'level.scene')!
	e1b := again.find('E1')?
	assert e1b.position == core.vec2(7, 8)
	assert hp(e1b).max == 20
}

fn test_undo_redo_keeps_selection() {
	_, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'level.scene')!
	mut g := d.find('Group')?
	d.select(g)
	d.set_node_prop(mut g, 'rotation', serialize.Value(30.0), true)!
	mut child := d.add_node(mut g, 'Child')!
	assert d.rel_path(child) == 'Group/Child'
	d.undo()! // remove Child
	assert d.find('Group/Child') == none
	assert d.has_selection() && d.selected.name == 'Group'
	d.undo()! // revert rotation
	assert d.find('Group')?.rotation == 0
	assert !d.can_undo()
	d.redo()!
	d.redo()!
	assert d.find('Group')?.rotation == 30
	assert d.selected.name == 'Child'
}

fn test_prefab_rules() {
	_, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'level.scene')!
	mut gun := d.find('E2/Gun')?
	assert d.is_prefab_owned(gun)
	mut failed := false
	d.delete(mut gun) or {
		failed = true
		assert err.msg().contains('belongs to the source prefab')
	}
	assert failed
	assert d.find('E2/Gun') != none
	failed = false
	d.rename(mut gun, 'Cannon') or {
		failed = true
		assert err.msg().contains('belongs to the source prefab')
	}
	assert failed
	failed = false
	d.remove_component(mut gun, 0) or {
		failed = true
		assert err.msg().contains('belongs to the source prefab')
	}
	assert failed

	mut e2 := d.find('E2')?
	assert d.is_instance_root(e2)
	assert d.field_overridden(e2, 0, 'tag')
	assert !d.field_overridden(e2, 0, 'max')
	assert d.node_prop_overridden(gun, 'rotation')
	assert !d.node_prop_overridden(gun, 'position')

	// adding a child to an instance is allowed, and it can be deleted again
	mut extra := d.add_node(mut e2, 'Extra')!
	assert !d.is_prefab_owned(extra)
	d.delete(mut extra)!
	// deleting the whole instance is allowed
	d.delete(mut e2)!
	assert d.find('E2') == none
}

fn test_variant_keeps_from() {
	dir, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'boss.scene')!
	assert d.root().prefab_id == 'enemy001'
	assert d.root().find('Gun') != none
	mut root := d.scene.root
	d.set_field(mut root, 0, 'tag', serialize.Value('boss'))!
	d.save()!
	text := os.read_file(os.join_path(dir, 'boss.scene'))!
	assert text.starts_with('node Boss from @asset("enemy001") {')
	assert text.contains('max = 500')
	assert text.contains('tag = "boss"')
	assert !text.contains('Gun')
}

fn test_asset_field_checks_kind() {
	_, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'level.scene')!
	mut g := d.find('Group')?
	d.add_component(mut g, 'Skin')!
	mut failed := false
	d.set_field(mut g, 0, 'texture', serialize.Value('enemy.scene')) or {
		failed = true
		assert err.msg().contains('this field needs texture')
	}
	assert failed
	d.set_field(mut g, 0, 'texture', serialize.Value('tex.png'))!
	skin := g.get_component[Skin]()?
	assert skin.texture.id == 'tex00001'
	failed = false
	d.set_field(mut g, 0, 'nope', serialize.Value(1.0)) or {
		failed = true
		assert err.msg().contains('no serializable field "nope"')
	}
	assert failed
	failed = false
	d.add_component(mut g, 'Skin') or {
		failed = true
		assert err.msg().contains('already has Skin')
	}
	assert failed
}

fn test_make_prefab_and_instantiate() {
	dir, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'level.scene')!
	mut g := d.find('Group')?
	d.add_component(mut g, 'Hp')!
	d.set_field(mut g, 0, 'max', serialize.Value(3.0))!
	id := d.make_prefab(mut g, 'prefabs/group')!
	assert os.exists(os.join_path(dir, 'prefabs/group.scene'))
	assert g.prefab_id == id
	d.save()!
	text := os.read_file(os.join_path(dir, 'level.scene'))!
	assert text.contains('node Group from @asset("${id}") {\n    position = [10, 10]\n  }')

	mut root := d.scene.root
	inst := d.instantiate_prefab('prefabs/group.scene', mut root)!
	assert inst.name == 'Group (1)'
	assert hp(inst).max == 3

	// a prefab must not contain itself
	mut e := scenedoc.open(mut l, 'enemy.scene')!
	mut eroot := e.scene.root
	mut failed := false
	e.instantiate_prefab('boss.scene', mut eroot) or {
		failed = true
		assert err.msg().contains('circular')
	}
	assert failed
}

fn test_reparent_keeps_world_position() {
	_, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'level.scene')!
	mut e1 := d.find('E1')?
	mut g := d.find('Group')?
	before := e1.world_position()
	d.reparent(mut e1, mut g, -1)!
	assert d.find('Group/E1') != none
	after := e1.world_position()
	assert before.distance(after) < 0.001
	mut root := d.scene.root
	mut failed := false
	d.reparent(mut g, mut e1, -1) or {
		failed = true
		assert err.msg().contains('subtree')
	}
	assert failed
	d.move_sibling(mut g, -1)!
	assert root.children[0].name == 'Group'
}

fn test_duplicate() {
	_, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'level.scene')!
	e2 := d.find('E2')?
	copy := d.duplicate(e2)!
	assert copy.name == 'E2 (1)'
	assert copy.prefab_id == 'enemy001'
	assert hp(copy).tag == 'elite'
	assert copy.find('Gun')?.rotation == 45
	again := d.duplicate(copy)!
	assert again.name == 'E2 (2)'
}

fn test_poll_propagates_prefab_change() {
	dir, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'level.scene')!
	mut e2 := d.find('E2')?
	d.set_field(mut e2, 0, 'tag', serialize.Value('boss'))! // unsaved change
	os.write_file(os.join_path(dir, 'enemy.scene'), 'node Enemy {
  Hp { max = 99 }
  node Gun { position = [8, 0]  Hp { max = 1 } }
}')!
	_, rebuilt := d.poll()
	assert rebuilt
	assert hp(d.find('E1')?).max == 99
	e2b := d.find('E2')?
	assert hp(e2b).max == 99
	assert hp(e2b).tag == 'boss' // the unsaved override is still there
	assert d.dirty
}

fn test_play_scene_is_independent() {
	_, mut l := setup_doc()
	mut d := scenedoc.open(mut l, 'level.scene')!
	mut play := d.play_scene()!
	mut n := play.find('E1')?
	n.position = core.vec2(-1, -1)
	assert d.find('E1')?.position == core.vec2(100, 50)
	assert !d.dirty
	play.unload()
}
