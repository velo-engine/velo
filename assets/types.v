module assets

// AssetKind — asset kind, inferred from the file extension on first import and stored in .meta.
pub enum AssetKind {
	unknown
	texture
	audio
	scene
	text
}

pub fn kind_from_ext(path string) AssetKind {
	ext := path.all_after_last('.').to_lower()
	return match ext {
		'png', 'jpg', 'jpeg', 'bmp', 'tga' { .texture }
		'wav', 'ogg', 'mp3' { .audio }
		'scene', 'prefab' { .scene }
		'txt', 'json', 'md', 'csv' { .text }
		else { .unknown }
	}
}

pub fn kind_from_str(s string) AssetKind {
	return match s {
		'texture' { .texture }
		'audio' { .audio }
		'scene' { .scene }
		'text' { .text }
		else { .unknown }
	}
}

// AssetRef[T] — a TYPED asset reference, stored as a stable ID (not a path).
// Assigning an AssetRef[AudioClip] to an AssetRef[Texture] slot is a compile error;
// an ID pointing to a file of the wrong kind reports a clear error on load.
pub struct AssetRef[T] {
pub:
	id string
}

pub fn ref[T](id string) AssetRef[T] {
	return AssetRef[T]{
		id: id
	}
}

pub fn (r AssetRef[T]) is_set() bool {
	return r.id != ''
}

// ---------- Loaded asset data ----------
// The `version` field increments on every hot reload, so the renderer/other systems know to update.

pub struct Texture {
pub:
	id   string
	path string // absolute path to the source file
pub mut:
	width        int
	height       int
	frame_width  int // from .meta: size of one frame if this is a sprite sheet
	frame_height int
	filter       string = 'linear' // 'linear' | 'nearest' (pixel art)
	version      int
}

// frame_count: number of frames in the sprite sheet (laid out in rows, left -> right, top -> bottom).
pub fn (t &Texture) frame_count() int {
	fw := t.frame_w()
	fh := t.frame_h()
	if fw <= 0 || fh <= 0 {
		return 1
	}
	return (t.width / fw) * (t.height / fh)
}

pub fn (t &Texture) frame_w() int {
	return if t.frame_width > 0 { t.frame_width } else { t.width }
}

pub fn (t &Texture) frame_h() int {
	return if t.frame_height > 0 { t.frame_height } else { t.height }
}

// frame_rect returns (x, y, w, h) of frame i in the source image.
pub fn (t &Texture) frame_rect(i int) (int, int, int, int) {
	fw := t.frame_w()
	fh := t.frame_h()
	cols := if fw > 0 { t.width / fw } else { 1 }
	count := t.frame_count()
	idx := if count > 0 { ((i % count) + count) % count } else { 0 }
	c := if cols > 0 { idx % cols } else { 0 }
	r := if cols > 0 { idx / cols } else { 0 }
	return c * fw, r * fh, fw, fh
}

// SceneAsset — text content of a .scene/.prefab file. Parsing is handled by the serialize module.
pub struct SceneAsset {
pub:
	id   string
	path string
pub mut:
	source  string
	version int
}

pub struct TextAsset {
pub:
	id   string
	path string
pub mut:
	text    string
	version int
}

// AudioClip — a sound file (.wav or .ogg). The velo.audio module decodes it when it is first played.
pub struct AudioClip {
pub:
	id   string
	path string
pub mut:
	bytes int
	// From .meta: `stream: true` decodes while playing (long music), `false` decodes it all up front;
	// '' = automatic (streams .ogg files longer than 20 seconds).
	stream  string
	version int
}
