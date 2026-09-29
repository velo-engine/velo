module scenedoc

import os
import engine.core
import engine.assets
import engine.serialize

// Document — a .scene file (scene or prefab) open in the editor.
//
// All edits go through Document in order to:
//   * support undo/redo (each step stores a snapshot as .scene text, and the tree is rebuilt on undo),
//   * respect prefab rules: parts owned by the source prefab cannot be deleted/renamed/moved,
//     because the override format only knows "overwrite" and "add" (see README: no deletion via override),
//   * save in proper diff form: instances only write what differs from the prefab, variants keep `from`.
//
// This module has no graphics dependency, so it can be tested without a GPU.
@[heap]
pub struct Document {
pub mut:
	loader   &serialize.SceneLoader
	db       &assets.AssetDatabase
	scene    &core.Scene // scene in edit mode: components receive on_load/on_destroy but never update
	asset_id string      // '' if never saved
	path     string      // relative path within the assets directory
	selected &core.Node = unsafe { nil }
	dirty    bool
mut:
	undo_stack []Snapshot
	redo_stack []Snapshot
	refs       map[string]&core.Node // cache of source prefabs (read-only) for comparing overrides
	events     []assets.AssetEvent
}

struct Snapshot {
	text     string
	selected string // path of the selected node
}

const max_undo = 200
const no_selection = '\x00'

// open opens an existing scene/prefab (by path or asset ID).
pub fn open(mut loader serialize.SceneLoader, key string) !&Document {
	id := loader.db.resolve(key) or { return error('scene "${key}" not found') }
	e := loader.db.entry(id) or { return error('asset ${id} not found') }
	if e.kind != .scene {
		return error('"${e.path}" is ${e.kind}, not a scene/prefab')
	}
	mut root := loader.load_document(id)!
	return &Document{
		loader:   loader
		db:       loader.db
		scene:    loader.new_scene(mut root)
		asset_id: id
		path:     e.path
	}
}

// new_empty creates a new document with no file yet (save_as is needed to save it).
pub fn new_empty(mut loader serialize.SceneLoader, root_name string) &Document {
	mut root := core.Node.new(root_name)
	return &Document{
		loader: loader
		db:     loader.db
		scene:  loader.new_scene(mut root)
	}
}

pub fn (d &Document) root() &core.Node {
	return d.scene.root
}

// title: display name, with a * if there are unsaved changes.
pub fn (d &Document) title() string {
	name := if d.path == '' { '(unsaved)' } else { d.path }
	return if d.dirty { '${name} *' } else { name }
}

// text: .scene content of the current state.
pub fn (mut d Document) text() !string {
	return d.loader.save_node(d.scene.root)
}

// close calls on_destroy on the whole tree (releasing asset references).
pub fn (mut d Document) close() {
	d.scene.unload()
	d.selected = unsafe { nil }
}

// ---------- Node selection ----------

pub fn (mut d Document) select(n &core.Node) {
	d.selected = unsafe { n }
}

pub fn (d &Document) has_selection() bool {
	return d.contains(d.selected)
}

// contains: whether the node still belongs to the tree being edited (after undo, old pointers are no longer valid).
pub fn (d &Document) contains(n &core.Node) bool {
	return n != unsafe { nil } && n.scene == d.scene && !n.destroyed
}

// rel_path: the node's path from the document root ('' = root).
pub fn (d &Document) rel_path(n &core.Node) string {
	if n == unsafe { nil } || n == d.scene.root || n.parent == unsafe { nil } {
		return ''
	}
	parent := d.rel_path(n.parent)
	return if parent == '' { n.name } else { '${parent}/${n.name}' }
}

pub fn (d &Document) find(rel string) ?&core.Node {
	if rel == no_selection {
		return none
	}
	return d.scene.root.find(rel)
}

// ---------- Undo / redo ----------

// checkpoint snapshots the state BEFORE an edit. Call it once at the start of each operation
// (mouse drag: when the drag starts; input field: on commit).
pub fn (mut d Document) checkpoint() ! {
	d.undo_stack << d.snapshot()!
	if d.undo_stack.len > max_undo {
		d.undo_stack.delete(0)
	}
	d.redo_stack.clear()
	d.dirty = true
}

// undo_depth / collapse_undo merge several consecutive operations into ONE undo step:
//   depth := d.undo_depth()
//   d.add_node(...)!  d.set_field(...)!
//   d.collapse_undo(depth)
pub fn (d &Document) undo_depth() int {
	return d.undo_stack.len
}

