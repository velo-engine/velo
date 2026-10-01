module app

import runtime

// WorkerPool (desktop, Android, iOS) — a few threads that decode assets (see Preloader). They only run run_job,
// which reads files and returns fresh buffers, so no engine state is shared with the main thread.
struct WorkerPool {
mut:
	jobs    chan LoadJob
	results chan LoadResult
	started bool
}

fn (mut w WorkerPool) begin_frame() {}

// submit hands a job to the workers; false when they are busy enough (it stays queued for the next frame).
fn (mut w WorkerPool) submit(job LoadJob) bool {
	if !w.started {
		w.start()
	}
	return w.jobs.try_push(job) == .success
}

fn (mut w WorkerPool) poll() ?LoadResult {
	if !w.started {
		return none
	}
	mut res := LoadResult{}
	if w.results.try_pop(mut res) == .success {
		return res
	}
	return none
}

fn (mut w WorkerPool) start() {
	w.jobs = chan LoadJob{cap: 32}
	w.results = chan LoadResult{cap: 32}
	mut n := runtime.nr_cpus() - 1 // leave a core to the main thread
	n = if n < 1 {
		1
	} else if n > 4 {
		4
	} else {
		n
	}
	for _ in 0 .. n {
		spawn load_worker(w.jobs, w.results)
	}
	w.started = true
}

fn (mut w WorkerPool) close() {
	if w.started {
		w.jobs.close()
	}
}

fn load_worker(jobs chan LoadJob, results chan LoadResult) {
	for {
		job := <-jobs or { return }
		results <- run_job(job)
	}
}
