module serialize

import velo.core
import velo.assets

struct CachedDesc {
	hash u64
	desc NodeDesc
}

// SceneLoader builds a Node tree from a .scene file, handling nested prefabs and overrides.
//
// The single override rule: when a node is created `from` a prefab, everything written in its block
// is applied on top of a copy of the prefab:
//   * node properties (position, ...)             -> overwritten
//   * components already in the prefab            -> only the written fields are overwritten
//   * components not yet present                  -> added
//   * `node X { ... }` matching an existing child -> override applied to that child (recursively)
//   * other child nodes                           -> added
// A prefab "variant" is simply a prefab whose root node is `from` another prefab.
@[heap]
pub struct SceneLoader {
pub mut:
	registry &Registry
	db       &assets.AssetDatabase
mut:
	cache map[string]CachedDesc
	stack []string
}

pub fn new_loader(registry &Registry, db &assets.AssetDatabase) &SceneLoader {
	return &SceneLoader{
		registry: registry
		db:       db
	}
}

// load_scene creates a complete Scene (on_load already called for every component).
pub fn (mut l SceneLoader) load_scene(key string) !&core.Scene {
	mut root := l.instantiate(key)!
	root.prefab_id = ''
	return l.new_scene(mut root)
}

// new_scene creates a Scene around an existing node tree (calls on_load) and installs the prefab loader for scene.instantiate.
pub fn (mut l SceneLoader) new_scene(mut root core.Node) &core.Scene {
	mut scene := core.Scene.new(root.name)
	scene.assets = l.db
	loader := unsafe { &l }
	scene.instantiate_fn = fn [loader] (k string) !&core.Node {
		mut ld := unsafe { loader }
		return ld.instantiate(k)
	}
	scene.set_root(mut root)
	return scene
}

// load_document builds a file's node tree for EDITING (editor). Unlike instantiate:
// the root's prefab_id is the prefab the file inherits from (`node X from @asset(...)`, i.e. a variant) or '',
// so that when saved, a variant still only writes what differs from the source prefab.
pub fn (mut l SceneLoader) load_document(key string) !&core.Node {
	id := l.db.resolve(key) or { return error('scene "${key}" not found') }
	l.stack << id
	defer {
		l.stack.pop()
	}
	desc := l.parse_asset(id)!
	return l.build(desc, l.db.path_of(id) or { id })
}

// instantiate_source builds a node tree from in-memory .scene text (used by the editor for undo/redo, play mode).
// Like load_document: the root's prefab_id is the prefab the text inherits from, or ''.
pub fn (mut l SceneLoader) instantiate_source(src string, file string) !&core.Node {
	l.stack << (l.db.id_of(file) or { file })
	defer {
		l.stack.pop()
	}
	desc := parse(src, file)!
	return l.build(desc, file)
}

// instantiate creates a NEW node tree from a prefab (not yet attached to any scene).
pub fn (mut l SceneLoader) instantiate(key string) !&core.Node {
	id := l.db.resolve(key) or { return error('prefab "${key}" not found') }
	if id in l.stack {
		chain := l.stack.map(l.db.path_of(it) or { it })
		return error('circular prefab nesting: ${chain.join(' -> ')} -> ${l.db.path_of(id) or { id }}')
	}
	l.stack << id
	defer {
		l.stack.pop()
	}
	desc := l.parse_asset(id)!
	file := l.db.path_of(id) or { id }
	mut n := l.build(desc, file)!
	n.prefab_id = id
	return n
}

// parse_asset returns the NodeDesc of a scene file, cached by content hash.
pub fn (mut l SceneLoader) parse_asset(id string) !NodeDesc {
	e := l.db.entry(id) or { return error('asset ${id} not found') }
	if cached := l.cache[id] {
		if cached.hash == e.hash {
			return cached.desc
		}
	}
	sa := l.db.load[assets.SceneAsset](id)!
	src := sa.source
	l.db.release(id)
	desc := parse(src, e.path)!
	l.cache[id] = CachedDesc{e.hash, desc}
	return desc
}

fn (mut l SceneLoader) build(desc NodeDesc, file string) !&core.Node {
	mut n := if desc.from != '' {
		mut inst := l.instantiate(desc.from) or { return error('${file}:${desc.line}: ${err}') }
		inst.name = desc.name
		inst
	} else {
		core.Node.new(desc.name)
	}
	l.apply_desc(mut n, desc, file)!
	return n
}

fn (mut l SceneLoader) apply_desc(mut n core.Node, desc NodeDesc, file string) ! {
	apply_node_props(mut n, desc.props) or { return error('${file}:${desc.line}: ${err}') }
	for cd in desc.components {
		t := l.registry.get(cd.type_name) or {
			return error('${file}:${cd.line}: component "${cd.type_name}" is not registered ' +
				'(registered: ${l.registry.names().join(', ')})')
		}
		if mut existing := n.component_by_type_name(cd.type_name) {
			t.apply(mut existing, cd.props) or { return error('${file}:${cd.line}: ${err}') }
		} else {
			mut c := t.create()
			t.apply(mut c, cd.props) or { return error('${file}:${cd.line}: ${err}') }
			n.add_component_dyn(c)
		}
	}
	for cdesc in desc.children {
		if cdesc.from == '' {
			if mut existing := direct_child(n, cdesc.name) {
				l.apply_desc(mut existing, cdesc, file)!
				continue
			}
		}
		mut child := l.build(cdesc, file)!
		n.add_child(mut child)
	}
}

// direct_child: the direct child node named `name`.
pub fn direct_child(n &core.Node, name string) ?&core.Node {
	for c in n.children {
		if c.name == name {
			return c
		}
	}
	return none
}

// apply_node_props assigns node properties (position, rotation, scale, active, z_index, y_sort).
pub fn apply_node_props(mut n core.Node, props map[string]Value) ! {
	for k, v in props {
		match k {
			'position' {
				n.position = v.as_vec2()!
			}
			'rotation' {
				n.rotation = f32(v.as_f64()!)
			}
			'scale' {
				n.scale = v.as_vec2()!
			}
			'active' {
				n.active = v.as_bool()!
			}
			'z_index' {
				n.z_index = int(v.as_f64()!)
			}
			'y_sort' {
				n.y_sort = v.as_bool()!
			}
			'unscaled_time' {
				n.unscaled_time = v.as_bool()!
			}
			'persistent' {
				n.persistent = v.as_bool()!
			}
			else {
				return error('node has no property "${k}" (only position, rotation, scale, active, z_index, y_sort, unscaled_time, persistent)')
			}
		}
	}
}
