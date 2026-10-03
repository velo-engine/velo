module editor

import math
import velo.core
import velo.render

// ParticleSystem tools in the Inspector, below its fields: a button per preset (one undo step each), Restart and
// Burst for trying the effect, and how many particles are alive. The effect itself previews live in the scene view.

const preset_cols = 3

fn (mut e Editor) draw_particle_tools(x f32, y0 f32, w f32, n &core.Node, ro bool) f32 {
	mut y := y0
	mut ps := n.get_component[render.ParticleSystem]() or { return y }
	e.ui.text_in(Rect{x, y, w, row_h}, 'Presets · ${ps.alive()} particles alive', c_dim, 0)
	y += row_h
	if ro {
		return y + 2
	}
	names := render.particle_preset_names()
	bw := (w - f32(preset_cols - 1) * 3) / f32(preset_cols)
	for i, name in names {
		r :=
			Rect{x + f32(i % preset_cols) * (bw + 3), y + f32(i / preset_cols) * (row_h + 3), bw, row_h}
		if e.ui.button(r, name, true) {
			e.doc.checkpoint() or {}
			ps.apply_preset(name)
		}
	}
	y += f32(int(math.ceil(f64(names.len) / f64(preset_cols)))) * (row_h + 3) + 2
	half := (w - 3) / 2
	if e.ui.button(Rect{x, y, half, row_h}, 'Restart', true) {
		ps.replay()
	}
	if e.ui.button(Rect{x + half + 3, y, half, row_h}, 'Burst', true) {
		ps.emit(math.max(ps.burst, 20))
	}
	return y + row_h + 4
}
