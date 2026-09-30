import os
import time
import math
import encoding.binary
import velo.core
import velo.assets
import velo.serialize
import velo.audio

// wav builds a 16-bit PCM WAV file.
fn wav(rate int, channels int, samples []i16) []u8 {
	mut b := []u8{}
	b << 'RIFF'.bytes()
	b << le32(u32(36 + samples.len * 2))
	b << 'WAVEfmt '.bytes()
	b << le32(16)
	b << le16(1)
	b << le16(u16(channels))
	b << le32(u32(rate))
	b << le32(u32(rate * channels * 2))
	b << le16(u16(channels * 2))
	b << le16(16)
	b << 'data'.bytes()
	b << le32(u32(samples.len * 2))
	for s in samples {
		b << le16(u16(s))
	}
	return b
}

fn le16(v u16) []u8 {
	mut b := []u8{len: 2}
	binary.little_endian_put_u16(mut b, v)
	return b
}

fn le32(v u32) []u8 {
	mut b := []u8{len: 4}
	binary.little_endian_put_u32(mut b, v)
	return b
}

fn close(a f32, b f32) bool {
	return math.abs(a - b) < 0.002
}

// constant: a sound whose every sample is `v` (easy to check after mixing).
fn constant(frames int, v f32) &audio.Sound {
	return &audio.Sound{
		sample_rate: 100
		data:        []f32{len: frames * 2, init: v}
		frames:      frames
	}
}

fn new_mixer() audio.Mixer {
	return audio.Mixer{
		sample_rate: 100
	}
}

fn test_decode_wav_mono_and_stereo() {
	mono := audio.decode_wav(wav(8000, 1, [i16(16384), -16384, 0]))!
	assert mono.sample_rate == 8000
	assert mono.frames == 3
	assert mono.data == [f32(0.5), 0.5, -0.5, -0.5, 0, 0]
	stereo := audio.decode_wav(wav(44100, 2, [i16(32767), 0, 0, -32768]))!
	assert stereo.frames == 2
	assert close(stereo.data[0], 1) && stereo.data[1] == 0 && stereo.data[3] == -1
	if _ := audio.decode_wav('RIFFxxxxWAVE'.bytes()) {
		assert false, 'no fmt/data chunk must fail'
	}
	if _ := audio.decode_wav('hello'.bytes()) {
		assert false, 'not a WAV'
	}
}

fn test_mix_volume_pan_and_end() {
	mut m := new_mixer()
	s := constant(10, 0.5)
	id := m.play(s, volume: 0.5, pan: 1)
	assert m.is_playing(id)
	mut out := []f32{len: 8 * 2}
	m.mix(mut out, 8)
	assert close(out[0], 0) // panned right: nothing on the left
	assert close(out[1], 0.25)
	m.mix(mut out, 8) // 2 frames left, then it ends
	assert close(out[3], 0.25)
	assert out[5] == 0
	assert !m.is_playing(id)
	assert m.voice_count() == 0
}

fn test_mix_loops_pitch_and_clamps() {
	mut m := new_mixer()
	s := constant(4, 0.8)
	a := m.play(s, looping: true, pitch: 2)
	m.play(s, looping: true)
	mut out := []f32{len: 50 * 2}
	m.mix(mut out, 50)
	assert m.is_playing(a)
	assert out[99] == 1 // 0.8 + 0.8, clamped
	m.stop_all()
	assert m.voice_count() == 0
}

fn test_bus_volume_pause_and_fade() {
	mut m := new_mixer()
	s := constant(1000, 1)
	music := m.play(s, bus: 'music')
	m.set_bus_volume('music', 0.25)
	mut out := []f32{len: 10 * 2}
	m.mix(mut out, 10)
	assert close(out[19], 0.25)
	m.set_paused(true)
	m.mix(mut out, 10)
	assert out[19] == 0
	m.set_paused(false)
	m.stop(music, 0.2) // 20 frames at 100 Hz
	assert !m.is_playing(music)
	m.mix(mut out, 10)
	assert out[19] < 0.25 && out[19] > 0
	m.mix(mut out, 10)
	assert out[19] == 0
	assert m.voice_count() == 0
}

