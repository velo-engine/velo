module app

// Chosen at compile time: the web and iOS builds have no usable threads/semaphores (V needs sem_timedwait on iOS).

$if emscripten ? || ios {
import time

// a frame may spend this long decoding before the rest waits for the next frame
const web_load_budget = 8 * time.millisecond

// WorkerPool (web) — the browser build has no threads: jobs run on the main thread, a few per frame,
// so a scene change fade keeps moving while the next scene loads.
struct WorkerPool {
mut:
	done  []LoadResult
	frame time.StopWatch
}

fn (mut w WorkerPool) begin_frame() {
	w.frame = time.new_stopwatch()
}

fn (mut w WorkerPool) submit(job LoadJob) bool {
	if w.frame.elapsed() > web_load_budget {
		return false
	}
	w.done << run_job(job)
	return true
}

fn (mut w WorkerPool) poll() ?LoadResult {
	if w.done.len == 0 {
		return none
	}
	return w.done.pop()
}

fn (mut w WorkerPool) close() {}
}
