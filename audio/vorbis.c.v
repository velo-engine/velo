module audio

#flag -I @VEXEROOT/thirdparty/stb_vorbis
#include "@VMODROOT/audio/stb_vorbis_impl.c"

@[typedef]
struct C.stb_vorbis {}

@[typedef]
struct C.stb_vorbis_info {
	sample_rate u32
	channels    int
}

fn C.stb_vorbis_open_memory(data &u8, len int, err &int, alloc voidptr) &C.stb_vorbis
fn C.stb_vorbis_get_info(f &C.stb_vorbis) C.stb_vorbis_info
fn C.stb_vorbis_stream_length_in_samples(f &C.stb_vorbis) u32
fn C.stb_vorbis_get_samples_float_interleaved(f &C.stb_vorbis, channels int, buffer &f32, num_floats int) int
fn C.stb_vorbis_seek_start(f &C.stb_vorbis) int
fn C.stb_vorbis_close(f &C.stb_vorbis)

// OggDecoder — reads an Ogg Vorbis file from memory, a block at a time. `data` must stay alive while it is open.
struct OggDecoder {
mut:
	f           &C.stb_vorbis = unsafe { nil }
	channels    int
	sample_rate int
	mono        []f32 // scratch for mono files (decoded mono, then written to both sides)
}

fn OggDecoder.open(data []u8) !OggDecoder {
	mut err := 0
	f := C.stb_vorbis_open_memory(data.data, data.len, &err, unsafe { nil })
	if f == unsafe { nil } {
		return error('cannot read the Ogg Vorbis data (stb_vorbis error ${err})')
	}
	info := C.stb_vorbis_get_info(f)
	return OggDecoder{
		f:           f
		channels:    info.channels
		sample_rate: int(info.sample_rate)
	}
}

// length in frames.
fn (d &OggDecoder) length() int {
	return int(C.stb_vorbis_stream_length_in_samples(d.f))
}

// read decodes up to `max_frames` stereo frames into `out`, starting at frame `at`. Returns the frames read (0 at the end).
fn (mut d OggDecoder) read(mut out []f32, at int, max_frames int) int {
	if d.f == unsafe { nil } || max_frames <= 0 {
		return 0
	}
	if d.channels == 1 {
		if d.mono.len < max_frames {
			d.mono = []f32{len: max_frames}
		}
		n := C.stb_vorbis_get_samples_float_interleaved(d.f, 1, d.mono.data, max_frames)
		for i in 0 .. n {
			out[(at + i) * 2] = d.mono[i]
			out[(at + i) * 2 + 1] = d.mono[i]
		}
		return n
	}
	return C.stb_vorbis_get_samples_float_interleaved(d.f, 2, unsafe { &out[at * 2] }, max_frames * 2)
}

fn (mut d OggDecoder) rewind() {
	if d.f != unsafe { nil } {
		C.stb_vorbis_seek_start(d.f)
	}
}

fn (mut d OggDecoder) close() {
	if d.f != unsafe { nil } {
		C.stb_vorbis_close(d.f)
		d.f = unsafe { nil }
	}
}
