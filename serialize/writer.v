module serialize

import os
import velo.core

// save_node converts a node tree into .scene text.
// Nodes that are prefab instances only write what DIFFERS from the source prefab, so scene files stay short
// and editing the source prefab propagates everywhere it is used (except for overridden fields).
//
// If the root has a prefab_id (an instance, or the root of a prefab variant opened with load_document)
// the file is written as `node X from @asset(...) { ... }`.
pub fn (mut l SceneLoader) save_node(n &core.Node) !string {
	lines := l.write_node(n, none, 0)!
	return lines.join('\n') + '\n'
}

pub fn (mut l SceneLoader) save_to_file(n &core.Node, path string) ! {
	os.write_file(path, l.save_node(n)!)!
}

const default_node = core.Node{}

// write_node returns the text lines of a node. `reference` is the corresponding node in the source prefab
// (if any) — in that case only the differences are written, and [] is returned if nothing differs.
fn (mut l SceneLoader) write_node(n &core.Node, reference ?&core.Node, depth int) ![]string {
	pad := '  '.repeat(depth)
	mut body := []string{}
	mut header := 'node ${ident_or_quoted(n.name)} {'
	mut ref := unsafe { reference }

	if n.prefab_id != '' && reference == none {
		header = 'node ${ident_or_quoted(n.name)} from @asset("${n.prefab_id}") {'
		ref = l.instantiate(n.prefab_id)!
	}

	// Node properties
	base := ref or { &default_node }
	if n.position != base.position {
		body << '${pad}  position = ${vec2_value(n.position).to_text()}'
	}
	if n.rotation != base.rotation {
		body << '${pad}  rotation = ${Value(f64(n.rotation)).to_text()}'
	}
	if n.scale != base.scale {
		body << '${pad}  scale = ${vec2_value(n.scale).to_text()}'
	}
	if n.active != base.active {
		body << '${pad}  active = ${n.active}'
	}

	// Component
	for c in n.components {
		tname := core.short_type_name(c.type_name())
		t := l.registry.get(tname) or {
			body << '${pad}  # (skipped ${tname}: not registered with the Registry)'
			continue
		}
		now := t.dump(c)
		mut before := map[string]Value{}
		mut in_ref := false
		if r := ref {
			if rc := r.component_by_type_name(tname) {
				before = t.dump(rc)
				in_ref = true
			}
		}
		if !in_ref {
			before = t.dump(t.create())
		}
		mut parts := []string{}
		for k, v in now {
			if old := before[k] {
				if old.to_text() == v.to_text() {
					continue
				}
			}
			parts << '${k} = ${v.to_text()}'
		}
		if parts.len == 0 && in_ref {
			continue // component identical to the prefab: nothing to write
		}
		body << '${pad}  ${tname} { ${parts.join('  ')} }'
	}

	// Node con
	for ch in n.children {
		if ch.destroyed {
			continue
		}
		body << l.write_node(ch, matching_child(ref, ch), depth + 1)!
	}

	if reference != none && body.len == 0 {
		return []
	}
	mut out := ['${pad}${header}']
	out << body
	out << '${pad}}'
	return out
}

// matching_child: the child node with the same name (and same prefab source) in the source prefab, if any.
pub fn matching_child(ref ?&core.Node, ch &core.Node) ?&core.Node {
	if r := ref {
		if rc := direct_child(r, ch.name) {
			if rc.prefab_id == ch.prefab_id {
				return rc
			}
		}
	}
	return none
}

fn ident_or_quoted(s string) string {
	if s.len > 0 && (s[0].is_letter() || s[0] == `_`)
		&& s.bytes().all(it.is_letter() || it.is_digit() || it == `_`) && s !in ['node', 'from'] {
		return s
	}
	return Value(s).to_text()
}
