module audio

import sokol.audio as saudio

#flag ios -framework AudioToolbox
#flag ios -framework AVFoundation

// The device runs in push mode: the game mixes on its own thread once per frame (pump) and hands the samples
// to sokol_audio, which plays them from a small queue. No callback thread touches V memory (the GC does not
// know about it, and the web has no threads), at the cost of about one queue length (~40 ms) of latency.
const device_buffer_frames = 2048

struct DeviceState {
mut:
	started bool
	buf     []f32
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
	println('[audio] ${m.sample_rate} Hz, stereo')
}

// pump mixes what the device needs next and queues it. Call it once per frame (the app does).
pub fn pump() {
	mut d := unsafe { device }
	if !d.started {
		return
	}
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
		saudio.shutdown()
		d.started = false
	}
}

pub fn is_started() bool {
	return device.started
}
