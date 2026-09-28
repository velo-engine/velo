module main

import os
import engine.assets

const usage = 'Safex Engine asset management tool

Usage:
  v run tools/assetdb.v <assets dir> <command> [args]

Commands:
  list                    list assets: ID, kind, path, import settings
  deps   <asset>          what this asset uses (recursive)
  users  <asset>          who uses this asset (check before deleting!)
  unused <scene> [...]    assets not used by any root scene (no need to package)
  check                   find broken references (nonexistent IDs) and duplicate IDs

<asset>/<scene> can be a relative path or an asset ID.
Example:
  v run tools/assetdb.v examples/demo/assets unused scenes/main.scene'

fn main() {
	args := os.args[1..]
	if args.len < 2 {
		println(usage)
		exit(1)
	}
	db := assets.open(args[0]) or {
		eprintln(err)
		exit(1)
	}
	match args[1] {
		'list' {
			for e in db.all() {
				mut settings := []string{}
				for k, v in e.meta.settings {
					settings << '${k}=${v}'
				}
				println('${e.id}  ${e.kind.str():-8}  ${e.path:-32}  ${settings.join(' ')}')
			}
			println('\n${db.len()} asset')
		}
		'deps', 'users' {
			if args.len < 3 {
				eprintln('missing <asset> argument')
				exit(1)
			}
			id := db.resolve(args[2]) or {
				eprintln('asset "${args[2]}" not found')
				exit(1)
			}
			ids := if args[1] == 'deps' { db.dependencies_deep(id) } else { db.dependents(id) }
			title := if args[1] == 'deps' { 'uses' } else { 'used by' }
			println('${db.path_of(id) or { id }} ${title}:')
			if ids.len == 0 {
				println('  (none)')
			}
			for d in ids {
				println('  ${d}  ${db.path_of(d) or { '<MISSING — asset does not exist>' }}')
			}
		}
		'unused' {
			if args.len < 3 {
				eprintln('at least one root scene is required')
				exit(1)
			}
			roots := args[2..]
			unused := db.unused(roots)
			println('Assets not used by ${roots.join(', ')}:')
			for id in unused {
				e := db.entry(id) or { continue }
				// Other scenes/prefabs may be root scenes of their own; still list them but add a note.
				note := if e.kind == .scene { '  (scene/prefab)' } else { '' }
				println('  ${id}  ${e.path}${note}')
			}
			if unused.len == 0 {
				println('  (none)')
			}
		}
		'check' {
			missing := db.missing_references()
			for pair in missing {
				println('BROKEN REFERENCE: ${db.path_of(pair[0]) or { pair[0] }} -> @asset("${pair[1]}")')
			}
			for w in db.warnings {
				println('WARNING: ${w}')
			}
			if missing.len == 0 && db.warnings.len == 0 {
				println('OK — ${db.len()} assets, no broken references.')
			} else {
				exit(2)
			}
		}
		else {
			println(usage)
			exit(1)
		}
	}
}
