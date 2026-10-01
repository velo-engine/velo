module main

import v.ast
import v.token

// expr generates a JavaScript expression. Statements an expression needs first (or-blocks, if/match used
// as values, if-guards) are written to the output before the statement that uses the expression.
fn (mut g Gen) expr(node ast.Expr) string {
	match node {
		ast.IntegerLiteral {
			return js_number(node.val)
		}
		ast.FloatLiteral {
			return js_number(node.val)
		}
		ast.BoolLiteral {
			return if node.val { 'true' } else { 'false' }
		}
		ast.StringLiteral {
			if node.language == .c {
				return js_string(v_unescape(node.val, node.is_raw))
			}
			return js_string(v_unescape(node.val, node.is_raw))
		}
		ast.CharLiteral {
			return char_code(node.val).str()
		}
		ast.StringInterLiteral {
			return g.string_inter(node)
		}
		ast.None, ast.Nil {
			return 'null'
		}
		ast.Ident {
			return g.ident(node)
		}
		ast.SelectorExpr {
			return g.selector(node)
		}
		ast.IndexExpr {
			return g.index_expr(node)
		}
		ast.CallExpr {
			return g.call_expr(node)
		}
		ast.InfixExpr {
			return g.infix(node)
		}
		ast.PrefixExpr {
			return g.prefix(node)
		}
		ast.PostfixExpr {
			return g.postfix(node)
		}
		ast.ParExpr {
			inner := g.expr(node.expr)
			if inner.starts_with('(') && inner.ends_with(')') && is_balanced(inner) {
				return inner
			}
			return '(${inner})'
		}
		ast.UnsafeExpr {
			return g.expr(node.expr)
		}
		ast.Likely {
			return g.expr(node.expr)
		}
		ast.CastExpr {
			return g.cast(node)
		}
		ast.AsCast {
			return g.expr(node.expr)
		}
		ast.EnumVal {
			return g.enum_val(node.typ, node.val)
		}
		ast.StructInit {
			return g.struct_init(node)
		}
		ast.ArrayInit {
			return g.array_init(node)
		}
		ast.MapInit {
			return g.map_init(node)
		}
		ast.IfExpr {
			return g.if_value(node)
		}
		ast.MatchExpr {
			return g.match_value(node)
		}
		ast.AnonFn {
			return g.anon_fn(node)
		}
		ast.LambdaExpr {
			return g.lambda(node)
		}
		ast.ConcatExpr {
			mut vals := []string{}
			for v in node.vals {
				vals << g.expr(v)
			}
			return '[${vals.join(', ')}]'
		}
		ast.ArrayDecompose {
			return g.expr(node.expr)
		}
		ast.AtExpr {
			return g.at_expr(node)
		}
		ast.TypeNode {
			return g.type_desc(node.typ)
		}
		ast.TypeOf {
			t := if node.typ != 0 { node.typ } else { ast.void_type }
			return js_string(g.table.type_to_str(t))
		}
		ast.SizeOf {
			return '8'
		}
		ast.IsRefType {
			return 'false'
		}
		ast.DumpExpr {
			return 'V.dump(${g.expr(node.expr)}, ${js_string(node.expr.str())})'
		}
		ast.ComptimeCall {
			return g.comptime_call(node)
		}
		ast.Comment, ast.EmptyExpr {
			return ''
		}
		ast.IfGuardExpr {
			return g.unsupported(token.Pos{}, 'an if-guard outside of `if`')
		}
		ast.OrExpr {
			return ''
		}
		ast.RangeExpr {
			return g.unsupported(node.pos, 'a range used as a value')
		}
		ast.ChanInit, ast.GoExpr, ast.SpawnExpr, ast.SelectExpr, ast.LockExpr {
			return g.unsupported(node.pos, 'concurrency (go, spawn, chan, select, lock)')
		}
		ast.SqlExpr, ast.SqlQueryDataExpr {
			return g.unsupported(node.pos, 'sql')
		}
		ast.OffsetOf {
			return g.unsupported(node.pos, '__offsetof')
		}
		ast.ComptimeSelector, ast.ComptimeType {
			return g.unsupported(node.pos, 'comptime reflection')
		}
		ast.Assoc {
			return g.unsupported(node.pos, 'the old `{...a | x: 1}` syntax (use `T{...a, x: 1}`)')
		}
		ast.CTempVar {
			return node.name
		}
		ast.NodeError {
			return ''
		}
	}
}

fn is_balanced(s string) bool {
	mut depth := 0
	for i, c in s {
		if c == `(` {
			depth++
		} else if c == `)` {
			depth--
			if depth == 0 && i != s.len - 1 {
				return false
			}
		}
	}
	return depth == 0
}

