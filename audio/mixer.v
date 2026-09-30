module audio

import math
import velo.assets

// VoiceId — a playing sound, returned by Mixer.play (0 = nothing was started).
pub type VoiceId = u32

@[params]
pub struct PlayOptions {
pub:
	volume  f32 = 1
	pitch   f32 = 1 // playback speed: 2 = one octave up and twice as fast
	pan     f32    // -1 = left, 0 = center, 1 = right
	looping bool
	bus     string = 'sfx' // volume group, see Mixer.set_bus_volume
	fade_in f32 // seconds to rise from silence
}

const max_voices = 64
const stream_chunk_frames = 4096

@[heap]
struct Voice {
mut:
	id      VoiceId
	sound   &Sound = unsafe { nil }
	pos     f64 // frame position in the sound (or in `buf` when streamed)
	volume  f32
	pitch   f32
	pan     f32
	looping bool
	paused  bool
	bus     string
	done    bool
	// fading: `fade` goes toward `fade_to` at `fade_speed` per second; stop once it reaches 0 if `stop_at_zero`
	fade         f32 = 1
	fade_to      f32 = 1
	fade_speed   f32
	stop_at_zero bool
	// gains used at the end of the last block (the next block ramps from them: no clicks on changes)
	last_l f32
	last_r f32
	primed bool
	// streaming
	dec        OggDecoder
	buf        []f32
	buf_frames int
	ended      bool
}

// Mixer — plays any number of sounds at once and mixes them into stereo samples. The device (see start/pump)
// pulls from the global one every frame; tests and tools can call `mix` themselves.
@[heap]
pub struct Mixer {
pub mut:
	master      f32 = 1
	sample_rate int = 44100 // output rate, set by the device
mut:
	buses   map[string]f32
	voices  []&Voice
	next_id u32 = 1
	sounds  map[string]&Sound // clip id -> decoded sound
	paused  bool
	music   VoiceId
}

const default_mixer = &Mixer{}

// mixer: the mixer the audio device plays (AudioSource uses it too).
pub fn mixer() &Mixer {
	return default_mixer
}

// load decodes the clip (once; again after the file changed on disk).
pub fn (mut m Mixer) load(clip &assets.AudioClip) !&Sound {
	if s := m.sounds[clip.id] {
		if s.version == clip.version {
			return s
		}
	}
	decoded := decode_file(clip.path, clip.stream) or {
		return error('${clip.path}: ${err.msg()}')
	}
	s := &Sound{
		...decoded
		id:      clip.id
		version: clip.version
	}
	m.sounds[clip.id] = s
	return s
}

// forget drops the decoded data of a clip (sounds already playing finish normally).
pub fn (mut m Mixer) forget(id string) {
	m.sounds.delete(id)
}

// play starts `s`. Returns 0 when too many sounds are playing (64) or the sound cannot be read.
pub fn (mut m Mixer) play(s &Sound, opts PlayOptions) VoiceId {
	if s.frames <= 0 || m.voice_count() >= max_voices {
		return 0
	}
	mut v := &Voice{
		id:      m.next_id
		sound:   s
		volume:  opts.volume
		pitch:   opts.pitch
		pan:     opts.pan
		looping: opts.looping
		bus:     opts.bus
	}
	if opts.fade_in > 0 {
		v.fade = 0
		v.fade_speed = 1 / opts.fade_in
	}
	if s.streamed() {
		v.dec = OggDecoder.open(s.encoded) or {
			eprintln('[audio] ${err}')
			return 0
		}
		v.buf = []f32{len: stream_chunk_frames * 2}
		v.refill()
	}
	m.next_id++
	if m.next_id == 0 {
		m.next_id = 1
	}
	m.voices << v
	return v.id
}

fn (m &Mixer) voice(id VoiceId) ?&Voice {
	if id == 0 {
		return none
	}
	for v in m.voices {
		if v.id == id && !v.done {
			return v
		}
	}
	return none
}

// stop stops a sound, fading it out over `fade` seconds (0 = at once).
pub fn (mut m Mixer) stop(id VoiceId, fade f32) {
	mut v := m.voice(id) or { return }
	if fade > 0 && !v.paused {
		v.fade_to = 0
		v.fade_speed = v.fade / fade
		v.stop_at_zero = true
	} else {
		v.finish()
	}
}

pub fn (mut m Mixer) stop_all() {
	for mut v in m.voices {
		v.finish()
	}
	m.voices.clear()
	m.music = 0
}

pub fn (mut m Mixer) pause(id VoiceId) {
	if mut v := m.voice(id) {
		v.paused = true
	}
}

pub fn (mut m Mixer) resume(id VoiceId) {
	if mut v := m.voice(id) {
		v.paused = false
	}
}

// is_playing: the sound has not finished or been stopped (a paused sound counts as playing).
pub fn (m &Mixer) is_playing(id VoiceId) bool {
	v := m.voice(id) or { return false }
	return !v.stop_at_zero
}

pub fn (mut m Mixer) set_volume(id VoiceId, volume f32) {
	if mut v := m.voice(id) {
		v.volume = volume
	}
}

pub fn (mut m Mixer) set_pan(id VoiceId, pan f32) {
	if mut v := m.voice(id) {
		v.pan = pan
	}
}

pub fn (mut m Mixer) set_pitch(id VoiceId, pitch f32) {
	if mut v := m.voice(id) {
		v.pitch = pitch
	}
}

