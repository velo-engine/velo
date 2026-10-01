// velo.audio for the WebGL runtime: the same Mixer / AudioSource API as audio/*.v, played with WebAudio.
// Clips are decoded before the game starts (decode_all, called by the app), so play() is synchronous like on
// desktop. Browsers only start sound after a click/tap/key press: the app resumes the context on the first one.

import * as V from './v.ts'
import * as core from './core.ts'
import * as assets from './assets.ts'
import type * as serialize from './serialize.ts'

type FieldSpec = core.FieldSpec

export type VoiceId = number

// Sound — a decoded clip.
export class Sound {
	static __vname = 'audio.Sound'
	id = ''
	version = 0
	sample_rate = 0
	frames = 0
	buffer: AudioBuffer | null = null
	streamed(): boolean {
		return false
	}
	duration(): number {
		return this.sample_rate > 0 ? this.frames / this.sample_rate : 0
	}
}

export class PlayOptions {
	static __vname = 'audio.PlayOptions'
	volume = 1
	pitch = 1
	pan = 0
	looping = false
	bus = 'sfx'
	fade_in = 0
}

const max_voices = 64

interface Voice {
	id: VoiceId
	sound: Sound
	source: AudioBufferSourceNode | null
	gain: GainNode
	panner: StereoPannerNode | null
	volume: number
	pitch: number
	pan: number
	looping: boolean
	bus: string
	paused: boolean
	done: boolean
	// playback position: `offset` seconds into the sound at context time `since` (advancing at `pitch`)
	offset: number
	since: number
}

let ctx: AudioContext | null = null
const decoded = new Map<string, AudioBuffer>()

export function context(): AudioContext | null {
	if (ctx === null && typeof AudioContext !== 'undefined') {
		try {
			ctx = new AudioContext()
		} catch {
			ctx = null
		}
	}
	return ctx
}

// decode_all decodes every downloaded audio clip (the app calls it before the game starts).
export async function decode_all(db: assets.AssetDatabase) {
	const ac = context()
	if (ac === null) return
	const jobs: Promise<void>[] = []
	for (const [id, bytes] of db.data.bytes) {
		const e = db.entry(id)
		if (!e || e.kind !== 'audio') continue
		jobs.push(
			ac
				.decodeAudioData(bytes.slice(0))
				.then((buf) => {
					decoded.set(id, buf)
				})
				.catch((err) => console.error(`[audio] cannot decode ${e.path}: ${err}`)),
		)
	}
	await Promise.all(jobs)
}

// resume starts sound after a user gesture.
export function resume() {
	const ac = context()
	if (ac !== null && ac.state === 'suspended' && !default_mixer.paused) ac.resume().catch(() => {})
}

export class Mixer {
	static __vname = 'audio.Mixer'
	master = 1
	sample_rate = 44100
	buses = new Map<string, number>()
	bus_nodes = new Map<string, GainNode>()
	master_node: GainNode | null = null
	voices = new Map<VoiceId, Voice>()
	next_id = 1
	sounds = new Map<string, Sound>()
	paused = false
	music: VoiceId = 0

	private out(bus: string): AudioNode | null {
		const ac = context()
		if (ac === null) return null
		if (this.master_node === null) {
			this.master_node = ac.createGain()
			this.master_node.connect(ac.destination)
			this.sample_rate = ac.sampleRate
		}
		this.master_node.gain.value = this.master
		let n = this.bus_nodes.get(bus)
		if (!n) {
			n = ac.createGain()
			n.gain.value = this.bus_volume(bus)
			n.connect(this.master_node)
			this.bus_nodes.set(bus, n)
		}
		return n
	}

	load(clip: assets.AudioClip): Sound {
		const s = this.sounds.get(clip.id)
		if (s && s.version === clip.version) return s
		const buf = decoded.get(clip.id)
		if (!buf) throw new V.VError(`${clip.path}: the browser cannot decode this sound (use .wav or .ogg)`)
		const snd = new Sound()
		snd.id = clip.id
		snd.version = clip.version
		snd.sample_rate = buf.sampleRate
		snd.frames = buf.length
		snd.buffer = buf
		this.sounds.set(clip.id, snd)
		return snd
	}

	forget(id: string) {
		this.sounds.delete(id)
	}

	play(s: Sound, opts?: Partial<PlayOptions>): VoiceId {
		const o = Object.assign(new PlayOptions(), opts ?? {})
		const ac = context()
		if (ac === null || s.buffer === null || s.frames <= 0 || this.voice_count() >= max_voices) return 0
		const out = this.out(o.bus)
		if (out === null) return 0
		const gain = ac.createGain()
		let panner: StereoPannerNode | null = null
		if (typeof ac.createStereoPanner === 'function') {
			panner = ac.createStereoPanner()
			panner.pan.value = Math.max(-1, Math.min(1, o.pan))
			gain.connect(panner)
			panner.connect(out)
		} else {
			gain.connect(out)
		}
		const v: Voice = {
			id: this.next_id++,
			sound: s,
			source: null,
			gain,
			panner,
			volume: o.volume,
			pitch: o.pitch,
			pan: o.pan,
			looping: o.looping,
			bus: o.bus,
			paused: false,
			done: false,
			offset: 0,
			since: ac.currentTime,
		}
		if (o.fade_in > 0) {
			gain.gain.setValueAtTime(0, ac.currentTime)
			gain.gain.linearRampToValueAtTime(o.volume, ac.currentTime + o.fade_in)
		} else {
			gain.gain.value = o.volume
		}
		this.voices.set(v.id, v)
		this.start_source(v)
		return v.id
	}

