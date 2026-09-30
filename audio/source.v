module audio

import math
import velo.core
import velo.assets
import velo.serialize

// register_builtins registers AudioSource so .scene files (and the editor) can use it.
pub fn register_builtins(mut r serialize.Registry) {
	r.register[AudioSource]()
}

// AudioSource — plays a clip from a node.
//
//   node Coin { AudioSource { clip = @asset("5c1d9e02")  play_on_start = false } }
//
// From code: src.play(), src.play_one_shot() (overlapping copies, e.g. repeated hits), src.stop(), src.pause(),
// src.resume(), src.is_playing(). With `spatial`, the sound is quieter the farther the node is from the
// middle of the screen (the camera) and pans to its side.
pub struct AudioSource {
	core.Component
pub mut:
	clip          assets.AssetRef[assets.AudioClip]
	volume        f32 = 1
	pitch         f32 = 1
	looping       bool
	play_on_start bool   = true
	bus           string = 'sfx' @[choices: 'sfx|music|ui|voice']
	// Spatial: silent beyond `range` world units from the listener (the camera center, or the screen center).
	spatial bool
	range   f32 = 800
	// Stop over this many seconds instead of cutting off (stop() and when the node is destroyed).
	fade_out f32
	loaded   &assets.AudioClip = unsafe { nil } @[hide]
	voice    VoiceId           @[hide]
}

pub fn (mut s AudioSource) on_load() {
	s.set_clip(s.clip)
}

pub fn (mut s AudioSource) start() {
	if s.play_on_start {
		s.play()
	}
}

pub fn (mut s AudioSource) update(dt f32) {
	if s.voice == 0 {
		return
	}
	mut m := mixer()
	if !m.is_playing(s.voice) {
		s.voice = 0
		return
	}
	vol, pan := s.spatial_mix()
	m.set_volume(s.voice, s.volume * vol)
	m.set_pan(s.voice, pan)
	m.set_pitch(s.voice, s.pitch)
}

pub fn (mut s AudioSource) on_destroy() {
	s.stop()
	s.release_clip()
}

// set_clip changes the clip (stops the one playing).
pub fn (mut s AudioSource) set_clip(r assets.AssetRef[assets.AudioClip]) {
	s.stop()
	s.release_clip()
	s.clip = r
	if !r.is_set() || s.node == unsafe { nil } || s.node.scene == unsafe { nil }
		|| s.node.scene.assets == unsafe { nil } {
		return
	}
	mut db := s.node.scene.assets
	s.loaded = db.get(r) or {
		eprintln('[audio] ${s.node.path()}: ${err}')
		return
	}
}

fn (mut s AudioSource) release_clip() {
	if s.loaded != unsafe { nil } && s.node != unsafe { nil } && s.node.scene != unsafe { nil }
		&& s.node.scene.assets != unsafe { nil } {
		mut db := s.node.scene.assets
		db.release(s.loaded.id)
	}
	s.loaded = unsafe { nil }
}

fn (mut s AudioSource) sound() ?&Sound {
	if s.loaded == unsafe { nil } {
		return none
	}
	mut m := mixer()
	return m.load(s.loaded) or {
		eprintln('[audio] ${err}')
		return none
	}
}

// play starts the clip from the beginning (stopping this source's previous play).
pub fn (mut s AudioSource) play() {
	mut m := mixer()
	m.stop(s.voice, 0)
	snd := s.sound() or {
		s.voice = 0
		return
	}
	vol, pan := s.spatial_mix()
	s.voice = m.play(snd,
		volume:  s.volume * vol
		pitch:   s.pitch
		pan:     pan
		looping: s.looping
		bus:     s.bus
	)
}

// play_one_shot plays the clip once more on top of what is playing (never loops, not stopped by stop()).
pub fn (mut s AudioSource) play_one_shot() {
	snd := s.sound() or { return }
	vol, pan := s.spatial_mix()
	mut m := mixer()
	m.play(snd, volume: s.volume * vol, pitch: s.pitch, pan: pan, bus: s.bus)
}

pub fn (mut s AudioSource) stop() {
	if s.voice != 0 {
		mut m := mixer()
		m.stop(s.voice, s.fade_out)
		s.voice = 0
	}
}

pub fn (mut s AudioSource) pause() {
	mut m := mixer()
	m.pause(s.voice)
}

pub fn (mut s AudioSource) resume() {
	mut m := mixer()
	m.resume(s.voice)
}

pub fn (s &AudioSource) is_playing() bool {
	return mixer().is_playing(s.voice)
}

// spatial_mix: volume factor and pan for the node's distance and side from the listener (1, 0 when not spatial).
fn (s &AudioSource) spatial_mix() (f32, f32) {
	if !s.spatial || s.node == unsafe { nil } || s.node.scene == unsafe { nil } {
		return 1, 0
	}
	sc := s.node.scene
	mut listener := sc.view_center()
	mut half_w := sc.view_size.x / 2
	if cam := sc.active_camera() {
		listener = cam.center()
		half_w /= if cam.zoom > 0.001 { cam.zoom } else { f32(1) }
	}
	return spatial_gain(s.node.world_position(), listener, s.range, half_w)
}

// spatial_gain: linear fall-off to 0 at `range`, pan from the horizontal offset (strongest, 0.8, half a screen away).
pub fn spatial_gain(p core.Vec2, listener core.Vec2, range f32, half_width f32) (f32, f32) {
	d := p.distance(listener)
	vol := if range > 0 { f32(math.clamp(1 - d / range, 0, 1)) } else { f32(1) }
	pan := if half_width > 0 {
		f32(math.clamp((p.x - listener.x) / half_width, -1, 1)) * 0.8 // never fully one-sided
	} else {
		f32(0)
	}
	return vol, pan
}