// needs_clone: the expression reads a struct that lives somewhere else (a variable, a field, an item):
// storing it must copy it, as V does.
fn needs_clone(e ast.Expr) bool {
	return match e {
		ast.Ident, ast.SelectorExpr, ast.IndexExpr { true }
		ast.ParExpr { needs_clone(e.expr) }
		ast.UnsafeExpr { needs_clone(e.expr) }
		ast.AsCast { needs_clone(e.expr) }
		ast.PrefixExpr { e.op == .mul }
		else { false }
	}
}

// expr_value: an expression whose value is stored (assigned, returned, put in a struct or array): value
// structs are cloned.
fn (mut g Gen) expr_value(e ast.Expr, t ast.Type) string {
	s := g.expr(e)
	if s == '' {
		return s
	}
	if needs_clone(e) && g.is_value_struct(t) {
		return g.clone_code(s, t)
	}
	return s
}

fn (mut g Gen) clone_code(s string, t ast.Type) string {
	if t.has_flag(.option) {
		return 'V.clone(${s})'
	}
	sym := g.sym(g.unwrap_alias(t))
	if sym.mod == g.mod || sym.mod in g.user_mods || sym.name in positional_types
		|| g.is_asset_ref(t) {
		return '${s}.clone()'
	}
	return 'V.clone(${s})'
}

// ---------- Or blocks ----------

// with_or applies an `or { }` block, `?` or `!` to an option/result expression. `typ` is the full type
// (with the option/result flag) of `code`.
fn (mut g Gen) with_or(code string, or_block ast.OrExpr, typ ast.Type, pos token.Pos) string {
	match or_block.kind {
		.absent {
			return code
		}
		.propagate_option {
			t := g.tmp()
			g.writeln('const ${t} = ${code}')
			if g.fn_ret.has_flag(.option) {
				g.writeln('if (${t} === null) return null')
			} else if g.fn_ret.has_flag(.result) {
				g.writeln("if (${t} === null) throw V.error('none')")
			} else {
				g.writeln("if (${t} === null) V.panic('none: ${g.pos_str(pos)}')")
			}
			return t
		}
		.propagate_result {
			if typ.has_flag(.option) {
				return 'V.unwrap(${code})'
			}
			return code
		}
		.block {
			value_type := typ.clear_flags(.option, .result)
			is_void := value_type == ast.void_type || value_type == 0
			if typ.has_flag(.result) {
				t := if is_void { '' } else { g.tmp() }
				if t != '' {
					g.writeln('let ${t}')
				}
				g.writeln('try {')
				if t != '' {
					g.writeln('\t${t} = ${code}')
				} else {
					g.writeln('\t${code}')
				}
				g.writeln('} catch (_e) {')
				g.indent++
				if or_block.err_used {
					g.writeln('const err = V.as_error(_e)')
				} else {
					g.writeln('V.as_error(_e)')
				}
				g.or_body(or_block.stmts, t, value_type)
				g.indent--
				g.writeln('}')
				return t
			}
			// option: a single plain value can use `??`
			if !or_block.err_used && or_block.stmts.len == 1 && !is_void {
				last := or_block.stmts[0]
				if last is ast.ExprStmt && !g.is_noreturn_expr(last.expr)
					&& last.expr !is ast.IfExpr && last.expr !is ast.MatchExpr {
					old := g.begin_capture()
					val := g.expr_value(last.expr, value_type)
					pre := g.end_capture(old)
					if pre == '' {
						return '(${code} ?? ${val})'
					}
				}
			}
			t := g.tmp()
			g.writeln('let ${t} = ${code}')
			g.writeln('if (${t} === null) {')
			g.indent++
			if or_block.err_used {
				g.writeln("const err = V.error('none')")
			}
			g.or_body(or_block.stmts, if is_void { '' } else { t }, value_type)
			g.indent--
			g.writeln('}')
			return t
		}
	}
}

// or_body generates an or-block: its last expression (if any, and if it is not return/break/panic) is the value.
fn (mut g Gen) or_body(stmts []ast.Stmt, result string, typ ast.Type) {
	g.branch_body(stmts, result, typ)
}

// ---------- Identifiers ----------

fn (mut g Gen) ident(node ast.Ident) string {
	if node.or_expr.kind != .absent {
		base := g.ident_plain(node)
		t := if node.obj is ast.Var { node.obj.typ } else { ast.void_type }
		return g.with_or(base, node.or_expr, t, node.pos)
	}
	return g.ident_plain(node)
}

