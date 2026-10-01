module main

import v.ast

// Runtime structs whose constructor takes the fields in order (fast, allocation-light value types).
const positional_types = {
	'velo.core.Vec2':         ['x', 'y']
	'velo.core.Color':        ['r', 'g', 'b', 'a']
	'velo.core.Insets':       ['left', 'top', 'right', 'bottom']
	'velo.core.Affine2':      ['a', 'b', 'c', 'd', 'tx', 'ty']
	'velo.core.Touch':        ['id', 'pos', 'start', 'phase']
	'velo.render.Rect':       ['x', 'y', 'w', 'h']
	'velo.assets.AssetEvent': ['kind', 'id', 'path']
}

// V modules that the WebGL runtime provides (velo.* engine modules and the vlib modules it shims).
const runtime_vlib_modules = ['math', 'rand', 'os', 'time', 'strings', 'strconv', 'arrays', 'maps',
	'math.bits', 'encoding.binary', 'hash.fnv1a', 'term']

// unwrap_alias follows type aliases (`type Score = int`) down to the real type.
fn (g &Gen) unwrap_alias(t ast.Type) ast.Type {
	mut typ := t
	for depth := 0; depth < 10; depth++ {
		sym := g.table.sym(typ)
		if sym.kind == .alias && sym.info is ast.Alias {
			typ = sym.info.parent_type.derive_add_muls(typ)
			continue
		}
		break
	}
	return typ
}

fn (g &Gen) sym(t ast.Type) &ast.TypeSymbol {
	return g.table.sym(t)
}

fn (g &Gen) final_sym(t ast.Type) &ast.TypeSymbol {
	return g.table.final_sym(t)
}

fn (g &Gen) is_option(t ast.Type) bool {
	return t.has_flag(.option)
}

fn (g &Gen) is_result(t ast.Type) bool {
	return t.has_flag(.result)
}

fn (g &Gen) is_int_type(t ast.Type) bool {
	if t.has_option_or_result() {
		return false
	}
	ft := g.unwrap_alias(t)
	if ft.is_ptr() {
		return false
	}
	idx := ft.idx()
	return idx in ast.integer_type_idxs || idx == ast.int_literal_type_idx
		|| idx == ast.rune_type_idx || idx == ast.char_type_idx
		|| (g.sym(ft).kind == .enum && g.is_flag_enum(ft))
}

fn (g &Gen) is_unsigned_type(t ast.Type) bool {
	ft := g.unwrap_alias(t)
	return !ft.is_ptr() && ft.idx() in ast.unsigned_integer_type_idxs
}

fn (g &Gen) is_float_type(t ast.Type) bool {
	if t.has_option_or_result() {
		return false
	}
	ft := g.unwrap_alias(t)
	return !ft.is_ptr() && ft.idx() in ast.float_type_idxs
}

fn (g &Gen) is_number_type(t ast.Type) bool {
	return g.is_int_type(t) || g.is_float_type(t)
}

fn (g &Gen) is_string_type(t ast.Type) bool {
	ft := g.unwrap_alias(t)
	return !ft.is_ptr() && ft.idx() == ast.string_type_idx
}

fn (g &Gen) is_bool_type(t ast.Type) bool {
	ft := g.unwrap_alias(t)
	return !ft.is_ptr() && ft.idx() == ast.bool_type_idx
}

fn (g &Gen) is_rune_type(t ast.Type) bool {
	ft := g.unwrap_alias(t)
	return !ft.is_ptr() && ft.idx() == ast.rune_type_idx
}

fn (g &Gen) kind_of(t ast.Type) ast.Kind {
	return g.final_sym(t).kind
}

fn (g &Gen) is_array_type(t ast.Type) bool {
	k := g.kind_of(t)
	return k == .array || k == .array_fixed
}

fn (g &Gen) is_map_type(t ast.Type) bool {
	return g.kind_of(t) == .map
}

fn (g &Gen) is_enum_type(t ast.Type) bool {
	return g.kind_of(t) == .enum
}

fn (g &Gen) is_flag_enum(t ast.Type) bool {
	sym := g.final_sym(t)
	if sym.info is ast.Enum {
		return sym.info.is_flag
	}
	return false
}