pub fn (mut d Document) collapse_undo(depth int) {
	if depth >= 0 && d.undo_stack.len > depth + 1 {
		d.undo_stack.trim(depth + 1)
	}
}

pub fn (d &Document) can_undo() bool {
	return d.undo_stack.len > 0
}

pub fn (d &Document) can_redo() bool {
	return d.redo_stack.len > 0
}

pub fn (mut d Document) undo() ! {
	if d.undo_stack.len == 0 {
		return error('nothing left to undo')
	}
	cur := d.snapshot()!
	s := d.undo_stack.pop()
	d.restore(s)!
	d.redo_stack << cur
	d.dirty = true
}

pub fn (mut d Document) redo() ! {
	if d.redo_stack.len == 0 {
		return error('nothing left to redo')
	}
	cur := d.snapshot()!
	s := d.redo_stack.pop()
	d.restore(s)!
	d.undo_stack << cur
	d.dirty = true
}

fn (mut d Document) snapshot() !Snapshot {
	return Snapshot{
		text:     d.text()!
		selected: if d.has_selection() { d.rel_path(d.selected) } else { no_selection }
	}
}

// restore rebuilds the whole tree from text (keeping the selected node by path).
fn (mut d Document) restore(s Snapshot) ! {
	mut root := d.loader.instantiate_source(s.text, d.file_name())!
	d.replace_root(mut root, s.selected)
}

fn (mut d Document) replace_root(mut root core.Node, selected string) {
	d.scene.unload()
	d.scene.name = root.name
	d.scene.set_root(mut root)
	d.selected = unsafe { nil }
	if n := d.find(selected) {
		d.selected = n
	}
}

fn (d &Document) file_name() string {
	return if d.path == '' { 'untitled.scene' } else { d.path }
}

// ---------- Prefabs: reference roots, edit permissions, overrides ----------

fn (mut d Document) prefab_ref(id string) ?&core.Node {
	if r := d.refs[id] {
		return r
	}
	r := d.loader.instantiate(id) or { return none }
	d.refs[id] = r
	return r
}

// reference_of: the corresponding node in the source prefab (read-only), or none if the node does not come from a prefab.
// Same rule as the writer: children are matched by name + same prefab source.
pub fn (mut d Document) reference_of(n &core.Node) ?&core.Node {
	if n.parent != unsafe { nil } && n != d.scene.root {
		if pr := d.reference_of(n.parent) {
			if rc := serialize.matching_child(pr, n) {
				return rc
			}
		}
	}
	if n.prefab_id != '' {
		return d.prefab_ref(n.prefab_id)
	}
	return none
}

// is_prefab_owned: the node is part of a prefab whose parent is an instance (cannot be deleted/renamed/moved).
pub fn (mut d Document) is_prefab_owned(n &core.Node) bool {
	if n == d.scene.root || n.parent == unsafe { nil } {
		return false
	}
	pr := d.reference_of(n.parent) or { return false }
	serialize.matching_child(pr, n) or { return false }
	return true
}

// is_instance_root: the node was created `from` a prefab (and is not a built-in part of the parent prefab).
pub fn (mut d Document) is_instance_root(n &core.Node) bool {
	return n.prefab_id != '' && !d.is_prefab_owned(n)
}

// node_prop_overridden: the node property differs from the source prefab.
pub fn (mut d Document) node_prop_overridden(n &core.Node, prop string) bool {
	r := d.reference_of(n) or { return false }
	return match prop {
		'position' { r.position != n.position }
		'rotation' { r.rotation != n.rotation }
		'scale' { r.scale != n.scale }
		'active' { r.active != n.active }
		else { false }
	}
}

// component_in_prefab: component `type_name` exists in the node's source prefab.
pub fn (mut d Document) component_in_prefab(n &core.Node, type_name string) bool {
	r := d.reference_of(n) or { return false }
	r.component_by_type_name(type_name) or { return false }
	return true
}

// field_overridden: the component field differs from the source prefab.
pub fn (mut d Document) field_overridden(n &core.Node, idx int, field string) bool {
	r := d.reference_of(n) or { return false }
	tname := core.short_type_name(n.components[idx].type_name())
	t := d.loader.registry.get(tname) or { return false }
	rc := r.component_by_type_name(tname) or { return false }
	now := t.dump(n.components[idx])[field] or { return false }
	before := t.dump(rc)[field] or { return true }
	return now.to_text() != before.to_text()
}

// ---------- Node operations ----------