fn (mut g Gen) ident_plain(node ast.Ident) string {
	match node.kind {
		.constant {
			if node.obj is ast.ConstField {
				return g.qualify(node.obj.mod, short_name(node.obj.name))
			}
			return g.qualify(node.mod, short_name(node.name))
		}
		.global {
			return g.qualify(node.mod, short_name(node.name))
		}
		.function {
			return g.fn_ref(node.name)
		}
		else {}
	}

	if node.obj is ast.ConstField {
		return g.qualify(node.obj.mod, short_name(node.obj.name))
	}
	if node.obj is ast.GlobalField {
		return g.qualify(node.mod, short_name(node.name))
	}
	if node.name.contains('.') {
		// a function used as a value, e.g. `arr.map(strings.to_upper)`
		return g.fn_ref(node.name)
	}
	return js_name(node.name)
}

// fn_ref: a named function used as a value or called.
fn (mut g Gen) fn_ref(name string) string {
	if f := g.table.find_fn(name) {
		if f.is_static_type_method {
			// `Foo.new` — a static method
			return g.qualify(f.mod, short_name(name.all_before_last('__static__')))
		}
		return g.qualify(f.mod, short_name(name))
	}
	if name.contains('.') {
		return g.qualify(name.all_before_last('.'), name.all_after_last('.'))
	}
	return js_name(name)
}

// ---------- Selectors ----------

fn (mut g Gen) selector(node ast.SelectorExpr) string {
	code := g.selector_plain(node)
	if node.or_block.kind != .absent {
		return g.with_or(code, node.or_block, node.typ, node.pos)
	}
	return code
}

fn (mut g Gen) selector_plain(node ast.SelectorExpr) string {
	// T.name, typeof(x).name
	if node.gkind_field == .name {
		if node.expr is ast.Ident && node.expr.name in g.cur_generic_names {
			return 'V.type_name(${js_name(node.expr.name)})'
		}
		return js_string(g.table.type_to_str(node.name_type))
	}
	if node.expr is ast.TypeOf {
		t := if node.expr.typ != 0 { node.expr.typ } else { node.name_type }
		if node.field_name == 'name' {
			return js_string(g.table.type_to_str(t))
		}
		if node.field_name == 'idx' {
			return t.idx().str()
		}
	}
	etype :=
		node.expr_type.set_nr_muls(0) // `&string`, `&[]int` behave like the values they point to
	obj := g.expr(node.expr)
	field := node.field_name
	if field == 'len' || field == 'cap' {
		if g.is_string_type(etype) || g.is_array_type(etype) {
			return '${obj}.length'
		}
		if g.is_map_type(etype) {
			return '${obj}.size'
		}
	}
	// `x.Component` (an embedded struct) is `x` itself
	esym := g.final_sym(etype)
	if esym.info is ast.Struct {
		for emb in esym.info.embeds {
			if g.sym(emb).embed_name() == field {
				return obj
			}
		}
		// a method used as a value: bind it to its receiver
		if !g.table.struct_has_field(esym, field) {
			if _ := g.table.find_method_with_embeds(esym, field) {
				return 'V.bind(${obj}, ${js_string(field)})'
			}
		}
	}
	// error values: `err.msg` field form of IError
	return '${obj}.${field}'
}

// place: an expression that is modified in place. A map item is created when missing (`m[k] << x`,
// `m[k].hp -= 1`), as V does.
fn (mut g Gen) place(e ast.Expr) string {
	match e {
		ast.IndexExpr {
			if g.is_map_type(e.left_type) && e.index !is ast.RangeExpr {
				return 'V.M.entry(${g.place(e.left)}, ${g.expr(e.index)}, () => ${g.zero_value(e.typ)})'
			}
			if g.is_array_type(e.left_type) && e.index !is ast.RangeExpr
				&& e.or_expr.kind == .absent {
				return '${g.place(e.left)}[${g.expr(e.index)}]'
			}
		}
		ast.SelectorExpr {
			if e.or_block.kind == .absent && e.gkind_field != .name
				&& e.field_name !in ['len', 'cap'] {
				esym := g.final_sym(e.expr_type)
				if esym.info is ast.Struct {
					for emb in esym.info.embeds {
						if g.sym(emb).embed_name() == e.field_name {
							return g.place(e.expr)
						}
					}
				}
				return '${g.place(e.expr)}.${e.field_name}'
			}
		}
		ast.ParExpr {
			return g.place(e.expr)
		}
		else {}
	}

	return g.expr(e)
}

// ---------- Index ----------

