module render3d

import velo.assets
import velo.model3d

// Parsed models, shared by every component showing the same asset (one parse and one GPU upload per file).
@[heap]
struct ModelCache {
mut:
	models map[string]&CachedModel
}

struct CachedModel {
mut:
	model &model3d.Model
	refs  int
	path  string
}

const model_cache = &ModelCache{}

fn cache() &ModelCache {
	return model_cache
}

// acquire_model parses the model asset on first use (nil if it cannot be read; the error is printed once).
fn acquire_model(mut db assets.AssetDatabase, id string) &model3d.Model {
	mut c := cache()
	key := db.resolve(id) or { id }
	if mut cm := c.models[key] {
		cm.refs++
		return cm.model
	}
	a := db.load[assets.Model](key) or {
		eprintln('[render3d] model ${id}: ${err}')
		c.models[key] = &CachedModel{
			model: unsafe { nil }
			refs:  1
		}
		return unsafe { nil }
	}
	m := model3d.load_fbx(a.path) or {
		eprintln('[render3d] ${err}')
		unsafe { nil }
	}
	if m != unsafe { nil } {
		println('[render3d] loaded ${a.path.all_after_last('/')}: ${m.triangle_count()} triangles, ${m.bones.len} bones, ${m.clips.len} clips')
	}
	c.models[key] = &CachedModel{
		model: m
		refs:  1
		path:  a.path
	}
	return m
}

fn release_model(id string) {
	mut c := cache()
	for key, mut cm in c.models {
		if key == id || cm.path.ends_with(id) {
			cm.refs--
			return
		}
	}
}

// preload_model parses a model ahead of time (e.g. while a loading screen shows), so the first frame that
// shows it does not stall.
pub fn preload_model(mut db assets.AssetDatabase, key string) bool {
	m := acquire_model(mut db, key)
	return m != unsafe { nil }
}