// add_node adds an empty node as the last child of `parent`.
pub fn (mut d Document) add_node(mut parent core.Node, name string) !&core.Node {
	d.expect_mine(parent)!
	d.checkpoint()!
	mut n := core.Node.new(unique_child_name(parent, name))
	parent.add_child(mut n)
	d.selected = n
	return n
}

// delete deletes a node (the root and nodes owned by the source prefab cannot be deleted).
pub fn (mut d Document) delete(mut n core.Node) ! {
	d.expect_mine(n)!
	if n == d.scene.root {
		return error('cannot delete the root node')
	}
	if d.is_prefab_owned(n) {
		return error('"${n.name}" belongs to the source prefab and cannot be deleted via override (edit the prefab, or turn off active)')
	}
	d.checkpoint()!
	mut parent := n.parent
	idx := n.child_index()
	n.destroy()
	d.scene.flush_destroyed()
	d.selected = if parent.children.len == 0 {
		parent
	} else if idx < parent.children.len {
		parent.children[idx]
	} else {
		parent.children.last()
	}
}

// duplicate duplicates the node (and its subtree) right after itself.
pub fn (mut d Document) duplicate(n &core.Node) !&core.Node {
	d.expect_mine(n)!
	if n == d.scene.root {
		return error('cannot duplicate the root node')
	}
	text := d.loader.save_node(n)!
	mut copy := d.loader.instantiate_source(text, d.file_name())!
	mut parent := n.parent
	copy.name = unique_child_name(parent, n.name)
	d.checkpoint()!
	parent.insert_child(mut copy, n.child_index() + 1)
	d.selected = copy
	return copy
}

pub fn (mut d Document) rename(mut n core.Node, name string) ! {
	d.expect_mine(n)!
	new_name := name.trim_space()
	if new_name == n.name {
		return
	}
	if new_name == '' {
		return error('node name must not be empty')
	}
	if d.is_prefab_owned(n) {
		return error('"${n.name}" belongs to the source prefab; renaming it would break the override link')
	}
	if n.parent != unsafe { nil } {
		if _ := serialize.direct_child(n.parent, new_name) {
			return error('a child node named "${new_name}" already exists')
		}
	}
	d.checkpoint()!
	n.name = new_name
	if n == d.scene.root {
		d.scene.name = new_name
	}
}

// reparent moves the node to a new parent at position `index` (-1 = last), keeping its on-screen position.
pub fn (mut d Document) reparent(mut n core.Node, mut new_parent core.Node, index int) ! {
	d.expect_mine(n)!
	d.expect_mine(new_parent)!
	if n == d.scene.root {
		return error('cannot move the root node')
	}
	if n.is_ancestor_of(new_parent) {
		return error('cannot move a node into its own subtree')
	}
	if d.is_prefab_owned(n) {
		return error('"${n.name}" belongs to the source prefab and cannot be moved')
	}
	same_parent := n.parent == new_parent
	if !same_parent {
		if _ := serialize.direct_child(new_parent, n.name) {
			return error('"${new_parent.name}" already has a child node named "${n.name}"')
		}
	}
	mut at := if index < 0 { new_parent.children.len } else { index }
	if same_parent && n.child_index() < at {
		at-- // remove itself from the list before inserting
	}
	if same_parent && at == n.child_index() {
		return
	}
	d.checkpoint()!
	world := n.world_matrix()
	new_parent.insert_child(mut n, at)
	// keep the on-screen transform
	local := new_parent.world_matrix().inverse().mul(world)
	n.position = local.position()
	n.rotation = local.rotation_deg()
	n.scale = local.scale()
}

// move_sibling swaps order with a sibling node (delta = -1 up, +1 down). Draw order follows tree order.
pub fn (mut d Document) move_sibling(mut n core.Node, delta int) ! {
	d.expect_mine(n)!
	if n == d.scene.root {
		return error('the root node has no siblings')
	}
	if _ := d.reference_of(n.parent) {
		return error('children of a prefab instance are loaded in the prefab order and cannot be reordered')
	}
	mut parent := n.parent
	to := n.child_index() + delta
	if to < 0 || to >= parent.children.len {
		return
	}
	d.checkpoint()!
	parent.insert_child(mut n, to)
}

// set_node_prop assigns position/rotation/scale/active. `record` = record an undo step
// (false while dragging: the undo step was recorded when the drag started).
pub fn (mut d Document) set_node_prop(mut n core.Node, prop string, v serialize.Value, record bool) ! {
	d.expect_mine(n)!
	mut tmp := core.Node{
		position: n.position
		rotation: n.rotation
		scale:    n.scale
		active:   n.active
	}
	serialize.apply_node_props(mut tmp, {
		prop: v
	})! // validate before recording undo
	if record {
		d.checkpoint()!
	}
	d.dirty = true
	n.position = tmp.position
	n.rotation = tmp.rotation
	n.scale = tmp.scale
	n.active = tmp.active
}

