// Save data for web builds: the browser's localStorage (files written in a browser live in memory and are
// lost on reload). Values are text; `velo_ls_len` returns the size needed to copy one, including the final 0.
#include <emscripten.h>

EM_JS(void, velo_ls_set, (const char* key, const char* value), {
	try { localStorage.setItem(UTF8ToString(key), UTF8ToString(value)); } catch (e) { console.warn('velo: cannot save', e); }
});

EM_JS(int, velo_ls_len, (const char* key), {
	var v = null;
	try { v = localStorage.getItem(UTF8ToString(key)); } catch (e) {}
	return v === null ? -1 : lengthBytesUTF8(v) + 1;
});

EM_JS(void, velo_ls_get, (const char* key, char* out, int size), {
	var v = null;
	try { v = localStorage.getItem(UTF8ToString(key)); } catch (e) {}
	stringToUTF8(v === null ? '' : v, out, size);
});
