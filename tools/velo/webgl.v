module main

import os
import time
import hash.fnv1a

// WebGL builds: the game's V code is translated to JavaScript and runs on the engine's TypeScript runtime
// (webgl/runtime), drawing with WebGL — no Emscripten, small downloads, instant start.
//   velo build webgl [dir] [--release] [-o <dir>]   writes <out>/index.html + game.js + assets/
//   velo run webgl [dir]                            builds, then serves it on http://localhost:8080
//
// Steps: tools/v2js (built once, cached in <engine>/build/tools) type-checks the game with the V compiler
// and writes one .js file per V module; esbuild bundles them with the runtime into game.js; the assets are
// copied next to it with assets.json, the list the runtime downloads before the game starts.

const webgl_shell = $embed_file('../../webgl/shell.html').to_string()

fn find_node_tool(name string) string {
	return os.find_abs_path_of_executable(name) or {
		fail('`${name}` not found — WebGL builds need Node.js (https://nodejs.org, or `brew install node`)')
	}
}

// ensure_webgl_deps installs esbuild into <engine>/webgl/node_modules the first time.
fn ensure_webgl_deps(home string) string {
	dir := os.join_path(home, 'webgl')
	esbuild := os.join_path(dir, 'node_modules', '.bin', 'esbuild')
	if !os.is_file(esbuild) {
		npm := find_node_tool('npm')
		step('installing the WebGL build tools (esbuild) into ${dir}')
		os.chdir(dir) or { fail(err.msg()) }
		must(npm, ['install', '--no-audit', '--no-fund'])
	}
	return esbuild
}

// ensure_v2js builds tools/v2js (the V -> JavaScript translator) when it is missing or older than its sources.
fn ensure_v2js(home string) string {
	src := os.join_path(home, 'tools', 'v2js')
	bin_dir := os.join_path(home, 'build', 'tools')
	bin := os.join_path(bin_dir, 'v2js')
	mut stale := !os.is_file(bin)
	if !stale {
		built := os.file_last_mod_unix(bin)
		for f in os.ls(src) or { []string{} } {
			if f.ends_with('.v') && os.file_last_mod_unix(os.join_path(src, f)) > built {
				stale = true
				break
			}
		}
	}
	if stale {
		os.mkdir_all(bin_dir) or { fail(err.msg()) }
		step('building the V -> JavaScript translator (tools/v2js)')
		must(vexe(), ['-o', bin, src])
	}
	return bin
}

fn build_webgl(home string, p Project, o MobileOptions) {
	find_node_tool('node')
	b := WebglBuild{
		home:    home
		p:       p
		o:       o
		esbuild: ensure_webgl_deps(home)
		v2js:    ensure_v2js(home)
		out_dir: if o.output != '' { o.output } else { p.build_dir('webgl') }
	}
	if !b.build() {
		fail('WebGL build failed')
	}
	if o.run {
		b.serve_and_watch()
	}
}

struct WebglBuild {
	home    string
	p       Project
	o       MobileOptions
	esbuild string
	v2js    string
	out_dir string
}

// build translates, bundles and packages the game; false (with the errors printed) when a step fails.
fn (b WebglBuild) build() bool {
	p := b.p
	step('checking assets')
	if assetdb(b.home, p.assets_dir(), ['check']) != 0 {
		eprintln('velo: fix the asset errors above (see `velo assets check`)')
		return false
	}
	gen_dir := os.join_path(p.dir, 'build', '.webgl-gen') // the translated modules, before bundling
	os.rmdir_all(gen_dir) or {}
	os.mkdir_all(b.out_dir) or { fail(err.msg()) }

	step('translating ${p.name} to JavaScript')
	os.setenv('VELO_HOME', b.home, true)
	if run(b.v2js, [p.dir, '-o', gen_dir]) != 0 {
		return false
	}

	step('bundling${if b.o.release { ' (release)' } else { '' }}')
	runtime := os.join_path(b.home, 'webgl', 'runtime', 'index.ts')
	mut args := [os.join_path(gen_dir, 'entry.js'), '--bundle', '--format=esm', '--target=es2020',
		'--keep-names', '--alias:velo-runtime=${runtime}',
		'--outfile=${os.join_path(b.out_dir,
			'game.js')}', '--log-level=warning']
	if b.o.release {
		args << ['--minify']
	} else {
		args << ['--sourcemap']
	}
	if run(b.esbuild, args) != 0 {
		return false
	}

	// assets + the list the runtime downloads
	assets_out := os.join_path(b.out_dir, 'assets')
	os.rmdir_all(assets_out) or {}
	mut entries := []string{}
	for rel in packaged_assets(p) {
		if rel.ends_with('.meta') {
			continue
		}
		src := os.join_path(p.assets_dir(), rel)
		dst := os.join_path(assets_out, rel)
		os.mkdir_all(os.dir(dst)) or { fail(err.msg()) }
		os.cp(src, dst) or { fail(err.msg()) }
		entries << manifest_entry(src, rel)
	}
	os.write_file(os.join_path(assets_out, 'assets.json'), '{"entries": [\n' + entries.join(',\n') +
		'\n]}\n') or { fail(err.msg()) }
	// `velo run webgl` pages reload themselves when the game is rebuilt (see serve.mjs)
	dev := if b.o.run { webgl_live_reload } else { '' }
	os.write_file(os.join_path(b.out_dir, 'index.html'), webgl_shell.replace('{{TITLE}}',
		html_escape(p.name)).replace('{{DEV}}', dev)) or { fail(err.msg()) }
	step('built ${os.join_path(b.out_dir, 'index.html')} (${entries.len} assets)')
	return true
}

