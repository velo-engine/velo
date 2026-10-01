// Tests of the WebGL runtime and of tools/v2js:   cd webgl && npm test
//
//  1. language: tests/lang/main.v runs natively (`v run`) and translated to JavaScript; the outputs must match.
//  2. runtime: the engine logic ported to TypeScript (scenes, prefabs, store, screen fit, tweens, physics, ...).
//
// Needs `v` on PATH and `npm install` (esbuild) in webgl/.

import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))
const webgl = resolve(here, '..')
const home = resolve(webgl, '..')
let failures = 0
let passes = 0

function check(name: string, ok: boolean, detail = '') {
	if (ok) {
		passes++
	} else {
		failures++
		console.log(`FAIL ${name}${detail ? '\n' + detail : ''}`)
	}
}

function run(cmd: string, args: string[], cwd = home): string {
	return execFileSync(cmd, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, VELO_HOME: home } })
}

// ---------- 1. language: native V vs translated JavaScript ----------

function language_test() {
	const out = join(tmpdir(), `velo-v2js-test-${process.pid}`)
	rmSync(out, { recursive: true, force: true })
	mkdirSync(out, { recursive: true })
	const v2js = join(out, 'v2js')
	run('v', ['-o', v2js, join(home, 'tools', 'v2js')])
	const lang = join(here, 'lang')
	const native = run('v', ['run', lang])
	run(v2js, [lang, '-o', join(out, 'gen')])
	writeFileSync(join(out, 'gen', 'node_entry.js'), "import { main } from './main.js'\nmain()\n")
	const esbuild = join(webgl, 'node_modules', '.bin', 'esbuild')
	run(esbuild, [join(out, 'gen', 'node_entry.js'), '--bundle', '--format=esm', '--platform=node', `--alias:velo-runtime=${join(webgl, 'runtime', 'index.ts')}`, `--outfile=${join(out, 'bundle.mjs')}`, '--log-level=error'])
	const js = run('node', [join(out, 'bundle.mjs')])
	const a = native.split('\n')
	const b = js.split('\n')
	let diff = ''
	for (let i = 0; i < Math.max(a.length, b.length); i++) {
		if (a[i] !== b[i]) diff += `  line ${i + 1}:\n    v:  ${JSON.stringify(a[i])}\n    js: ${JSON.stringify(b[i])}\n`
	}
	check('language: V and JavaScript print the same', diff === '', diff)
	rmSync(out, { recursive: true, force: true })
}

// ---------- 2. runtime ----------