	private start_source(v: Voice) {
		const ac = context()!
		const src = ac.createBufferSource()
		src.buffer = v.sound.buffer
		src.loop = v.looping
		src.playbackRate.value = Math.max(0.01, v.pitch)
		src.connect(v.gain)
		const dur = v.sound.buffer!.duration
		const at = v.looping ? v.offset % dur : Math.min(v.offset, dur)
		src.onended = () => {
			if (v.source === src && !v.paused) this.finish(v)
		}
		src.start(0, at)
		v.source = src
		v.since = ac.currentTime
		v.offset = at
	}

	private finish(v: Voice) {
		v.done = true
		try {
			v.gain.disconnect()
			if (v.panner) v.panner.disconnect()
		} catch {}
		this.voices.delete(v.id)
		if (this.music === v.id) this.music = 0
	}

	private position_of(v: Voice): number {
		const ac = context()
		if (ac === null || v.paused) return v.offset
		return v.offset + (ac.currentTime - v.since) * v.pitch
	}

	stop(id: VoiceId, fade: number) {
		const v = this.voices.get(id)
		if (!v) return
		const ac = context()!
		if (fade > 0 && v.source && !v.paused) {
			v.gain.gain.cancelScheduledValues(ac.currentTime)
			v.gain.gain.setValueAtTime(v.gain.gain.value, ac.currentTime)
			v.gain.gain.linearRampToValueAtTime(0, ac.currentTime + fade)
			const src = v.source
			src.stop(ac.currentTime + fade)
			// it still counts as playing until the fade ends (onended finishes it)
			return
		}
		const src = v.source
		v.source = null
		if (src) {
			try {
				src.stop()
			} catch {}
		}
		this.finish(v)
	}

	stop_all() {
		for (const id of [...this.voices.keys()]) this.stop(id, 0)
	}

	pause(id: VoiceId) {
		const v = this.voices.get(id)
		if (!v || v.paused) return
		v.offset = this.position_of(v)
		v.paused = true
		const src = v.source
		v.source = null
		if (src) {
			try {
				src.stop()
			} catch {}
		}
	}

	resume(id: VoiceId) {
		const v = this.voices.get(id)
		if (!v || !v.paused) return
		v.paused = false
		this.start_source(v)
	}

	is_playing(id: VoiceId): boolean {
		const v = this.voices.get(id)
		return v !== undefined && !v.done
	}

	set_volume(id: VoiceId, volume: number) {
		const v = this.voices.get(id)
		if (!v || v.volume === volume) return
		v.volume = volume
		const ac = context()!
		v.gain.gain.setTargetAtTime(volume, ac.currentTime, 0.015)
	}

	set_pan(id: VoiceId, pan: number) {
		const v = this.voices.get(id)
		if (!v || v.pan === pan) return
		v.pan = pan
		if (v.panner) v.panner.pan.setTargetAtTime(Math.max(-1, Math.min(1, pan)), context()!.currentTime, 0.015)
	}

	set_pitch(id: VoiceId, pitch: number) {
		const v = this.voices.get(id)
		if (!v || v.pitch === pitch) return
		v.offset = this.position_of(v)
		v.since = context()!.currentTime
		v.pitch = pitch
		if (v.source) v.source.playbackRate.value = Math.max(0.01, pitch)
	}

	position(id: VoiceId): number {
		const v = this.voices.get(id)
		if (!v) return 0
		const dur = v.sound.buffer ? v.sound.buffer.duration : 0
		const p = this.position_of(v)
		return v.looping && dur > 0 ? p % dur : Math.min(p, dur)
	}

	set_paused(paused: boolean) {
		this.paused = paused
		const ac = context()
		if (ac === null) return
		if (paused) ac.suspend().catch(() => {})
		else ac.resume().catch(() => {})
	}

	set_bus_volume(bus: string, volume: number) {
		this.buses.set(bus, volume)
		const n = this.bus_nodes.get(bus)
		if (n) n.gain.value = volume
	}

	bus_volume(bus: string): number {
		return this.buses.get(bus) ?? 1
	}

	voice_count(): number {
		return this.voices.size
	}

	play_music(s: Sound, volume: number, fade: number): VoiceId {
		this.stop_music(fade)
		this.music = this.play(s, { volume, looping: true, bus: 'music', fade_in: fade })
		return this.music
	}