fn (mut g Gen) index_expr(node ast.IndexExpr) string {
	ltype := node.left_type.set_nr_muls(0)
	if node.index is ast.RangeExpr {
		r := node.index
		obj := g.expr(node.left)
		lo := if r.has_low { g.expr(r.low) } else { '0' }
		if r.has_high {
			return '${obj}.slice(${lo}, ${g.expr(r.high)})'
		}
		return '${obj}.slice(${lo})'
	}
	if node.or_expr.kind != .absent {
		val := g.guard_value(node)
		return g.with_or(val, node.or_expr, node.typ.set_flag(.option), node.pos)
	}
	obj := g.expr(node.left)
	idx := g.expr(node.index)
	if g.is_map_type(ltype) {
		return 'V.M.get(${obj}, ${idx}, () => ${g.zero_value(node.typ)})'
	}
	if g.is_string_type(ltype) {
		return '${obj}.charCodeAt(${idx})'
	}
	return '${obj}[${idx}]'
}

// ---------- Operators ----------

fn (mut g Gen) infix(node ast.InfixExpr) string {
	lt := node.left_type
	rt := node.right_type
	rtv := rt.set_nr_muls(0)
	match node.op {
		.key_in, .not_in {
			neg := if node.op == .not_in { '!' } else { '' }
			l := g.expr(node.left)
			if node.right is ast.ArrayInit && node.right.exprs.len > 0 && node.right.exprs.len <= 8
				&& !g.is_struct_type(lt) && is_simple_js(l) {
				mut parts := []string{}
				for e in node.right.exprs {
					parts << '${l} === ${g.expr(e)}'
				}
				return '${neg}(${parts.join(' || ')})'
			}
			r := g.expr(node.right)
			if g.is_map_type(rtv) {
				return '${neg}${r}.has(${l})'
			}
			if g.is_string_type(rtv) {
				return '${neg}${r}.includes(${l})'
			}
			if g.is_struct_type(lt) || g.is_array_type(lt) {
				return '${neg}V.A.contains(${r}, ${l})'
			}
			return '${neg}${r}.includes(${l})'
		}
		.key_is, .not_is {
			neg := if node.op == .not_is { '!' } else { '' }
			l := g.expr(node.left)
			mut desc := ''
			if node.right is ast.TypeNode {
				desc = g.type_desc(node.right.typ)
			} else if node.right is ast.None {
				return if neg == '' { '(${l} === null)' } else { '(${l} !== null)' }
			} else {
				desc = g.type_desc(rt)
			}
			return '${neg}V.is_type(${l}, ${desc})'
		}
		.left_shift {
			if g.is_array_type(lt) {
				a := g.place(node.left)
				elem := g.array_elem_type(lt)
				is_arr := g.is_array_type(rt) && !g.is_array_type(elem)
				if is_arr {
					return 'V.push(${a}, ${g.expr(node.right)}, true)'
				}
				return '${a}.push(${g.expr_value(node.right, rt)})'
			}
		}
		.and, .logical_or {
			l := g.expr(node.left)
			old := g.begin_capture()
			g.indent++
			r := g.expr(node.right)
			g.indent--
			pre := g.end_capture(old)
			op := if node.op == .and { '&&' } else { '||' }
			if pre == '' {
				return '(${l} ${op} ${r})'
			}
			// the right side needs statements: only run them when it is evaluated
			t := g.tmp()
			g.writeln('let ${t} = ${l}')
			if node.op == .and {
				g.writeln('if (${t}) {')
			} else {
				g.writeln('if (!${t}) {')
			}
			g.write_raw(pre)
			g.writeln('\t${t} = ${r}')
			g.writeln('}')
			return t
		}
		else {}
	}

	l := g.expr(node.left)
	if node.right is ast.None {
		if node.op == .eq {
			return '(${l} === null)'
		}
		if node.op == .ne {
			return '(${l} !== null)'
		}
	}
	r := g.expr(node.right)
	return g.binary(node.op, l, r, lt, rt)
}

fn (g &Gen) array_elem_type(t ast.Type) ast.Type {
	sym := g.final_sym(t)
	if sym.info is ast.Array {
		return sym.info.elem_type
	}
	if sym.info is ast.ArrayFixed {
		return sym.info.elem_type
	}
	return ast.void_type
}