// is_struct_type: a V struct (by value or reference).
fn (g &Gen) is_struct_type(t ast.Type) bool {
	return g.kind_of(t) == .struct
}

// is_value_struct: a struct held by value, which V copies on assignment (clone it in JavaScript).
fn (g &Gen) is_value_struct(t ast.Type) bool {
	if t.is_ptr() || t.has_flag(.result) {
		return false
	}
	ut := g.unwrap_alias(t)
	if ut.is_ptr() {
		return false
	}
	sym := g.sym(ut)
	if sym.kind != .struct {
		return false
	}
	if sym.info is ast.Struct {
		if sym.info.is_heap {
			return false // @[heap] structs are always used through references
		}
	}
	return true
}

// is_reference: compared by identity (`===`): pointers, interfaces, functions, heap structs.
fn (g &Gen) is_reference(t ast.Type) bool {
	if t.is_ptr() || t.is_any_kind_of_pointer() {
		return true
	}
	k := g.kind_of(t)
	return k in [.interface, .function, .voidptr, .chan, .thread]
}

// mod_namespace: the JavaScript name a V module is reachable under in generated code.
fn (mut g Gen) mod_namespace(mod string) string {
	if mod == '' || mod == g.mod {
		return ''
	}
	if mod == 'builtin' {
		return 'V' // builtin constants (max_i32, ...) and functions live in the V helper module
	}
	if mod.starts_with('velo.') {
		ns := mod.all_after('velo.').replace('.', '_')
		g.used_ns[ns] = true
		return ns
	}
	if mod in runtime_vlib_modules {
		ns := mod.replace('.', '_')
		g.used_ns[ns] = true
		return ns
	}
	if mod in g.user_mods {
		ns := user_mod_ns(mod)
		g.user_imports[mod] = true
		return ns
	}
	g.error_once('module "${mod}" is not available in the WebGL runtime')
	return mod.replace('.', '_')
}

fn user_mod_ns(mod string) string {
	return 'm_' + mod.replace('.', '_')
}

// qualify: `name` declared in module `mod`, as referenced from the current module.
// (`name` is the V name: mangled when it is a local JavaScript identifier, as is after `ns.`)
fn (mut g Gen) qualify(mod string, name string) string {
	ns := g.mod_namespace(mod)
	if ns == '' {
		return js_name(name)
	}
	return '${ns}.${name}'
}

// short_name: the declaration name without its module (`velo.core.Node` -> `Node`, `main.Bob` -> `Bob`).
fn short_name(full string) string {
	base := full.all_before('[')
	return base.all_after_last('.')
}

// class_ref: the JavaScript expression naming a struct's class.
fn (mut g Gen) class_ref(t ast.Type) string {
	ut := g.unwrap_alias(t.clear_flags(.option, .result).set_nr_muls(0))
	sym := g.sym(ut)
	mut name := sym.name
	mut mod := sym.mod
	if sym.info is ast.Struct {
		if sym.info.parent_type != 0 && sym.generic_types.len == 0 {
			// generic instance (AssetRef[Texture]): the generic struct's class
			psym := g.sym(sym.info.parent_type)
			name = psym.name
			mod = psym.mod
		}
	}
	if sym.kind == .generic_inst && sym.info is ast.GenericInst {
		psym := g.table.sym_by_idx(sym.info.parent_idx)
		name = psym.name
		mod = psym.mod
	}
	if mod == 'builtin' {
		match short_name(name) {
			'IError', 'Error', 'MessageError' { return 'V.VError' }
			else { return 'Object' }
		}
	}
	return g.qualify(mod, short_name(name))
}

// generic_args_of: the concrete type arguments of a generic struct instance (AssetRef[Texture] -> [Texture]).
fn (g &Gen) generic_args_of(t ast.Type) []ast.Type {
	sym := g.sym(g.unwrap_alias(t.set_nr_muls(0)))
	if sym.info is ast.Struct {
		if sym.info.concrete_types.len > 0 {
			return sym.info.concrete_types
		}
	}
	if sym.info is ast.GenericInst {
		return sym.info.concrete_types
	}
	return []
}

