// Android GC support for Boehm GC when running on sokol's render thread.
#pragma once

#if defined(_VGCBOEHM) || defined(CUSTOM_DEFINE_gcboehm)

static inline void velo_android_gc_register_thread(void) {
#if defined(GC_THREADS)
	GC_allow_register_threads();
	struct GC_stack_base sb;
	if (GC_get_stack_base(&sb) == 0) {
		GC_register_my_thread(&sb);
	}
#endif
}

static inline void velo_android_gc_collect(void) {
	GC_gcollect();
}
#else
static inline void velo_android_gc_register_thread(void) {}
static inline void velo_android_gc_collect(void) {}
#endif
