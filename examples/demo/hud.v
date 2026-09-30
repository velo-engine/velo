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

// PauseControls — P pauses the game (scene.paused), T toggles slow motion (scene.time_scale), M goes back to the menu.
// It lives on the HUD, which has `unscaled_time`, so it (and the HUD's buttons and scroll view) keeps working while paused.
pub struct PauseControls {
	core.Component
pub mut:
	slow_motion f32    = 0.3
	label       string = 'Paused' // child shown while paused
	menu        string = 'scenes/menu.scene'
}

pub fn (mut c PauseControls) update(dt f32) {
	input := c.input()
	mut sc := c.scene()
	if input.was_pressed(.p) {
		sc.paused = !sc.paused
		if mut label := c.node.find(c.label) {
			label.active = sc.paused
			if sc.paused {
				label.scale = core.vec2(0.6, 0.6)
				label.tween().scale_to(core.vec2(1, 1), 0.35, .elastic_out)
			}
		}
	}
	if input.was_pressed(.t) {
		sc.time_scale = if sc.time_scale < 1 { f32(1) } else { c.slow_motion }
	}
	if input.was_pressed(.m) {
		sc.change_scene(c.menu, fade: 0.4)
	}
}

// MenuScreen — the title screen: shows the saved best score, Play starts the game, Reset forgets the best score.
pub struct MenuScreen {
	core.Component
pub mut:
	game string = 'scenes/main.scene'
}

pub fn (mut m MenuScreen) start() {
	m.show_best()
	if mut title := m.node.find('Title') {
		title.scale = core.vec2(0.8, 0.8)
		title.tween().scale_to(core.vec2(1, 1), 0.6, .elastic_out)
	}
}

pub fn (mut m MenuScreen) update(dt f32) {
	mut sc := m.scene()
	if m.clicked('Play') || m.input().was_pressed(.enter) || m.input().was_pressed(.space) {
		sc.change_scene(m.game, fade: 0.4)
	}
	if m.clicked('Reset') {
		mut st := sc.store
		st.delete('best')
		m.show_best()
	}
}

fn (m &MenuScreen) clicked(name string) bool {
	n := m.node.find(name) or { return false }
	b := n.get_component[render.Button]() or { return false }
	return b.clicked
}

fn (mut m MenuScreen) show_best() {
	best := m.scene().store.get_int('best', 0)
	if mut n := m.node.find('Best') {
		if mut l := n.get_component[render.Label]() {
			l.text = if best > 0 { 'Best: ${best}' } else { 'Collect as many coins as you can!' }
		}
	}
}
