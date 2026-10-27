module app

$if android {
	#include "@VMODROOT/app/android_gc.h"
}

fn C.velo_android_gc_register_thread()
fn C.velo_android_gc_collect()

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
