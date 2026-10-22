//go:build linux

package x11

import (
	"github.com/jezek/xgb/xproto"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// rootSize returns the current root window size in pixels. The setup block's
// size is stale after RandR changes, so this asks the server each time.
func (b *Backend) rootSize() (int, int, error) {
	g, err := xproto.GetGeometry(b.conn, xproto.Drawable(b.root)).Reply()
	if err != nil {
		return 0, 0, err
	}
	return int(g.Width), int(g.Height), nil
}

// detectScale reads Xft.dpi from RESOURCE_MANAGER: HiDPI desktops set 192
// (2×). Points are pixels / scale.
func (b *Backend) detectScale() float64 {
	if b.opts.Scale > 0 {
		return b.opts.Scale
	}
	r, err := xproto.GetProperty(b.conn, false, b.root, xproto.AtomResourceManager, xproto.AtomString, 0, maxPropLongs).Reply()
	if err != nil {
		return 1
	}
	if dpi := parseXftDPI(propString(r)); dpi >= 192 {
		return 2
	}
	return 1
}

// DisplayInfo implements agent.Backend.
func (b *Backend) DisplayInfo() (protocol.DisplayInfo, error) {
	w, h, err := b.rootSize()
	if err != nil {
		return protocol.DisplayInfo{}, err
	}
	s := b.detectScale()
	b.setScale(s)
	return protocol.DisplayInfo{
		WidthPoints:  float64(w) / s,
		HeightPoints: float64(h) / s,
		Scale:        s,
	}, nil
}
