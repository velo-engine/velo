module main

import velo.core
import velo.render

// TouchMarkers — draws a ring under every finger on the screen, numbered in the order they went down,
// to show multi-touch at work (try the joystick with one thumb and "More coins" with the other).
pub struct TouchMarkers {
	core.Component
pub mut:
	size  f32        = 70
	color core.Color = core.rgba(255, 230, 120, 90)
	marks map[u64]&core.Node @[hide]
}

pub fn (mut m TouchMarkers) update(dt f32) {
	input := m.input()
	for id, mut mark in m.marks {
		t := input.touch(id) or {
			mark.destroy()
			m.marks.delete(id)
			continue
		}
		mark.position = t.pos
	}
	for t in input.touches {
		if t.is_up() || t.id in m.marks {
			continue
		}
		mut mark := core.Node.new('Touch')
			.with(&render.UITransform{ size: core.vec2(m.size, m.size) })
			.with(&render.Panel{ color: m.color, radius: m.size / 2, border_width: 2 })
		mut num := core.Node.new('Number')
			.with(&render.Label{
				text:   '${m.marks.len + 1}'
				size:   20
				align:  'center'
				valign: 'middle'
			})
		mark.add_child(mut num)
		mark.position = t.pos
		m.node.add_child(mut mark)
		m.marks[t.id] = mark
	}
}
