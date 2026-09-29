// Garbage collection for web builds (`velo build web` uses -gc boehm). Collecting in the middle of wasm
// code is unsafe: pointers that live only in wasm locals are invisible to a conservative GC. So automatic
// collection is off, and a JS timer collects between frames, when no wasm function is on the stack and
// every live object is reachable from the heap or static data (registered as roots here).
#include <emscripten.h>
// gc.h is already included by V (builtin) when building with -gc boehm.

extern char __global_base;
extern char __heap_base;

static void velo_web_gc_tick(void* user_data) {
	(void)user_data;
	GC_enable();
	GC_gcollect();
	GC_disable();
}

static void velo_web_gc_setup(double interval_ms) {
	GC_disable();
	GC_add_roots(&__global_base, &__heap_base);
	emscripten_set_interval(velo_web_gc_tick, interval_ms, 0);
}