	stop_music(fade: number) {
		if (this.music !== 0) {
			this.stop(this.music, fade)
			this.music = 0
		}
	}

	// mix: the browser mixes by itself (kept for API compatibility).
	mix(_out: number[], _frames: number) {}

	// set_master applies `master` (the V field is read every frame there).
	sync() {
		if (this.master_node) this.master_node.gain.value = this.master
	}
}

const default_mixer = new Mixer()

export function mixer(): Mixer {
	return default_mixer
}

export function start() {
	context()
}

export function pump() {
	default_mixer.sync()
}

export function shutdown() {
	default_mixer.stop_all()
}

// ---------- AudioSource (audio/source.v) ----------

export class AudioSource extends core.Component {
	static __vname = 'audio.AudioSource'
	static __fields: FieldSpec[] = [
		{ name: 'clip', type: 'asset:audio' },
		{ name: 'volume', type: 'f32' },
		{ name: 'pitch', type: 'f32' },
		{ name: 'looping', type: 'bool' },
		{ name: 'play_on_start', type: 'bool' },
		{ name: 'bus', type: 'string', choices: ['sfx', 'music', 'ui', 'voice'] },
		{ name: 'spatial', type: 'bool' },
		{ name: 'range', type: 'f32' },
		{ name: 'fade_out', type: 'f32' },
	]
	clip = new assets.AssetRef('', assets.AudioClip)
	volume = 1
	pitch = 1
	looping = false
	play_on_start = true
	bus = 'sfx'
	spatial = false
	range = 800
	fade_out = 0
	loaded: assets.AudioClip | null = null
	voice: VoiceId = 0

	on_load() {
		this.set_clip(this.clip)
	}
	start() {
		if (this.play_on_start) this.play()
	}
	update(_dt: number) {
		if (this.voice === 0) return
		const m = mixer()
		if (!m.is_playing(this.voice)) {
			this.voice = 0
			return
		}
		const [vol, pan] = this.spatial_mix()
		m.set_volume(this.voice, this.volume * vol)
		m.set_pan(this.voice, pan)
		m.set_pitch(this.voice, this.pitch)
	}
	on_destroy() {
		this.stop()
		this.release_clip()
	}
	set_clip(r: assets.AssetRef) {
		this.stop()
		this.release_clip()
		this.clip = r.clone()
		if (!r.is_set() || !this.node || !this.node.scene || !this.node.scene.assets) return
		try {
			this.loaded = this.node.scene.assets.get<assets.AudioClip>(assets.AudioClip, r)
		} catch (e) {
			console.error(`[audio] ${this.node.path()}: ${V.as_error(e).message}`)
		}
	}
	release_clip() {
		if (this.loaded !== null && this.node && this.node.scene && this.node.scene.assets) this.node.scene.assets.release(this.loaded.id)
		this.loaded = null
	}
	sound(): Sound | null {
		if (this.loaded === null) return null
		try {
			return mixer().load(this.loaded)
		} catch (e) {
			console.error(`[audio] ${V.as_error(e).message}`)
			return null
		}
	}
	play() {
		const m = mixer()
		m.stop(this.voice, 0)
		const snd = this.sound()
		if (snd === null) {
			this.voice = 0
			return
		}
		const [vol, pan] = this.spatial_mix()
		this.voice = m.play(snd, { volume: this.volume * vol, pitch: this.pitch, pan, looping: this.looping, bus: this.bus })
	}
	play_one_shot() {
		const snd = this.sound()
		if (snd === null) return
		const [vol, pan] = this.spatial_mix()
		mixer().play(snd, { volume: this.volume * vol, pitch: this.pitch, pan, bus: this.bus })
	}
	stop() {
		if (this.voice !== 0) {
			mixer().stop(this.voice, this.fade_out)
			this.voice = 0
		}
	}
	pause() {
		mixer().pause(this.voice)
	}
	resume() {
		mixer().resume(this.voice)
	}
	is_playing(): boolean {
		return mixer().is_playing(this.voice)
	}
	spatial_mix(): [number, number] {
		if (!this.spatial || !this.node || !this.node.scene) return [1, 0]
		const sc = this.node.scene
		let listener = sc.view_center()
		let half_w = sc.view_size.x / 2
		const cam = sc.active_camera()
		if (cam !== null) {
			listener = cam.center()
			half_w /= cam.zoom > 0.001 ? cam.zoom : 1
		}
		return spatial_gain(this.node.world_position(), listener, this.range, half_w)
	}
}

export function spatial_gain(p: core.Vec2, listener: core.Vec2, range: number, half_width: number): [number, number] {
	const d = p.distance(listener)
	const vol = range > 0 ? Math.min(Math.max(1 - d / range, 0), 1) : 1
	const pan = half_width > 0 ? Math.min(Math.max((p.x - listener.x) / half_width, -1), 1) * 0.8 : 0
	return [vol, pan]
}

export function register_builtins(r: serialize.Registry) {
	r.register(AudioSource)
}
