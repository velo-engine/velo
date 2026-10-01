module app

import time
import velo.assets
import velo.render
import velo.audio

// LoadJob — one asset to decode ahead of time. Plain values only: it crosses to a worker thread.
struct LoadJob {
	id      string
	version int
	path    string
	audio   bool
	stream  string // AudioClip.stream
}

struct LoadResult {
	job   LoadJob
	image render.DecodedImage
	sound audio.Sound
	err   string
}

// run_job does the slow part of loading (read + decode), touching no engine state; any thread may run it.
fn run_job(job LoadJob) LoadResult {
	if job.audio {
		s := audio.decode_file(job.path, job.stream) or {
			return LoadResult{
				job: job
				err: err.msg()
			}
		}
		return LoadResult{
			job:   job
			sound: s
		}
	}
	img := render.decode_image(job.path) or { return LoadResult{
		job: job
		err: err.msg()
	} }
	return LoadResult{
		job:   job
		image: img
	}
}

// Preloader — decodes the textures and sounds of the next scene on worker threads (one frame at a time on the
// web) while the old scene fades out, so the switch and the first frames of the new scene do not stall.
// The main thread only uploads the results (adopt_image / Mixer.adopt). An asset still missing when the scene
// starts is loaded the old way, on first draw / first play.
struct Preloader {
mut:
	textures map[string]&assets.Texture // held (one reference each) until release()
	clips    map[string]&assets.AudioClip
	queue    []LoadJob // not handed to the pool yet
	pending  int       // handed to the pool, result not back yet
	total    int
	clock    time.StopWatch
	pool     WorkerPool
}

// start queues every texture and sound that the scene `key` uses (directly or through prefabs).
fn (mut p Preloader) start(mut db assets.AssetDatabase, r &render.Renderer, key string) {
	id := db.resolve(key) or { return }
	if p.total == 0 {
		p.clock = time.new_stopwatch()
	}
	for dep in db.dependencies_deep(id) {
		e := db.entry(dep) or { continue }
		if e.kind == .texture && dep !in p.textures {
			t := db.load[assets.Texture](dep) or { continue }
			p.textures[dep] = t
			if !r.has_image(t) {
				p.queue << LoadJob{
					id:      dep
					version: t.version
					path:    t.path
				}
			}
		} else if e.kind == .audio && dep !in p.clips {
			c := db.load[assets.AudioClip](dep) or { continue }
			p.clips[dep] = c
			if !audio.mixer().has(c) {
				p.queue << LoadJob{
					id:      dep
					version: c.version
					path:    c.path
					audio:   true
					stream:  c.stream
				}
			}
		}
	}
	p.total += p.queue.len
}

// pump hands queued jobs to the pool and uploads the finished ones. Call it once per frame.
fn (mut p Preloader) pump(mut r render.Renderer) {
	p.pool.begin_frame()
	for p.queue.len > 0 && p.pool.submit(p.queue[0]) {
		p.queue.delete(0)
		p.pending++
	}
	for {
		res := p.pool.poll() or { break }
		p.pending--
		p.finish(res, mut r)
	}
}

fn (mut p Preloader) finish(res LoadResult, mut r render.Renderer) {
	job := res.job
	if res.err != '' {
		eprintln('[velo] preload ${job.path}: ${res.err}')
		return
	}
	if job.audio {
		c := p.clips[job.id] or { return }
		if c.version == job.version {
			mut m := audio.mixer()
			m.adopt(c, res.sound)
		}
		return
	}
	t := p.textures[job.id] or {
		render.free_decoded(res.image)
		return
	}
	if t.version != job.version {
		// changed on disk meanwhile (hot reload): the first draw reads the new file
		render.free_decoded(res.image)
		return
	}
	r.adopt_image(t, res.image)
}

fn (p &Preloader) done() bool {
	return p.queue.len == 0 && p.pending == 0
}

// progress: 0..1 over everything started since the last release.
fn (p &Preloader) progress() f32 {
	if p.total == 0 {
		return 1
	}
	return f32(p.total - p.queue.len - p.pending) / f32(p.total)
}

// release drops the references taken by start; call it once the new scene holds its own.
fn (mut p Preloader) release(mut db assets.AssetDatabase) {
	if p.total > 0 {
		println('[velo] decoded ${p.total} assets ahead in ${p.clock.elapsed().milliseconds()} ms')
	}
	for id, _ in p.textures {
		db.release(id)
	}
	for id, _ in p.clips {
		db.release(id)
	}
	p.textures.clear()
	p.clips.clear()
	p.total = 0
}