// ---------- Component ----------

// add_component adds a registered component (with default values).
pub fn (mut d Document) add_component(mut n core.Node, type_name string) ! {
	d.expect_mine(n)!
	t := d.loader.registry.get(type_name) or {
		return error('component "${type_name}" is not registered')
	}
	if _ := n.component_by_type_name(type_name) {
		return error('"${n.name}" already has ${type_name}')
	}
	d.checkpoint()!
	n.add_component_dyn(t.create())
}

pub fn (mut d Document) remove_component(mut n core.Node, idx int) ! {
	d.expect_mine(n)!
	if idx < 0 || idx >= n.components.len {
		return error('no component #${idx}')
	}
	tname := core.short_type_name(n.components[idx].type_name())
	if d.component_in_prefab(n, tname) {
		return error('${tname} belongs to the source prefab and cannot be removed via override')
	}
	d.checkpoint()!
	n.remove_component(idx)
}

// set_field assigns a component field. AssetRef fields accept an ID or a path, and the asset kind is checked.
pub fn (mut d Document) set_field(mut n core.Node, idx int, field string, v serialize.Value) ! {
	d.expect_mine(n)!
	if idx < 0 || idx >= n.components.len {
		return error('no component #${idx}')
	}
	tname := core.short_type_name(n.components[idx].type_name())
	t := d.loader.registry.get(tname) or { return error('component "${tname}" is not registered') }
	mut is_asset := false
	mut value := v
	for f in t.fields {
		if f.name == field && f.asset_kind != .unknown {
			value = serialize.Value(serialize.AssetId{d.check_asset(v, f.asset_kind)!})
			is_asset = true
		}
	}
	// try on a copy so an invalid value does not pollute the undo history
	mut probe := t.create()
	t.apply(mut probe, {
		field: value
	})!
	d.checkpoint()!
	mut c := n.components[idx]
	if is_asset {
		c.on_destroy() // release the old asset, load the new one (Sprite.texture, ...)
	}
	t.apply(mut c, {
		field: value
	})!
	if is_asset {
		c.on_load()
	}
}

fn (d &Document) check_asset(v serialize.Value, want assets.AssetKind) !string {
	key := v.as_asset()!
	if key == '' {
		return ''
	}
	id := d.db.resolve(key) or { return error('asset "${key}" not found') }
	e := d.db.entry(id) or { return error('asset "${key}" not found') }
	if e.kind != want {
		return error('"${e.path}" is ${e.kind}, this field needs ${want}')
	}
	return id
}

// ---------- Prefab ----------

// instantiate_prefab adds an instance of prefab `key` as a child of `parent`.
pub fn (mut d Document) instantiate_prefab(key string, mut parent core.Node) !&core.Node {
	d.expect_mine(parent)!
	id := d.db.resolve(key) or { return error('prefab "${key}" not found') }
	if d.asset_id != '' && (id == d.asset_id || d.asset_id in d.db.dependencies_deep(id)) {
		return error('prefab "${d.db.path_of(id) or { id }}" contains (or is) the open file — this would create circular nesting')
	}
	mut n := d.loader.instantiate(id)!
	n.name = unique_child_name(parent, n.name)
	d.checkpoint()!
	parent.add_child(mut n)
	d.selected = n
	return n
}

// make_prefab writes the subtree of `n` to a new prefab file `rel_path`, then turns `n` into an instance of it.
pub fn (mut d Document) make_prefab(mut n core.Node, rel_path string) !string {
	d.expect_mine(n)!
	if n == d.scene.root {
		return error('cannot turn the root node into a prefab of its own file (use "Save as")')
	}
	rel := normalize_scene_path(rel_path)!
	abs := os.join_path(d.db.root, rel)
	if os.exists(abs) {
		return error('"${rel}" already exists')
	}
	// the prefab is saved at the coordinate origin; the position in the scene becomes an instance override
	pos := n.position
	n.position = core.Vec2{}
	text := d.loader.save_node(n) or {
		n.position = pos
		return err
	}
	n.position = pos
	os.mkdir_all(os.dir(abs))!
	os.write_file(abs, text)!
	d.poll_assets()
	id := d.db.id_of(rel) or { return error('cannot import "${rel}"') }
	d.checkpoint()!
	n.prefab_id = id
	return id
}

