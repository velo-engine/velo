# Velo Engine

A 2D game engine written in [V](https://vlang.io), with a **Node + Component** architecture like Unity / Cocos Creator,
but with a simpler Scene/Prefab model and stricter asset management.

![demo](docs/screenshot.png)

## Quick start

```bash
v run examples/demo          # coin collector demo: arrows/WASD, R scatters more coins, F1 debug, Esc quits
v run examples/demo --editor # scene/prefab editor (see the "Editor" section)
v test tests/                # unit tests for core, asset, serialize, scenedoc (no GPU needed)
v run tools/assetdb.v examples/demo/assets list
```

### New project

Install the `velo` CLI once (any directory on your `PATH`), then use it from anywhere:

```bash
v -o ~/.local/bin/velo tools/velo.v
velo new mygame && cd mygame
velo editor        # or: velo run, velo build, velo assets list
```

`velo` runs `v -path "@vlib|<parent of the repo>|@vmodules" ...`, so projects find `velo.*` without symlinks or copies
(the repo directory must therefore be named `velo`).
The engine location is baked in when `velo` is built; set `VELO_HOME` to override it.

Tested with V 0.5.2 (release and master). Graphics use V's built-in `gg` module
(on top of sokol: Metal on macOS, D3D11 on Windows, OpenGL on Linux), nothing else to install.

## Structure

```
velo/         repo root = the `velo` module (import velo.core, velo.app, ...)
  core/       Node, Component, Scene, Input, Vec2/Color/Affine2       (no graphics dependency)
  assets/     AssetDatabase: .meta, stable IDs, AssetRef[T], reference counting, dependency graph, hot reload
  serialize/  .scene format, parser, reflection, Registry, SceneLoader (prefab + override), writer
  render/     Renderer (gg), Sprite, SpriteAnimator, Label components
  app/        game loop, input, hot reload
  scenedoc/   scene/prefab editing model: undo/redo, prefab rules, diff-style saving (no GPU needed)
  editor/     editor UI (gg): Hierarchy, Scene view, Inspector, Assets, Play
  examples/demo/  sample game + assets (sprites, prefabs, scenes)
  tools/          velo CLI (velo.v) and asset tool (assetdb.v)
  tests/          unit tests
```

Module dependency order (no cycles): `assets` ← `core` ← `serialize` ← `render` ← `app`,
and `serialize` ← `scenedoc` ← `editor` (the editor also uses `render`).
As a result `core`, `assets`, `serialize`, `scenedoc` run without a GPU (tests, tools, servers).

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
Supported field types: `f32 f64 int bool string core.Vec2 core.Color assets.AssetRef[...]`.

## Scene = Prefab

There is only **one** file format. A scene is simply a prefab chosen as the root when running.

```
node Coin {
  Sprite { texture = @asset("c0149b7d")  size = [32, 32] }
  SpriteAnimator { fps = 10 }
  Pickup { radius = 30  value = 1 }
}
```

- `node Name { ... }` — a node; node properties: `position rotation scale active`
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
	.with(&render.Sprite{ texture: tex, size: core.vec2(18, 18) })
	.with(&FadeAway{ duration: 0.5 })
```

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
| Scene view | click to select (clicking a child of a prefab selects the instance root), drag the body to move freely, right/middle mouse or Alt+drag: pan, mouse wheel: zoom, F: frame all |
| Gizmos | **W** Move (drag an arrow to move along one axis, the square to move freely), **E** Rotate (drag the ring), **R** Scale (drag a box to scale one axis, the center box for uniform scale), **Y** Anchor (drag the pivot circle to move the Sprite's anchor, or click one of the 9 dots on its corners/edges/center; the sprite and children stay in place, only the pivot used by rotate/scale moves), **T** toggles local/global move axes. Shift snaps (10px / 15° / 0.1 / 0.1), Esc cancels the drag, each drag is one undo step. Also available as toolbar buttons |
| Inspector | generated from the `Registry` (no editor code needed per component). Fields overridden relative to the prefab are highlighted in yellow. Add/remove components, assign assets, "Create prefab from this node", "Unpack prefab", "Open prefab" |
| Assets | double-click a scene/prefab to open it; drag prefabs/images into the Scene view or Hierarchy to add them (image -> node with a `Sprite`) |
| Toolbar | New, Save (Ctrl/Cmd+S), Save as (Ctrl+Shift+S), Undo/Redo (Ctrl+Z / Ctrl+Y), Play/Stop (Ctrl+P) |

- **Input fields** use `.scene` syntax: numbers, `"strings"`, `[255, 200, 0, 255]`; asset fields accept a path or ID and check the asset kind.
- **Play** builds a separate scene from the current editing state; all changes made while playing are discarded on stop.
- **Prefab rules** match the file format: parts owned by the source prefab can only have their values edited (no delete/rename/move,
  no removing components); adding nodes/components to an instance is allowed. Saving still only writes what differs from the prefab; opening a prefab variant
  and saving it keeps `from`.
- **Hot reload in the editor**: editing a prefab (in another editor or a text editor) updates every instance in the open scene,
  keeping unsaved overrides.
- All editing logic lives in `scenedoc.Document` (no graphics dependency) and is unit tested; `editor/` is just the UI.

## Current limitations and next steps

- Scene hot reload **resets game state** (score, positions) because the whole tree is rebuilt.
- Not yet available: audio (the `AudioClip` asset kind exists), physics/collision, camera, z-order sorting (currently drawn in tree order),
  removing prefab components via override, a `library/` directory caching import results, build packaging.
- Editor: no copy/paste between scenes, multi-selection,
  save prompt when closing the window, or per-field "Revert" to the prefab value.
- Small note about `gg` 0.5.x: creating an image mid-frame leaves the cached image not yet uploaded to the GPU;
  `render/renderer.v` handles this (see `image_for`).
