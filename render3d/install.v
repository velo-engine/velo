module render3d

import velo.app
import velo.core
import velo.serialize

// register_builtins registers the 3D components for .scene files.
pub fn register_builtins(mut r serialize.Registry) {
	r.register[Transform3D]()
	r.register[Camera3D]()
	r.register[DirectionalLight3D]()
	r.register[PointLight3D]()
	r.register[Environment3D]()
	r.register[MeshRenderer3D]()
	r.register[SkinnedModel3D]()
	r.register[BoneAttach3D]()
	r.register[Particles3D]()
	r.register[Trail3D]()
}

// install adds 3D to a game: registers the components and draws the 3D world every frame.
//
//   mut game := app.new(...)!
//   render3d.install(mut game)
//   game.run()
pub fn install(mut a app.App) &Renderer3D {
	register_builtins(mut a.registry)
	r := new_renderer(a.db)
	a.world_data = r
	a.world_draw = draw_world
	return r
}

fn draw_world(data voidptr, scene &core.Scene, width int, height int) {
	mut r := unsafe { &Renderer3D(data) }
	r.draw(scene, width, height)
}
