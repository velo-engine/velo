module app

import gg

$if android {
	#include "@VMODROOT/app/android_gc.h"
}

fn C.velo_android_gc_register_thread()
fn C.velo_android_gc_collect()
fn C.velo_android_gc_release_ui_thread()
fn C.velo_android_gc_disable()
fn C.velo_android_gc_enable()
fn C.velo_android_gc_pin_fonts(voidptr)

fn android_gc_register_thread() {
	$if android {
		C.velo_android_gc_register_thread()
	}
}

fn android_gc_collect() {
	$if android {
		C.velo_android_gc_collect()
	}
}

// android_gc_release_ui_thread unregisters the Java UI thread from the GC once sokol_main has handed control to
// sokol's render thread (see android_gc.h).
fn android_gc_release_ui_thread() {
	$if android {
		C.velo_android_gc_release_ui_thread()
	}
}

// android_gc_pause stops collections until android_gc_resume: from handing over to sokol's render thread until
// gg's font is pinned (see android_gc.h), so no collection can free the font in between.
fn android_gc_pause() {
	$if android {
		C.velo_android_gc_disable()
	}
}

fn android_gc_resume() {
	$if android {
		C.velo_android_gc_enable()
	}
}

// android_gc_pin_fonts keeps gg's font data alive (fontstash holds it in malloc'd memory on Android).
fn android_gc_pin_fonts(ctx &gg.Context) {
	$if android {
		if ctx.ft != unsafe { nil } {
			C.velo_android_gc_pin_fonts(voidptr(ctx.ft.fons))
		}
	}
}
