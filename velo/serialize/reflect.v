module serialize

import engine.core
import engine.assets

// Automatic serialization via V's comptime reflection: NO need to write read/write code for each component.
//
// Supported field types: f32, f64, int, bool, string, core.Vec2, core.Color,
// assets.AssetRef[Texture | SceneAsset | AudioClip | TextAsset].
// Fields of other types (pointers, maps, ...) are skipped automatically. Hide a field with the @[hide] attribute:
//
//   velocity core.Vec2 @[hide]

// set_fields assigns values from the scene file into the struct. Unknown field -> error (catches typos).
pub fn set_fields[T](mut obj T, props map[string]Value) ! {
	mut used := map[string]bool{}
	$for field in T.fields {
		if v := props[field.name] {
			if 'hide' !in field.attrs {
				used[field.name] = true
				$if field.typ is f32 {
					obj.$(field.name) = f32(v.as_f64()!)
				} $else $if field.typ is f64 {
					obj.$(field.name) = v.as_f64()!
				} $else $if field.typ is int {
					obj.$(field.name) = int(v.as_f64()!)
				} $else $if field.typ is bool {
					obj.$(field.name) = v.as_bool()!
				} $else $if field.typ is string {
					obj.$(field.name) = v.as_string()!
				} $else $if field.typ is core.Vec2 {
					obj.$(field.name) = v.as_vec2()!
				} $else $if field.typ is core.Color {
					obj.$(field.name) = v.as_color()!
				} $else $if field.typ is assets.AssetRef[assets.Texture] {
					obj.$(field.name) = assets.AssetRef[assets.Texture]{
						id: v.as_asset()!
					}
				} $else $if field.typ is assets.AssetRef[assets.SceneAsset] {
					obj.$(field.name) = assets.AssetRef[assets.SceneAsset]{
						id: v.as_asset()!
					}
				} $else $if field.typ is assets.AssetRef[assets.AudioClip] {
					obj.$(field.name) = assets.AssetRef[assets.AudioClip]{
						id: v.as_asset()!
					}
				} $else $if field.typ is assets.AssetRef[assets.TextAsset] {
					obj.$(field.name) = assets.AssetRef[assets.TextAsset]{
						id: v.as_asset()!
					}
				} $else {
					used[field.name] = false
				}
			}
		}
	}
	for k, _ in props {
		if !used[k] {
			return error('${core.short_type_name(T.name)} has no serializable field "${k}"')
		}
	}
}

// dump_fields reads all serializable fields into a map (in declaration order).
pub fn dump_fields[T](obj T) map[string]Value {
	mut out := map[string]Value{}
	$for field in T.fields {
		if 'hide' !in field.attrs {
			$if field.typ is f32 {
				out[field.name] = Value(f64(obj.$(field.name)))
			} $else $if field.typ is f64 {
				out[field.name] = Value(obj.$(field.name))
			} $else $if field.typ is int {
				out[field.name] = Value(f64(obj.$(field.name)))
			} $else $if field.typ is bool {
				out[field.name] = Value(obj.$(field.name))
			} $else $if field.typ is string {
				out[field.name] = Value(obj.$(field.name))
			} $else $if field.typ is core.Vec2 {
				out[field.name] = vec2_value(obj.$(field.name))
			} $else $if field.typ is core.Color {
				out[field.name] = color_value(obj.$(field.name))
			} $else $if field.typ is assets.AssetRef[assets.Texture] {
				out[field.name] = Value(AssetId{obj.$(field.name).id})
			} $else $if field.typ is assets.AssetRef[assets.SceneAsset] {
				out[field.name] = Value(AssetId{obj.$(field.name).id})
			} $else $if field.typ is assets.AssetRef[assets.AudioClip] {
				out[field.name] = Value(AssetId{obj.$(field.name).id})
			} $else $if field.typ is assets.AssetRef[assets.TextAsset] {
				out[field.name] = Value(AssetId{obj.$(field.name).id})
			}
		}
	}
	return out
}

// FieldInfo — describes a field for the editor/inspector.
pub struct FieldInfo {
pub:
	name       string
	type_name  string
	asset_kind assets.AssetKind // asset kind accepted by an AssetRef[...] field (.unknown if not an AssetRef)
}

pub fn describe_fields[T]() []FieldInfo {
	mut kinds := map[string]assets.AssetKind{}
	$for field in T.fields {
		$if field.typ is assets.AssetRef[assets.Texture] {
			kinds[field.name] = .texture
		} $else $if field.typ is assets.AssetRef[assets.SceneAsset] {
			kinds[field.name] = .scene
		} $else $if field.typ is assets.AssetRef[assets.AudioClip] {
			kinds[field.name] = .audio
		} $else $if field.typ is assets.AssetRef[assets.TextAsset] {
			kinds[field.name] = .text
		}
	}
	mut out := []FieldInfo{}
	sample := T{}
	for k, v in dump_fields(sample) {
		out << FieldInfo{
			name:       k
			type_name:  v.type_name()
			asset_kind: kinds[k] or { assets.AssetKind.unknown }
		}
	}
	return out
}
