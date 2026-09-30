module app

import os
import velo.core
import sokol.sapp

#include "@VMODROOT/app/safe_area.h"

fn C.velo_android_safe_insets(activity voidptr, out &int) int
fn C.velo_ios_safe_insets(window voidptr, out &f64) int
fn C.sapp_ios_get_window() voidptr

// query_safe_insets returns the safe area insets in window points (`scale` = framebuffer pixels per point),
// or none when the platform cannot tell yet.
//
// On desktop there is no safe area, but VELO_SAFE_AREA="left,top,right,bottom" (window points) fakes one,
// to try a layout for notched phones without a device.
fn query_safe_insets(scale f32) ?core.Insets {
	$if android {
		mut px := [4]int{}
		if C.velo_android_safe_insets(sapp.android_get_native_activity(), &px[0]) == 0 {
			return none
		}
		return core.Insets{f32(px[0]) / scale, f32(px[1]) / scale, f32(px[2]) / scale, f32(px[3]) / scale}
	} $else $if ios {
		mut pt := [4]f64{}
		if C.velo_ios_safe_insets(C.sapp_ios_get_window(), &pt[0]) == 0 {
			return none
		}
		k := sapp.dpi_scale() / scale // iOS points -> pixels -> window points
		return core.Insets{f32(pt[0]) * k, f32(pt[1]) * k, f32(pt[2]) * k, f32(pt[3]) * k}
	} $else {
		env := os.getenv('VELO_SAFE_AREA')
		if env == '' {
			return core.Insets{}
		}
		v := env.split(',').map(it.trim_space().f32())
		if v.len != 4 {
			eprintln('[velo] VELO_SAFE_AREA must be "left,top,right,bottom" (got "${env}")')
			return core.Insets{}
		}
		return core.Insets{v[0], v[1], v[2], v[3]}
	}
}
