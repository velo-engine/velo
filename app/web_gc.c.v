module app

// Web builds only: see web_gc.h (collect between frames, from the JS event loop).
$if emscripten ? && gcboehm ? {
	#include "@VMODROOT/app/web_gc.h"
}

fn C.velo_web_gc_setup(interval_ms f64)

fn setup_web_gc() {
	$if emscripten ? && gcboehm ? {
		C.velo_web_gc_setup(1000)
	}
}
