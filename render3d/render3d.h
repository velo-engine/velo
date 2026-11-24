// Helpers for sokol_gfx fields V's bindings do not expose as writable.
static inline void velo3d_depth(sg_pipeline_desc* d, int compare, bool write) {
	d->depth.compare = (sg_compare_func)compare;
	d->depth.write_enabled = write;
}
