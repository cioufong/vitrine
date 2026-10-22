package x11

// Platform-independent RandR decision helpers for following the host's
// display size (tested on any OS).

// modeInfo is a RandR mode's id and size.
type modeInfo struct {
	ID   uint32
	W, H int
}

// preferredMode returns an output's preferred mode. RandR lists the
// preferred modes first (GetOutputInfo.NumPreferred counts them); virtio-gpu
// marks the size the host asked for as preferred via EDID. Without a
// preferred flag the first listed mode is used, as `xrandr --auto` does.
func preferredMode(outputModes []uint32, numPreferred int, all map[uint32]modeInfo) (modeInfo, bool) {
	_ = numPreferred // preferred or not, the first entry is the one to use
	for _, id := range outputModes {
		if m, ok := all[id]; ok && m.W > 0 && m.H > 0 {
			return m, true
		}
	}
	return modeInfo{}, false
}

// shouldApply decides whether to switch an output to its preferred mode.
// It acts when the output is connected but unlit, on the first look (agent
// start) when the current size differs, and afterwards only when the
// preferred mode itself changed (the host resized the display). A mode the
// user picked later in the desktop's display settings is left alone.
func shouldApply(seen bool, lastPreferred, preferred, current modeInfo, active bool) bool {
	if !active {
		return true
	}
	if current.W == preferred.W && current.H == preferred.H {
		return false
	}
	if !seen {
		return true
	}
	return lastPreferred.W != preferred.W || lastPreferred.H != preferred.H
}

// rect bounding helper for screen sizing: the screen must cover every lit CRTC.
type crtcBox struct{ X, Y, W, H int }

// screenSizeFor returns the screen size needed when the target CRTC shows a
// w×h mode at 0,0 while the other lit CRTCs keep their places.
func screenSizeFor(w, h int, others []crtcBox) (int, int) {
	for _, o := range others {
		w = max(w, o.X+o.W)
		h = max(h, o.Y+o.H)
	}
	return w, h
}

// screenMM converts a pixel size to millimetres at 96 DPI (what desktops
// assume for virtual displays without a physical size).
func screenMM(w, h int) (uint32, uint32) {
	return uint32(float64(w)*25.4/96 + 0.5), uint32(float64(h)*25.4/96 + 0.5)
}