async function runtime_tests() {
	const V = await import('../runtime/v.ts')
	const core = await import('../runtime/core.ts')
	const assets = await import('../runtime/assets.ts')
	const serialize = await import('../runtime/serialize.ts')
	const render = await import('../runtime/render.ts')
	const physics = await import('../runtime/physics.ts')

	// V helpers
	check('fstr', V.fstr(2) === '2.0' && V.fstr(0.5) === '0.5')
	check('idiv', V.idiv(-7, 2) === -3)
	check('u8', V.u8(256) === 0 && V.u8(-1) === 255)
	check('S.split_into_lines', JSON.stringify(V.S.split_into_lines('a\nb\r\nc\n')) === '["a","b","c"]')
	check('fmt', V.fmt(42, '', 5, 987698, false, true) === '00042' && V.fmt(3.14159, 'f', 0, 2, false, false, true) === '3.14')
	check('eq', V.eq(core.vec2(1, 2), core.vec2(1, 2)) && !V.eq(core.vec2(1, 2), core.vec2(2, 1)))

	// math
	const m = core.Affine2.trs(core.vec2(10, 20), 90, core.vec2(2, 2))
	const p = m.apply(core.vec2(1, 0))
	check('Affine2.trs', Math.abs(p.x - 10) < 1e-9 && Math.abs(p.y - 22) < 1e-9)
	check('Affine2.inverse', m.inverse().apply(p).distance(core.vec2(1, 0)) < 1e-9)
	check('Color.lerp', core.rgba(0, 0, 0, 0).lerp(core.rgba(255, 255, 255, 255), 0.5).r === 128)

	// screen fit (same numbers as tests/screen_test.v)
	const fit = core.fit_screen(core.vec2(1920, 1080), core.vec2(960, 540), 'expand')
	check('fit_screen expand', fit.scale === 2 && fit.view_size.x === 960)
	const tall = core.fit_screen(core.vec2(1000, 1000), core.vec2(960, 540), 'expand')
	check('fit_screen expand tall', Math.abs(tall.view_origin.y - (540 - 960) / 2) < 1e-6)
	const bars = core.fit_screen(core.vec2(1000, 1000), core.vec2(960, 540), 'fit')
	check('fit_screen fit', Math.abs(bars.area_pos.x) < 1e-9 && Math.abs(bars.area_pos.y - (1000 - 540 * (1000 / 960)) / 2) < 1e-6)

	// store
	const st = core.Store.from_text('# save\ncoins = 5\nratio = 0.5\nname = "a \\"b\\""\nmusic = false\n')
	check('Store parse', st.get_int('coins', 0) === 5 && st.get_f64('ratio', 0) === 0.5 && st.get_string('name', '') === 'a "b"' && st.get_bool('music', true) === false)
	st.set_f64('speed', 2)
	check('Store encode', st.encode().includes('speed = 2.0') && st.encode().includes('name = "a \\"b\\""'))

	// scenes: a database from in-memory files
	const files: Record<string, { id: string; kind: string; text?: string; settings?: Record<string, string> }> = {
		'prefabs/coin.scene': { id: 'c0', kind: 'scene', text: 'node Coin {\n  Sprite { size = [32, 32] }\n  Spin { speed = 90 }\n  node Glow { Label { text = "x" } }\n}\n' },
		'prefabs/big.scene': { id: 'b0', kind: 'scene', text: 'node Big from @asset("c0") {\n  scale = [2, 2]\n  Spin { speed = 180 }\n  node Glow { Label { size = 40 } }\n}\n' },
		'scenes/main.scene': {
			id: 'm0',
			kind: 'scene',
			text: 'node Main {\n  node A from @asset("c0") { position = [10, 0] }\n  node B from @asset("b0") { }\n  node "Two words" { z_index = 2 }\n}\n',
		},
		'scenes/loop.scene': { id: 'l0', kind: 'scene', text: 'node L from @asset("l0") { }\n' },
	}
	const manifest: assets.Manifest = { entries: [] }
	const data = new assets.Preloaded()
	for (const [path, f] of Object.entries(files)) {
		manifest.entries.push({ id: f.id, path, kind: f.kind, settings: f.settings ?? {}, deps: [], bytes: 0, hash: 1 })
		if (f.text !== undefined) data.text.set(f.id, f.text)
	}
	const db = new assets.AssetDatabase('assets', manifest, data)
	class Spin extends core.Component {
		static __fields = [{ name: 'speed', type: 'f32' }]
		static __vname = 'main.Spin'
		speed = 1
		ticks = 0
		update(dt: number) {
			this.ticks++
			this.node.rotation += this.speed * dt
		}
	}
	const reg = serialize.new_registry()
	render.register_builtins(reg)
	reg.register(Spin)
	const loader = serialize.new_loader(reg, db)
	const scene = loader.load_scene('scenes/main.scene')
	const b = scene.find('B')!
	check('prefab variant', b.scale.x === 2 && b.get_component<Spin>(Spin)!.speed === 180)
	check('prefab nested override', b.find('Glow')!.get_component<any>(render.Label).size === 40 && b.find('Glow')!.get_component<any>(render.Label).text === 'x')
	check('quoted node name', scene.find('Two words')!.z_index === 2)
	let circular = ''
	try {
		loader.load_scene('scenes/loop.scene')
	} catch (e) {
		circular = String(e)
	}
	check('circular prefab error', circular.includes('circular prefab nesting'), circular)
	let typo = ''
	try {
		serialize.parse('node X {\n  Spin { sped = 1 }\n}', 'x.scene')
		const n = loader.instantiate_source('node X {\n  Spin { sped = 1 }\n}', 'x.scene')
		void n
	} catch (e) {
		typo = String(e)
	}
	check('unknown field error has file:line', typo.includes('x.scene:2') && typo.includes('sped'), typo)
	scene.update(0.5)
	check('component update', Math.abs(scene.find('A')!.rotation - 45) < 1e-9)
	scene.time_scale = 0.5
	scene.update(1)
	check('time_scale', Math.abs(scene.find('A')!.rotation - 90) < 1e-9)
	scene.paused = true
	scene.update(1)
	check('paused', Math.abs(scene.find('A')!.rotation - 90) < 1e-9)
	scene.paused = false
	scene.time_scale = 1
	// destroy during update + instantiate
	const c = scene.instantiate('prefabs/coin.scene', scene.root)
	check('instantiate', c.scene === scene && scene.root.children.includes(c))
	c.destroy()
	check('destroy is deferred', scene.root.children.includes(c))
	scene.update(0)
	check('destroy flushed', !scene.root.children.includes(c))

	// tweens and timers
	const tn = core.Node.new('T')
	scene.add(tn)
	let called = 0
	tn.tween().move_to(core.vec2(100, 0), 1, 'linear').call(() => called++)
	tn.after(0.5, () => called++)
	scene.update(0.5)
	check('tween halfway', Math.abs(tn.position.x - 50) < 1e-9 && called === 1)
	scene.update(0.6)
	check('tween done', tn.position.x === 100 && called === 2)

	// input
	const inp = new core.Input()
	inp.key_down('a')
	check('input pressed', inp.was_pressed('a') && inp.axis_x() === -1)
	inp.end_frame()
	check('input held', !inp.was_pressed('a') && inp.is_down('a'))
	inp.touch_begin(5, core.vec2(1, 1))
	inp.touch_end(5, core.vec2(2, 2), false)
	check('quick tap kept for a frame', inp.touch(5)!.phase === 'began' && inp.mouse_pressed)
	inp.end_frame()
	check('quick tap ends next frame', inp.touch(5)!.phase === 'ended')

	// UI layout
	const ui = core.Scene.new('UI')
	const list = core.Node.new('List').with(V.make(render.UITransform, { size: core.vec2(100, 0), anchor: core.vec2(0, 0) })).with(new render.Layout())
	ui.add(list)
	for (let i = 0; i < 3; i++) list.add_child(core.Node.new(`I${i}`).with(V.make(render.UITransform, { size: core.vec2(80, 20), anchor: core.vec2(0, 0) })))
	list.get_component<any>(render.Layout).arrange()
	check('Layout vertical', list.children[2].position.y === 56 && list.get_component<any>(render.UITransform).size.y === 76)
	const block = render.layout_text('one two three four', 10, 1.25, true, false, 50, 0, 6, { width: (s: string, size: number) => s.length * size * 0.5 })
	check('wrap_lines', JSON.stringify(block.lines) === '["one two","three four"]', JSON.stringify(block.lines))

	// sprite slicing
	const spr = new render.Sprite()
	const tex = new assets.Texture()
	tex.width = 30
	tex.height = 30
	spr.tex = tex
	spr.size = core.vec2(90, 60)
	spr.draw_mode = 'sliced'
	spr.border_left = spr.border_right = spr.border_top = spr.border_bottom = 10
	check('9-slice quads', spr.quads().length === 9)

	// physics: a box falls on a static floor and rests on it
	const ps = core.Scene.new('P')
	ps.root.with(V.make(physics.PhysicsWorld, { gravity: core.vec2(0, 980) }))
	const floor = core.Node.new('Floor')
	floor.position = core.vec2(0, 200)
	floor.with(V.make(physics.BoxCollider, { size: core.vec2(1000, 40) }))
	const box = core.Node.new('Box')
	box.with(new physics.RigidBody()).with(V.make(physics.BoxCollider, { size: core.vec2(40, 40) }))
	ps.add(floor)
	ps.add(box)
	for (let i = 0; i < 180; i++) ps.update(1 / 60)
	check('physics: box rests on the floor', Math.abs(box.position.y - 160) < 3, `y = ${box.position.y}`)
	const col = box.get_component<any>(physics.BoxCollider)
	check('physics: touching', col.is_touching(floor))
	const ray = ps.root.get_component<any>(physics.PhysicsWorld).raycast(core.vec2(0, -100), core.vec2(0, 500))
	check('physics: raycast hits the box first', ray !== null && ray.node === box && Math.abs(ray.point.y - 140) < 3, ray ? `${ray.node.name} ${ray.point.y}` : 'no hit')
	// a ball bounces off a wall
	const bs = core.Scene.new('B')
	bs.root.with(V.make(physics.PhysicsWorld, { gravity: core.vec2(0, 0) }))
	const wall = core.Node.new('Wall')
	wall.position = core.vec2(300, 0)
	wall.with(V.make(physics.BoxCollider, { size: core.vec2(20, 400) }))
	const ball = core.Node.new('Ball').with(new physics.RigidBody()).with(V.make(physics.CircleCollider, { radius: 10, restitution: 1 }))
	bs.add(wall)
	bs.add(ball)
	ball.get_component<any>(physics.RigidBody).set_velocity(core.vec2(400, 0))
	for (let i = 0; i < 90; i++) bs.update(1 / 60)
	check('physics: restitution bounces back', ball.get_component<any>(physics.RigidBody).velocity().x < -300 && ball.position.x < 290, `${ball.position.x} ${ball.get_component<any>(physics.RigidBody).velocity().x}`)
}

const only = process.argv[2]
if (!only || only === 'runtime') await runtime_tests()
if ((!only || only === 'lang') && existsSync(join(webgl, 'node_modules', '.bin', 'esbuild'))) language_test()
console.log(`${passes} passed, ${failures} failed`)
process.exit(failures > 0 ? 1 : 0)