// unpack turns an instance into a plain node (writing the full content instead of only overrides).
pub fn (mut d Document) unpack(mut n core.Node) ! {
	d.expect_mine(n)!
	if !d.is_instance_root(n) {
		return error('"${n.name}" is not a prefab instance')
	}
	d.checkpoint()!
	n.prefab_id = ''
}

// ---------- Saving and syncing with disk ----------

pub fn (mut d Document) save() ! {
	if d.path == '' {
		return error('document has no path yet — use save_as')
	}
	d.write(d.path)!
}

pub fn (mut d Document) save_as(rel_path string) ! {
	rel := normalize_scene_path(rel_path)!
	if rel != d.path && os.exists(os.join_path(d.db.root, rel)) {
		return error('"${rel}" already exists')
	}
	d.write(rel)!
}

fn (mut d Document) write(rel string) ! {
	text := d.text()!
	abs := os.join_path(d.db.root, rel)
	os.mkdir_all(os.dir(abs))!
	os.write_file(abs, text)!
	d.path = rel
	d.poll_assets()
	d.asset_id = d.db.id_of(rel) or { '' }
	// the "modified" event for this very file is caused by our own write, not an external edit
	d.events = d.events.filter(!(it.id == d.asset_id && it.kind == .modified))
	d.dirty = false
}

fn (mut d Document) poll_assets() {
	evs := d.db.poll_changes()
	if evs.any(it.kind in [.modified, .removed, .moved]) {
		d.refs.clear()
	}
	d.events << evs
}

// poll scans for changes on disk. If a prefab used by the document was edited (or this file itself was edited
// externally while there are no unsaved changes), the tree is rebuilt to reflect the new content.
// Returns every asset event (including events from previous saves) so the editor can forward them to the renderer,
// and true if the tree was rebuilt.
pub fn (mut d Document) poll() ([]assets.AssetEvent, bool) {
	// The text must be generated BEFORE scanning: the loader still holds the old prefab so the diff stays correct.
	before := d.snapshot() or { Snapshot{} }
	d.poll_assets()
	evs := d.events.clone()
	d.events.clear()
	mut deps := []string{}
	for id in prefab_ids(d.scene.root) {
		deps << id
		deps << d.db.dependencies_deep(id)
	}
	mut changed_self := false
	mut changed_dep := false
	for ev in evs {
		if ev.kind != .modified {
			continue
		}
		if ev.id == d.asset_id && d.asset_id != '' {
			changed_self = true
		} else if ev.id in deps {
			changed_dep = true
		}
	}
	if changed_self && !d.dirty {
		// file edited externally: reload the whole file
		mut root := d.loader.load_document(d.asset_id) or { return evs, false }
		d.replace_root(mut root, before.selected)
		d.undo_stack.clear()
		d.redo_stack.clear()
		return evs, true
	}
	if changed_dep && before.text != '' {
		d.restore(before) or { return evs, false }
		return evs, true
	}
	return evs, false
}

fn prefab_ids(n &core.Node) []string {
	mut out := []string{}
	if n.prefab_id != '' {
		out << n.prefab_id
	}
	for c in n.children {
		out << prefab_ids(c)
	}
	return out
}

// play_scene creates a runnable scene from the current state (does not affect the document).
pub fn (mut d Document) play_scene() !&core.Scene {
	text := d.text()!
	mut root := d.loader.instantiate_source(text, d.file_name())!
	root.prefab_id = ''
	return d.loader.new_scene(mut root)
}

// ---------- Utilities ----------

fn (d &Document) expect_mine(n &core.Node) ! {
	if !d.contains(n) {
		return error('node does not belong to the open document')
	}
}

// unique_child_name: 'Coin', 'Coin (1)', 'Coin (2)', ... — child names must be distinct for overrides to match.
pub fn unique_child_name(parent &core.Node, base string) string {
	serialize.direct_child(parent, base) or { return base }
	stem := if base.ends_with(')') && base.contains(' (') {
		base.all_before_last(' (')
	} else {
		base
	}
	mut i := 1
	for {
		name := '${stem} (${i})'
		serialize.direct_child(parent, name) or { return name }
		i++
	}
	return base
}

fn normalize_scene_path(p string) !string {
	mut rel := p.trim_space().replace('\\', '/').trim_left('/')
	if rel == '' {
		return error('empty path')
	}
	if rel.contains('..') {
		return error('path must be inside the assets directory')
	}
	if !rel.ends_with('.scene') && !rel.ends_with('.prefab') {
		rel += '.scene'
	}
	return rel
}
