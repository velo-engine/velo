module main

import os
import strings
import v.ast
import v.token

// Gen — turns the checked AST of one V module into one JavaScript (ES module) file.
struct Gen {
	table       &ast.Table
	project_dir string
	user_mods   []string // modules of the game (transpiled), as opposed to velo.* / vlib (provided by the runtime)
	comptime    map[string]bool
mut:
	mod               string // the module being generated, e.g. 'main'
	out               strings.Builder
	indent            int
	tmp_count         int
	used_ns           map[string]bool // runtime namespaces referenced (core, render, math, ...)
	user_imports      map[string]bool // other game modules referenced
	errors            []string
	warnings          []string
	reported          map[string]bool
	file_path         string // current V file (for messages)
	fn_decl           &ast.FnDecl = unsafe { nil }
	fn_ret            ast.Type // return type of the function being generated
	cur_generic_names []string
	defer_var         string // the defer list of the current function ('' = none)
	in_lambda_ret     bool
	loop_writeback    []string
}

fn new_gen(table &ast.Table, project_dir string, user_mods []string) Gen {
	return Gen{
		table:       table
		project_dir: project_dir
		user_mods:   user_mods
		out:         strings.new_builder(64 * 1024)
	}
}

// ---------- Output ----------

fn (mut g Gen) writeln(s string) {
	if s == '' {
		g.out.writeln('')
		return
	}
	g.out.write_string('\t'.repeat(g.indent))
	// no semicolons are written: a statement starting like this would continue the previous line
	if s[0] in [`(`, `[`, `\``, `+`, `-`, `/`] {
		g.out.write_u8(`;`)
	}
	g.out.writeln(s)
}

fn (mut g Gen) tmp() string {
	g.tmp_count++
	return '_t${g.tmp_count}'
}

// capture generates code into a separate buffer; returns what was written (the hoisted statements).
fn (mut g Gen) begin_capture() strings.Builder {
	old := g.out
	g.out = strings.new_builder(256)
	return old
}

fn (mut g Gen) end_capture(old strings.Builder) string {
	s := g.out.str()
	g.out = old
	return s
}

// write_raw writes already-indented captured code.
fn (mut g Gen) write_raw(code string) {
	g.out.write_string(code)
}

// ---------- Messages ----------

fn (mut g Gen) pos_str(pos token.Pos) string {
	rel := g.file_path.replace(g.project_dir + '/', '')
	return '${rel}:${pos.line_nr + 1}'
}

fn (mut g Gen) error_at(pos token.Pos, msg string) {
	g.errors << '${g.pos_str(pos)}: ${msg}'
}

fn (mut g Gen) warn_at(pos token.Pos, msg string) {
	key := '${g.pos_str(pos)}: ${msg}'
	if key in g.reported {
		return
	}
	g.reported[key] = true
	g.warnings << key
}

fn (mut g Gen) error_once(msg string) {
	if msg in g.reported {
		return
	}
	g.reported[msg] = true
	g.errors << msg
}

// unsupported reports a V feature the WebGL runtime cannot run and returns code that panics if reached.
fn (mut g Gen) unsupported(pos token.Pos, what string) string {
	g.error_at(pos, '${what} is not supported in WebGL builds')
	return 'V.panic(${js_string('not supported in WebGL builds: ' + what)})'
}

// ---------- Module ----------

struct ModuleDecls {
mut:
	structs     []ast.StructDecl
	ifaces      []ast.InterfaceDecl
	enums       []ast.EnumDecl
	consts      []ast.ConstField
	globals     []ast.GlobalField
	fns         []&ast.FnDecl
	file_of     map[string]string // decl name -> file path
	const_file  []string
	fn_file     []string
	struct_file []string
}

