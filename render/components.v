module render

import velo.core
import velo.assets
import velo.serialize

// register_builtins registers the engine's built-in components so .scene files can use them.
pub fn register_builtins(mut r serialize.Registry) {
	r.register[core.Camera]()
	r.register[core.Canvas]()
	r.register[Sprite]()
	r.register[SpriteAnimator]()
	r.register[Label]()
	r.register[UITransform]()
	r.register[Panel]()
	r.register[Button]()
	r.register[Toggle]()
	r.register[ProgressBar]()
	r.register[ScrollView]()
	r.register[Widget]()
	r.register[Layout]()
	r.register[Joystick]()
	r.register[TextInput]()
	r.register[ParticleSystem]()
	r.register[TileMap]()
}

// Sprite — draws a texture (or one frame of a sprite sheet) at the node's position.
// `draw_mode` picks how the frame fills `size` (see sprite_modes.v):
//   'simple'  stretches the whole frame
//   'sliced'  9-slice: the `border_*` edges keep their size, the edges/center stretch (panels, buttons)
//   'tiled'   repeats the frame (or, with borders, its edges/center between fixed corners)
pub struct Sprite {
	core.Component
pub mut:
	texture   assets.AssetRef[assets.Texture]
	color     core.Color = core.white
	anchor    core.Vec2  = core.Vec2{0.5, 0.5} // (0,0) top-left corner, (0.5,0.5) center
	size      core.Vec2 // 0 = use the texture's frame size
	frame     int
	flip_x    bool
	flip_y    bool
	draw_mode string = 'simple' @[choices: 'simple|sliced|tiled']
	// 9-slice borders in texture pixels, measured inward from the frame's edges.
	border_left   int
	border_top    int
	border_right  int
	border_bottom int
	fill_center   bool = true // false: sliced/tiled draw only the border ring (frames, outlines)
	// World units per texture pixel for the borders and the tile repeat (2 = twice as thick / big).
	pixel_scale f32 = 1
	// A .glsl effect to draw with (see shader.v); its PARAMS and PARAM_COLOR built-ins.
	shader        assets.AssetRef[assets.Shader]
	shader_params core.Vec2
	shader_color  core.Color = core.white
	// Loaded texture and shader (runtime, not serialized).
	tex         &assets.Texture = unsafe { nil } @[hide]
	loaded      string          @[hide]
	shader_data &assets.Shader = unsafe { nil }  @[hide]
}

// on_load: fetches the texture from the AssetDatabase (increments the reference count).
pub fn (mut s Sprite) on_load() {
	s.acquire()
	if s.shader_data == unsafe { nil } {
		s.shader_data = load_shader(s.node, s.shader)
	}
}

// on_destroy: releases the reference so the asset is freed when no one uses it anymore.
pub fn (mut s Sprite) on_destroy() {
	s.drop()
	s.shader_data = release_shader_asset(s.node, s.shader_data)
}

// set_shader changes the shader effect at runtime (an unset ref draws the plain texture again).
pub fn (mut s Sprite) set_shader(r assets.AssetRef[assets.Shader]) {
	s.shader_data = release_shader_asset(s.node, s.shader_data)
	s.shader = r
	s.shader_data = load_shader(s.node, r)
}

// set_texture changes the texture at runtime, managing references automatically.
pub fn (mut s Sprite) set_texture(r assets.AssetRef[assets.Texture]) {
	s.drop()
	s.texture = r
	s.acquire()
}

fn (mut s Sprite) acquire() {
	if !s.texture.is_set() || s.node == unsafe { nil } || s.node.scene == unsafe { nil } {
		return
	}
	mut db := s.node.scene.assets
	if db == unsafe { nil } || s.loaded == s.texture.id {
		return
	}
	s.tex = db.get(s.texture) or {
		eprintln('[Sprite] ${s.node.path()}: ${err}')
		return
	}
	s.loaded = s.texture.id
}

fn (mut s Sprite) drop() {
	if s.loaded == '' || s.node == unsafe { nil } || s.node.scene == unsafe { nil } {
		return
	}
	mut db := s.node.scene.assets
	if db != unsafe { nil } {
		db.release(s.loaded)
	}
	s.loaded = ''
	s.tex = unsafe { nil }
}

// display_size: drawn size (before multiplying by the node's scale).
pub fn (s &Sprite) display_size() core.Vec2 {
	if s.size.x > 0 && s.size.y > 0 {
		return s.size
	}
	if s.tex == unsafe { nil } {
		return core.Vec2{}
	}
	return core.vec2(s.tex.frame_w(), s.tex.frame_h())
}

// local_rect: the rectangle (x, y, w, h) the sprite occupies in node coordinates (before applying the transform).
pub fn (s &Sprite) local_rect() (f32, f32, f32, f32) {
	sz := s.display_size()
	return -s.anchor.x * sz.x, -s.anchor.y * sz.y, sz.x, sz.y
}