// binary: `l op r` with V semantics (integer division, operator overloading, struct equality, ...).
fn (mut g Gen) binary(op token.Kind, l string, r string, lt ast.Type, rt ast.Type) string {
	// operator overloading on structs
	if g.is_struct_type(lt) && !lt.has_flag(.option) {
		sym := g.final_sym(lt.set_nr_muls(0))
		ops := {
			token.Kind.plus: '+'
			.minus:          '-'
			.mul:            '*'
			.div:            '/'
			.mod:            '%'
		}
		if vop := ops[op] {
			if _ := g.table.find_method_with_embeds(sym, vop) {
				return '${l}.${operator_method(vop)}(${r})'
			}
		}
		has_eq := if _ := g.table.find_method_with_embeds(sym, '==') { true } else { false }
		has_lt := if _ := g.table.find_method_with_embeds(sym, '<') { true } else { false }
		match op {
			.eq, .ne {
				neg := if op == .ne { '!' } else { '' }
				if has_eq {
					return '${neg}${l}.op_eq(${r})'
				}
				if lt.is_ptr() || rt.is_ptr() {
					return if op == .eq { '(${l} === ${r})' } else { '(${l} !== ${r})' }
				}
				if g.has_runtime_op_eq(lt) {
					return '${neg}${l}.op_eq(${r})'
				}
				return '${neg}V.eq(${l}, ${r})'
			}
			.lt {
				if has_lt {
					return '${l}.op_lt(${r})'
				}
			}
			.gt {
				if has_lt {
					return '${r}.op_lt(${l})'
				}
			}
			.le {
				if has_lt {
					return '!${r}.op_lt(${l})'
				}
			}
			.ge {
				if has_lt {
					return '!${l}.op_lt(${r})'
				}
			}
			else {}
		}
	}
	match op {
		.eq, .ne {
			if g.is_array_type(lt) || g.is_map_type(lt) || g.kind_of(lt) == .sum_type {
				neg := if op == .ne { '!' } else { '' }
				return '${neg}V.eq(${l}, ${r})'
			}
			return if op == .eq { '(${l} === ${r})' } else { '(${l} !== ${r})' }
		}
		.div {
			if g.is_int_type(lt) && g.is_int_type(rt) {
				return 'Math.trunc(${l} / ${r})'
			}
			return '(${l} / ${r})'
		}
		.mul {
			if g.is_int32(lt) && g.is_int32(rt) {
				if g.is_unsigned_type(lt) {
					return '(Math.imul(${l}, ${r}) >>> 0)'
				}
				return 'Math.imul(${l}, ${r})'
			}
			return '(${l} * ${r})'
		}
		.right_shift {
			if g.is_unsigned_type(lt) {
				return '(${l} >>> ${r})'
			}
			return '(${l} >> ${r})'
		}
		.unsigned_right_shift {
			return '(${l} >>> ${r})'
		}
		.and {
			return '(${l} && ${r})'
		}
		.logical_or {
			return '(${l} || ${r})'
		}
		.lt, .gt, .le, .ge {
			if g.is_enum_type(lt) && !g.is_flag_enum(lt) {
				ints := g.enum_ints_ref(lt)
				return '(${ints}[${l}] ${op.str()} ${ints}[${r}])'
			}
			return '(${l} ${op.str()} ${r})'
		}
		else {
			return '(${l} ${op.str()} ${r})'
		}
	}
}

// is_int32: an integer type of 32 bits or fewer (multiplication wraps like in V).
fn (g &Gen) is_int32(t ast.Type) bool {
	ft := g.unwrap_alias(t)
	if ft.is_ptr() || t.has_option_or_result() {
		return false
	}
	return ft.idx() in [ast.int_type_idx, ast.i32_type_idx, ast.u32_type_idx, ast.i16_type_idx,
		ast.u16_type_idx, ast.i8_type_idx, ast.u8_type_idx, ast.rune_type_idx]
}

// has_runtime_op_eq: engine value types implement `==` as op_eq (faster than V.eq).
fn (g &Gen) has_runtime_op_eq(t ast.Type) bool {
	return g.sym(g.unwrap_alias(t)).name in ['velo.core.Vec2', 'velo.core.Color', 'velo.core.Affine2',
		'velo.assets.AssetRef']
}

fn (mut g Gen) enum_ints_ref(t ast.Type) string {
	sym := g.final_sym(t)
	return g.qualify(sym.mod, '${short_name(sym.name)}__ints')
}

fn (mut g Gen) prefix(node ast.PrefixExpr) string {
	match node.op {
		.amp {
			return g.expr(node.right)
		}
		.mul {
			return g.expr(node.right)
		}
		.minus {
			r := g.expr(node.right)
			if g.is_struct_type(node.right_type) {
				return '${r}.mul(-1)'
			}
			return '(-${r})'
		}
		.not {
			return '!${g.expr(node.right)}'
		}
		.bit_not {
			r := g.expr(node.right)
			if g.is_unsigned_type(node.right_type) {
				return '(~${r} >>> 0)'
			}
			return '(~${r})'
		}
		.arrow {
			return g.unsupported(node.pos, 'channels')
		}
		else {
			return '${node.op.str()}${g.expr(node.right)}'
		}
	}
}