// gen_module generates the JavaScript of a whole V module from its files.
fn (mut g Gen) gen_module(mod string, files []&ast.File) string {
	g.mod = mod
	g.out = strings.new_builder(64 * 1024)
	g.used_ns = map[string]bool{}
	g.user_imports = map[string]bool{}
	g.tmp_count = 0
	mut d := ModuleDecls{}
	for f in files {
		for stmt in f.stmts {
			match stmt {
				ast.StructDecl {
					if stmt.language == .v {
						d.structs << stmt
						d.struct_file << f.path
					}
				}
				ast.InterfaceDecl {
					d.ifaces << stmt
				}
				ast.EnumDecl {
					d.enums << stmt
				}
				ast.ConstDecl {
					for cf in stmt.fields {
						if !cf.is_virtual_c {
							d.consts << cf
							d.const_file << f.path
						}
					}
				}
				ast.GlobalDecl {
					for gf in stmt.fields {
						d.globals << gf
					}
				}
				ast.FnDecl {
					if stmt.language == .v && !stmt.no_body && !g.is_flag_enum_builtin(stmt) {
						d.fns << unsafe { &stmt }
						d.fn_file << f.path
					}
				}
				else {}
			}
		}
	}
	// methods grouped by receiver struct
	mut methods := map[string][]int{} // struct type name -> indexes in d.fns
	mut free_fns := []int{}
	for i, f in d.fns {
		if f.is_method || f.is_static_type_method {
			rt := if f.is_static_type_method {
				f.receiver.typ
			} else {
				f.receiver.typ.set_nr_muls(0)
			}
			rsym := g.sym(rt)
			if rsym.kind == .struct && rsym.mod == mod {
				methods[rsym.name] << i
				continue
			}
		}
		free_fns << i
	}
	// classes, base classes first
	order := g.struct_order(d.structs)
	for si in order {
		sd := d.structs[si]
		g.file_path = d.struct_file[si]
		g.gen_class(sd, d.fns, methods[sd.name] or { []int{} }, d.fn_file)
		g.writeln('')
	}
	for idecl in d.ifaces {
		mut members := []string{}
		for m in idecl.methods {
			members << js_string(m.name)
		}
		for fld in idecl.fields {
			members << js_string(fld.name)
		}
		name := short_name(idecl.name)
		g.writeln('export const ${js_name(name)} = V.iface(${js_string(mod + '.' + name)}, [${members.join(', ')}])')
	}
	for ed in d.enums {
		g.gen_enum(ed)
	}
	if d.ifaces.len > 0 || d.enums.len > 0 {
		g.writeln('')
	}
	for i, cf in d.consts {
		g.file_path = d.const_file[i]
		g.fn_decl = unsafe { nil }
		g.defer_var = ''
		val := g.expr_value(cf.expr, cf.typ)
		g.writeln('export const ${js_name(short_name(cf.name))} = ${val}')
	}
	for gf in d.globals {
		val := if gf.has_expr { g.expr_value(gf.expr, gf.typ) } else { g.zero_value(gf.typ) }
		g.writeln('export let ${js_name(short_name(gf.name))} = ${val}')
	}
	if d.consts.len > 0 || d.globals.len > 0 {
		g.writeln('')
	}
	for i in free_fns {
		g.file_path = d.fn_file[i]
		g.gen_fn(d.fns[i], false)
		g.writeln('')
	}
	body := g.out.str()
	// header: imports of what was used
	mut head := strings.new_builder(1024)
	head.writeln('// Generated by tools/v2js from V module `${mod}` — do not edit.')
	mut ns := ['V']
	mut keys := g.used_ns.keys()
	keys.sort()
	for k in keys {
		ns << k
	}
	head.writeln('import { ${ns.join(', ')} } from \'velo-runtime\'')
	mut ukeys := g.user_imports.keys()
	ukeys.sort()
	for u in ukeys {
		head.writeln('import * as ${user_mod_ns(u)} from \'./${u}.js\'')
	}
	head.writeln('')
	return head.str() + body
}

// struct_order: structs sorted so a struct comes after the struct it embeds (JavaScript `extends`).
fn (g &Gen) struct_order(structs []ast.StructDecl) []int {
	mut done := map[string]bool{}
	mut out := []int{}
	mut passes := 0
	for out.len < structs.len && passes <= structs.len {
		passes++
		for i, sd in structs {
			if sd.name in done {
				continue
			}
			mut ready := true
			for e in sd.embeds {
				ename := g.sym(e.typ).name
				if structs.any(it.name == ename) && ename !in done {
					ready = false
				}
			}
			if ready {
				done[sd.name] = true
				out << i
			}
		}
	}
	return out
}

