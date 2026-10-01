module audio

// AudioThread (web) — the browser build has no threads: pump() fills the device queue once per frame.
struct AudioThread {}

fn (mut t AudioThread) start() {}

fn (t &AudioThread) running() bool {
	return false
}

fn (mut t AudioThread) stop() {}
