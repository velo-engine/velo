import math
import os
import velo.kine2d
import velo.webp

// Spine 4.2 packs read directly by kine2d (JSON skeleton + text atlas + lossless WebP page), no GPU.
// The real-pack tests read every `<pack>/<name>.json` + `<name>.atlas` under the folder named by SPINE42_REFS
// and are skipped when it is unset; the IK and atlas tests are self-contained.

const refs_dir = os.getenv('SPINE42_REFS')

fn spine_packs() []string {
	mut out := []string{}
	for e in os.ls(refs_dir) or { [] } {
		if os.is_dir(os.join_path(refs_dir, e)) {
			out << e
		}
	}
	out.sort()
	return out
}

fn finite(x f32) bool {
	return !math.is_nan(f64(x)) && !math.is_inf(f64(x), 0)
}

fn pack_files(dir string) ?(string, string, string) {
	name := os.file_name(dir).all_before('__')
	skel := os.join_path(dir, '${name}.json')
	atlas := os.join_path(dir, '${name}.atlas')
	if !os.exists(skel) || !os.exists(atlas) {
		return none
	}
	return skel, atlas, name
}

fn test_real_packs_load_and_play() {
	if refs_dir == '' || !os.is_dir(refs_dir) {
		println('skipped: set SPINE42_REFS to a folder of Spine 4.2 packs')
		return
	}
	for pack in spine_packs() {
		dir := os.join_path(refs_dir, pack)
		skel_path, atlas_path, name := pack_files(dir) or {
			println('skipped: ${pack} not found')
			continue
		}
		src := os.read_file(skel_path)!
		assert kine2d.is_spine_json(src), name
		data := kine2d.parse_spine_skeleton(src)!
		atlas := kine2d.parse_spine_atlas(os.read_file(atlas_path)!)!
		assert data.bones.len > 0 && data.slots.len > 0, name
		assert atlas.pages.len > 0 && atlas.regions.len > 0, name
		// pages decode, and agree with the atlas
		mut page_size := [][]int{}
		for p in atlas.pages {
			img := webp.decode(os.read_bytes(os.join_path(dir, p.name))!)!
			assert img.rgba.len == img.width * img.height * 4
			if p.width > 0 {
				assert img.width == p.width && img.height == p.height, '${name} ${p.name}'
			}
			page_size << [img.width, img.height]
		}
		// every drawable attachment has its atlas region
		for skin in data.skins {
			for key, att in skin.attachments {
				if att.kind == .other {
					continue
				}
				assert att.path in atlas.regions, '${name}: ${skin.name} ${key} -> "${att.path}" not in atlas'
			}
		}
		// setup pose fills the box the Spine editor reported (skeleton width/height)
		setup := data.build(atlas, none, 0, '')
		mut x0, mut y0, mut x1, mut y1 := f32(1e9), f32(1e9), f32(-1e9), f32(-1e9)
		for p in setup {
			for i := 0; i < p.positions.len; i += 2 {
				x0 = if p.positions[i] < x0 { p.positions[i] } else { x0 }
				x1 = if p.positions[i] > x1 { p.positions[i] } else { x1 }
				y0 = if p.positions[i + 1] < y0 { p.positions[i + 1] } else { y0 }
				y1 = if p.positions[i + 1] > y1 { p.positions[i + 1] } else { y1 }
			}
		}
		mut w, mut h := f32(0), f32(0)
		if setup.len > 0 {
			w, h = x1 - x0, y1 - y0
			// the editor's box and ours differ by a few pixels at most (mesh hulls vs all vertices)
			assert math.abs(w - data.width) <= data.width * 0.05 + 4, '${name}: setup width ${w} vs ${data.width}'
			assert math.abs(h - data.height) <= data.height * 0.05 + 4, '${name}: setup height ${h} vs ${data.height}'
		} else {
			// effect rigs (*eff) show nothing until an animation switches attachments on
			assert name.ends_with('eff'), '${name}: empty setup pose'
		}
		// every animation produces sane geometry across its length
		mut drawn := 0
		for anim_name in data.names {
			anim := data.animations[anim_name]
			for step in 0 .. 9 {
				t := anim.duration * f32(step) / 8
				for p in data.build(atlas, anim, t, '') {
					drawn++
					ps := page_size[p.page]
					assert p.uvs.len == p.positions.len
					for v in p.positions {
						assert finite(v), '${name}/${anim_name} @${t}: bad position'
					}
					for i := 0; i < p.uvs.len; i += 2 {
						assert p.uvs[i] >= -1 && p.uvs[i] <= ps[0] + 1, '${name}/${anim_name}: u ${p.uvs[i]}'
						assert p.uvs[i + 1] >= -1 && p.uvs[i + 1] <= ps[1] + 1, '${name}/${anim_name}: v ${p.uvs[i + 1]}'
					}
					for i in p.indices {
						assert i >= 0 && i < p.positions.len / 2
					}
				}
			}
		}
		assert drawn > 0, name
		println('${name}: bones=${data.bones.len} slots=${data.slots.len} ik=${data.iks.len} anims=${data.names} setup=${int(w)}x${int(h)} (spine ${int(data.width)}x${int(data.height)}) skipped=${data.skipped}')
	}
}

const ik_skel = '{
  "skeleton": {"spine": "4.2.11", "width": 10, "height": 10},
  "bones": [
    {"name": "root"},
    {"name": "upper", "parent": "root", "length": 100},
    {"name": "lower", "parent": "upper", "x": 100, "length": 100},
    {"name": "target", "parent": "root", "x": 120, "y": 60}
  ],
  "slots": [],
  "ik": [{"name": "arm", "bones": ["upper", "lower"], "target": "target"}],
  "animations": {"reach": {"bones": {"target": {"translate": [{"x": 0, "y": 0}, {"time": 1, "x": -40, "y": 40}]}}}}
}'

fn test_two_bone_ik_reaches_target() {
	data := kine2d.parse_spine_skeleton(ik_skel)!
	for t in [f32(0), 0.5, 1] {
		p := data.pose(data.animations['reach'], t)
		lower := p.world[2]
		// tip of the lower bone = its origin + length along its x axis
		tip_x := lower.wx + lower.a * 100
		tip_y := lower.wy + lower.c * 100
		target := p.world[3]
		assert math.abs(tip_x - target.wx) < 0.5 && math.abs(tip_y - target.wy) < 0.5, 'ik @${t}: tip ${tip_x},${tip_y} target ${target.wx},${target.wy}'
	}
}

fn test_atlas_old_and_new_forms() {
	old := 'a.png\nsize: 64,32\nformat: RGBA8888\nfilter: Linear,Linear\nrepeat: none\nhand\n  rotate: true\n  xy: 2, 4\n  size: 10, 20\n  orig: 12, 22\n  offset: 1, 2\n  index: -1\n'
	a := kine2d.parse_spine_atlas(old)!
	r := a.regions['hand']
	assert a.pages[0].width == 64 && r.degrees == 90 && r.x == 2 && r.width == 10 && r.orig_h == 22
		&& r.offset_y == 2
	newer := 'p1.webp\nsize:32,32\npma:true\nbody\nbounds:1,2,3,4\noffsets:1,1,5,6\n\np2.webp\nsize:16,16\nfx\nbounds:0,0,8,8\nrotate:90\n'
	b := kine2d.parse_spine_atlas(newer)!
	assert b.pages.len == 2 && b.pages[0].pma
	assert b.regions['body'].page == 0 && b.regions['body'].orig_w == 5
	assert b.regions['fx'].page == 1 && b.regions['fx'].degrees == 90
}
