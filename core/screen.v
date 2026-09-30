module core

// ScaleMode — how the design resolution (the size the game is made for, e.g. 960x540) is fitted to the window
// or phone screen.
pub enum ScaleMode {
	expand // the whole design area is visible, scaled up as much as it fits; extra room on the longer side shows more of the game, around it (default)
	fit    // exactly the design area, with black bars on the longer side (letterbox)
	fill   // covers the screen: the design area is cropped on the longer side
	width  // the design width fills the screen width; more or less is visible vertically
	height // the design height fills the screen height; more or less is visible horizontally
	none   // no scaling: one unit per window point, the view is the window size (top-left at 0, 0)
}

pub fn scale_mode_from_str(s string) !ScaleMode {
	return match s {
		'expand', '' { .expand }
		'fit' { .fit }
		'fill' { .fill }
		'width' { .width }
		'height' { .height }
		'none' { .none }
		else { error('unknown scale mode "${s}" (expand, fit, fill, width, height or none)') }
	}
}

// ScreenFit — where the game is drawn in the window, for one window size.
// "Screen units" are the units UI and camera-less nodes are placed in (world units without a camera).
pub struct ScreenFit {
pub:
	scale       f32  // window points per screen unit
	view_origin Vec2 // screen units at the top-left of the visible game area
	view_size   Vec2 // screen units visible
	area_pos    Vec2 // the game area in the window, in points (only smaller than the window with `fit`)
	area_size   Vec2
}

// fit_screen computes the ScreenFit of a design size in a window (both sizes: design in screen units, window in points).
pub fn fit_screen(window Vec2, design Vec2, mode ScaleMode) ScreenFit {
	if mode == .none || design.x <= 0 || design.y <= 0 || window.x <= 0 || window.y <= 0 {
		return ScreenFit{
			scale:     1
			view_size: window
			area_size: window
		}
	}
	sx := window.x / design.x
	sy := window.y / design.y
	s := match mode {
		.fill {
			if sx > sy { sx } else { sy }
		}
		.width {
			sx
		}
		.height {
			sy
		}
		else {
			if sx < sy { sx } else { sy }
		}
	}

	if mode == .fit {
		size := design.mul(s)
		return ScreenFit{
			scale:     s
			view_size: design
			area_pos:  (window - size).mul(0.5)
			area_size: size
		}
	}
	view := window.mul(1 / s)
	return ScreenFit{
		scale:       s
		view_origin: (design - view).mul(0.5) // the design area stays centered
		view_size:   view
		area_size:   window
	}
}

// to_window: screen units -> window points.
pub fn (f ScreenFit) to_window() Affine2 {
	return Affine2.trs(f.area_pos - f.view_origin.mul(f.scale), 0, vec2(f.scale, f.scale))
}

// from_window converts a window point (mouse, touch) to screen units.
pub fn (f ScreenFit) from_window(p Vec2) Vec2 {
	s := if f.scale > 0 { f.scale } else { f32(1) }
	return (p - f.area_pos).mul(1 / s) + f.view_origin
}

// insets_from_window converts safe area insets measured from the window edges (points) to insets from the edges
// of the visible game area (screen units); parts already covered by letterbox bars do not count.
pub fn (f ScreenFit) insets_from_window(window Vec2, ins Insets) Insets {
	s := if f.scale > 0 { f.scale } else { f32(1) }
	right_bar := window.x - f.area_pos.x - f.area_size.x
	bottom_bar := window.y - f.area_pos.y - f.area_size.y
	return Insets{
		left:   max0(ins.left - f.area_pos.x) / s
		top:    max0(ins.top - f.area_pos.y) / s
		right:  max0(ins.right - right_bar) / s
		bottom: max0(ins.bottom - bottom_bar) / s
	}
}

fn max0(v f32) f32 {
	return if v > 0 { v } else { 0 }
}
