// velo.editor in the WebGL runtime: the editor is a desktop tool, so a game's `--editor` branch only needs to
// compile. editor.new() reports that it is not available.

import * as V from './v.ts'
import * as serialize from './serialize.ts'

export class Config {
	static __vname = 'editor.Config'
	title = 'Velo Editor'
	assets_dir = 'assets'
	scene = ''
	width = 1600
	height = 900
}

export class Editor {
	static __vname = 'editor.Editor'
	registry = serialize.new_registry()
	run() {}
}

function new_(_cfg?: Partial<Config>): Editor {
	throw new V.VError('the editor is not available in WebGL builds (run `velo editor` on desktop)')
}
export { new_ as new }
