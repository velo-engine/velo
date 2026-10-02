module audio

// Chosen at compile time: the web and iOS builds have no usable threads/semaphores (V needs sem_timedwait on iOS).

$if emscripten ? || ios {
// AudioThread (web) — the browser build has no threads: pump() fills the device queue once per frame.
struct AudioThread {}

fn (mut t AudioThread) start() {}

fn (t &AudioThread) running() bool {
	return false
}

fn (mut t AudioThread) stop() {}
}
