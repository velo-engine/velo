module serialize

// .scene file syntax (shared by scenes and prefabs):
//
//   # comment
//   node Player {                       <- root node
//     position = [100, 200]             <- node properties: position, rotation, scale, active
//     Sprite { texture = @asset("7f3a91c2")  color = [255, 255, 255, 255] }   <- component
//     PlayerController { speed = 300 }
//     node Weapon from @asset("b21e0d44") {    <- child node that is an instance of another prefab
//       Damage { value = 15 }                  <- only write what differs from the source prefab (override)
//     }
//   }
//
// Node names containing spaces go in double quotes: node "Big Coin" { ... }

pub struct ComponentDesc {
pub mut:
	type_name string
	props     map[string]Value
	line      int
}

pub struct NodeDesc {
pub mut:
	name       string
	from       string // asset ID (or path) of the source prefab, '' for a plain node
	props      map[string]Value
	components []ComponentDesc
	children   []NodeDesc
	line       int
}

enum TokKind {
	ident
	str
	num
	lbrace
	rbrace
	lbrack
	rbrack
	comma
	eq
	at
	lparen
	rparen
	eof
}

struct Token {
	kind TokKind
	text string
	line int
}

struct Parser {
	file string
mut:
	toks []Token
	pos  int
}

// parse reads the contents of a .scene file and returns a description tree (no real nodes created yet).
pub fn parse(src string, file string) !NodeDesc {
	mut p := Parser{
		file: file
		toks: tokenize(src, file)!
	}
	root := p.parse_node()!
	if p.peek().kind != .eof {
		return p.err('only one root node is allowed per file')
	}
	return root
}

// parse_value_text reads ONE value written in .scene syntax, e.g. `[1, 2]`, `"abc"`, `@asset("id")`
// (used by the editor to accept values the user types into the inspector).
pub fn parse_value_text(src string) !Value {
	mut p := Parser{
		file: 'value'
		toks: tokenize(src, 'value')!
	}
	v := p.parse_value()!
	if p.peek().kind != .eof {
		return p.err('unexpected "${p.peek().text}" after the value')
	}
	return v
}

fn (mut p Parser) parse_node() !NodeDesc {
	kw := p.next()
	if kw.kind != .ident || kw.text != 'node' {
		return p.err_at(kw, 'expected keyword `node`, got "${kw.text}"')
	}
	name_tok := p.next()
	if name_tok.kind != .ident && name_tok.kind != .str {
		return p.err_at(name_tok, 'expected a node name after `node`')
	}
	mut n := NodeDesc{
		name: name_tok.text
		line: kw.line
	}
	if p.peek().kind == .ident && p.peek().text == 'from' {
		p.next()
		v := p.parse_value()!
		n.from = v.as_asset() or { return p.err('expected @asset("id") after `from`') }
	}
	p.expect(.lbrace, '{')!
	for {
		t := p.peek()
		if t.kind == .rbrace {
			p.next()
			break
		}
		if t.kind == .eof {
			return p.err_at(t, 'missing `}` closing node "${n.name}" (opened on line ${n.line})')
		}
		if t.kind == .ident && t.text == 'node' {
			n.children << p.parse_node()!
			continue
		}
		if t.kind != .ident {
			return p.err_at(t, 'unexpected "${t.text}"')
		}
		p.next()
		after := p.peek()
		if after.kind == .eq {
			p.next()
			n.props[t.text] = p.parse_value()!
		} else if after.kind == .lbrace {
			n.components << p.parse_component(t)!
		} else {
			return p.err_at(after, 'expected `=` (property) or `{` (component) after "${t.text}"')
		}
	}
	return n
}

fn (mut p Parser) parse_component(name Token) !ComponentDesc {
	p.expect(.lbrace, '{')!
	mut c := ComponentDesc{
		type_name: name.text
		line:      name.line
	}
	for {
		t := p.next()
		if t.kind == .rbrace {
			break
		}
		if t.kind != .ident {
			return p.err_at(t, 'expected a field name in component ${c.type_name}, got "${t.text}"')
		}
		p.expect(.eq, '=')!
		c.props[t.text] = p.parse_value()!
	}
	return c
}