fn (g &Gen) is_asset_ref(t ast.Type) bool {
	sym := g.sym(g.unwrap_alias(t.set_nr_muls(0)))
	return sym.name.starts_with('velo.assets.AssetRef[') || sym.name == 'velo.assets.AssetRef'
}

// type_desc: a runtime type descriptor (see V.TypeDesc in webgl/runtime/v.ts) for type arguments and `is`.
fn (mut g Gen) type_desc(t ast.Type) string {
	typ := t.clear_flags(.option, .result).set_nr_muls(0)
	if g.cur_generic_names.len > 0 {
		gname := g.table.type_to_str(typ)
		if gname in g.cur_generic_names {
			return js_name(gname)
		}
	}
	ut := g.unwrap_alias(typ)
	sym := g.sym(ut)
	match sym.kind {
		.struct {
			return g.class_ref(ut)
		}
		.interface {
			if sym.mod == 'builtin' {
				return 'V.VError'
			}
			return g.qualify(sym.mod, short_name(sym.name))
		}
		.array, .array_fixed {
			return "'[]'"
		}
		.map {
			return "'map'"
		}
		.function {
			return "'fn'"
		}
		.sum_type, .enum {
			return js_string(short_name(sym.name))
		}
		else {
			return js_string(sym.name)
		}
	}
}

// zero_value: the JavaScript expression for V's zero value of `t` (struct fields without a default, `[]T{len: n}`).
fn (mut g Gen) zero_value(t ast.Type) string {
	if t.has_flag(.option) {
		return 'null'
	}
	if g.cur_generic_names.len > 0 {
		gname := g.table.type_to_str(t)
		if gname in g.cur_generic_names {
			return 'V.zero(${js_name(gname)})'
		}
	}
	if t.is_ptr() || t.is_any_kind_of_pointer() {
		return 'null'
	}
	ut := g.unwrap_alias(t)
	if ut.is_ptr() {
		return 'null'
	}
	idx := ut.idx()
	if idx == ast.string_type_idx {
		return "''"
	}
	if idx == ast.bool_type_idx {
		return 'false'
	}
	if idx in ast.number_type_idxs
		|| idx in [ast.rune_type_idx, ast.char_type_idx, ast.int_literal_type_idx, ast.float_literal_type_idx] {
		return '0'
	}
	sym := g.sym(ut)
	match sym.kind {
		.array {
			return '[]'
		}
		.array_fixed {
			if sym.info is ast.ArrayFixed {
				return 'V.make_array(${sym.info.size}, () => ${g.zero_value(sym.info.elem_type)})'
			}
			return '[]'
		}
		.map {
			return 'new Map()'
		}
		.enum {
			if sym.info is ast.Enum {
				if sym.info.is_flag {
					return '0'
				}
				if sym.info.vals.len > 0 {
					return js_string(sym.info.vals[0])
				}
			}
			return "''"
		}
		.struct {
			return g.new_struct(ut, []string{}, []string{})
		}
		.multi_return {
			return '[]'
		}
		else {
			return 'null'
		}
	}
}

// new_struct: `T{name0: val0, ...}` with every other field at its default.
fn (mut g Gen) new_struct(t ast.Type, names []string, vals []string) string {
	ut := g.unwrap_alias(t.set_nr_muls(0).clear_flags(.option, .result))
	sym := g.sym(ut)
	if g.is_asset_ref(ut) {
		mut id := "''"
		for i, n in names {
			if n == 'id' {
				id = vals[i]
			}
		}
		args := g.generic_args_of(ut)
		tdesc := if args.len > 0 { g.type_desc(args[0]) } else { 'null' }
		return 'new ${g.class_ref(ut)}(${id}, ${tdesc})'
	}
	if pos_fields := positional_types[sym.name] {
		mut args := []string{len: pos_fields.len, init: 'undefined'}
		for i, n in names {
			fi := pos_fields.index(n)
			if fi >= 0 {
				args[fi] = vals[i]
			}
		}
		for args.len > 0 && args.last() == 'undefined' {
			args.delete_last()
		}
		return 'new ${g.class_ref(ut)}(${args.join(', ')})'
	}
	cls := g.class_ref(ut)
	if names.len == 0 {
		return 'new ${cls}()'
	}
	mut fields := []string{}
	for i, n in names {
		fields << '${n}: ${vals[i]}'
	}
	return 'V.make(${cls}, {${fields.join(', ')}})'
}

