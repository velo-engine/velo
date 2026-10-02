module audio

import time

// Chosen at compile time: the web and iOS builds have no usable threads/semaphores (V needs sem_timedwait on iOS).

$if !(emscripten ? || ios) {
// how often the audio thread tops up the device queue (it holds ~46 ms)
const fill_interval = 4 * time.millisecond

// AudioThread (desktop, Android) — mixes into the device queue every few milliseconds, independent of the
// frame rate. It is a V thread (known to the GC); the game reaches the mixer through its lock.
struct AudioThread {
mut:
	quit   chan bool
	handle thread
	on     bool
}

fn (mut t AudioThread) start() {
	t.quit = chan bool{cap: 1}
	t.handle = spawn audio_loop(t.quit)
	t.on = true
}

fn (t &AudioThread) running() bool {
	return t.on
}

fn (mut t AudioThread) stop() {
	if !t.on {
		return
	}
	t.quit <- true
	t.handle.wait()
	t.on = false
}

fn audio_loop(quit chan bool) {
	for {
		fill()
		select {
			_ := <-quit {
				return
			}
			fill_interval {}
		}
	}
}
}
