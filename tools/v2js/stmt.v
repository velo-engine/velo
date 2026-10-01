module main

import v.ast
import v.token

fn (mut g Gen) stmts(stmts []ast.Stmt) {
	for s in stmts {
		g.stmt(s)
	}
}

fn (mut g Gen) stmt(node ast.Stmt) {
	match node {
		ast.AssignStmt {
			g.assign_stmt(node)
		}
		ast.ExprStmt {
			g.expr_stmt(node.expr)
		}
		ast.Return {
			g.return_stmt(node)
		}
		ast.ForStmt {
			g.for_stmt(node)
		}
		ast.ForCStmt {
			g.for_c_stmt(node)
		}
		ast.ForInStmt {
			g.for_in_stmt(node)
		}
		ast.BranchStmt {
			g.branch_stmt(node)
		}
		ast.Block {
			g.writeln('{')
			g.indent++
			g.stmts(node.stmts)
			g.indent--
			g.writeln('}')
		}
		ast.DeferStmt {
			if g.defer_var == '' {
				g.error_at(node.pos, 'defer outside of a function')
				return
			}
			g.writeln('${g.defer_var}.push(() => {')
			g.indent++
			g.stmts(node.stmts)
			g.indent--
			g.writeln('})')
		}
		ast.AssertStmt {
			cond := g.expr(node.expr)
			msg := if node.extra !is ast.EmptyExpr {
				g.expr(node.extra)
			} else {
				js_string(g.pos_str(node.pos))
			}
			g.writeln('V.assert_(${cond}, ${msg})')
		}
		ast.GotoLabel, ast.GotoStmt {
			g.writeln(g.unsupported(node.pos, 'goto'))
		}
		ast.ComptimeFor {
			g.writeln(g.unsupported(node.pos, 'comptime `\$for`'))
		}
		ast.EmptyStmt, ast.SemicolonStmt, ast.NodeError, ast.Import, ast.Module, ast.HashStmt {}
		ast.ConstDecl, ast.GlobalDecl, ast.FnDecl, ast.StructDecl, ast.EnumDecl, ast.InterfaceDecl,
		ast.TypeDecl {}
		ast.AsmStmt, ast.SqlStmt, ast.DebuggerStmt {
			g.writeln(g.unsupported(node.pos, 'asm, sql and \$dbg statements'))
		}
	}
}

// expr_stmt: an expression used as a statement (calls, `x++`, if/match without a value, `a << b`).
fn (mut g Gen) expr_stmt(e ast.Expr) {
	match e {
		ast.IfExpr {
			g.if_stmt(e, '')
			return
		}
		ast.MatchExpr {
			g.match_stmt(e, '')
			return
		}
		ast.Comment {
			return
		}
		ast.UnsafeExpr {
			g.expr_stmt(e.expr)
			return
		}
		ast.CallExpr {
			if e.should_be_skipped {
				return
			}
		}
		else {}
	}

	s := g.expr(e)
	if s != '' {
		g.writeln(s)
	}
}

// ---------- Assignment ----------

