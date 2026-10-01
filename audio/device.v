module audio

import sokol.audio as saudio

#flag ios -framework AudioToolbox
#flag ios -framework AVFoundation

// The device runs in push mode: we mix and hand the samples to sokol_audio, which plays them from a small queue
// (~40 ms). sokol's own callback thread never touches V memory (the GC does not know about it).
// On desktop and phones the mixing runs on a thread of ours (see device_notd_emscripten.v), so a long frame
// (scene load, GC pause) does not starve the queue; on the web, which has no threads, the app's pump() does it
// once per frame.
const device_buffer_frames = 2048

struct DeviceState {
mut:
	started bool
	buf     []f32
	thread  AudioThread
}

const device = &DeviceState{}

// start opens the default output device (stereo). The app calls it at startup; without it (tests, tools)
// sounds can still be mixed by hand with Mixer.mix.
pub fn start() {
	mut d := unsafe { device }
	if d.started {
		return
	}
	saudio.setup(
		num_channels:  2
		buffer_frames: device_buffer_frames
	)
	if !saudio.is_valid() {
		eprintln('[audio] no audio output device, sound is off')
		return
	}
	d.started = true
	mut m := mixer()
	m.sample_rate = saudio.sample_rate()
	d.buf = []f32{len: device_buffer_frames * 2}
	d.thread.start()
	println('[audio] ${m.sample_rate} Hz, stereo${if d.thread.running() {
		', own thread'
	} else {
		''
	}}')
}

// pump mixes what the device needs next and queues it. Call it once per frame (the app does); it does
// nothing while the audio thread runs.
pub fn pump() {
	mut d := unsafe { device }
	if !d.started || d.thread.running() {
		return
	}
	fill()
}

// fill tops up the device queue (only one thread at a time: the audio thread, or pump without it).
fn fill() {
	mut d := unsafe { device }
	mut m := mixer()
	mut want := saudio.expect()
	for want > 0 {
		n := if want > device_buffer_frames { device_buffer_frames } else { want }
		m.mix(mut d.buf, n)
		saudio.push(&d.buf[0], n)
		want -= n
	}
}

// shutdown stops every sound and closes the device.
pub fn shutdown() {
	mut d := unsafe { device }
	mut m := mixer()
	m.stop_all()
	if d.started {
		d.thread.stop()
		saudio.shutdown()
		d.started = false
	}
}

pub fn is_started() bool {
	return device.started
}