fn (mut g Gen) gen_class(sd ast.StructDecl, fns []&ast.FnDecl, method_idxs []int, fn_files []string) {
	name := short_name(sd.name)
	cls := js_name(name)
	mut extends := ''
	if sd.embeds.len > 0 {
		extends = ' extends ${g.class_ref(sd.embeds[0].typ)}'
	}
	g.writeln('export class ${cls}${extends} {')
	g.indent++
	g.writeln('static __vname = ${js_string(g.mod + '.' + name)}')
	// serializable fields (what V's `$for field in T.fields` reflection sees: own fields, no @[hide])
	mut specs := []string{}
	for fld in sd.fields {
		if has_attr(fld.attrs, 'hide') {
			continue
		}
		spec := g.field_spec(fld.typ)
		if spec == '' {
			continue
		}
		choices := choices_of(fld.attrs)
		if choices.len > 0 {
			specs << '{ name: ${js_string(fld.name)}, type: ${js_string(spec)}, choices: [${choices.map(js_string(it)).join(', ')}] }'
		} else {
			specs << '{ name: ${js_string(fld.name)}, type: ${js_string(spec)} }'
		}
	}
	g.writeln('static __fields = [${specs.join(', ')}]')
	for fld in sd.fields {
		g.fn_decl = unsafe { nil }
		val := if fld.has_default_expr {
			g.expr_value(fld.default_expr, fld.typ)
		} else {
			g.zero_value(fld.typ)
		}
		g.writeln('${fld.name} = ${val}')
	}
	if sd.embeds.len > 1 {
		g.writeln('constructor() {')
		g.indent++
		g.writeln('super()')
		for e in sd.embeds[1..] {
			g.writeln('V.init_embed(this, ${g.class_ref(e.typ)})')
		}
		g.indent--
		g.writeln('}')
	}
	// clone: V copies structs held by value
	g.writeln('clone() {')
	g.indent++
	g.writeln('const o = Object.assign(Object.create(Object.getPrototypeOf(this)), this)')
	for fld in sd.fields {
		if g.is_value_struct(fld.typ) {
			g.writeln('o.${fld.name} = V.clone(this.${fld.name})')
		}
	}
	g.writeln('return o')
	g.indent--
	g.writeln('}')
	for i in method_idxs {
		g.file_path = fn_files[i]
		g.gen_fn(fns[i], true)
	}
	g.indent--
	g.writeln('}')
	if sd.embeds.len > 1 {
		for e in sd.embeds[1..] {
			g.writeln('V.mixin(${cls}, ${g.class_ref(e.typ)})')
		}
	}
}

fn (mut g Gen) gen_enum(ed ast.EnumDecl) {
	name := js_name(short_name(ed.name))
	mut vals := []string{}
	mut ints := []string{}
	mut next := i64(0)
	for f in ed.fields {
		vals << js_string(f.name)
		mut v := next
		if f.has_expr {
			v = g.const_int(f.expr) or { next }
		}
		ints << '${js_string(f.name)}: ${if ed.is_flag {
			(u64(1) << ints.len).str()
		} else {
			v.str()
		}}'
		next = v + 1
	}
	if ed.is_flag {
		// @[flag] enums are bit sets: their values are numbers
		for i, f in ed.fields {
			g.writeln('export const ${name}__${f.name} = ${u64(1) << i}')
		}
	}
	g.writeln('export const ${name}__values = [${vals.join(', ')}]')
	g.writeln('export const ${name}__ints = { ${ints.join(', ')} }')
}

// const_int evaluates a constant integer expression of an enum value.
fn (g &Gen) const_int(e ast.Expr) ?i64 {
	match e {
		ast.IntegerLiteral {
			return js_number(e.val).i64()
		}
		ast.PrefixExpr {
			if e.op == .minus {
				v := g.const_int(e.right)?
				return -v
			}
		}
		ast.ParExpr {
			return g.const_int(e.expr)
		}
		ast.InfixExpr {
			a := g.const_int(e.left)?
			b := g.const_int(e.right)?
			return match e.op {
				.plus { a + b }
				.minus { a - b }
				.mul { a * b }
				.left_shift { i64(u64(a) << b) }
				.pipe { a | b }
				else { none }
			}
		}
		ast.CharLiteral {
			return i64(char_code(e.val))
		}
		else {}
	}

	return none
}

// ---------- Functions ----------

