module main

import v.ast

// Array methods whose argument is an expression using `it` (or `a`/`b` for sorting).
const it_methods = ['filter', 'map', 'any', 'all', 'count']
// methods that change the array/map they are called on (`m[k].delete(0)` must create the map item first)
const mutating_methods = ['delete', 'insert', 'prepend', 'clear', 'trim', 'sort', 'sort_with_compare',
	'reverse_in_place', 'delete_many', 'delete_last', 'pop', 'drop', 'reset']
const sort_methods = ['sort', 'sorted']

fn (mut g Gen) call_expr(node ast.CallExpr) string {
	if node.should_be_skipped {
		return ''
	}
	if node.language != .v {
		return g.unsupported(node.pos, 'calling ${node.language} code (`${node.name}`)')
	}
	code := if node.is_method { g.method_call(node) } else { g.fn_call(node) }
	return g.with_or(code, node.or_block, node.return_type, node.pos)
}

// call_args generates the arguments of a call to `f` (variadic arguments packed into an array).
fn (mut g Gen) call_args(node ast.CallExpr, f ?ast.Fn) []string {
	mut out := []string{}
	mut variadic_at := -1
	if fun := f {
		if fun.is_variadic {
			variadic_at = fun.params.len - 1 - if fun.is_method { 1 } else { 0 }
		}
	}
	for i, a in node.args {
		if variadic_at >= 0 && i >= variadic_at {
			if a.expr is ast.ArrayDecompose {
				out << g.expr(a.expr.expr)
				break
			}
			mut rest := []string{}
			for va in node.args[i..] {
				rest << g.expr_value(va.expr, va.typ)
			}
			out << '[${rest.join(', ')}]'
			break
		}
		out << g.expr(a.expr)
	}
	return out
}

// type_args: the concrete type arguments passed first to a generic function of the game or the engine.
fn (mut g Gen) type_args(node ast.CallExpr, f ast.Fn, receiver ast.Type) []string {
	if f.generic_names.len == 0 {
		return []
	}
	if f.mod in runtime_vlib_modules || f.mod == 'builtin' {
		return []
	}
	rec_generics := if receiver != 0 { g.receiver_generic_names(receiver) } else { []string{} }
	mut out := []string{}
	for i, gn in f.generic_names {
		if gn in rec_generics {
			continue
		}
		if i < node.concrete_types.len {
			out << g.type_desc(node.concrete_types[i])
		} else {
			out << 'null'
		}
	}
	return out
}

fn (mut g Gen) fn_call(node ast.CallExpr) string {
	name := node.name
	// builtin functions
	match name {
		'println', 'print', 'eprintln', 'eprint' {
			arg := if node.args.len > 0 {
				g.to_string(g.expr(node.args[0].expr), node.args[0].typ)
			} else {
				"''"
			}
			return 'V.${name}(${arg})'
		}
		'panic' {
			return 'V.panic(${g.expr(node.args[0].expr)})'
		}
		'exit' {
			return 'V.exit(${g.expr(node.args[0].expr)})'
		}
		'error' {
			return 'V.error(${g.expr(node.args[0].expr)})'
		}
		'error_with_code' {
			return 'V.error_with_code(${g.expr(node.args[0].expr)}, ${g.expr(node.args[1].expr)})'
		}
		'isnil' {
			return '(${g.expr(node.args[0].expr)} == null)'
		}
		'free', 'gc_collect', 'gc_disable', 'gc_enable', 'print_backtrace', 'flush_stdout',
		'flush_stderr' {
			return ''
		}
		'arguments' {
			return '[]'
		}
		'sizeof', '__sizeof' {
			return '8'
		}
		'copy' {
			return 'V.copy(${g.expr(node.args[0].expr)}, ${g.expr(node.args[1].expr)})'
		}
		'malloc', 'vcalloc', 'memdup', 'C.memcpy', 'vmemcpy' {
			return g.unsupported(node.pos, 'manual memory (`${name}`)')
		}
		else {}
	}

	if node.is_fn_var || node.is_fn_a_const {
		args := g.call_args(node, none)
		callee := if node.is_fn_a_const {
			g.qualify(node.const_name.all_before_last('.'), short_name(node.const_name))
		} else {
			js_name(name)
		}
		return '${callee}(${args.join(', ')})'
	}
	f := g.table.find_fn(name) or {
		// a local variable holding a function (closure parameter, ...)
		args := g.call_args(node, none)
		return '${js_name(name)}(${args.join(', ')})'
	}
	if f.is_static_type_method {
		// `Foo.new(...)` is a static method of Foo's class
		mut args := g.type_args(node, f, 0)
		args << g.call_args(node, f)
		cls := g.class_ref(f.receiver_type)
		mname := short_name(name.all_after('__static__'))
		return '${cls}.${mname}(${args.join(', ')})'
	}
	mut args := g.type_args(node, f, 0)
	args << g.call_args(node, f)
	callee := g.qualify(f.mod, short_name(name))
	return '${callee}(${args.join(', ')})'
}