fn (mut g Gen) assign_stmt(node ast.AssignStmt) {
	is_decl := node.op == .decl_assign
	// `a, b := f()` / `a, b = f()` (multi-return call)
	if node.left.len > 1 && node.right.len == 1 {
		rhs := g.expr(node.right[0])
		mut names := []string{}
		mut plain := true
		for l in node.left {
			if l is ast.Ident {
				names << if l.name == '_' { '' } else { js_name(l.name) }
			} else {
				plain = false
			}
		}
		if is_decl && plain {
			g.writeln('let [${names.join(', ')}] = ${rhs}')
			return
		}
		t := g.tmp()
		g.writeln('const ${t} = ${rhs}')
		for i, l in node.left {
			if l is ast.Ident && l.name == '_' {
				continue
			}
			g.assign_to(l, '${t}[${i}]', node.left_types[i] or { ast.void_type }, .assign, is_decl)
		}
		return
	}
	// `a, b = b, a` (parallel assignment): evaluate every value first
	if node.left.len > 1 {
		mut vals := []string{}
		for i, r in node.right {
			vals << g.expr_value(r, node.right_types[i] or { ast.void_type })
		}
		if is_decl {
			mut parts := []string{}
			for i, l in node.left {
				if l is ast.Ident && l.name == '_' {
					g.writeln(vals[i])
					continue
				}
				parts << '${g.lhs_name(l)} = ${vals[i]}'
			}
			if parts.len > 0 {
				g.writeln('let ${parts.join(', ')}')
			}
			return
		}
		mut tmps := []string{}
		for v in vals {
			t := g.tmp()
			g.writeln('const ${t} = ${v}')
			tmps << t
		}
		for i, l in node.left {
			if l is ast.Ident && l.name == '_' {
				continue
			}
			g.assign_to(l, tmps[i], node.left_types[i] or { ast.void_type }, .assign, false)
		}
		return
	}
	left := node.left[0]
	right := node.right[0]
	ltype := node.left_types[0] or { ast.void_type }
	rtype := node.right_types[0] or { ast.void_type }
	if left is ast.Ident && left.name == '_' {
		g.expr_stmt(right)
		return
	}
	if is_decl {
		val := g.expr_value(right, rtype)
		kw := if g.decl_is_mut(left) { 'let' } else { 'const' }
		g.writeln('${kw} ${g.lhs_name(left)} = ${val}')
		return
	}
	if node.op == .assign {
		val := g.expr_value(right, if ltype != 0 { ltype } else { rtype })
		g.assign_to(left, val, ltype, .assign, false)
		return
	}
	// compound assignment: +=, -=, ...
	val := g.expr(right)
	g.assign_to(left, val, ltype, node.op, false)
}

fn (mut g Gen) decl_is_mut(e ast.Expr) bool {
	if e is ast.Ident {
		if e.is_mut {
			return true
		}
		if e.obj is ast.Var {
			return e.obj.is_mut
		}
	}
	return true
}

fn (mut g Gen) lhs_name(e ast.Expr) string {
	if e is ast.Ident {
		return js_name(e.name)
	}
	return g.expr(e)
}

// compound_op: the binary operator of a compound assignment (`+=` -> `+`).
fn compound_op(op token.Kind) token.Kind {
	return match op {
		.plus_assign { .plus }
		.minus_assign { .minus }
		.mult_assign { .mul }
		.div_assign { .div }
		.mod_assign { .mod }
		.and_assign { .amp }
		.or_assign { .pipe }
		.xor_assign { .xor }
		.left_shift_assign { .left_shift }
		.right_shift_assign { .right_shift }
		.unsigned_right_shift_assign { .unsigned_right_shift }
		.boolean_and_assign { .and }
		.boolean_or_assign { .logical_or }
		else { .unknown }
	}
}

// assign_to writes `left op= val` for any assignable expression (variables, fields, array and map items, `*p`).
fn (mut g Gen) assign_to(left ast.Expr, val string, ltype ast.Type, op token.Kind, is_decl bool) {
	if is_decl {
		g.writeln('let ${g.lhs_name(left)} = ${val}')
		return
	}
	match left {
		ast.IndexExpr {
			if g.is_map_type(left.left_type) {
				m := g.expr(left.left)
				k := g.expr(left.index)
				if op == .assign {
					g.writeln('${m}.set(${k}, ${val})')
				} else {
					mt := g.tmp()
					kt := g.tmp()
					g.writeln('const ${mt} = ${m}, ${kt} = ${k}')
					cur := 'V.M.get(${mt}, ${kt}, () => ${g.zero_value(ltype)})'
					g.writeln('${mt}.set(${kt}, ${g.binary(compound_op(op), cur, val, ltype, ltype)})')
				}
				return
			}
		}
		ast.PrefixExpr {
			if left.op == .mul {
				target := g.expr(left.right)
				if g.is_value_struct(ltype) && op == .assign {
					g.writeln('V.assign_into(${target}, ${val})')
					return
				}
				g.warn_at(left.pos,
					'assigning through a pointer to a non-struct value has no effect in WebGL builds')
			}
		}
		ast.ParExpr {
			g.assign_to(left.expr, val, ltype, op, false)
			return
		}
		else {}
	}

	target := g.place(left)
	if op == .assign {
		g.writeln('${target} = ${val}')
		return
	}
	bop := compound_op(op)
	// operators JavaScript cannot express as `x op= y` with V semantics
	if g.is_struct_type(ltype) || (bop == .div && g.is_int_type(ltype))
		|| (bop == .right_shift && g.is_unsigned_type(ltype)) {
		g.writeln('${target} = ${g.binary(bop, target, val, ltype, ltype)}')
		return
	}
	jsop := match op {
		.unsigned_right_shift_assign { '>>>=' }
		.boolean_and_assign { '&&=' }
		.boolean_or_assign { '||=' }
		else { op.str() }
	}

	g.writeln('${target} ${jsop} ${val}')
}

