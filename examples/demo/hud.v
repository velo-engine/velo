module main

import velo.core
import velo.render

// SpawnButton — clicking the Button on the same node scatters more coins.
pub struct SpawnButton {
	core.Component
pub mut:
	spawner string = 'World/Coins'
}

pub fn (mut b SpawnButton) update(dt f32) {
	btn := b.node.get_component[render.Button]() or { return }
	if !btn.clicked {
		return
	}
	node := b.scene().find(b.spawner) or { return }
	if mut s := node.get_component[CoinSpawner]() {
		s.spawn()
	}
}

// PickupLog — appends a line per pickup to the ScrollView's content and keeps the newest one in view.
pub struct PickupLog {
	core.Component
pub mut:
	max_lines int = 40
}

pub fn (mut l PickupLog) add(text string) {
	mut sv := l.node.get_component[render.ScrollView]() or { return }
	mut content := sv.content_node() or { return }
	width := if t := content.get_component[render.UITransform]() { t.size.x - 12 } else { 160 }
	mut line := core.Node.new('Line')
		.with(&render.UITransform{ size: core.vec2(width, 18), anchor: core.vec2(0, 0) })
		.with(&render.Label{ text: text, size: 16, color: core.rgba(255, 230, 120, 255) })
	content.add_child(mut line)
	for content.children.len > l.max_lines {
		content.children[0].destroy()
		content.children.delete(0)
	}
	if mut layout := content.get_component[render.Layout]() {
		layout.arrange() // size the content now so scrolling to the bottom sees the new line
	}
	sv.scroll_to_bottom()
}