fn (mut g Gen) postfix(node ast.PostfixExpr) string {
	op := if node.op == .inc { '++' } else { '--' }
	if node.expr is ast.IndexExpr && g.is_map_type(node.expr.left_type) {
		m := g.expr(node.expr.left)
		k := g.expr(node.expr.index)
		mt := g.tmp()
		kt := g.tmp()
		g.writeln('const ${mt} = ${m}, ${kt} = ${k}')
		sign := if node.op == .inc { '+' } else { '-' }
		return '${mt}.set(${kt}, V.M.get(${mt}, ${kt}, () => 0) ${sign} 1)'
	}
	if node.op == .question || node.op == .not {
		return g.expr(node.expr)
	}
	return '${g.expr(node.expr)}${op}'
}

// ---------- Casts ----------

fn (mut g Gen) cast(node ast.CastExpr) string {
	x := g.expr(node.expr)
	to := g.unwrap_alias(node.typ)
	from := node.expr_type
	if to.is_ptr() || to.is_any_kind_of_pointer() {
		return x
	}
	to_sym := g.sym(to)
	from_k := g.kind_of(from)
	if to_sym.kind == .enum {
		if g.is_flag_enum(to) {
			return x
		}
		if g.is_number_type(from) {
			return 'V.enum_from_int(${g.enum_ints_ref(to)}, ${x})'
		}
		return x
	}
	if from_k == .enum && !g.is_flag_enum(from) && g.is_number_type(to) {
		return '${g.enum_ints_ref(from)}[${x}]'
	}
	idx := to.idx()
	from_float := g.is_float_type(from)
	if g.is_bool_type(from) && g.is_number_type(to) {
		return '(${x} ? 1 : 0)'
	}
	match idx {
		ast.int_type_idx, ast.i32_type_idx {
			if from_float {
				return 'V.int(${x})'
			}
			if g.is_int32(from) || from.idx() == ast.int_literal_type_idx {
				return x
			}
			return '(${x} | 0)'
		}
		ast.i64_type_idx, ast.isize_type_idx, ast.u64_type_idx, ast.usize_type_idx {
			if from_float {
				return 'Math.trunc(${x})'
			}
			return x
		}
		ast.u8_type_idx, ast.char_type_idx {
			if node.expr is ast.CharLiteral || node.expr is ast.IntegerLiteral {
				return x
			}
			return 'V.u8(${x})'
		}
		ast.i8_type_idx {
			return 'V.i8(${x})'
		}
		ast.u16_type_idx {
			return 'V.u16(${x})'
		}
		ast.i16_type_idx {
			return 'V.i16(${x})'
		}
		ast.u32_type_idx {
			return 'V.u32(${x})'
		}
		ast.rune_type_idx {
			if from_float {
				return 'Math.trunc(${x})'
			}
			return x
		}
		ast.f32_type_idx, ast.f64_type_idx {
			return x
		}
		ast.string_type_idx {
			if g.is_string_type(from) {
				return x
			}
			return 'V.str(${x})'
		}
		ast.bool_type_idx {
			return x
		}
		else {
			return x
		}
	}
}

fn (mut g Gen) enum_val(t ast.Type, val string) string {
	if g.is_flag_enum(t) {
		sym := g.final_sym(t)
		return g.qualify(sym.mod, '${short_name(sym.name)}__${val}')
	}
	return js_string(val)
}

// ---------- Strings ----------

fn (mut g Gen) string_inter(node ast.StringInterLiteral) string {
	mut sb := []string{}
	sb << '`'
	for i, val in node.vals {
		sb << template_part(v_unescape(val, false))
		if i >= node.exprs.len {
			continue
		}
		e := node.exprs[i]
		t := node.expr_types[i] or { ast.void_type }
		x := g.expr(e)
		fchar := node.fmts[i] or { `_` }
		width := node.fwidths[i] or { 0 }
		prec := node.precisions[i] or { 987698 }
		plus := node.pluss[i] or { false }
		fill := node.fills[i] or { false }
		has_fmt := (node.need_fmts[i] or { false }) || width != 0 || prec != 987698 || plus
			|| fchar !in [`_`, 0, `d`, `s`, `g`]
		if has_fmt {
			kind := if fchar == `_` || fchar == 0 { '' } else { fchar.ascii_str() }
			sb << '\${V.fmt(${x}, ${js_string(kind)}, ${width}, ${prec}, ${plus}, ${fill}, ${g.is_float_type(t)})}'
			continue
		}
		sb << '\${${g.to_string(x, t)}}'
	}
	sb << '`'
	return sb.join('')
}

