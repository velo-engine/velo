module main

import os

// Web (browser) builds, via Emscripten:
//   velo build web [dir] [--release] [-o <dir>]   writes <out>/index.html + .js + .wasm + .data
//   velo run web [dir]                            builds, then serves the page and opens the browser (emrun)
//
// V drives the compile as usual, but through a small `emcc` wrapper (written next to the build) that
// works around two V 0.5.2 + Emscripten problems before calling the real emcc:
//   - V's generated C declares `stdin/stdout/stderr` without `const`, which Emscripten's musl rejects;
//   - `gg` embeds a font from V's examples/, which V installs (e.g. Homebrew) may not ship.
// The project's assets/ are preloaded at /assets (see app.runtime_assets_dir); text uses the first
// .ttf in assets/fonts/, since a browser has no font files of its own.

// The emcc wrapper and the HTML page, embedded into the velo tool (see web/).
const web_emcc_wrapper = $embed_file('web/emcc.sh').to_string()
const web_shell = $embed_file('web/shell.html').to_string()

fn find_emcc() string {
	return os.find_abs_path_of_executable('emcc') or {
		fail('`emcc` (Emscripten) not found — install it: `brew install emscripten`, or see https://emscripten.org/docs/getting_started/downloads.html')
	}
}

fn build_web(home string, p Project, o MobileOptions) {
	emcc := find_emcc()
	prepare_mobile_build(home, p)
	if uses_physics(p) {
		fail('velo.physics is not supported on the web yet (Box2D is not built for Emscripten)')
	}
	fonts := os.join_path(p.assets_dir(), 'fonts')
	if !(os.ls(fonts) or { []string{} }).any(it.ends_with('.ttf')) {
		warn('no .ttf in assets/fonts/ — the web build falls back to an ASCII-only font')
	}

	out_dir := if o.output != '' { o.output } else { p.build_dir('web') }
	os.mkdir_all(out_dir) or { fail(err.msg()) }
	for f in os.ls(out_dir) or { []string{} } {
		if f.starts_with('index.') {
			os.rm(os.join_path(out_dir, f)) or {}
		}
	}
	tool_dir := os.join_path(p.build_dir('web'), '.toolchain')
	os.mkdir_all(tool_dir) or { fail(err.msg()) }
	wrapper :=
		os.join_path(tool_dir, 'emcc') // must be named emcc: V picks its Emscripten mode from it
	os.write_file(wrapper, web_emcc_wrapper) or { fail(err.msg()) }
	os.chmod(wrapper, 0o755) or { fail(err.msg()) }
	shell := os.join_path(tool_dir, 'shell.html')
	os.write_file(shell, web_shell.replace('{{TITLE}}', p.name)) or { fail(err.msg()) }

	// Only the packaged files (no hidden files, no library/ cache) are preloaded.
	staged := os.join_path(tool_dir, 'assets')
	os.rmdir_all(staged) or {}
	for rel in packaged_assets(p) {
		dst := os.join_path(staged, rel)
		os.mkdir_all(os.dir(dst)) or { fail(err.msg()) }
		os.cp(os.join_path(p.assets_dir(), rel), dst) or { fail(err.msg()) }
	}

	optimize := if o.release { '-O3' } else { '-O2' }
	cflags := [
		optimize,
		'-Wno-incompatible-pointer-types',
		'-Wno-incompatible-function-pointer-types',
		// V 0.5.2's vmemcpy/vmemmove treat pointers <= 0xFFFF as invalid and silently skip the copy; wasm
		// puts static data (string literals, constant arrays) right there, so start it at 64 KiB instead.
		'-sGLOBAL_BASE=65536',
		'-sALLOW_MEMORY_GROWTH=1',
		'-sSTACK_SIZE=4MB',
		'--preload-file ${os.quoted_path(staged)}@/assets',
		'--shell-file ${os.quoted_path(shell)}',
	].join(' ')
	os.setenv('VELO_REAL_EMCC', emcc, true)
	// A failed C compile must not upload the generated code anywhere (V 0.5.2 reports C errors by default).
	os.setenv('V_C_ERROR_BUG_REPORT_DISABLED', '1', true)
	step('building ${p.name} for the web${if o.release { ' (release)' } else { '' }}')
	// Boehm GC from V's bundled sources, single-threaded; app/web_gc.h collects between frames.
	mut args := ['-os', 'wasm32_emscripten', '-gc', 'boehm', '-d', 'use_bundled_libgc', '-d',
		'no_gc_threads', '-cc', wrapper, '-cflags', cflags, '-o', os.join_path(out_dir, 'index.html')]
	// No `-prod` here: V 0.5.2's -prod builds crash on wasm ("Probe overflow" in maps); --release only
	// raises the emcc optimization level (-O3 above).
	args << p.dir
	if v_cmd(home, args, []) != 0 {
		fail('web build failed')
	}
	step('built ${os.join_path(out_dir, 'index.html')}')
	if o.run {
		serve_web(emcc, out_dir)
	}
}

// serve_web serves the build over http (browsers do not run WebAssembly from file://) and opens it.
fn serve_web(emcc string, dir string) {
	emrun := os.join_path(os.dir(os.real_path(emcc)), 'emrun')
	page := os.join_path(dir, 'index.html')
	if os.is_file(emrun) {
		step('serving on http://localhost:8080 — Ctrl+C to stop')
		exit(run(emrun, ['--no-emrun-detect', '--port', '8080', page]))
	}
	python := os.find_abs_path_of_executable('python3') or {
		fail('serve ${dir} with any static web server (e.g. `python3 -m http.server`) and open index.html')
	}
	step('serving on http://localhost:8080/index.html — Ctrl+C to stop')
	exit(run(python, ['-m', 'http.server', '8080', '--directory', dir]))
}
