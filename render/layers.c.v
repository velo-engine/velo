module render

// sokol_gl layers: the app draws a 3D world between the 2D world (layer 0) and the HUD (layer 1)
// when one is installed (see Renderer.hud_layer).

fn C.sgl_layer(layer_id int)
fn C.sgl_draw_layer(layer_id int)

// use_hud_layer: everything drawn with sokol_gl from now on in this frame goes to the HUD layer.
pub fn use_hud_layer() {
	C.sgl_layer(1)
}

// use_world_layer: back to the 2D world layer (the default at the start of every frame).
pub fn use_world_layer() {
	C.sgl_layer(0)
}

// draw_layer draws the sokol_gl commands recorded into `layer` this frame (inside a render pass).
pub fn draw_layer(layer int) {
	C.sgl_draw_layer(layer)
}
