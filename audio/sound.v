module audio

import os
import encoding.binary

// Sound — a decoded clip, ready for the mixer: stereo frames (left, right interleaved) at the file's sample rate.
// A streamed sound keeps the encoded .ogg bytes instead and decodes them while it plays (see Voice).
@[heap]
pub struct Sound {
pub:
	id          string
	version     int
	sample_rate int
	data        []f32 // interleaved stereo; empty when streamed
	encoded     []u8  // the .ogg file, when streamed
	frames      int   // length in frames
}

pub fn (s &Sound) streamed() bool {
	return s.encoded.len > 0
}

// duration in seconds.
pub fn (s &Sound) duration() f32 {
	return if s.sample_rate > 0 { f32(s.frames) / f32(s.sample_rate) } else { 0 }
}

// streaming decisions: `.meta` `stream: true|false`, or automatically for .ogg files longer than this.
const auto_stream_seconds = 20

// decode_file decodes a .wav or .ogg file. `stream` is the clip's `.meta` setting ('' = automatic).
pub fn decode_file(path string, stream string) !Sound {
	data := os.read_bytes(path)!
	ext := os.file_ext(path).to_lower()
	return match ext {
		'.wav' { decode_wav(data)! }
		'.ogg' { decode_ogg(data, stream)! }
		else { error('${os.file_name(path)}: unsupported audio format "${ext}" (use .wav or .ogg)') }
	}
}

// decode_wav reads a RIFF/WAVE file: PCM 8/16/24/32-bit or 32-bit float, any channel count
// (mono is played on both sides; channels past the first two are dropped).
pub fn decode_wav(b []u8) !Sound {
	if b.len < 12 || b[0..4].bytestr() != 'RIFF' || b[8..12].bytestr() != 'WAVE' {
		return error('not a WAV file')
	}
	mut format := 0
	mut channels := 0
	mut rate := 0
	mut bits := 0
	mut pcm := []u8{}
	mut found_data := false
	mut i := 12
	for i + 8 <= b.len {
		id := b[i..i + 4].bytestr()
		size := int(binary.little_endian_u32(b[i + 4..i + 8]))
		body := i + 8
		end := if size < 0 || body + size > b.len { b.len } else { body + size }
		if id == 'fmt ' && end - body >= 16 {
			format = int(binary.little_endian_u16(b[body..body + 2]))
			channels = int(binary.little_endian_u16(b[body + 2..body + 4]))
			rate = int(binary.little_endian_u32(b[body + 4..body + 8]))
			bits = int(binary.little_endian_u16(b[body + 14..body + 16]))
			if format == 0xfffe && end - body >= 26 {
				format = int(binary.little_endian_u16(b[body + 24..body + 26])) // WAVE_FORMAT_EXTENSIBLE
			}
		} else if id == 'data' {
			pcm = unsafe { b[body..end] } // only read below, while `b` is alive
			found_data = true
		}
		i = body + size + (size & 1) // chunks are padded to an even size
	}
	if channels <= 0 || rate <= 0 || !found_data {
		return error('WAV file without a "fmt " or "data" chunk')
	}
	if !(format == 1 && bits in [8, 16, 24, 32]) && !(format == 3 && bits == 32) {
		return error('unsupported WAV encoding (format ${format}, ${bits} bits): use PCM or 32-bit float')
	}
	bps := bits / 8
	frame_bytes := bps * channels
	frames := pcm.len / frame_bytes
	mut out := []f32{len: frames * 2}
	for f in 0 .. frames {
		base := f * frame_bytes
		l := wav_sample(pcm, base, bits, format)
		r := if channels > 1 { wav_sample(pcm, base + bps, bits, format) } else { l }
		out[f * 2] = l
		out[f * 2 + 1] = r
	}
	return Sound{
		sample_rate: rate
		data:        out
		frames:      frames
	}
}

fn wav_sample(b []u8, at int, bits int, format int) f32 {
	return match bits {
		8 {
			(f32(b[at]) - 128) / 128
		}
		16 {
			f32(i16(binary.little_endian_u16(b[at..at + 2]))) / 32768
		}
		24 {
			v := int(u32(b[at]) << 8 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 24) >> 8
			f32(v) / 8388608
		}
		else {
			if format == 3 {
				binary.little_endian_f32_at(b, at)
			} else {
				f32(f64(int(binary.little_endian_u32(b[at..at + 4]))) / 2147483648.0)
			}
		}
	}
}

// decode_ogg decodes an Ogg Vorbis file fully, or only reads its header when it is to be streamed.
pub fn decode_ogg(b []u8, stream string) !Sound {
	mut dec := OggDecoder.open(b)!
	defer {
		dec.close()
	}
	rate := dec.sample_rate
	frames := dec.length()
	auto := frames > auto_stream_seconds * rate
	if stream == 'true' || (stream != 'false' && auto) {
		return Sound{
			sample_rate: rate
			encoded:     b
			frames:      frames
		}
	}
	mut out := []f32{len: frames * 2}
	mut got := 0
	for got < frames {
		n := dec.read(mut out, got, frames - got)
		if n <= 0 {
			break
		}
		got += n
	}
	if got < frames {
		out.trim(got * 2)
	}
	return Sound{
		sample_rate: rate
		data:        out
		frames:      got
	}
}