// to_string: code converting a value of type `t` to text like V's interpolation / str() does.
fn (mut g Gen) to_string(x string, t ast.Type) string {
	if t.has_flag(.option) {
		return 'V.str(${x})'
	}
	if g.is_string_type(t) {
		return x
	}
	if g.is_float_type(t) {
		if g.unwrap_alias(t).idx() == ast.f32_type_idx {
			return 'V.f32str(${x})' // the shortest text that reads back as the same f32, like V
		}
		return 'V.fstr(${x})'
	}
	if g.is_rune_type(t) {
		return 'String.fromCodePoint(${x})'
	}
	if g.is_int_type(t) || g.is_bool_type(t) || (g.is_enum_type(t) && !g.is_flag_enum(t)) {
		return x
	}
	ut := g.unwrap_alias(t)
	sym := g.final_sym(ut)
	if sym.kind == .struct && !ut.is_ptr() {
		if _ := g.table.find_method_with_embeds(sym, 'str') {
			return '${x}.str()'
		}
	}
	if sym.kind == .array {
		elem := g.array_elem_type(ut)
		if g.is_float_type(elem) {
			return 'V.str(${x}, true)'
		}
	}
	return 'V.str(${x})'
}

fn (mut g Gen) at_expr(node ast.AtExpr) string {
	match node.kind {
		.file_path, .vmod_file, .vexe_path, .vroot_path, .vmodroot_path, .vmod_hash, .vhash {
			// absolute paths of the build machine do not belong in a web page
			return js_string(node.val.replace(g.project_dir + '/', '').replace(g.project_dir, '.'))
		}
		else {
			return js_string(node.val)
		}
	}
}

fn (mut g Gen) comptime_call(node ast.ComptimeCall) string {
	match node.kind {
		.env {
			return js_string(node.env_value)
		}
		.d {
			return js_string(node.compile_value)
		}
		.embed_file {
			return g.unsupported(node.pos,
				'\$embed_file (put the file in assets/ and load it as a TextAsset)')
		}
		.zero {
			return g.zero_value(node.result_type)
		}
		else {
			return g.unsupported(node.pos, '\$${node.method_name}')
		}
	}
}

// ---------- Composite literals ----------

fn (mut g Gen) struct_init(node ast.StructInit) string {
	t := node.typ
	mut names := []string{}
	mut vals := []string{}
	fields := g.struct_fields(t)
	for i, f in node.init_fields {
		mut name := f.name
		if node.no_keys || name == '' {
			if i < fields.len {
				name = fields[i].name
			}
		}
		if f.is_embed {
			// `Foo{ Component: core.Component{...} }`: copy the embedded struct's fields
			names << '...'
			vals << g.expr(f.expr)
			continue
		}
		names << name
		vals << g.expr_value(f.expr, if f.expected_type != 0 { f.expected_type } else { f.typ })
	}
	if node.has_update_expr {
		base := g.expr(node.update_expr)
		mut parts := []string{}
		for i, n in names {
			parts << '${n}: ${vals[i]}'
		}
		return 'V.update(${base}, {${parts.join(', ')}})'
	}
	if g.is_runtime_params_struct(t) {
		mut parts := []string{}
		for i, n in names {
			parts << '${n}: ${vals[i]}'
		}
		return '{${parts.join(', ')}}'
	}
	if names.any(it == '...') {
		mut cls := g.class_ref(t)
		mut parts := []string{}
		for i, n in names {
			if n == '...' {
				parts << '...${vals[i]}'
			} else {
				parts << '${n}: ${vals[i]}'
			}
		}
		return 'V.make(${cls}, {${parts.join(', ')}})'
	}
	return g.new_struct(t, names, vals)
}

fn (mut g Gen) array_init(node ast.ArrayInit) string {
	elem := node.elem_type
	if node.exprs.len > 0 {
		mut vals := []string{}
		for i, e in node.exprs {
			et := node.expr_types[i] or { elem }
			vals << g.expr_value(e, if et != 0 { et } else { elem })
		}
		if node.has_update_expr {
			return '[...${g.expr(node.update_expr)}, ${vals.join(', ')}]'
		}
		return '[${vals.join(', ')}]'
	}
	if node.has_len || node.is_fixed {
		len := if node.has_len {
			g.expr(node.len_expr)
		} else {
			sym := g.final_sym(node.typ)
			if sym.info is ast.ArrayFixed {
				sym.info.size.str()
			} else {
				'0'
			}
		}
		init := if node.has_init {
			g.expr_value(node.init_expr, elem)
		} else {
			g.zero_value(elem)
		}
		uses_index := node.has_index || init.contains('index')
		param := if uses_index { 'index' } else { '' }
		return 'V.make_array(${len}, (${param}) => ${init})'
	}
	return '[]'
}

