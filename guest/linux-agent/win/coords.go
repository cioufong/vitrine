package win

import "math"

// Virtual-screen geometry in physical pixels (SM_XVIRTUALSCREEN… may be
// negative with monitors left of / above the primary).
type virtualScreen struct{ X, Y, W, H int }

// scaleForDPI converts GetDpiForSystem's result to the protocol scale.
func scaleForDPI(dpi uint32) float64 {
	if dpi == 0 {
		return 1
	}
	return float64(dpi) / 96
}

// toPixel converts a guest point (top-left of the virtual screen = 0,0) to a
// physical desktop pixel.
func toPixel(p float64, scale float64, origin int) int {
	return origin + int(math.Round(p*scale))
}

// toPoint converts a physical desktop pixel to a guest point.
func toPoint(px int, scale float64, origin int) float64 {
	return float64(px-origin) / scale
}

// normalizeAbs maps a desktop pixel to SendInput's absolute 0..65535 range
// over the virtual desktop (MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_VIRTUALDESK):
// the first pixel maps to 0 and the last to 65535.
func normalizeAbs(px, origin, size int) int32 {
	if size <= 1 {
		return 0
	}
	v := math.Round(float64(px-origin) * 65535 / float64(size-1))
	return int32(math.Max(0, math.Min(65535, v)))
}

// outerFromFrame converts a desired visible frame (DWM extended frame bounds)
// into the window rect SetWindowPos expects, preserving the window's
// invisible resize borders (about 7 px on Windows 10/11).
func outerFromFrame(target, frame, window pxRect) pxRect {
	l, t := frame.Left-window.Left, frame.Top-window.Top
	r, b := window.Right-frame.Right, window.Bottom-frame.Bottom
	return pxRect{target.Left - l, target.Top - t, target.Right + r, target.Bottom + b}
}

// wheelDelta is the Windows WHEEL_DELTA for one notch.
const wheelDelta = 120

// preciseStep is the trackpad distance (points) that makes one notch.
const preciseStep = 10

// wheelNotches converts a host scroll delta into whole notches, accumulating
// precise (trackpad pixel) deltas in acc. Line deltas round, and any
// non-zero line delta moves at least one notch.
func wheelNotches(acc *float64, d float64, precise bool) int {
	if !precise {
		n := int(math.Round(d))
		if n == 0 && d != 0 {
			n = int(math.Copysign(1, d))
		}
		return n
	}
	*acc += d
	n := int(*acc / preciseStep)
	*acc -= float64(n) * preciseStep
	return n
}