// ---------- Return ----------

fn (mut g Gen) return_stmt(node ast.Return) {
	if node.exprs.len == 0 {
		g.writeln('return')
		return
	}
	if node.exprs.len == 1 {
		e := node.exprs[0]
		etype := node.types[0] or { ast.void_type }
		// `return error(...)` in a `!T` function throws; in a `?T` function it is `none`
		if g.is_error_expr(e, etype) {
			if g.fn_ret.has_flag(.result) {
				g.writeln('throw ${g.expr(e)}')
			} else {
				g.writeln('return null')
			}
			return
		}
		if e is ast.None {
			g.writeln('return null')
			return
		}
		// returning several values from a multi-return call
		g.writeln('return ${g.expr_value(e, etype)}')
		return
	}
	mut vals := []string{}
	for i, e in node.exprs {
		vals << g.expr_value(e, node.types[i] or { ast.void_type })
	}
	g.writeln('return [${vals.join(', ')}]')
}

// is_error_expr: `error('...')`, `error_with_code(...)`, or a value of type IError.
fn (mut g Gen) is_error_expr(e ast.Expr, t ast.Type) bool {
	if e is ast.CallExpr {
		if e.name in ['error', 'error_with_code'] && !e.is_method {
			return true
		}
	}
	if t != 0 {
		sym := g.sym(t.clear_flags(.option, .result))
		if sym.name in ['IError', 'Error', 'MessageError']
			&& !g.fn_ret.clear_flags(.option, .result).is_ptr()
			&& g.sym(g.fn_ret.clear_flags(.option, .result)).name != sym.name {
			return true
		}
	}
	return false
}

// ---------- Branches ----------

fn (mut g Gen) branch_stmt(node ast.BranchStmt) {
	kw := if node.kind == .key_break { 'break' } else { 'continue' }
	if node.label != '' {
		g.writeln('${kw} ${node.label}')
	} else {
		g.writeln(kw)
	}
}

// ---------- If ----------

// if_stmt generates an if/else chain. `result` names a variable each branch's last expression is stored in
// (when the if is used as a value), '' for a plain statement.
fn (mut g Gen) if_stmt(node ast.IfExpr, result string) {
	if node.is_comptime {
		g.comptime_if(node, result)
		return
	}
	g.if_branches(node, 0, result)
}

// if_branches emits branches[i..] — opening with `if (` (or `} else if`) and closing the chain.
fn (mut g Gen) if_branches(node ast.IfExpr, i int, result string) {
	if i >= node.branches.len {
		return
	}
	branch := node.branches[i]
	is_else := node.has_else && i == node.branches.len - 1
	if is_else {
		g.branch_body(branch.stmts, result, node.typ)
		return
	}
	if branch.cond is ast.IfGuardExpr {
		g.if_guard_branch(node, i, branch.cond, result)
		return
	}
	// the condition may need statements of its own: evaluate them before the `if`
	old := g.begin_capture()
	cond := g.expr(branch.cond)
	pre := g.end_capture(old)
	g.write_raw(pre)
	g.writeln('if (${cond}) {')
	g.indent++
	g.branch_body(branch.stmts, result, node.typ)
	g.indent--
	if i + 1 < node.branches.len {
		next := node.branches[i + 1]
		next_is_else := node.has_else && i + 1 == node.branches.len - 1
		if next_is_else {
			g.writeln('} else {')
			g.indent++
			g.branch_body(next.stmts, result, node.typ)
			g.indent--
			g.writeln('}')
		} else {
			g.writeln('} else {')
			g.indent++
			g.if_branches(node, i + 1, result)
			g.indent--
			g.writeln('}')
		}
	} else {
		g.writeln('}')
	}
}