fn (mut g Gen) map_init(node ast.MapInit) string {
	if node.keys.len == 0 {
		if node.has_update_expr {
			return 'V.M.clone(${g.expr(node.update_expr)})'
		}
		return 'new Map()'
	}
	mut pairs := []string{}
	for i, k in node.keys {
		vt := node.val_types[i] or { node.value_type }
		pairs << '[${g.expr(k)}, ${g.expr_value(node.vals[i], vt)}]'
	}
	if node.has_update_expr {
		return 'new Map([...${g.expr(node.update_expr)}, ${pairs.join(', ')}])'
	}
	return 'new Map([${pairs.join(', ')}])'
}

// ---------- if / match as values ----------

fn (mut g Gen) if_value(node ast.IfExpr) string {
	if !node.is_expr && !node.force_expr {
		g.if_stmt(node, '')
		return ''
	}
	if !node.is_comptime && node.has_else && !node.branches.any(it.cond is ast.IfGuardExpr) {
		// try a ternary: every branch a single expression, nothing to hoist
		old := g.begin_capture()
		mut conds := []string{}
		mut vals := []string{}
		mut simple := true
		for i, br in node.branches {
			if br.stmts.len != 1 || br.stmts[0] !is ast.ExprStmt {
				simple = false
				break
			}
			last := br.stmts[0] as ast.ExprStmt
			if g.is_noreturn_expr(last.expr) {
				simple = false
				break
			}
			if i < node.branches.len - 1 {
				conds << g.expr(br.cond)
			}
			vals << g.expr_value(last.expr, node.typ)
		}
		pre := g.end_capture(old)
		if simple && pre == '' {
			mut s := vals.last()
			for i := conds.len - 1; i >= 0; i-- {
				s = '${conds[i]} ? ${vals[i]} : ${s}'
			}
			return '(${s})'
		}
	}
	t := g.tmp()
	g.writeln('let ${t}')
	g.if_stmt(node, t)
	return t
}

fn (mut g Gen) match_value(node ast.MatchExpr) string {
	if !node.is_expr {
		g.match_stmt(node, '')
		return ''
	}
	t := g.tmp()
	g.writeln('let ${t}')
	g.match_stmt(node, t)
	return t
}

// ---------- Functions as values ----------

fn (mut g Gen) anon_fn(node ast.AnonFn) string {
	f := &node.decl
	prev_fn := g.fn_decl
	prev_ret := g.fn_ret
	prev_defer := g.defer_var
	prev_indent := g.indent
	g.fn_decl = f
	g.fn_ret = f.return_type
	g.defer_var = ''
	mut params := []string{}
	for i, p in f.params {
		params << if p.name == '_' || p.name == '' { '_p${i}' } else { js_name(p.name) }
	}
	old := g.begin_capture()
	g.indent = prev_indent + 1
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
	body := g.end_capture(old)
	g.indent = prev_indent
	g.fn_decl = prev_fn
	g.fn_ret = prev_ret
	g.defer_var = prev_defer
	pad := '\t'.repeat(g.indent)
	func := '(${params.join(', ')}) => {\n${body}${pad}}'
	if node.inherited_vars.len == 0 {
		return func
	}
	// V closures capture copies of the variables they list, when they are created
	mut names := []string{}
	mut vals := []string{}
	for v in node.inherited_vars {
		names << js_name(v.name)
		vals << if !v.is_mut && g.is_value_struct(v.typ) {
			'V.clone(${js_name(v.name)})'
		} else {
			js_name(v.name)
		}
	}
	return '((${names.join(', ')}) => ${func})(${vals.join(', ')})'
}

fn (mut g Gen) lambda(node ast.LambdaExpr) string {
	mut params := []string{}
	for p in node.params {
		params << js_name(p.name)
	}
	old := g.begin_capture()
	g.indent++
	body := g.expr(node.expr)
	g.indent--
	pre := g.end_capture(old)
	if pre == '' {
		return '((${params.join(', ')}) => ${body})'
	}
	pad := '\t'.repeat(g.indent)
	return '((${params.join(', ')}) => {\n${pre}${pad}\treturn ${body}\n${pad}})'
}