fn (mut g Gen) method_call(node ast.CallExpr) string {
	name := node.name
	ltype := node.left_type
	// a struct field holding a function: `obj.on_done()`
	if node.is_field {
		obj := g.expr(node.left)
		args := g.call_args(node, none)
		return '${obj}.${name}(${args.join(', ')})'
	}
	if node.is_static_method {
		cls := g.class_ref(if node.receiver_type != 0 { node.receiver_type } else { ltype })
		f := g.find_method(ltype, name)
		mut args := []string{}
		if fun := f {
			args << g.type_args(node, fun, 0)
		}
		args << g.call_args(node, f)
		return '${cls}.${name}(${args.join(', ')})'
	}
	// `x.type_name()` / `x.str()` on interfaces and sum types
	if name == 'type_name' && node.args.len == 0 {
		return 'V.type_name_of(${g.expr(node.left)})'
	}
	lsym := g.final_sym(ltype)
	user_method := g.find_method(ltype, name)
	// methods of builtin types (string, arrays, maps, numbers), unless the game defines them (on an alias)
	if user_method == none || g.is_builtin_mod(user_method) {
		ns := g.method_ns(ltype.set_nr_muls(0))
		if ns != '' {
			return g.builtin_method(node, ns)
		}
	}
	obj := g.expr(node.left)
	match lsym.kind {
		.enum {
			if fun := user_method {
				if !g.is_builtin_mod(user_method) && !(g.is_flag_enum(ltype)
					&& name in flag_enum_methods) {
					mut args := [obj]
					args << g.call_args(node, fun)
					return '${g.qualify(fun.mod, short_name(g.sym(fun.receiver_type).name) + '__' +
						name)}(${args.join(', ')})'
				}
			}
			return g.enum_builtin_method(node, obj)
		}
		.sum_type, .alias {
			if fun := user_method {
				rsym := g.sym(fun.receiver_type)
				// vlib types (strings.Builder = []u8, ...) are classes in the runtime: plain method calls
				if rsym.kind in [.sum_type, .alias, .enum] && fun.mod !in runtime_vlib_modules {
					mut args := [obj]
					args << g.call_args(node, fun)
					return '${g.qualify(fun.mod, short_name(rsym.name) + '__' + name)}(${args.join(', ')})'
				}
			}
		}
		else {}
	}

	if fun := user_method {
		rsym := g.sym(fun.receiver_type)
		if rsym.kind in [.sum_type, .alias, .enum] && lsym.kind != .struct
			&& fun.mod !in runtime_vlib_modules {
			mut args := [obj]
			args << g.call_args(node, fun)
			return '${g.qualify(fun.mod, short_name(rsym.name) + '__' + name)}(${args.join(', ')})'
		}
		mut args := g.type_args(node, fun, fun.receiver_type)
		args << g.call_args(node, fun)
		mname := if operator_method(name) != '' { operator_method(name) } else { name }
		return '${obj}.${mname}(${args.join(', ')})'
	}
	if name == 'str' && node.args.len == 0 {
		return g.to_string(obj, ltype)
	}
	if name in ['msg', 'code'] {
		return '${obj}.${name}()'
	}
	if name == 'free' {
		return ''
	}
	// interfaces and anything else: call the method by name
	args := g.call_args(node, none)
	return '${obj}.${name}(${args.join(', ')})'
}

fn (g &Gen) is_builtin_mod(f ?ast.Fn) bool {
	if fun := f {
		return fun.mod == 'builtin' || fun.mod == ''
	}
	return false
}

// find_method: the method `name` of a type, looking through embedded structs.
fn (g &Gen) find_method(t ast.Type, name string) ?ast.Fn {
	sym := g.sym(t.clear_flags(.option, .result).set_nr_muls(0))
	if f := g.table.find_method_with_embeds(sym, name) {
		return f
	}
	fsym := g.final_sym(t.clear_flags(.option, .result).set_nr_muls(0))
	if f := g.table.find_method_with_embeds(fsym, name) {
		return f
	}
	return none
}