// if_guard_branch: `if x := opt() { ... } else { ... }` (also for `!T` results and `m[k]` / `a[i]`).
fn (mut g Gen) if_guard_branch(node ast.IfExpr, i int, guard ast.IfGuardExpr, result string) {
	branch := node.branches[i]
	is_result := guard.expr_type.has_flag(.result)
	vars := guard.vars.map(if it.name == '_' { '' } else { js_name(it.name) })
	t := g.tmp()
	ok := if is_result { g.tmp() } else { '' }
	err := if is_result { g.tmp() } else { '' }
	g.writeln('{')
	g.indent++
	if is_result {
		g.writeln('let ${t}, ${ok} = true, ${err} = null')
		g.writeln('try {')
		g.indent++
		val := g.expr(guard.expr)
		g.writeln('${t} = ${val}')
		g.indent--
		g.writeln('} catch (_e) {')
		g.writeln('\t${ok} = false')
		g.writeln('\t${err} = V.as_error(_e)')
		g.writeln('}')
		g.writeln('if (${ok}) {')
	} else {
		val := g.guard_value(guard.expr)
		g.writeln('const ${t} = ${val}')
		g.writeln('if (${t} !== null) {')
	}
	g.indent++
	if vars.len == 1 {
		if vars[0] != '' {
			mut val := t
			if g.is_value_struct(guard.expr_type.clear_flags(.option, .result)) {
				val = 'V.clone(${t})'
			}
			g.writeln('const ${vars[0]} = ${val}')
		}
	} else if vars.len > 1 {
		g.writeln('const [${vars.join(', ')}] = ${t}')
	}
	g.branch_body(branch.stmts, result, node.typ)
	g.indent--
	if i + 1 < node.branches.len {
		g.writeln('} else {')
		g.indent++
		if is_result {
			next := node.branches[i + 1]
			if next.scope != unsafe { nil } && next.scope.find_var('err') != none {
				g.writeln('const err = ${err}')
			}
		}
		g.if_branches(node, i + 1, result)
		g.indent--
	}
	g.writeln('}')
	g.indent--
	g.writeln('}')
}

// guard_value: the value tested by an if-guard: an option, a map item or an array item (null when missing).
fn (mut g Gen) guard_value(e ast.Expr) string {
	if e is ast.IndexExpr {
		if g.is_map_type(e.left_type) {
			return 'V.M.opt(${g.expr(e.left)}, ${g.expr(e.index)})'
		}
		if g.is_array_type(e.left_type) {
			a := g.tmp()
			i := g.tmp()
			g.writeln('const ${a} = ${g.expr(e.left)}, ${i} = ${g.expr(e.index)}')
			return '(${i} >= 0 && ${i} < ${a}.length ? ${a}[${i}] : null)'
		}
	}
	return g.expr(e)
}

// branch_body generates a branch; with `result`, its last expression is stored there.
fn (mut g Gen) branch_body(stmts []ast.Stmt, result string, typ ast.Type) {
	if result == '' || stmts.len == 0 {
		g.stmts(stmts)
		return
	}
	g.stmts(stmts[..stmts.len - 1])
	last := stmts.last()
	if last is ast.ExprStmt {
		e := last.expr
		if g.is_noreturn_expr(e) {
			g.stmt(last)
			return
		}
		if e is ast.IfExpr && !e.is_comptime && e.is_expr {
			g.if_stmt(e, result)
			return
		}
		if e is ast.MatchExpr && e.is_expr {
			g.match_stmt(e, result)
			return
		}
		g.writeln('${result} = ${g.expr_value(e, typ)}')
		return
	}
	g.stmt(last)
}

// is_noreturn_expr: a call that never returns (panic, exit) used as the value of a branch.
fn (g &Gen) is_noreturn_expr(e ast.Expr) bool {
	if e is ast.CallExpr {
		return e.is_noreturn || e.name in ['panic', 'exit']
	}
	return false
}

// comptime_if: `$if webgl ? { } $else { }` — only the branch the checker selected is generated.
fn (mut g Gen) comptime_if(node ast.IfExpr, result string) {
	for i, branch in node.branches {
		is_else := node.has_else && i == node.branches.len - 1
		if is_else || g.comptime_true(branch) {
			g.writeln('{')
			g.indent++
			g.branch_body(branch.stmts, result, node.typ)
			g.indent--
			g.writeln('}')
			return
		}
	}
}

