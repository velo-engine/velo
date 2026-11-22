// Android GC support for Boehm GC when running on sokol's render thread.
#pragma once

#if defined(_VGCBOEHM) || defined(CUSTOM_DEFINE_gcboehm)
#include <link.h>
#include <stdint.h>

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

static inline void velo_android_gc_disable(void) {
	GC_disable();
}

static inline void velo_android_gc_enable(void) {
	GC_enable();
}

// Make the writable segments (.data/.bss) of this game library GC roots: V globals and consts (e.g. module
// singletons like the analytics manager) live there and must keep their heap objects alive. libgc's own
// dynamic-library scan is not reliable for an app .so loaded by Android's NativeActivity; adding the
// range again is harmless (overlapping roots are merged).
static int velo_android_gc_phdr_cb(struct dl_phdr_info* info, size_t size, void* data) {
	(void)size;
	uintptr_t self = (uintptr_t)data;
	int mine = 0;
	for (int i = 0; i < info->dlpi_phnum; i++) {
		const ElfW(Phdr)* p = &info->dlpi_phdr[i];
		uintptr_t start = (uintptr_t)info->dlpi_addr + p->p_vaddr;
		if (p->p_type == PT_LOAD && self >= start && self < start + p->p_memsz) {
			mine = 1;
		}
	}
	if (!mine) {
		return 0;
	}
	for (int i = 0; i < info->dlpi_phnum; i++) {
		const ElfW(Phdr)* p = &info->dlpi_phdr[i];
		if (p->p_type == PT_LOAD && (p->p_flags & PF_W)) {
			char* start = (char*)(info->dlpi_addr + p->p_vaddr);
			GC_add_roots(start, start + p->p_memsz);
		}
	}
	return 1;
}

static int velo_android_gc_roots_added = 0;
static inline void velo_android_gc_add_lib_roots(void) {
	if (!velo_android_gc_roots_added) {
		velo_android_gc_roots_added = 1;
		dl_iterate_phdr(velo_android_gc_phdr_cb, (void*)&velo_android_gc_roots_added);
	}
}

// The Android UI (Java main) thread runs sokol_main, where V's GC_INIT() registers it with the collector. Once
// sokol_main returns, that thread lives in the Java Looper and never runs V code again, so it is unregistered
// (libgc allows that once for the main thread) instead of being stopped and scanned on every collection.
static inline void velo_android_gc_release_ui_thread(void) {
	velo_android_gc_add_lib_roots();
#if defined(GC_THREADS)
	if (GC_thread_is_registered()) {
		GC_unregister_my_thread();
	}
#endif
}

// On Android, V's fontstash module allocates with plain malloc (`$if gcboehm ? && !android` in
// vlib/fontstash/fontstash.c.v), so the font file bytes that gg hands to fonsAddFontMem() (a GC allocation) are
// referenced only from memory the collector never scans. The GC then frees the font and stb_truetype reads garbage
// (assert in stbtt__GetGlyphShapeTT / crash). Keep every font's data reachable from an uncollectable block.
static int velo_android_gc_pinned_fonts = 0;
static void** velo_android_gc_font_pins = NULL;

static inline void velo_android_gc_pin_fonts(void* ctx) {
#if defined(FONTSTASH_IMPLEMENTATION)
	FONScontext* s = (FONScontext*)ctx;
	if (s == NULL || s->nfonts <= velo_android_gc_pinned_fonts) {
		return;
	}
	void** pins = (void**)GC_MALLOC_UNCOLLECTABLE((size_t)s->nfonts * sizeof(void*));
	for (int i = 0; i < s->nfonts; i++) {
		pins[i] = (s->fonts[i] != NULL) ? (void*)s->fonts[i]->data : NULL;
	}
	if (velo_android_gc_font_pins != NULL) {
		GC_FREE(velo_android_gc_font_pins);
	}
	velo_android_gc_font_pins = pins;
	velo_android_gc_pinned_fonts = s->nfonts;
#else
	(void)ctx;
#endif
}
#else
static inline void velo_android_gc_register_thread(void) {}
static inline void velo_android_gc_collect(void) {}
static inline void velo_android_gc_disable(void) {}
static inline void velo_android_gc_enable(void) {}
static inline void velo_android_gc_release_ui_thread(void) {}
static inline void velo_android_gc_pin_fonts(void* ctx) { (void)ctx; }
#endif
