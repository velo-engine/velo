module render

import sokol.sgl
import velo.core
import velo.assets

// TexturedMesh — triangles cut out of a texture, in node space.
// Without a texture the triangles are filled with the vertex colors (uvs are then ignored).
pub struct TexturedMesh {
pub:
	texture   &assets.Texture = unsafe { nil }
	positions []f32 // x0, y0, x1, y1, ... node space
	uvs       []f32 // u0, v0, ... in 0..1 of the texture
	indices   []int // three per triangle
	color     core.Color = core.white
	colors    []core.Color // optional, one per vertex, multiplied with `color`
	additive  bool         // add to what is behind instead of blending over it (glows, fire, sparks)
}

// MeshDrawable — a component that draws textured triangles, e.g. a velo.kine2d skeleton.
// Any component with this method qualifies; render does not depend on the component's module.
pub interface MeshDrawable {
	meshes() []TexturedMesh
}

// Previewable — a component that animates in the editor's scene view while the game is not playing
// (the editor never calls `update` there). `preview` must not change serialized fields or destroy nodes.
pub interface Previewable {
mut:
	preview(dt f32)
}

// draw_mesh draws `mesh` through the node matrix `m` (so rotation, non-uniform scale and flips all apply).
pub fn (mut r Renderer) draw_mesh(mesh TexturedMesh, m core.Affine2) {
	textured := mesh.texture != unsafe { nil }
	if mesh.indices.len < 3 || (textured && mesh.uvs.len < mesh.positions.len) {
		return
	}
	nverts := mesh.positions.len / 2
	for i in mesh.indices {
		if i < 0 || i >= nverts {
			return
		}
	}
	s := r.ctx.scale
	c := mesh.color
	per_vertex := mesh.colors.len >= nverts
	sgl.load_pipeline(if mesh.additive { r.ctx.pipeline.add } else { r.ctx.pipeline.alpha })
	if textured {
		img := r.image_for(mesh.texture) or { return }
		if !img.simg_ok {
			return
		}
		sgl.enable_texture()
		sgl.texture(img.simg, img.ssmp)
	}
	sgl.begin_triangles()
	for i in mesh.indices[..mesh.indices.len - mesh.indices.len % 3] {
		p := m.apply(core.vec2(mesh.positions[i * 2], mesh.positions[i * 2 + 1]))
		vc := if per_vertex { mul_color(c, mesh.colors[i]) } else { c }
		u, v := if textured { mesh.uvs[i * 2], mesh.uvs[i * 2 + 1] } else { f32(0), f32(0) }
		sgl.v2f_t2f_c4b(p.x * s, p.y * s, u, v, vc.r, vc.g, vc.b, vc.a)
	}
	sgl.end()
	if textured {
		sgl.disable_texture()
	}
	sgl.load_pipeline(r.ctx.pipeline.alpha)
	r.draw_calls++
	if r.debug {
		mut x0, mut y0 := f32(1e9), f32(1e9)
		mut x1, mut y1 := f32(-1e9), f32(-1e9)
		for i in 0 .. nverts {
			p := m.apply(core.vec2(mesh.positions[i * 2], mesh.positions[i * 2 + 1]))
			x0 = if p.x < x0 { p.x } else { x0 }
			y0 = if p.y < y0 { p.y } else { y0 }
			x1 = if p.x > x1 { p.x } else { x1 }
			y1 = if p.y > y1 { p.y } else { y1 }
		}
		r.ctx.draw_rect_empty(x0, y0, x1 - x0, y1 - y0, to_gg(core.rgba(0, 255, 0, 120)))
	}
}