fn (g &Gen) comptime_true(branch ast.IfBranch) bool {
	key := '|id=${branch.id}|'
	if v := g.table.comptime_is_true[key] {
		return v.val
	}
	return false
}

// ---------- Match ----------

fn (mut g Gen) match_stmt(node ast.MatchExpr, result string) {
	if node.is_comptime {
		g.writeln(g.unsupported(node.pos, 'comptime `\$match`'))
		return
	}
	mut cond := g.expr(node.cond)
	if !is_simple_js(cond) {
		t := g.tmp()
		g.writeln('const ${t} = ${cond}')
		cond = t
	}
	mut first := true
	for branch in node.branches {
		if branch.is_else {
			if first {
				g.writeln('{')
			} else {
				g.writeln('} else {')
			}
		} else {
			mut conds := []string{}
			for e in branch.exprs {
				conds << g.match_cond(node, cond, e)
			}
			kw := if first { 'if' } else { '} else if' }
			g.writeln('${kw} (${conds.join(' || ')}) {')
		}
		first = false
		g.indent++
		g.branch_body(branch.stmts, result, node.return_type)
		g.indent--
	}
	if !first {
		g.writeln('}')
	}
}

// match_cond: the test of one match branch value (a value, a range `a...b`, or a type for sum types).
fn (mut g Gen) match_cond(node ast.MatchExpr, cond string, e ast.Expr) string {
	if node.is_sum_type || g.kind_of(node.cond_type) == .interface {
		match e {
			ast.TypeNode {
				return 'V.is_type(${cond}, ${g.type_desc(e.typ)})'
			}
			ast.None {
				return '${cond} === null'
			}
			else {}
		}
	}
	if e is ast.RangeExpr {
		lo := g.expr(e.low)
		hi := g.expr(e.high)
		return '(${cond} >= ${lo} && ${cond} <= ${hi})'
	}
	ctype := node.cond_type
	val := g.expr(e)
	if g.is_struct_type(ctype) || g.is_array_type(ctype) {
		return 'V.eq(${cond}, ${val})'
	}
	return '${cond} === ${val}'
}

fn is_simple_js(s string) bool {
	for c in s {
		if !(c.is_letter() || c.is_digit() || c in [`_`, `.`, `$`]) {
			return false
		}
	}
	return s != ''
}

// ---------- Loops ----------

// label_prefix: `outer: ` before a loop, so `break outer` / `continue outer` work.
fn label_prefix(label string) string {
	return if label != '' { '${label}: ' } else { '' }
}

fn (mut g Gen) for_stmt(node ast.ForStmt) {
	lp := label_prefix(node.label)
	if node.is_inf {
		g.writeln('${lp}for (;;) {')
	} else {
		old := g.begin_capture()
		g.indent++
		cond := g.expr(node.cond)
		g.indent--
		pre := g.end_capture(old)
		if pre == '' {
			g.writeln('${lp}while (${cond}) {')
		} else {
			// the condition needs statements: evaluate them at the top of every iteration
			g.writeln('${lp}for (;;) {')
			g.write_raw(pre)
			g.writeln('\tif (!(${cond})) break')
		}
	}
	g.indent++
	g.stmts(node.stmts)
	g.indent--
	g.writeln('}')
}

fn (mut g Gen) for_c_stmt(node ast.ForCStmt) {
	lp := label_prefix(node.label)
	mut init := ''
	if node.has_init {
		init = g.simple_stmt(node.init, true)
	}
	mut cond := ''
	mut pre := ''
	if node.has_cond {
		old := g.begin_capture()
		g.indent++
		cond = g.expr(node.cond)
		g.indent--
		pre = g.end_capture(old)
	}
	inc := if node.has_inc { g.simple_stmt(node.inc, false) } else { '' }
	if pre == '' {
		g.writeln('${lp}for (${init}; ${cond}; ${inc}) {')
	} else {
		g.writeln('${lp}for (${init}; ; ${inc}) {')
		g.write_raw(pre)
		g.writeln('\tif (!(${cond})) break')
	}
	g.indent++
	g.stmts(node.stmts)
	g.indent--
	g.writeln('}')
}

