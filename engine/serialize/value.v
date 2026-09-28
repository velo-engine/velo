module serialize

import engine.core

// AssetId — an `@asset("7f3a91c2")` value in a scene file.
pub struct AssetId {
pub:
	id string
}

// Value — a property value in a .scene file.
pub type Value = AssetId | []Value | bool | f64 | string

pub fn (v Value) as_f64() !f64 {
	return match v {
		f64 { v }
		bool {
			if v { 1.0 } else { 0.0 }
		}
		else { error('expected a number, got ${v.to_text()}') }
	}
}

pub fn (v Value) as_bool() !bool {
	return match v {
		bool { v }
		f64 { v != 0 }
		else { error('expected true/false, got ${v.to_text()}') }
	}
}

pub fn (v Value) as_string() !string {
	return match v {
		string { v }
		else { error('expected a string "...", got ${v.to_text()}') }
	}
}

pub fn (v Value) as_asset() !string {
	return match v {
		AssetId { v.id }
		string { v } // allows writing a path; the loader will resolve it
		else { error('expected @asset("id"), got ${v.to_text()}') }
	}
}

// as_number_list: a number array of any length.
pub fn (v Value) as_number_list() ![]f64 {
	if v is []Value {
		mut out := []f64{}
		for x in v {
			out << x.as_f64()!
		}
		return out
	}
	return error('expected a number array [...], got ${v.to_text()}')
}

pub fn (v Value) as_numbers(n int) ![]f64 {
	out := v.as_number_list()!
	if out.len != n {
		return error('expected an array of ${n} numbers, got ${out.len} elements')
	}
	return out
}

pub fn (v Value) as_vec2() !core.Vec2 {
	n := v.as_numbers(2)!
	return core.vec2(f32(n[0]), f32(n[1]))
}

// as_color accepts [r, g, b] or [r, g, b, a].
pub fn (v Value) as_color() !core.Color {
	n := v.as_number_list()!
	if n.len == 3 {
		return core.rgba(u8(n[0]), u8(n[1]), u8(n[2]), 255)
	}
	if n.len != 4 {
		return error('a color needs [r, g, b] or [r, g, b, a]')
	}
	return core.rgba(u8(n[0]), u8(n[1]), u8(n[2]), u8(n[3]))
}

pub fn vec2_value(p core.Vec2) Value {
	return Value([Value(f64(p.x)), Value(f64(p.y))])
}

pub fn color_value(c core.Color) Value {
	return Value([Value(f64(c.r)), Value(f64(c.g)), Value(f64(c.b)), Value(f64(c.a))])
}

// to_text converts the value back to .scene file syntax.
pub fn (v Value) to_text() string {
	return match v {
		AssetId {
			'@asset("${v.id}")'
		}
		bool {
			v.str()
		}
		f64 {
			fmt_num(v)
		}
		string {
			'"' + v.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'
		}
		[]Value {
			'[' + v.map(it.to_text()).join(', ') + ']'
		}
	}
}

fn fmt_num(x f64) string {
	if x == f64(i64(x)) && x < 1e15 && x > -1e15 {
		return i64(x).str()
	}
	// round so that f32 -> f64 does not produce 0.30000001192092896
	s := '${x:.4f}'.trim_right('0')
	return s.trim_right('.')
}