// SpriteAnimator — plays the frames of a sprite sheet in sequence on the Sprite of the same node.
// The frame count comes from the frame_width/frame_height settings in the texture's .meta file.
pub struct SpriteAnimator {
	core.Component
pub mut:
	fps         f32  = 10
	playing     bool = true
	looping     bool = true
	first_frame int
	frame_count int // 0 = every frame in the sheet
	time        f32 @[hide]
}

pub fn (mut a SpriteAnimator) update(dt f32) {
	mut sprite := a.node.get_component[Sprite]() or { return }
	if sprite.tex == unsafe { nil } {
		return
	}
	if !a.playing {
		return
	}
	total := if a.frame_count > 0 {
		a.frame_count
	} else {
		sprite.tex.frame_count() - a.first_frame
	}
	if total <= 0 {
		return
	}
	a.time += dt
	mut idx := int(a.time * a.fps)
	if a.looping {
		idx = idx % total
	} else if idx >= total {
		idx = total - 1
		a.playing = false
	}
	sprite.frame = a.first_frame + idx
}

// Label — draws text (ignores rotation). With a UITransform on the node, the text is aligned inside its
// rectangle; otherwise it is aligned around the node's position. `\n` starts a new line.
pub struct Label {
	core.Component
pub mut:
	text   string
	size   int        = 20
	color  core.Color = core.white
	align  string     = 'left' @[choices: 'left|center|right']
	valign string     = 'top' @[choices: 'top|middle|bottom']
	font   assets.AssetRef[assets.Font] // .ttf/.otf; unset = the app's font
	// With a UITransform: `wrap` breaks lines at its width; `shrink` lowers the size until the text fits it.
	wrap         bool
	shrink       bool
	line_spacing f32 = 1.25 // line height, in font sizes
	// Readability over busy backgrounds (alpha 0 = off): a copy drawn behind at `shadow_offset`, and an
	// outline `outline_width` thick.
	shadow_color  core.Color   = core.rgba(0, 0, 0, 0)
	shadow_offset core.Vec2    = core.Vec2{2, 2}
	outline_color core.Color   = core.rgba(0, 0, 0, 0)
	outline_width f32          = 1.5
	font_data     &assets.Font = unsafe { nil } @[hide]
	layout_key    string       @[hide] // what `layout` was computed for
	layout        TextBlock    @[hide]
}

pub fn (mut l Label) on_load() {
	l.font_data = load_font(l.node, l.font)
}

pub fn (mut l Label) on_destroy() {
	l.font_data = release_font(l.node, l.font_data)
}

// set_font changes the font from code.
pub fn (mut l Label) set_font(r assets.AssetRef[assets.Font]) {
	l.font_data = release_font(l.node, l.font_data)
	l.font = r
	l.font_data = load_font(l.node, r)
}

fn load_font(n &core.Node, r assets.AssetRef[assets.Font]) &assets.Font {
	if !r.is_set() || n == unsafe { nil } || n.scene == unsafe { nil }
		|| n.scene.assets == unsafe { nil } {
		return unsafe { nil }
	}
	mut db := n.scene.assets
	return db.get(r) or {
		eprintln('[render] ${n.path()}: ${err}')
		unsafe { nil }
	}
}

// release_font gives the font back to the asset database; returns nil for the caller to store.
fn release_font(n &core.Node, f &assets.Font) &assets.Font {
	if f != unsafe { nil } && n != unsafe { nil } && n.scene != unsafe { nil }
		&& n.scene.assets != unsafe { nil } {
		mut db := n.scene.assets
		db.release(f.id)
	}
	return unsafe { nil }
}

fn load_shader(n &core.Node, r assets.AssetRef[assets.Shader]) &assets.Shader {
	if !r.is_set() || n == unsafe { nil } || n.scene == unsafe { nil }
		|| n.scene.assets == unsafe { nil } {
		return unsafe { nil }
	}
	mut db := n.scene.assets
	return db.get(r) or {
		eprintln('[render] ${n.path()}: ${err}')
		unsafe { nil }
	}
}

fn release_shader_asset(n &core.Node, s &assets.Shader) &assets.Shader {
	if s != unsafe { nil } && n != unsafe { nil } && n.scene != unsafe { nil }
		&& n.scene.assets != unsafe { nil } {
		mut db := n.scene.assets
		db.release(s.id)
	}
	return unsafe { nil }
}

// font_family: what gg draws the text with ('' = the default font).
fn font_family(f &assets.Font) string {
	return if f != unsafe { nil } { f.path } else { '' }
}

// text_point: where the text is anchored, in node space (for the given align/valign).
pub fn (l &Label) text_point() core.Vec2 {
	t := l.node.get_component[UITransform]() or { return core.Vec2{} }
	r := t.rect()
	x := match l.align {
		'center' { r.x + r.w / 2 }
		'right' { r.x + r.w }
		else { r.x }
	}

	y := match l.valign {
		'middle' { r.y + r.h / 2 }
		'bottom' { r.y + r.h }
		else { r.y }
	}

	return core.vec2(x, y)
}