fn test_play_music_cross_fades() {
	mut m := new_mixer()
	a := constant(1000, 1)
	b := constant(1000, 1)
	first := m.play_music(a, 1, 0)
	assert m.play_music(a, 1, 0) == first // already playing
	second := m.play_music(b, 1, 0.1)
	assert second != first && !m.is_playing(first) && m.is_playing(second)
	mut out := []f32{len: 20 * 2}
	m.mix(mut out, 20)
	assert m.voice_count() == 1 // the old one faded out
	m.stop_music(0)
	assert m.voice_count() == 0
}

fn test_spatial_gain() {
	vol, pan := audio.spatial_gain(core.vec2(100, 0), core.vec2(0, 0), 400, 200)
	assert close(vol, 0.75)
	assert close(pan, 0.4)
	far, side := audio.spatial_gain(core.vec2(-900, 0), core.vec2(0, 0), 400, 200)
	assert far == 0 && close(side, -0.8)
}

fn ogg_sample() ?string {
	for p in [os.join_path(@VEXEROOT, 'examples', 'sokol', 'sounds', 'pickup.ogg'),
		os.join_path(@VEXEROOT, '..', 'share', 'vlang', 'examples', 'sokol', 'sounds', 'pickup.ogg')] {
		if os.exists(p) {
			return p
		}
	}
	return none
}

fn test_ogg_decoded_and_streamed_play_the_same() {
	path := ogg_sample() or {
		println('skipped: V example pickup.ogg not found')
		return
	}
	full := audio.decode_file(path, 'false')!
	streamed := audio.decode_file(path, 'true')!
	assert !full.streamed() && streamed.streamed()
	assert full.frames == streamed.frames && full.frames > 1000
	mut m := audio.Mixer{
		sample_rate: full.sample_rate
	}
	mut o1 := []f32{len: 512 * 2}
	mut o2 := []f32{len: 512 * 2}
	x := m.play(&full)
	m.mix(mut o1, 512)
	m.stop(x, 0)
	m.play(&streamed)
	m.mix(mut o2, 512)
	for i in 0 .. o1.len {
		assert close(o1[i], o2[i])
	}
	// a streamed looping sound keeps going past its end
	m.stop_all()
	id := m.play(&streamed, looping: true)
	mut big := []f32{len: 4096 * 2}
	for _ in 0 .. (full.frames / 4096 + 2) {
		m.mix(mut big, 4096)
	}
	assert m.is_playing(id)
}

fn test_audio_source_loads_and_plays_from_scene() {
	dir := os.join_path(os.temp_dir(), 'velo_audio_test_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file_array(os.join_path(dir, 'beep.wav'), wav(100, 1, []i16{len: 50, init: 8192}))!
	mut db := assets.open(dir)!
	id := db.id_of('beep.wav')?
	mut reg := serialize.new_registry()
	audio.register_builtins(mut reg)
	mut l := serialize.new_loader(reg, db)
	mut root := l.instantiate_source('
node Main {
  node Beep { AudioSource { clip = @asset("${id}")  volume = 0.5  looping = true } }
  node Quiet { AudioSource { clip = @asset("${id}")  play_on_start = false  bus = "ui" } }
}',
		'main.scene')!
	mut scene := l.new_scene(mut root)
	mut m := audio.mixer()
	m.stop_all()
	m.sample_rate = 100
	scene.update(0.016)
	src := scene.find('Beep')?.get_component[audio.AudioSource]()?
	quiet := scene.find('Quiet')?.get_component[audio.AudioSource]()?
	assert src.is_playing()
	assert !quiet.is_playing()
	assert m.voice_count() == 1
	mut out := []f32{len: 10 * 2}
	m.mix(mut out, 10)
	assert close(out[0], 0.125)
	assert db.entry(id)?.refs == 2
	scene.unload()
	assert m.voice_count() == 0
	assert db.entry(id)?.refs == 0
}
