# Velo Engine

A 2D game engine written in [V](https://vlang.io), with a **Node + Component** architecture like Unity / Cocos Creator,
but with a simpler Scene/Prefab model and stricter asset management.

![demo](docs/screenshot.png)

## Quick start

```bash
v run examples/demo          # coin collector demo: title screen, then arrows/WASD, R more coins, P pause, M menu, Esc quits
v run examples/demo --editor # scene/prefab editor (see the "Editor" section)
v run examples/kine2d        # skeletal animations exported from the Kine2D editor (see "Kine2D animation")
v test tests/                # unit tests for core, asset, serialize, scenedoc, physics (no GPU needed)
v run tools/assetdb.v examples/demo/assets list
```

### New project

Install the `velo` CLI once (any directory on your `PATH`), then use it from anywhere:

```bash
v -o ~/.local/bin/velo tools/velo
velo new mygame && cd mygame
velo editor        # or: velo run, velo build, velo assets list
velo run ios-sim   # or: velo run android — see "Android and iOS"
velo run webgl     # in a browser — see "WebGL"
```

`velo` runs `v -path "@vlib|<parent of the repo>|@vmodules" ...`, so projects find `velo.*` without symlinks or copies
(the repo directory must therefore be named `velo`).
The engine location is baked in when `velo` is built; set `VELO_HOME` to override it.

Tested with V 0.5.2 (release and master). Graphics use V's built-in `gg` module
(on top of sokol: Metal on macOS, D3D11 on Windows, OpenGL on Linux), nothing else to install.
The optional `physics` module (used by the demo) needs [Box2D](https://box2d.org) v3.1+ as a system library:
`brew install box2d` on macOS, or build and install it from source elsewhere
(or build with `-d box2d_source` after `velo deps`, which compiles Box2D into the game — mobile builds always do this).

## Structure

```
velo/         repo root = the `velo` module (import velo.core, velo.app, ...)
  core/       Node, Component, Scene, Camera/Canvas, Input, Vec2/Color/Affine2       (no graphics dependency)
  assets/     AssetDatabase: .meta, stable IDs, AssetRef[T], reference counting, dependency graph, hot reload
  serialize/  .scene format, parser, reflection, Registry, SceneLoader (prefab + override), writer
  render/     Renderer (gg): draw order (z_index, y_sort, Canvas), Sprite, SpriteAnimator, Label, ParticleSystem, TileMap, UI components (Button, ScrollView, Widget, Layout, ...)
  audio/      AudioSource, Mixer (buses, fades, streaming .ogg), output device (sokol_audio)
  physics/    Box2D v3 bindings: PhysicsWorld, RigidBody, Box/Circle/CapsuleCollider (optional, no GPU needed)
  kine2d/     plays Kine2D editor exports (.skel.json + .atlas.json + .png): the Kine2D component (optional)
  app/        game loop, input, hot reload
  scenedoc/   scene/prefab editing model: undo/redo, prefab rules, diff-style saving (no GPU needed)
  editor/     editor UI (gg): Hierarchy, Scene view, Inspector, Assets, Play
  examples/demo/  sample game + assets (sprites, prefabs, scenes)
  examples/kine2d/  Kine2D animation sample (three exported characters)
  tools/          velo CLI (velo/), asset tool (assetdb.v), V -> JavaScript translator (v2js/)
  webgl/          WebGL runtime: the engine ported to TypeScript, for `velo build webgl` (see "WebGL")
  tests/          unit tests
```

Module dependency order (no cycles): `assets` ← `core` ← `serialize` ← `render`/`audio` ← `app`,
and `serialize` ← `scenedoc` ← `editor` (the editor also uses `render`), and `serialize` ← `physics`, `render` ← `kine2d` (imported by the game only).
As a result `core`, `assets`, `serialize`, `scenedoc`, `physics` run without a GPU (tests, tools, servers).

## Writing a component

Embed `core.Component`, declare `pub mut` fields, and override the lifecycle methods you need:

```v
pub struct PlayerController {
	core.Component
pub mut:
	speed      f32       = 220                 // serialized automatically, can be set in .scene files
	bounds_max core.Vec2 = core.Vec2{936, 530}
	velocity   core.Vec2 @[hide]               // @[hide]: not serialized
}

pub fn (mut p PlayerController) update(dt f32) {
	dir := core.vec2(p.input().axis_x(), p.input().axis_y()).normalized()
	p.node.position = p.node.position + dir.mul(p.speed * dt)
	if mut sprite := p.node.get_component[render.Sprite]() {
		sprite.flip_x = dir.x < 0
	}
}
```

Then register it with one line: `game.register[PlayerController]()`.

| Lifecycle | When |
|---|---|
| `on_load()` | the component enters the scene (the node already has a parent, sibling components are present) |
| `start()` | once, right before the first `update` |
| `update(dt)` | every frame, while the node is active and the component is enabled |
| `on_destroy()` | the node is destroyed or the scene is unloaded |

Common APIs: `node.get_component[T]()`, `node.add_component(&T{...})`, `node.find('Weapon/Muzzle')`,
`scene.find('World/Player')`, `node.world_position()`, `node.destroy()` (safe to call during update),
`scene.instantiate('prefabs/coin.scene', mut parent)`.

V's reflection (`$for field in T.fields`) handles reading/writing fields, so **no serialization code is needed**.
Supported field types: `f32 f64 int bool string []int core.Vec2 core.Color assets.AssetRef[...]`.

## Scenes and saved data

Any component can switch scenes; the app fades out, loads the new scene, and fades back in:

```v
c.scene().change_scene('scenes/level2.scene')                  // path or asset ID; fades 0.25 s each way
c.scene().change_scene('scenes/menu.scene', fade: 0.6, color: core.rgba(255, 255, 255, 255))
c.scene().reload()                                              // play the current scene again
```

The switch happens after the current frame; the old scene is destroyed (assets it alone used are freed).
A direct child of the root with `persistent = true` moves to the new scene instead, untouched (no `on_destroy` /
`on_load`, timers and tweens keep going): music that keeps playing, a player carried to the next level. If the new
scene has a root child with the same name, it is dropped for the one already running, so both scenes can include
the same persistent prefab (the demo's `prefabs/audio.scene`). In the editor, Play follows scene changes too (without
the fade; reloading the edited scene plays its unsaved state).

`scene.store` is the player's saved data, shared by every scene: whole numbers, decimals, true/false and text.

```v
mut st := c.scene().store
st.set_int('coins', st.get_int('coins', 0) + 5)     // get_* take the value to use when it is missing
st.set_bool('music', false)
st.save()!                                          // optional: the app also saves when quitting and in the background
```

It is saved as readable text (`coins = 5`, one per line) to `<config dir>/<app_id>/save.txt` on desktop
(`~/Library/Application Support` on macOS, `~/.config` on Linux, `%AppData%` on Windows), the app's private storage on
Android and iOS, and `localStorage` in a browser (written every second while it changes). Set `app_id` in `app.new`
(it defaults to one made from the title) and keep it once the game ships; `save_file` picks another path. A save is
written to a temporary file first and then renamed, so a crash never leaves half a save. Editor Play keeps its own
save data in memory, so testing never touches the game's real save.

The demo starts on a title screen (`scenes/menu.scene`) that shows the saved best score; Play (or Enter) starts the
game, **M** goes back, and the music never stops between them.

Limits: loading is synchronous (a big scene holds the frame while it loads; there is no loading screen yet); the
save file is not encrypted or signed; a killed process (not a normal quit) loses changes since the last save on
desktop — call `store.save()` at checkpoints.

## Time, timers and tweens

`scene.time_scale` changes the game speed (0.5 = slow motion) and `scene.paused = true` stops components, timers,
tweens and physics; drawing, input and sound go on. A node with `unscaled_time = true` (inherited by its children)
ignores both: put it on the pause menu or HUD so they keep working. `update(dt)` receives the scaled time;
`scene.time` / `scene.real_time` and `scene.dt` / `scene.unscaled_dt` give both.

Timers and tweens belong to a node: they run in its update (so they pause with it and use its time) and end
with it. Timers due in the same frame run in the order they were made.

```v
node.after(2, fn [mut node] () { node.destroy() })
mut t := node.every(0.5, fn [mut spawner] () { spawner.spawn() })   // t.cancel() stops it
scene.after(1, fn () { println('one second of game time later') })   // on the scene root

node.tween()
	.move_by(core.vec2(0, -40), 0.3, .quad_out).also().scale_to(core.vec2(1.5, 1.5), 0.3, .back_out)
	.wait(0.5)
	.call(fn [mut node] () { node.destroy() })
render.fade_to(mut node, 0, 0.4, .quad_in)            // alpha of the node's Sprite / Label / Panel / TileMap
render.color_to(mut node, core.rgba(255, 80, 80, 255), 0.2, .linear)
```

| Tween | |
|---|---|
| `move_to` / `move_by`, `rotate_to` / `rotate_by`, `scale_to` | node transform (absolute, or relative to where the step starts) |
| `value(get, set, to, seconds, ease)` | any number, e.g. a ProgressBar's `progress`; `progress(set, seconds, ease)` passes 0..1 |
| `also()` | the next step runs at the same time as the previous one (each keeps its own duration) |
| `wait(seconds)`, `call(fn)`, `delay(seconds)` | pause, run code, wait before starting |
| `repeat(times, yoyo)`, `on_complete(fn)` | `-1` = forever; `yoyo` plays every other pass backwards |
| `kill()`, `pause()`, `resume()`, `finish()`, `is_playing()` | `finish` jumps to the end; `node.kill_tweens()` stops all of a node's tweens |

Eases: `linear`, `quad/cubic/sine/expo` `_in/_out/_in_out`, `back_in/out/in_out` (overshoot), `elastic_out`,
`bounce_out`. Starting values are read when each step starts, so steps build on each other. In the demo, coins pop
and fade when picked up, the score bounces, **P** pauses (the HUD has `unscaled_time`) and **T** toggles slow motion.

Limits: a Button re-tints its target every frame (fade something else); fading a node does not fade its children.
Closures that capture variables should not be created every frame on the web (see "Web").

## Scene = Prefab

There is only **one** file format. A scene is simply a prefab chosen as the root when running.

```
node Coin {
  Sprite { texture = @asset("c0149b7d")  size = [32, 32] }
  SpriteAnimator { fps = 10 }
  Pickup { radius = 30  value = 1 }
}
```

- `node Name { ... }` — a node; node properties: `position rotation scale active z_index y_sort unscaled_time persistent` (see "Camera and draw order")
- `ComponentName { field = value }` — a component
- `node X from @asset("id") { ... }` — an instance of another prefab; the block inside is an **override**
- A prefab **variant** = a prefab whose root is `from` another prefab (see `prefabs/big_coin.scene`). No separate concept needed.

There is only one override rule: everything written in a `from` block is applied on top of a copy of the prefab.
Existing components → only the written fields are overwritten; new components → added; `node Child {}` matching an existing child's name → recursive override.
When saving (`loader.save_node`), instances **only write what differs from the source prefab**, so edits to a prefab propagate everywhere it is used.

Errors always include the file name and line number, e.g. `prefabs/coin.scene:5: Pickup has no serializable field "radis"`.
Circular prefab references are detected and reported.

Prefabs can also be built in code (type-checked by the compiler), handy for small effects:

```v
mut fx := core.Node.new('Sparkle')
	.with(&render.ParticleSystem{ texture: tex, rate: 0, burst: 14, looping: false, auto_destroy: true })
```

## Screen size and scaling

The game is laid out for a **design resolution** (`width`/`height` in `app.new`, 960x540 by default) and
`scale_mode` fits it to any window or phone screen. Positions, sizes, `input.mouse` and touches are all in these
screen units, whatever the real resolution or pixel density.

```v
mut game := app.new(scene: 'scenes/main.scene', width: 960, height: 540, scale_mode: 'expand',
	window_width: 1280, window_height: 720) // desktop window size at startup (0 = the design size)
```

| scale_mode | On a screen with another aspect ratio |
|---|---|
| `expand` (default) | the whole design area is visible, as large as it fits; the extra room on the longer side shows more of the game around it (no bars, nothing cut) |
| `fit` | exactly the design area, black bars on the longer side |
| `fill` | fills the screen, the design area is cropped on the longer side |
| `width` / `height` | the design width (or height) fills the screen; the other direction shows more or less |
| `none` | no scaling: one unit per window point, top-left at 0, 0 (how Velo worked before) |

The design area stays centered, so with `expand` a wider phone shows a bit more on the left and right:
`scene.view_origin` (the top-left of what is visible, can be negative) and `scene.view_size` describe the visible
area, `scene.view_center()` its middle. Widgets aligned to the screen, the Camera (it centers its target in the
visible area) and spatial sound use them, so a HUD built with `Widget` sticks to the real screen edges.
The math is in `core.fit_screen` (unit tested); the renderer draws through its matrix, text stays sharp at any scale.

Limits: no integer-only scaling for pixel art yet; the editor always shows the design area.

## Camera and draw order

A `Camera` shows the world around its node: the node's world position is at the center of the screen, its
rotation turns the view and `zoom` magnifies it. Without a camera, world = screen, as before. A `Canvas` puts its
node and everything under it in screen space: the camera does not move it and it draws over the world (HUD, menus).

```
node Main {
  node Cam { Camera { zoom = 1.25  follow = "World/Player"  smoothing = 6  limit_max = [960, 540] } }
  node World {
    y_sort = true                                  # lower on screen = in front
    node Player from @asset("e4a1b7c2") { }
    node Fireflies { z_index = 1  ParticleSystem { ... } }
  }
  node HUD { Canvas { } ... }
}
```

| Camera field | What it does |
|---|---|
| `zoom` | > 1 = closer |
| `follow`, `follow_offset` | path (from the scene root) of a node to move to every frame, after all updates; offset added to it |
| `smoothing` | how fast it catches up (1/s); `0` = sticks to the target |
| `limit_min`, `limit_max` | world rectangle the view stays inside (an axis with `limit_max <= limit_min` is unlimited); a smaller rectangle is centered |

The first enabled Camera on an active node is used (`scene.active_camera()`). From code: `cam.shake(strength, seconds)`,
`cam.center()`, `cam.visible_rect()`, `scene.screen_to_world(input.mouse)`, `scene.world_to_screen(p)`,
`node.screen_matrix()`. UI components (Button, ScrollView, Joystick, Widget) go through the camera by themselves, so
a Button in the world still clicks where it is drawn; `render.hit_test(n, screen_point)` does the same.

Draw order: nodes draw in tree order, world first and Canvas nodes after. `z_index` moves a node (with its children)
over or under others: it adds to the parent's, and equal values keep the tree order. `y_sort` on a node draws its
children ordered by their y (each with its whole subtree), for top-down scenes. The editor picks the topmost node in
this order, draws each Camera's frame (purple) and shows `z_index` / `y_sort` under Transform. The demo uses all of them
(`Camera`, y-sorted `World`, `HUD` Canvas; big coins shake the camera).

Limits: one camera at a time (no split screen or minimap render targets), no parallax layers, the editor scene view
shows the world without the camera (Play shows it through the camera).

## UI

UI nodes are ordinary nodes. Put them under a `Canvas` so a camera does not move them (without a camera, world = screen). A `UITransform` gives a node its rectangle;
the other UI components draw it, react to the mouse inside it, or position nodes relative to it.

```
node MoreCoins {
  UITransform { size = [160, 40] }                                  # rectangle: size + anchor
  Widget { align_right = true  right = 16  align_top = true  top = 14 }
  Panel { color = [70, 130, 220, 255]  radius = 8  border_width = 1 }
  Button { }
  node Text { Label { text = "More coins"  align = "center"  valign = "middle" } }
}
```

| Component | What it does |
|---|---|
| `UITransform` | `size` + `anchor` of the node's rectangle (used by everything below, and for picking in the editor) |
| `Panel` | fills the rectangle: `color`, `radius` (rounded corners when not rotated), `border_color`, `border_width`; stops clicks from reaching UI under it unless `block_input = false` |
| `Label` | text (`\n` = new line); `align` left/center/right, `valign` top/middle/bottom, `font`, `line_spacing`. With a UITransform it aligns inside the rectangle, `wrap` breaks lines at its width and `shrink` lowers the size until the text fits. `shadow_color`/`shadow_offset` and `outline_color`/`outline_width` (alpha 0 = off) keep it readable on busy backgrounds |
| `TextInput` | a one-line text field in the rectangle: click/tap to type (any language), arrows, Home/End, Backspace/Delete (held keys repeat), Enter submits, Esc or a click elsewhere stops. `text`, `placeholder`, `max_length`, `password`, `font`, `size`, colors; poll `changed` / `submitted`, or `focus()` / `blur()`. Phones and browsers show their keyboard while it has focus, and Esc does not quit the game then |
| `Button` | click (or tap, with any finger) on the rectangle (UITransform or Sprite). `btn.on_click(fn (mut b render.Button) {...})` or poll `btn.clicked` (true for one frame). Tints the Panel/Sprite of `target` by state (`normal/hover/pressed/disabled_color`, multiplied with its own color); `interactable = false` disables it |
| `Toggle` | with a Button on the same node: each click flips `is_on` and shows/hides the `checkmark` child (`changed` is true for that frame) |
| `ProgressBar` | draws `back_color` + a `fill_color` part for `progress` (0..1); `direction` horizontal/vertical, `reverse` |
| `ScrollView` | shows the `content` child through the rectangle: drag or mouse wheel, `inertia`, `elastic` edges, `clip`; `horizontal`/`vertical`; `scroll_to_top()`/`scroll_to_bottom()`. Buttons inside cancel their press once a drag starts, and are not clickable outside the viewport |
| `Widget` | aligns the node to the edges/center of the parent's rectangle (or the screen if the parent has none); left + right (or top + bottom) stretches the UITransform. Aligned to the screen it stays inside the phone's safe area (notch, rounded corners, system bars); `safe_area = false` reaches the real edges (full-bleed backgrounds) |
| `Joystick` | on-screen thumb stick: a finger (or the mouse) going down in the rectangle moves the `knob` child up to `radius` from the `base` child; read `value` (-1..1 per axis). `floating` moves the base under the thumb |
| `Layout` | arranges children in a `vertical`/`horizontal` list or a `grid` (`spacing`, `padding`, `child_align`, `columns`); `resize` grows the UITransform to fit, which is what a ScrollView content needs |

`Input` also has `mouse_pressed` / `mouse_released` (one frame) and `scroll` (wheel delta this frame).
Touch: `input.touches` lists every finger (`id`, `pos`, `start`, `phase` began/moved/stationary/ended/cancelled) and
the first finger also drives the mouse fields; `input.pointers()` is every finger plus the held mouse, for code that
should work the same with both. `scene.safe_insets` holds the safe area (screen units, from the edges of the visible
area); on desktop, `VELO_SAFE_AREA="left,top,right,bottom"` (window points) fakes one to try a phone layout, and F1 outlines it.
The demo's HUD uses a Button (`SpawnButton`) and a ScrollView + Layout pickup log (`PickupLog`, see `examples/demo/hud.v`);
its menu has a TextInput for the player's name (saved) and a title with an outline and a shadow.

**Clicks go to the topmost UI only.** Buttons, ScrollViews, Joysticks, TextInputs and Panels take the pointer in draw
order (z_index and Canvas included): a dialog Panel over buttons stops them, and of two overlapping buttons only the
one on top is clicked or hovered. An element still gets presses on its own children (a ScrollView can be dragged from
a button inside it). For gameplay clicks, `render.pointer_over_ui(scene, input.mouse)` tells whether the UI took it;
`render.pointer_target(scene, p)` returns the element.

**Fonts.** `.ttf` and `.otf` files are Font assets: set a Label's or TextInput's `font` to one (in the Inspector, or
`font = @asset("...")`), or `label.set_font(ref)` from code. Unset, text uses the app's font (`font_path` in `app.new`).
`Input.text` holds what was typed this frame, and `input.was_typed(.backspace)` includes key repeats, for custom fields.

Limits: text ignores rotation; no rich text (colors/bold inside one Label), text selection, clipboard or IME
candidate window in TextInput; a font file edited on disk needs a restart; Widget/Layout run in `update`, so the
editor shows them at their saved positions until you press Play; the anchor gizmo (Y) only edits Sprite anchors.

## Particles

`ParticleSystem` (built in, like `Sprite`) emits, moves and draws many small sprites in one draw call:

```
node Smoke {
  ParticleSystem { texture = @asset("5d9a0c66")  rate = 30  angle = -90  spread = 15  gravity = [0, -40]
                   start_size = 12  end_size = 40  start_color = [200, 200, 200, 180]  end_color = [120, 120, 120, 0] }
}
```

| Field | What it does |
|---|---|
| `texture` | particle image (a sprite sheet's frame 0, or a random frame with `random_frame`); unset = plain squares |
| `playing`, `looping`, `duration` | emitting; loop forever or stop after `duration` seconds |
| `rate`, `burst`, `max_particles` | particles per second, particles emitted at once when playing starts, live cap |
| `lifetime`, `speed`, `angle`, `spread` | seconds alive; initial speed; direction in degrees (0 = right, -90 = up, turns with the node) +- `spread` |
| `gravity`, `damping` | acceleration (world units/s²); fraction of velocity lost per second |
| `shape`, `shape_size` | where particles are born: `point`, `circle` (radius = `shape_size.x`) or `box` (w, h) |
| `start_size`/`end_size`, `start_color`/`end_color` | blended over each particle's life (fade out with an end alpha of 0) |
| `spin`, `random_angle` | rotation speed in degrees/s; random start rotation |
| `world_space` | on (default): particles stay where they were born when the node moves (trails); off: they move with it |
| `additive` | additive blending, for fire, sparks and glows |
| `auto_destroy` | destroy the node once emission stopped and the last particle died (one-shot effects) |

`lifetime_var`, `speed_var`, `size_var` and `spin_var` add +- randomness. From code: `ps.play()` (restarts, fires
the burst again), `ps.stop()`, `ps.emit(n)`, `ps.clear()`, `ps.alive()`, `ps.is_done()`, `ps.set_texture(ref)`.
The demo's coin pickup is a one-shot burst built in code (`make_sparkle` in `examples/demo/coins.v`) and its
fireflies are a looping emitter in `scenes/main.scene`. Particles use the renderer's `MeshDrawable` hook, whose
`TexturedMesh` now also takes per-vertex `colors`, `additive` and no texture (plain colored triangles).

In the editor, add it with "+ Add component", edit it in the Inspector (`shape` takes `"point"`, `"circle"` or `"box"`)
and it previews live in the scene view without pressing Play: the effect runs and one-shot bursts replay every
half second, without changing saved fields (`playing` stays on, `auto_destroy` does not delete the node).
Click inside its orange emission outline to select it. Any component can preview this way by implementing
`render.Previewable` (`preview(dt f32)`).

Limits: no sub-emitters, collisions, or color/size curves beyond start→end; particles draw at their node's place in the draw order (use `z_index`).

## Sliced and tiled sprites

`Sprite.draw_mode` picks how the frame fills `size`:

| draw_mode | |
|---|---|
| `simple` (default) | stretches the whole frame |
| `sliced` | 9-slice: `border_left/top/right/bottom` (texture pixels) cut the frame into a 3x3 grid; corners keep their size, edges and center stretch — panels, buttons, speech bubbles at any size |
| `tiled` | repeats the frame to fill `size` (the last row/column is cropped); with borders, the corners stay fixed and the edges/center repeat |

```
Sprite { texture = @asset("9a51ce07")  size = [150, 56]  draw_mode = "sliced"
         border_left = 8  border_top = 8  border_right = 8  border_bottom = 8  pixel_scale = 2 }
Sprite { texture = @asset("3e7d5a10")  size = [144, 36]  draw_mode = "tiled"  pixel_scale = 1.5 }
```

`pixel_scale` is world units per texture pixel for the borders and the tile repeat; `fill_center = false` draws only
the border ring. When `size` is smaller than two borders they shrink proportionally. Sliced/tiled sprites are drawn as one
batch of quads, so they rotate, scale, flip and tint (Button) like any Sprite; `sprite.quads()` returns the pieces.
In the editor, the Inspector shows the frame with its border lines (drag them to set the borders), the scene view
draws the lines on the selected sprite, and the **U** Size tool resizes it. The demo's `Sign` and `CrateWall` use them.

## Tile maps

`TileMap` (built in) draws a grid of tiles cut from one tileset. The tileset is an ordinary sprite sheet: the
`frame_width`/`frame_height` in its `.meta` give the tile size, and a tile is a frame index (left -> right,
top -> bottom). Use `filter: nearest` for pixel art.

```
node Pond {
  position = [312, 66]                     # top-left corner of the map (anchor [0, 0])
  TileMap { tileset = @asset("e71a0c3d")  columns = 7  rows = 3  tile_size = [48, 48]
            tiles = [3, 0, 1, 1, 1, 2, 7, -1, 4, 5, 11, 5, 6, 3, 13, 8, 9, 9, 9, 10, -1] }
}
```

| Field | What it does |
|---|---|
| `tileset` | the sprite sheet the tiles come from |
| `columns`, `rows` | map size in cells (from code, change it with `resize` so tiles keep their cell) |
| `tile_size` | cell size in world units; `0` = the tileset's frame size |
| `tiles` | `columns * rows` frame indices, row by row; `-1` = empty (a short list is padded with empty cells) |
| `anchor`, `color` | `[0, 0]` puts the map's top-left corner at the node, `[0.5, 0.5]` centers it; tint |

It is drawn in one draw call, and only the cells inside the screen (or the ScrollView/scene view clip) are submitted,
so large maps are cheap. It turns, scales and flips with its node like a Sprite. From code: `tm.get(col, row)`,
`tm.set(col, row, tile)`, `tm.fill_rect(...)`, `tm.flood_fill(col, row, tile)`, `tm.clear()`, `tm.resize(cols, rows)`,
`tm.count()`, `tm.world_to_cell(p)`, `tm.tile_at(p)` (the tile under a world point, e.g. to check what the player
stands on), `tm.cell_center(col, row)` (to place objects on the grid), `tm.set_tileset(ref)`.
The demo's pond (`scenes/main.scene`, tileset `sprites/tiles.png`) is a TileMap.

In the editor, select the node and paint in the scene view:

| Tool | Key | What it does |
|---|---|---|
| Paint | B | drag to paint the brush (click a tile in the Inspector's palette to pick it; that also switches to Paint) |
| Erase | X | drag to empty cells |
| Fill | G | flood-fills the clicked area (cells connected to it with the same tile) with the brush |
| Pick | I | click a cell to use its tile as the brush (an empty cell picks Erase) |

The scene view shows the map's grid and the cell under the mouse, with the brush previewed in it. Each drag is one undo step.
Clicking outside the map still selects other nodes. Esc or W/E/R/Y leave the tile tools. Editing `columns`/`rows` in
the Inspector resizes the map and keeps every tile in its cell. On a prefab instance, painted tiles are an override of
the whole `tiles` list. The Inspector shows a `[]int` field such as `tiles` as a value count, not a text field.

Limits: one layer per TileMap (stack nodes for layers), no per-tile flip/rotation, autotiling, animated tiles or
tile collisions yet (use colliders on child nodes); `tiles` is saved on one line.

## Audio

`AudioSource` plays a `.wav` (PCM 8/16/24/32-bit or float) or `.ogg` (Vorbis) clip. Sound works in the game, in the
editor's Play mode, on phones and on the web; `app` opens the output device and mixes once per frame.

```
node Audio {
  node Music { AudioSource { clip = @asset("5c01a7d4")  looping = true  bus = "music"  volume = 0.35 } }
  node Coin  { AudioSource { clip = @asset("5c01a7d3")  play_on_start = false } }
}
```

| Field | What it does |
|---|---|
| `clip` | the sound file |
| `volume`, `pitch`, `looping` | `pitch` is the playback speed (2 = an octave up) |
| `play_on_start` | play when the node starts (on by default) |
| `bus` | volume group: `sfx` (default), `music`, `ui`, `voice` |
| `spatial`, `range` | quieter with distance from the camera center (silent at `range` world units) and panned to its side |
| `fade_out` | seconds to fade out when stopped or destroyed, instead of cutting off |

From code: `src.play()`, `src.play_one_shot()` (overlapping copies: rapid pickups, footsteps), `src.stop()`, `src.pause()`,
`src.resume()`, `src.is_playing()`, `src.set_clip(ref)`. Global control goes through `audio.mixer()`:
`set_bus_volume('music', 0.5)` (options screens), `master`, `set_paused(true)`, `stop_all()`,
`play_music(sound, volume, fade)` (cross-fades from the current music), `load(clip)` then `play(sound, volume: .., pan: ..)`.
The game pauses all sound while it is in the background or minimized.

Long `.ogg` files (over 20 seconds, or `stream: true` in the `.meta`) are decoded while they play instead of all at
once, so a 3-minute track does not take 60 MB; `stream: false` forces full decoding. Short effects should stay `.wav` or
short `.ogg`. Editing a sound file hot reloads it (the next play uses the new file). The demo's music and coin sounds
(`examples/demo/assets/sounds`, generated for this repo) show both uses; big coins play the pickup lower.

How it works: `velo.audio` pushes samples to [sokol_audio](https://github.com/floooh/sokol) from the game loop
(no audio-thread callback touches V memory, which the GC and the web could not handle), about 45 ms ahead;
`.ogg` is decoded by stb_vorbis compiled from V's sources. The mixer (`audio.Mixer`) has no device dependency and is
unit tested by mixing into an array.

Limits: no `.mp3`, no effects (reverb, filters), no Doppler or 3D; seeking is not available; 64 sounds at once; a
frame taking longer than ~45 ms can make the sound stutter. Mobile builds link AudioToolbox/AVFoundation (iOS) and
AAudio (Android 8+), untested on devices so far.

## Physics

2D physics with [Box2D](https://box2d.org) v3. It is opt-in: register the components with the game's own ones
(`physics.register_builtins(mut r)`, see `examples/demo/main.v`), and the engine does not link Box2D unless you do.

```
node Main {
  PhysicsWorld { gravity = [0, 980] }                 # on the root (or any ancestor of the bodies)
  node Ground {
    position = [480, 520]
    BoxCollider { size = [960, 40] }                  # collider without a RigidBody = static
  }
  node Ball {
    RigidBody { }                                     # dynamic by default
    CircleCollider { radius = 16  restitution = 0.5 }
  }
}
```

| Component | What it does |
|---|---|
| `PhysicsWorld` | one Box2D world: `gravity` (pixels/s², y down), `pixels_per_meter` (default 50), `fixed_step`, `sub_steps`, `max_steps`. Steps in its own `update`, before its children update. `world.raycast(from, to)` returns the closest hit |
| `RigidBody` | `body_type` dynamic/kinematic/static, `gravity_scale`, `linear_damping`, `angular_damping`, `fixed_rotation`, `bullet`. `velocity()`/`set_velocity`, `angular_velocity()`/`set_angular_velocity`, `apply_force`, `apply_impulse`, `apply_torque`, `mass()`, `set_body_type` |
| `BoxCollider` / `CircleCollider` / `CapsuleCollider` | a shape (`size` or `radius`, `offset`) with `density`, `friction`, `restitution`, `sensor`. Becomes a shape of the RigidBody on the same node; without one it gets its own static body that follows the node |

Everything is in world units (pixels) and degrees, like the rest of the engine; mass and density stay in Box2D units (kg, kg/m²).
The body follows the node in world space, so bodies can live under moved/rotated parents, and setting `node.position`
from code teleports the body. Collider shapes use the node's world scale when they load.

Contacts are polled like `Button.clicked`: every collider has `touching` (current), `began` and `ended` (this frame only),
each a `Contact` with the other `node`, a `normal` pointing toward it, a `point` and whether it was a `sensor` overlap.

```v
if col := p.node.get_component[physics.CircleCollider]() {
	for c in col.began {
		if c.node.name == 'Spikes' { p.node.destroy() }
	}
}
```

In debug mode (F1) and in the editor, colliders are outlined (green, sensors yellow): the renderer draws any component
with `debug_outline()`/`debug_color()` (`render.DebugShape`). In the demo the crates are pushable bodies, the trees
have static trunk colliders and the player moves with `set_velocity`.

Limits: no joints, polygon/chain shapes, collision filtering or interpolation yet; shapes are built once (edit a collider's
fields at runtime and they will not be rebuilt); colliders on child nodes do not join the parent's RigidBody.

## Kine2D animation

The optional `kine2d` module plays skeletal animations made in the Kine2D editor. Its **BUILD** button writes
`<name>.skel.json`, `<name>.atlas.json` and `<name>.png`: copy all three into the assets directory, register the
component (`kine2d.register_builtins(mut r)`, see `examples/kine2d/main.v`) and point a `Kine2D` at the two JSON files:

```
node Goblin {
  position = [790, 440]                       # where the editor's canvas center was
  scale = [-1.6, 1.6]                         # negative x = mirrored
  Kine2D { data = @asset("4b1e0c11")  atlas = @asset("4b1e0c12")  animation = "idle" }
}
```

| Field | What it does |
|---|---|
| `data` / `atlas` | the `.skel.json` and `.atlas.json` (text assets); the atlas image is found next to the atlas file |
| `animation` | clip to play (`''` = the first one); changing it restarts from frame 0 |
| `skin` | skin id or name (`''` = the skin active when exporting) |
| `speed`, `playing`, `looping`, `color` | playback rate (negative plays backwards), pause, loop or stop at the end, tint |
| `canvas_size` | the editor canvas size the rig was built on; `0` = the export's `canvasSize` (800x600 if it has none) |

From code: `k.play('attack', false)` then poll `k.finished` (true once a non-looping clip reached its end),
`k.animations()`, `k.skins()`, `k.current_animation()`, `k.duration()`, `k.time`. The sample's `PlayOnce`
(`examples/kine2d/controls.v`) plays a clip once and returns to the one it interrupted.

Supported: region and mesh attachments, weighted meshes (skinning), mesh deform keys, bezier/easing curves on
position and rotation keys, scale keys, skins, attachment switching (display index keys) and draw order keys.
Editing the exported files hot reloads them. It draws textured triangles through the renderer's `render.MeshDrawable`
hook, so any component with a `meshes() []render.TexturedMesh` method is drawn the same way.

Limits: IK, transform and physics constraints and event keys are not applied yet (bake them into keys before exporting);
the binary export (`.skel.bin`) is not read, only the JSON one; the editor cannot click-select a skeleton in the scene view
(select it in the Hierarchy); `velo assets unused` does not know that the atlas uses its image.

## Asset management

- **Stable IDs** in a `.meta` file next to each asset (created if missing). Scenes reference assets by ID,
  so renaming/moving a file (along with its `.meta`) breaks nothing. Commit `.meta` files to Git.
- **`.meta` uses `key: value`** lines, easy to read and diff; it holds the import settings:
  ```
  id: c0149b7d
  kind: texture
  version: 1
  filter: nearest        # pixel art
  frame_width: 16        # sprite sheet -> SpriteAnimator knows the frame count
  frame_height: 16
  ```
- **Typed `AssetRef[T]`**: assigning an `AssetRef[AudioClip]` to an `AssetRef[Texture]` field is a compile error;
  an ID pointing to a file of the wrong kind reports a clear error on load.
- **Reference counting**: `db.load[T]` / `db.release(id)`. `Sprite` loads automatically in `on_load` and releases in `on_destroy`;
  when nothing uses an asset anymore, it is freed and the renderer deletes the texture on the GPU.
- **Dependency graph**: knows which asset uses which → find unused assets, check before deleting,
  know exactly what to package for a scene.
- **Duplicate ID detection** (copying a file along with its `.meta`) with automatic reassignment of a new ID.
- **Hot reload**: edit an image → the new image is drawn immediately; edit a `.scene`/prefab → the scene reloads (on a syntax error the old scene is kept).

```
$ v run tools/assetdb.v examples/demo/assets unused scenes/main.scene
Assets not used by scenes/main.scene:
  9f00aa12  sprites/rock_unused.png

$ v run tools/assetdb.v examples/demo/assets users sprites/coin.png
sprites/coin.png used by:
  d2c8f1a9  prefabs/coin.scene
```

## Editor

```bash
v run examples/demo --editor
```

The editor is compiled **together with** the game's components (V does not load code at runtime), so the game just needs a flag:

```v
if '--editor' in os.args {
	mut ed := editor.new(assets_dir: assets_dir, scene: 'scenes/main.scene')!
	register_components(mut ed.registry)   // same registration function as the game
	ed.run()
	return
}
```

| Area | What it does |
|---|---|
| Hierarchy | select, add/duplicate/delete, reorder; drag and drop to reparent (dropping on the top/bottom edge of a row = insert before/after). Prefab instances are shown in blue |
| Scene view | click to select (Sprite or UITransform rectangle) (clicking a child of a prefab selects the instance root), drag the body to move freely, right/middle mouse or Alt+drag: pan, mouse wheel: zoom, F: frame all |
| Gizmos | **W** Move (drag an arrow to move along one axis, the square to move freely), **E** Rotate (drag the ring), **R** Scale (drag a box to scale one axis, the center box for uniform scale), **Y** Anchor (drag the pivot circle to move the Sprite's anchor, or click one of the 9 dots on its corners/edges/center; the sprite and children stay in place, only the pivot used by rotate/scale moves), **U** Size (drag a corner/edge handle to resize the UITransform, or the Sprite's `size`; the opposite side stays put), **T** toggles local/global move axes. Shift snaps (10px / 15° / 0.1 / 0.1 / 10), Esc cancels the drag, each drag is one undo step. Also available as toolbar buttons |
| Inspector | generated from the `Registry` (no editor code needed per component). Fields overridden relative to the prefab are highlighted in yellow. String fields with fixed values (`draw_mode`, `align`, `body_type`, ... tagged `@[choices: 'a|b']`) show one button per value. A sliced/tiled Sprite shows its frame with draggable 9-slice border lines. Add/remove components, assign assets, "Create prefab from this node", "Unpack prefab", "Open prefab" |
| Assets | double-click a scene/prefab to open it; drag prefabs/images into the Scene view or Hierarchy to add them (image -> node with a `Sprite`) |
| Toolbar | New, Save (Ctrl/Cmd+S), Save as (Ctrl+Shift+S), Undo/Redo (Ctrl+Z / Ctrl+Y), Play/Stop (Ctrl+P) |

- **Input fields** use `.scene` syntax: numbers, `"strings"`, `[255, 200, 0, 255]`; asset fields accept a path or ID and check the asset kind.
- **Play** builds a separate scene (while playing, the mouse wheel over the scene view is also sent to the game) from the current editing state; all changes made while playing are discarded on stop.
- **Prefab rules** match the file format: parts owned by the source prefab can only have their values edited (no delete/rename/move,
  no removing components); adding nodes/components to an instance is allowed. Saving still only writes what differs from the prefab; opening a prefab variant
  and saving it keeps `from`.
- **Hot reload in the editor**: editing a prefab (in another editor or a text editor) updates every instance in the open scene,
  keeping unsaved overrides.
- All editing logic lives in `scenedoc.Document` (no graphics dependency) and is unit tested; `editor/` is just the UI.

## Android and iOS

`velo build <target>` packages the game, `velo run <target>` also installs and starts it (and shows its log):

```bash
velo doctor                              # which targets this machine can build, and what is missing
velo run ios-sim                         # iOS Simulator (macOS + Xcode)
velo run android                         # first connected device / running emulator
velo build ios --release                 # signed .app + .ipa for devices
velo build android --release --aab       # Android App Bundle for Google Play
```

Output goes to `build/<target>/` in the project. Games need no code changes: on a phone `app.new` ignores
`assets_dir` and uses the packaged assets, the first finger acts as the left mouse button (so UI buttons, scroll views
and `input.mouse` work), and hot reload is off. The window is the whole screen, fitted by the scale mode (see
"Screen size and scaling"): lay the game out for the design resolution and anchor UI with `Widget`.

- **Android** is built with [vab](https://github.com/vlang/vab) (`v install vab && v -prod ~/.vmodules/vab`),
  plus the Android SDK, NDK and a JDK. Android Studio installs all three; velo uses its bundled JDK when `JAVA_HOME` is unset.
  The APK contains `assets/` and a file list (`velo_assets.txt`); on first launch after an install they are copied
  to the app's internal storage, because the asset database works on real files.
  Debug builds are signed with a debug key; set `android.keystore` in `velo.toml` for release signing.
- **iOS** needs macOS with Xcode. velo compiles the C that V generates with the Xcode toolchain (V's own iOS
  step targets 32-bit ARM), bundles `<name>.app` with `assets/` inside, and signs it: ad hoc for the simulator; for devices
  with your "Apple Development" identity and a provisioning profile for `app.id` (Xcode creates both once you sign in
  with your Apple ID under Settings > Accounts; `ios.identity` / `ios.provisioning_profile` pick specific ones).
- **Physics**: phones have no system Box2D, so mobile builds compile it from source. The sources are cloned into
  `thirdparty/box2d` in the engine directory the first time a game that imports `velo.physics` is built (or by `velo deps`).
- Asset IDs must be stable, so the build first runs `velo assets check`, which also creates missing `.meta` files — commit them.

App settings live in `velo.toml` (created by `velo new`; every key is optional, defaults come from the directory name):

```toml
[app]
name = "My Game"            # name under the icon
id = "com.example.mygame"   # bundle / package ID
version = "1.0.0"
build = 1                   # increase for every store upload
orientation = "landscape"   # landscape | portrait | any (iOS only for now)
icon = "icon.png"           # square PNG, 1024x1024

[android]
keystore = "release.keystore"   # passwords: VAB_KS_PASS / VAB_KS_ALIAS_PASS environment variables
keystore_alias = "release"

[ios]
min_version = "14.0"
simulator = "iPhone 17"
```

## Web

```bash
velo build web                 # build/web/index.html + .js + .wasm + .data (upload the folder as is)
velo build web --release       # emcc -O3
velo run web                   # build, then serve on http://localhost:8080 and open the browser
```

Needs [Emscripten](https://emscripten.org) (`brew install emscripten`; `velo doctor` checks it). The project's
`assets/` are preloaded at `/assets`, where `app.new` looks for them in a browser; hot reload is off. Browsers have
no font files, so text uses the first `.ttf` in `assets/fonts/` — ship one that covers your language.

How it works around V 0.5.2 + Emscripten (see `tools/velo/web.v` and `tools/velo/web/emcc.sh`):
- V compiles through a small `emcc` wrapper that fixes the generated C's `stdin/stdout/stderr` declarations
  for musl, uses a copy of `sokol_app.h` with its broken JavaScript operators repaired (`) = >`, `!= =`, `== =`),
  and drops `gg`'s embedded example font when the V install does not ship it;
- `-sGLOBAL_BASE=65536`: V's `vmemcpy` skips copies from addresses below 64 KiB, where wasm keeps static data;
- Boehm GC from V's bundled sources, single-threaded, collecting only between frames from a JS timer
  (`app/web_gc.h`): wasm locals are invisible to a conservative GC, so collecting inside a frame frees live objects;
- no `-prod` (it crashes V maps on wasm) — `--release` only raises the emcc optimization level.

Limits: no `velo.physics` yet (Box2D is not built for Emscripten); avoid closures that capture variables
(`fn [x] () {}`) in code that runs every frame — V 0.5.2's closure runtime corrupts the wasm heap;
files written at runtime (settings, saves) live in memory and are lost on reload.

## WebGL

A second way to run in a browser, without Emscripten: the game's V code is **translated to JavaScript** and runs
on the engine's TypeScript runtime, drawing with WebGL. Downloads are small (the demo is 187 KB of JavaScript,
60 KB gzipped, plus its assets) and the page starts at once; physics works too.

```bash
velo build webgl                 # build/webgl/index.html + game.js + assets/ (upload the folder as is)
velo build webgl --release       # minified, no source map
velo run webgl                   # build, serve on http://localhost:8080, open the browser;
                                 # edit a .v file or an asset and it rebuilds, the page reloads itself
```

Needs [Node.js](https://nodejs.org) (`brew install node`): the first build installs
[esbuild](https://esbuild.github.io) into `webgl/node_modules` (`velo doctor` checks both).
`VELO_NO_OPEN=1` keeps `velo run webgl` from opening a browser.

How it works:
- `tools/v2js` (built once into `build/tools/` of the engine) reads the game with the V compiler's own parser and
  type checker — so the game must compile (`v -check .`) — with `-d webgl` defined: `$if webgl ? { ... }` picks
  web-only code. Every module of the game becomes one ES module; engine calls go to the runtime.
- `webgl/runtime/` is the engine ported to TypeScript with the same names and fields: `core` (nodes, scenes,
  tweens, timers, input, store), `serialize` (.scene parser, prefabs and overrides, registry), `assets`, `render`
  (sprites, sliced/tiled sprites, labels, UI, particles, tile maps; batched WebGL with an atlas for text),
  `audio` (WebAudio), `physics` and `kine2d`. Scenes, prefabs and `.meta` files are used as they are.
- V meets JavaScript like this: structs are classes (value structs are copied where V copies them), `?T` is the
  value or `null`, `!T` errors are exceptions, enums are their names (`'quad_out'`), maps are `Map`. Components
  list their serializable fields (what `$for field in T.fields` sees on desktop) in a generated `static __fields`.
- Assets are downloaded before the game starts (`assets.json` lists them), so loading stays synchronous; sounds
  are decoded up front. Text uses the browser's fonts (any language), and `.ttf`/`.otf` font assets work.
  Saved data goes to `localStorage`, like `velo build web`.

`cd webgl && npm test` runs the runtime tests and translates `webgl/tests/lang` (a tour of the V language);
its output must be the same as `v run webgl/tests/lang`. In the browser's console, `velo` is the running app
(`velo.scene`, `velo.input`, ...); debug builds come with a source map.

Limits:
- not translated: concurrency (`spawn`, `go`, channels, `lock`), C interop, comptime reflection (`$for`),
  `$embed_file`, `asm`, `goto` — v2js reports where. The editor is desktop only.
- numbers are JavaScript doubles: `i64`/`u64` lose precision past 2^53, and integers wrap only on casts and
  multiplication; strings count UTF-16 units (`len`, `s[i]`), the same as V for ASCII text.
- physics is a smaller solver than Box2D (same components and contacts, no joints, no continuous collision);
  scenes and assets are not hot reloaded in place (`velo run webgl` reloads the page).

## Current limitations and next steps

- Scene hot reload **resets game state** (score, positions) because the whole tree is rebuilt.
- Not yet available: physics joints,
  removing prefab components via override, a `library/` directory caching import results.
- Mobile: Android ignores `app.orientation` (it follows the device), and the iOS build patches two V 0.5.2 issues in the generated C (see `tools/velo/ios.v`).
- Editor: no copy/paste between scenes, multi-selection,
  save prompt when closing the window, or per-field "Revert" to the prefab value.
- Small note about `gg` 0.5.x: creating an image mid-frame leaves the cached image not yet uploaded to the GPU;
  `render/renderer.v` handles this (see `image_for`).