// position: seconds played (for a looping sound, within the current loop).
pub fn (m &Mixer) position(id VoiceId) f32 {
	v := m.voice(id) or { return 0 }
	if v.sound.streamed() {
		return 0 // not tracked for streamed sounds
	}
	return f32(v.pos) / f32(v.sound.sample_rate)
}

// set_paused pauses (true) or resumes every sound, e.g. while the game is in the background.
pub fn (mut m Mixer) set_paused(paused bool) {
	m.paused = paused
}

// set_bus_volume sets the volume of a group ("music", "sfx", or any name used in PlayOptions.bus).
pub fn (mut m Mixer) set_bus_volume(bus string, volume f32) {
	m.buses[bus] = volume
}

pub fn (m &Mixer) bus_volume(bus string) f32 {
	return m.buses[bus] or { 1 }
}

// voice_count: sounds playing (or paused).
pub fn (m &Mixer) voice_count() int {
	return m.voices.filter(!it.done).len
}

// play_music plays `s` on the "music" bus, looping, cross-fading from the music playing before over `fade` seconds.
// Playing the music that is already playing does nothing.
pub fn (mut m Mixer) play_music(s &Sound, volume f32, fade f32) VoiceId {
	if cur := m.voice(m.music) {
		if voidptr(cur.sound) == voidptr(s) && !cur.stop_at_zero { // same object (== would compare contents)
			return cur.id
		}
	}
	m.stop(m.music, fade)
	m.music = m.play(s, volume: volume, looping: true, bus: 'music', fade_in: fade)
	return m.music
}

pub fn (mut m Mixer) stop_music(fade f32) {
	m.stop(m.music, fade)
	m.music = 0
}

// mix writes `frames` stereo frames (left, right interleaved) into `out` and advances every sound.
pub fn (mut m Mixer) mix(mut out []f32, frames int) {
	for i in 0 .. frames * 2 {
		out[i] = 0
	}
	if m.paused || frames <= 0 {
		return
	}
	dt := f32(frames) / f32(m.sample_rate)
	for mut v in m.voices {
		if v.done || v.paused {
			continue
		}
		m.mix_voice(mut v, mut out, frames, dt)
	}
	for i in 0 .. frames * 2 {
		out[i] = f32(math.clamp(out[i], -1, 1))
	}
	if m.voices.any(it.done) {
		m.voices = m.voices.filter(!it.done)
	}
}

fn (m &Mixer) mix_voice(mut v Voice, mut out []f32, frames int, dt f32) {
	// fade, then the gains at the end of this block
	if v.fade != v.fade_to {
		step := v.fade_speed * dt
		v.fade = if v.fade < v.fade_to {
			math.min(v.fade + step, v.fade_to)
		} else {
			math.max(v.fade - step, v.fade_to)
		}
	}
	gain := v.volume * v.fade * m.bus_volume(v.bus) * m.master
	pan := f32(math.clamp(v.pan, -1, 1))
	gl := gain * math.min(f32(1), 1 - pan)
	gr := gain * math.min(f32(1), 1 + pan)
	if !v.primed {
		v.last_l, v.last_r, v.primed = gl, gr, true
	}
	step := f64(v.sound.sample_rate) / f64(m.sample_rate) * f64(math.max(v.pitch, f32(0.01)))
	streamed := v.sound.streamed()
	for f in 0 .. frames {
		if streamed && int(v.pos) + 1 >= v.buf_frames && !v.ended {
			v.refill()
		}
		n := if streamed { v.buf_frames } else { v.sound.frames }
		if v.pos >= n {
			if !streamed && v.looping {
				v.pos = math.fmod(v.pos, f64(n))
			} else {
				v.finish()
				break
			}
		}
		i := int(v.pos)
		frac := f32(v.pos - i)
		data := if streamed { v.buf } else { v.sound.data }
		l0, r0 := data[i * 2], data[i * 2 + 1]
		mut l1, mut r1 := l0, r0
		if i + 1 < n {
			l1, r1 = data[i * 2 + 2], data[i * 2 + 3]
		} else if !streamed && v.looping {
			l1, r1 = data[0], data[1]
		}
		t := f32(f + 1) / f32(frames)
		out[f * 2] += (l0 + (l1 - l0) * frac) * (v.last_l + (gl - v.last_l) * t)
		out[f * 2 + 1] += (r0 + (r1 - r0) * frac) * (v.last_r + (gr - v.last_r) * t)
		v.pos += step
	}
	v.last_l, v.last_r = gl, gr
	if v.stop_at_zero && v.fade <= 0 {
		v.finish()
	}
}

// refill keeps the frames not played yet and decodes more after them (streamed sounds).
fn (mut v Voice) refill() {
	from := math.min(int(v.pos), v.buf_frames)
	keep := v.buf_frames - from
	for i in 0 .. keep * 2 {
		v.buf[i] = v.buf[from * 2 + i]
	}
	v.pos -= from
	mut have := keep
	capacity := v.buf.len / 2
	mut rewound := false
	for have < capacity {
		n := v.dec.read(mut v.buf, have, capacity - have)
		if n <= 0 {
			if v.looping && !rewound {
				v.dec.rewind()
				rewound = true
				continue
			}
			v.ended = true
			break
		}
		rewound = false
		have += n
	}
	v.buf_frames = have
}

fn (mut v Voice) finish() {
	v.done = true
	v.dec.close()
}