fn (mut g Gen) gen_fn(f &ast.FnDecl, in_class bool) {
	prev_fn := g.fn_decl
	prev_ret := g.fn_ret
	prev_generics := g.cur_generic_names
	prev_defer := g.defer_var
	g.fn_decl = unsafe { f }
	g.fn_ret = f.return_type
	g.cur_generic_names = f.generic_names.clone()
	g.defer_var = ''
	defer {
		g.fn_decl = prev_fn
		g.fn_ret = prev_ret
		g.cur_generic_names = prev_generics
		g.defer_var = prev_defer
	}
	mut params := []string{}
	// type parameters of the function itself (not of a generic receiver) come first
	rec_generics := if f.is_method { g.receiver_generic_names(f.receiver.typ) } else { []string{} }
	for gn in f.generic_names {
		if gn !in rec_generics {
			params << js_name(gn)
		}
	}
	start := if f.is_method { 1 } else { 0 }
	for i in start .. f.params.len {
		p := f.params[i]
		mut ps := js_name(p.name)
		if p.name == '_' {
			ps = '_p${i}'
		}
		if f.is_variadic && i == f.params.len - 1 {
			ps += ' = []'
		} else if i == f.params.len - 1 && g.is_struct_type(p.typ) && !p.typ.is_ptr()
			&& has_attr(g.struct_attrs(p.typ), 'params') {
			ps += ' = ${g.zero_value(p.typ)}'
		}
		params << ps
	}
	mshort := f.short_name.all_after_last('__static__')
	name := if f.is_method || f.is_static_type_method {
		if in_class {
			fname := operator_method(mshort)
			if fname != '' {
				fname
			} else {
				mshort
			}
		} else {
			'${js_name(short_name(g.sym(f.receiver.typ).name))}__${mshort}'
		}
	} else {
		js_name(f.short_name)
	}
	if in_class {
		static_kw := if f.is_static_type_method { 'static ' } else { '' }
		g.writeln('${static_kw}${name}(${params.join(', ')}) {')
	} else {
		mut all := []string{}
		if f.is_method {
			all << js_name(f.receiver.name)
		}
		all << params
		g.writeln('export function ${name}(${all.join(', ')}) {')
	}
	g.indent++
	if f.is_method && in_class && f.receiver.name != '_' {
		g.writeln('const ${js_name(f.receiver.name)} = this')
	}
	if f.defer_stmts.len > 0 {
		g.defer_var = '_defers'
		g.writeln('const _defers = []')
		g.writeln('try {')
		g.indent++
		g.stmts(f.stmts)
		g.indent--
		g.writeln('} finally {')
		g.writeln('\tfor (let _i = _defers.length - 1; _i >= 0; _i--) _defers[_i]()')
		g.writeln('}')
	} else {
		g.stmts(f.stmts)
	}
	g.indent--
	g.writeln('}')
	if !in_class && !f.is_method && !f.is_static_type_method && name != f.short_name {
		// `fn new()` is `function new_()` here; other modules call it as `ns.new`
		g.writeln('export { ${name} as ${f.short_name} }')
	}
}

// is_flag_enum_builtin: the methods V generates for every @[flag] enum (has, set, ...): bit operations here.
fn (g &Gen) is_flag_enum_builtin(f ast.FnDecl) bool {
	if !f.is_method && !f.is_static_type_method {
		return false
	}
	if !g.is_flag_enum(f.receiver.typ) {
		return false
	}
	return f.short_name.all_after_last('__static__') in flag_enum_methods
}

const flag_enum_methods = ['is_empty', 'has', 'all', 'set', 'set_all', 'clear', 'clear_all', 'toggle',
	'zero', 'from']

fn (g &Gen) struct_attrs(t ast.Type) []ast.Attr {
	sym := g.sym(g.unwrap_alias(t.set_nr_muls(0)))
	if sym.info is ast.Struct {
		return sym.info.attrs
	}
	return []
}

// receiver_generic_names: the type parameters of a generic receiver (`fn (r AssetRef[T]) is_set()` -> ['T']).
fn (g &Gen) receiver_generic_names(t ast.Type) []string {
	sym := g.sym(t.set_nr_muls(0))
	if sym.info is ast.Struct {
		return sym.info.generic_types.map(g.table.type_to_str(it))
	}
	return []
}

// ---------- Driver ----------

// module_files groups the parsed files of the game by module.
fn module_files(files []&ast.File, project_dir string) map[string][]&ast.File {
	mut out := map[string][]&ast.File{}
	for f in files {
		if !os.real_path(f.path).starts_with(project_dir + '/') {
			continue
		}
		if f.mod.name !in out {
			out[f.mod.name] = []&ast.File{}
		}
		unsafe {
			out[f.mod.name] << f
		}
	}
	return out
}