const webgl_live_reload = "<script>new EventSource('/__velo_events').onmessage = (e) => { if (e.data === 'reload') location.reload() }</script>"

// serve_and_watch serves the build on localhost:8080 (module scripts and fetch() do not work from file://),
// opens it, and rebuilds when a .v file or an asset changes; the page then reloads itself.
fn (b WebglBuild) serve_and_watch() {
	node := find_node_tool('node')
	url := 'http://localhost:8080/'
	mut server := os.new_process(node)
	server.set_args([os.join_path(b.home, 'webgl', 'serve.mjs'), b.out_dir, '8080'])
	server.run()
	step('serving on ${url} — edit the game and it rebuilds; Ctrl+C to stop')
	opener := $if macos {
		'open'
	} $else $if windows {
		'explorer'
	} $else {
		'xdg-open'
	}
	if os.getenv('VELO_NO_OPEN') == '' && os.find_abs_path_of_executable(opener) or { '' } != '' {
		spawn fn [opener, url] () {
			time.sleep(800 * time.millisecond) // let the server start listening first
			os.execute('${opener} ${url}')
		}()
	}
	mut last := b.sources_stamp()
	for server.is_alive() {
		time.sleep(400 * time.millisecond)
		stamp := b.sources_stamp()
		if stamp == last {
			continue
		}
		last = stamp
		step('change detected, rebuilding')
		if b.build() {
			os.write_file(os.join_path(b.out_dir, '.velo-version'), time.now().unix_milli().str()) or {}
		}
	}
	server.wait()
	exit(server.code)
}

// sources_stamp changes whenever a V source of the game or an asset is added, removed or modified.
fn (b WebglBuild) sources_stamp() string {
	mut parts := []string{}
	for f in os.walk_ext(b.p.dir, '') {
		rel := f.all_after(b.p.dir)
		if rel.contains('/build/') || rel.contains('/.') {
			continue
		}
		if f.ends_with('.v') || rel.starts_with('/assets/') {
			parts << '${rel}:${os.file_last_mod_unix(f)}:${os.file_size(f)}'
		}
	}
	parts.sort()
	return parts.join('|')
}

// manifest_entry describes one asset for the runtime: ID, kind and settings from its .meta, references.
fn manifest_entry(path string, rel string) string {
	meta := os.read_file(path + '.meta') or {
		fail('${rel}.meta is missing (run `velo assets check`)')
	}
	mut id := ''
	mut kind := 'unknown'
	mut settings := []string{}
	for raw in meta.split_into_lines() {
		line := raw.trim_space()
		if line == '' || line.starts_with('#') || !line.contains(':') {
			continue
		}
		key := line.all_before(':').trim_space()
		val := line.all_after(':').trim_space()
		match key {
			'id' { id = val }
			'kind' { kind = val }
			'version' {}
			else { settings << '${json_str(key)}: ${json_str(val)}' }
		}
	}
	data := os.read_bytes(path) or { fail(err.msg()) }
	mut deps := []string{}
	if kind in ['scene', 'text'] {
		src := data.bytestr()
		mut i := 0
		for {
			idx := src.index_after('@asset("', i) or { break }
			start := idx + 8
			end := src.index_after('"', start) or { break }
			dep := src[start..end]
			if dep !in deps {
				deps << dep
			}
			i = end + 1
		}
	}
	return '  {"id": ${json_str(id)}, "path": ${json_str(rel)}, "kind": ${json_str(kind)}, "settings": {${settings.join(', ')}}, "deps": [${deps.map(json_str(it)).join(', ')}], "bytes": ${data.len}, "hash": ${fnv1a.sum32(data)}}'
}

fn json_str(s string) string {
	mut out := []u8{cap: s.len + 2}
	out << `"`
	for c in s.bytes() {
		match c {
			`"` { out << '\\"'.bytes() }
			`\\` { out << '\\\\'.bytes() }
			`\n` { out << '\\n'.bytes() }
			`\r` { out << '\\r'.bytes() }
			`\t` { out << '\\t'.bytes() }
			else { out << c }
		}
	}
	out << `"`
	return out.bytestr()
}

fn html_escape(s string) string {
	return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')
}