// simple_stmt: an assignment or expression for the init/increment parts of a C-style for loop.
fn (mut g Gen) simple_stmt(s ast.Stmt, is_init bool) string {
	match s {
		ast.AssignStmt {
			mut parts := []string{}
			for i, l in s.left {
				r := s.right[i] or { s.right[0] }
				val := g.expr(r)
				name := g.lhs_name(l)
				if s.op == .decl_assign {
					parts << '${name} = ${val}'
				} else if s.op == .assign {
					parts << '${name} = ${val}'
				} else {
					ltype := s.left_types[i] or { ast.void_type }
					bop := compound_op(s.op)
					if bop == .div && g.is_int_type(ltype) {
						parts << '${name} = ${g.binary(bop, name, val, ltype, ltype)}'
					} else {
						parts << '${name} ${s.op.str()} ${val}'
					}
				}
			}
			if s.op == .decl_assign && is_init {
				return 'let ' + parts.join(', ')
			}
			return parts.join(', ')
		}
		ast.ExprStmt {
			return g.expr(s.expr)
		}
		else {
			return ''
		}
	}
}

fn (mut g Gen) for_in_stmt(node ast.ForInStmt) {
	lp := label_prefix(node.label)
	key := if node.key_var == '' || node.key_var == '_' { '' } else { js_name(node.key_var) }
	val := if node.val_var == '' || node.val_var == '_' { '' } else { js_name(node.val_var) }
	if node.is_range {
		// for i in a .. b
		lo := g.expr(node.cond)
		hi := g.expr(node.high)
		name := if val != '' { val } else { g.tmp() }
		if is_simple_js(hi) && !hi.contains('.') {
			g.writeln('${lp}for (let ${name} = ${lo}; ${name} < ${hi}; ${name}++) {')
		} else {
			h := g.tmp()
			g.writeln('${lp}for (let ${name} = ${lo}, ${h} = ${hi}; ${name} < ${h}; ${name}++) {')
		}
		g.indent++
		g.stmts(node.stmts)
		g.indent--
		g.writeln('}')
		return
	}
	cond := g.expr(node.cond)
	ctype := node.cond_type.clear_flags(.option, .result).set_nr_muls(0)
	if g.is_map_type(ctype) {
		m := g.tmp()
		g.writeln('const ${m} = ${cond}')
		writeback := node.val_is_mut && val != '' && !g.is_reference(node.val_type)
			&& !g.is_struct_type(node.val_type) && !g.is_array_type(node.val_type)
			&& !g.is_map_type(node.val_type)
		k := if key != '' { key } else { g.tmp() }
		if val == '' {
			g.writeln('${lp}for (const ${k} of ${m}.keys()) {')
		} else if key == '' && !writeback {
			g.writeln('${lp}for (${if node.val_is_mut { 'let' } else { 'const' }} ${val} of ${m}.values()) {')
		} else {
			g.writeln('${lp}for (let [${k}, ${val}] of ${m}) {')
		}
		g.indent++
		if writeback {
			g.writeln('try {')
			g.indent++
			g.stmts(node.stmts)
			g.indent--
			g.writeln('} finally {')
			g.writeln('\t${m}.set(${k}, ${val})')
			g.writeln('}')
		} else {
			g.stmts(node.stmts)
		}
		g.indent--
		g.writeln('}')
		return
	}
	is_string := g.is_string_type(ctype)
	a := g.tmp()
	i := if key != '' { key } else { g.tmp() }
	g.writeln('${lp}for (let ${i} = 0, ${a} = ${cond}; ${i} < ${a}.length; ${i}++) {')
	g.indent++
	writeback := node.val_is_mut && val != '' && !is_string && !g.is_reference(node.val_type)
		&& !g.is_struct_type(node.val_type) && !g.is_array_type(node.val_type)
		&& !g.is_map_type(node.val_type)
	if val != '' {
		elem := if is_string { '${a}.charCodeAt(${i})' } else { '${a}[${i}]' }
		kw := if node.val_is_mut { 'let' } else { 'const' }
		g.writeln('${kw} ${val} = ${elem}')
	}
	if writeback {
		g.writeln('try {')
		g.indent++
		g.stmts(node.stmts)
		g.indent--
		g.writeln('} finally {')
		g.writeln('\t${a}[${i}] = ${val}')
		g.writeln('}')
	} else {
		g.stmts(node.stmts)
	}
	g.indent--
	g.writeln('}')
}