fn (mut p Parser) parse_value() !Value {
	t := p.next()
	match t.kind {
		.num {
			return Value(t.text.f64())
		}
		.str {
			return Value(t.text)
		}
		.ident {
			return match t.text {
				'true' { Value(true) }
				'false' { Value(false) }
				else {
					p.err_at(t, 'invalid value "${t.text}" (strings must be enclosed in "...")')
				}
			}
		}
		.lbrack {
			mut arr := []Value{}
			if p.peek().kind == .rbrack {
				p.next()
				return Value(arr)
			}
			for {
				arr << p.parse_value()!
				sep := p.next()
				if sep.kind == .rbrack {
					break
				}
				if sep.kind != .comma {
					return p.err_at(sep, 'expected `,` or `]` in array')
				}
			}
			return Value(arr)
		}
		.at {
			fn_name := p.next()
			if fn_name.text != 'asset' {
				return p.err_at(fn_name, 'only @asset("...") is supported')
			}
			p.expect(.lparen, '(')!
			s := p.next()
			if s.kind != .str {
				return p.err_at(s, '@asset expects a string')
			}
			p.expect(.rparen, ')')!
			return Value(AssetId{s.text})
		}
		else {
			return p.err_at(t, 'expected a value, got "${t.text}"')
		}
	}
}

fn (mut p Parser) peek() Token {
	return p.toks[p.pos]
}

fn (mut p Parser) next() Token {
	t := p.toks[p.pos]
	if p.pos < p.toks.len - 1 {
		p.pos++
	}
	return t
}

fn (mut p Parser) expect(k TokKind, what string) ! {
	t := p.next()
	if t.kind != k {
		return p.err_at(t, 'expected `${what}`, got "${t.text}"')
	}
}

fn (p &Parser) err(msg string) IError {
	return error('${p.file}:${p.toks[p.pos].line}: ${msg}')
}

fn (p &Parser) err_at(t Token, msg string) IError {
	return error('${p.file}:${t.line}: ${msg}')
}

fn tokenize(src string, file string) ![]Token {
	mut toks := []Token{}
	mut i := 0
	mut line := 1
	for i < src.len {
		c := src[i]
		if c == `\n` {
			line++
			i++
			continue
		}
		if c == ` ` || c == `\t` || c == `\r` || c == `;` {
			i++
			continue
		}
		if c == `#` {
			for i < src.len && src[i] != `\n` {
				i++
			}
			continue
		}
		single := match c {
			`{` { TokKind.lbrace }
			`}` { TokKind.rbrace }
			`[` { TokKind.lbrack }
			`]` { TokKind.rbrack }
			`,` { TokKind.comma }
			`=` { TokKind.eq }
			`@` { TokKind.at }
			`(` { TokKind.lparen }
			`)` { TokKind.rparen }
			else { TokKind.eof }
		}
		if single != .eof {
			toks << Token{single, c.ascii_str(), line}
			i++
			continue
		}
		if c == `"` {
			i++
			mut s := []u8{}
			for i < src.len && src[i] != `"` {
				if src[i] == `\\` && i + 1 < src.len {
					i++
					s << match src[i] {
						`n` { u8(`\n`) }
						`t` { u8(`\t`) }
						else { src[i] }
					}
				} else {
					if src[i] == `\n` {
						line++
					}
					s << src[i]
				}
				i++
			}
			if i >= src.len {
				return error('${file}:${line}: unterminated string `"`')
			}
			i++
			toks << Token{.str, s.bytestr(), line}
			continue
		}
		if c.is_digit() || c == `-` || c == `+` || c == `.` {
			start := i
			i++
			for i < src.len && (src[i].is_digit() || src[i] in [`.`, `e`, `E`, `-`, `+`]) {
				i++
			}
			toks << Token{.num, src[start..i], line}
			continue
		}
		if c.is_letter() || c == `_` {
			start := i
			for i < src.len && (src[i].is_letter() || src[i].is_digit() || src[i] == `_`) {
				i++
			}
			toks << Token{.ident, src[start..i], line}
			continue
		}
		return error('${file}:${line}: invalid character "${c.ascii_str()}"')
	}
	toks << Token{.eof, '<end of file>', line}
	return toks
}