// is_params_struct: a `@[params]` struct (named arguments) declared by the engine, passed as a plain object.
fn (g &Gen) is_runtime_params_struct(t ast.Type) bool {
	sym := g.sym(g.unwrap_alias(t.set_nr_muls(0)))
	if sym.info is ast.Struct {
		if !sym.mod.starts_with('velo.') && sym.mod !in runtime_vlib_modules {
			return false
		}
		return sym.info.attrs.any(it.name == 'params')
	}
	return false
}

// struct_fields: the fields of a struct type, in declaration order (embedded structs not expanded).
fn (g &Gen) struct_fields(t ast.Type) []ast.StructField {
	sym := g.sym(g.unwrap_alias(t.set_nr_muls(0)))
	if sym.info is ast.Struct {
		return sym.info.fields
	}
	return []
}

// field_spec: the serialization type of a component field, as serialize.set_fields understands it ('' = skipped).
fn (g &Gen) field_spec(t ast.Type) string {
	if t.is_ptr() || t.has_option_or_result() {
		return ''
	}
	sym := g.sym(t)
	match sym.name {
		'f32' { return 'f32' }
		'f64' { return 'f64' }
		'int' { return 'int' }
		'bool' { return 'bool' }
		'string' { return 'string' }
		'[]int' { return '[]int' }
		'velo.core.Vec2' { return 'Vec2' }
		'velo.core.Color' { return 'Color' }
		'velo.assets.AssetRef[velo.assets.Texture]' { return 'asset:texture' }
		'velo.assets.AssetRef[velo.assets.SceneAsset]' { return 'asset:scene' }
		'velo.assets.AssetRef[velo.assets.AudioClip]' { return 'asset:audio' }
		'velo.assets.AssetRef[velo.assets.TextAsset]' { return 'asset:text' }
		'velo.assets.AssetRef[velo.assets.Font]' { return 'asset:font' }
		else { return '' }
	}
}

// choices_of reads `@[choices: 'a|b|c']`.
fn choices_of(attrs []ast.Attr) []string {
	for a in attrs {
		if a.name == 'choices' {
			return a.arg.trim('\'"').split('|').map(it.trim_space())
		}
		if a.name.starts_with('choices:') {
			return a.name.all_after(':').trim_space().trim('\'"').split('|').map(it.trim_space())
		}
	}
	return []
}

fn has_attr(attrs []ast.Attr, name string) bool {
	return attrs.any(it.name == name)
}

// method_ns: the helper object of the WebGL runtime holding methods of a builtin type (`V.S` for strings, ...).
fn (g &Gen) method_ns(t ast.Type) string {
	if t.is_ptr() {
		return ''
	}
	ut := g.unwrap_alias(t)
	if ut.is_ptr() {
		return ''
	}
	idx := ut.idx()
	if idx == ast.string_type_idx {
		return 'V.S'
	}
	if idx == ast.rune_type_idx {
		return 'V.R'
	}
	if idx == ast.bool_type_idx {
		return 'V.B'
	}
	if idx in ast.float_type_idxs {
		return 'V.F'
	}
	if idx in ast.integer_type_idxs || idx == ast.int_literal_type_idx || idx == ast.char_type_idx {
		return 'V.N'
	}
	k := g.sym(ut).kind
	if k == .array || k == .array_fixed {
		return 'V.A'
	}
	if k == .map {
		return 'V.M'
	}
	return ''
}

// operator_method: the JavaScript method name of a V operator overload.
fn operator_method(op string) string {
	return match op {
		'+' { 'op_add' }
		'-' { 'op_sub' }
		'*' { 'op_mul' }
		'/' { 'op_div' }
		'%' { 'op_mod' }
		'==' { 'op_eq' }
		'<' { 'op_lt' }
		else { '' }
	}
}