// builtin_method: methods of strings, arrays, maps and numbers, provided by V.S / V.A / V.M / V.N / V.F / V.R.
fn (mut g Gen) builtin_method(node ast.CallExpr, ns string) string {
	name := node.name
	obj := if ns in ['V.A', 'V.M'] && name in mutating_methods {
		g.place(node.left)
	} else {
		g.expr(node.left)
	}
	ltype := node.left_type.set_nr_muls(0)
	if ns == 'V.A' {
		if name in it_methods && node.args.len == 1 {
			return '${ns}.${name}(${obj}, ${g.it_fn(node.args[0].expr, 'it')})'
		}
		if name in sort_methods {
			if node.args.len == 0 {
				return '${ns}.${name}(${obj})'
			}
			return '${ns}.${name}(${obj}, ${g.it_fn(node.args[0].expr, 'a, b')})'
		}
		if name == 'clone' {
			return '${obj}.slice()'
		}
		if name == 'len' {
			return '${obj}.length'
		}
		if name == 'contains' && node.args.len == 1 {
			elem := g.array_elem_type(ltype)
			arg := g.expr(node.args[0].expr)
			if g.is_struct_type(elem) || g.is_array_type(elem) {
				return 'V.A.contains(${obj}, ${arg})'
			}
			return '${obj}.includes(${arg})'
		}
		if name in ['insert', 'prepend'] && node.args.len >= 1 {
			mut args := []string{}
			for a in node.args {
				args << g.expr_value(a.expr, a.typ)
			}
			return '${ns}.${name}(${obj}, ${args.join(', ')})'
		}
	}
	if ns == 'V.S' && name == 'str' {
		return obj
	}
	if ns == 'V.N' && name == 'str' {
		return 'String(${obj})'
	}
	mut args := [obj]
	for a in node.args {
		args << g.expr(a.expr)
	}
	return '${ns}.${name}(${args.join(', ')})'
}

// it_fn: a function for `arr.filter(it > 0)` / `arr.sort(a.x < b.x)` (or the function passed as is).
fn (mut g Gen) it_fn(e ast.Expr, params string) string {
	match e {
		ast.AnonFn, ast.LambdaExpr {
			return g.expr(e)
		}
		ast.Ident {
			if e.kind == .function || e.name.contains('.') {
				return g.expr(e)
			}
			if e.obj is ast.Var {
				if g.kind_of(e.obj.typ) == .function {
					return js_name(e.name)
				}
			}
		}
		else {}
	}

	old := g.begin_capture()
	g.indent++
	body := g.expr(e)
	g.indent--
	pre := g.end_capture(old)
	if pre == '' {
		return '((${params}) => ${body})'
	}
	pad := '\t'.repeat(g.indent)
	return '((${params}) => {\n${pre}${pad}\treturn ${body}\n${pad}})'
}

// enum_builtin_method: `.str()`, and the bit operations of @[flag] enums.
fn (mut g Gen) enum_builtin_method(node ast.CallExpr, obj string) string {
	name := node.name
	mut args := []string{}
	for a in node.args {
		args << g.expr(a.expr)
	}
	if g.is_flag_enum(node.left_type) {
		match name {
			'has' { return '((${obj} & ${args[0]}) !== 0)' }
			'all' { return '((${obj} & ${args[0]}) === ${args[0]})' }
			'set' { return '(${obj} = ${obj} | ${args[0]})' }
			'clear' { return '(${obj} = ${obj} & ~${args[0]})' }
			'toggle' { return '(${obj} = ${obj} ^ ${args[0]})' }
			'set_all' { return '(${obj} = ${g.flag_all(node.left_type)})' }
			'clear_all' { return '(${obj} = 0)' }
			'is_empty' { return '(${obj} === 0)' }
			'zero' { return '0' }
			'str' { return 'String(${obj})' }
			else {}
		}
	}
	if name == 'str' {
		return obj
	}
	return g.unsupported(node.pos, 'enum method `${name}`')
}

// flag_all: every bit of a @[flag] enum set.
fn (g &Gen) flag_all(t ast.Type) string {
	sym := g.final_sym(t)
	if sym.info is ast.Enum {
		return ((u64(1) << sym.info.vals.len) - 1).str()
	}
	return '0'
}
