module main

import strings

// JavaScript words that cannot be used as variable or function names, plus the names generated code relies on.
const js_reserved = ['arguments', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
	'debugger', 'default', 'delete', 'do', 'else', 'enum', 'eval', 'export', 'extends', 'false',
	'finally', 'for', 'function', 'if', 'implements', 'import', 'in', 'instanceof', 'interface',
	'let', 'new', 'null', 'package', 'private', 'protected', 'public', 'return', 'static', 'super',
	'switch', 'this', 'throw', 'true', 'try', 'typeof', 'var', 'void', 'while', 'with', 'yield',
	'undefined', 'NaN', 'Infinity', 'Object', 'Array', 'Map', 'Set', 'String', 'Number', 'Math',
	'JSON', 'Date', 'Error', 'Promise', 'Symbol', 'console', 'window', 'document', 'globalThis',
	'self', 'V']

// js_name makes a V identifier safe as a JavaScript variable/function name.
fn js_name(name string) string {
	n := name.replace('.', '_')
	if n in js_reserved {
		return n + '_'
	}
	return n
}

// js_string quotes `s` as a JavaScript string literal.
fn js_string(s string) string {
	mut sb := strings.new_builder(s.len + 2)
	sb.write_u8(`'`)
	for r in s.runes() {
		match r {
			`'` {
				sb.write_string("\\'")
			}
			`\\` {
				sb.write_string('\\\\')
			}
			`\n` {
				sb.write_string('\\n')
			}
			`\r` {
				sb.write_string('\\r')
			}
			`\t` {
				sb.write_string('\\t')
			}
			`\0` {
				sb.write_string('\\0')
			}
			else {
				if r < 32 || r == 0x2028 || r == 0x2029 {
					sb.write_string('\\u${u32(r):04x}')
				} else {
					sb.write_string(r.str())
				}
			}
		}
	}
	sb.write_u8(`'`)
	return sb.str()
}

// template_part escapes text for a JavaScript template literal (`...${x}...`).
fn template_part(s string) string {
	mut sb := strings.new_builder(s.len)
	for r in s.runes() {
		match r {
			`\`` { sb.write_string('\\`') }
			`\\` { sb.write_string('\\\\') }
			`$` { sb.write_string('\\$') }
			`\r` { sb.write_string('\\r') }
			`\0` { sb.write_string('\\0') }
			else { sb.write_string(r.str()) }
		}
	}
	return sb.str()
}

// v_unescape turns the source text of a V string literal (escapes not yet processed) into its value.
fn v_unescape(src string, is_raw bool) string {
	if is_raw || !src.contains('\\') {
		return src
	}
	mut out := []u8{cap: src.len}
	mut i := 0
	for i < src.len {
		c := src[i]
		if c != `\\` || i + 1 >= src.len {
			out << c
			i++
			continue
		}
		n := src[i + 1]
		i += 2
		match n {
			`n` {
				out << `\n`
			}
			`t` {
				out << `\t`
			}
			`r` {
				out << `\r`
			}
			`0` {
				out << 0
			}
			`a` {
				out << 7
			}
			`b` {
				out << 8
			}
			`f` {
				out << 12
			}
			`v` {
				out << 11
			}
			`e` {
				out << 27
			}
			`x` {
				if i + 2 <= src.len {
					out << u8(('0x' + src[i..i + 2]).u32())
					i += 2
				}
			}
			`u` {
				if i + 4 <= src.len {
					r := rune(('0x' + src[i..i + 4]).u32())
					out << r.str().bytes()
					i += 4
				}
			}
			`U` {
				if i + 8 <= src.len {
					r := rune(('0x' + src[i..i + 8]).u32())
					out << r.str().bytes()
					i += 8
				}
			}
			`\n` {
				// line continuation: skip the newline and the indentation after it
				for i < src.len && src[i] in [` `, `\t`] {
					i++
				}
			}
			else {
				if n >= `0` && n <= `7` && i + 1 < src.len {
					// octal \NNN
					oct := src[i - 1..i + 2]
					out << u8(('0o' + oct).u32())
					i += 2
				} else {
					out << n
				}
			}
		}
	}
	return out.bytestr()
}

// char_code returns the code point of a V character literal's source text (`a`, `\n`, `\x41`, `é`).
fn char_code(src string) u32 {
	s := v_unescape(src, false)
	runes := s.runes()
	if runes.len == 0 {
		return 0
	}
	return u32(runes[0])
}

// js_number converts a V number literal to JavaScript (0o, 0x, 0b and _ separators are valid in both).
fn js_number(lit string) string {
	mut s := lit.replace('_', '')
	if s.starts_with('.') {
		s = '0' + s
	}
	if s.ends_with('.') {
		s += '0'
	}
	// 0777-style octal does not exist in V; leading zeros would make it legacy octal in JavaScript
	if s.len > 1 && s[0] == `0` && s[1].is_digit() && !s.contains('.') && !s.contains('e') {
		s = s.trim_left('0')
		if s == '' {
			s = '0'
		}
	}
	return s
}
