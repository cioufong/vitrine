//go:build linux

package x11

import (
	"fmt"
	"math"

	"github.com/jezek/xgb/xproto"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// EWMH / ICCCM constants.
const (
	sourcePager       = 2 // source indication: pager / direct user action
	netWMStateRemove  = 0
	netWMStateToggle  = 2
	iconicState       = 3
	gravityNorthWest  = 1
	moveResizeX       = 1 << 8
	moveResizeY       = 1 << 9
	moveResizeW       = 1 << 10
	moveResizeH       = 1 << 11
	moveResizeSrcBits = sourcePager << 12
)

// WindowAction implements agent.Backend using EWMH client messages to the
// window manager, falling back to direct requests for override-redirect windows.
func (b *Backend) WindowAction(a protocol.WindowAction) error {
	g, ok := b.lookup(a.WindowID)
	if !ok {
		// Minimized windows are not listed but can still be focused (which
		// restores them), closed, etc.; only move/resize need geometry.
		if a.Action == protocol.ActionMove || a.Action == protocol.ActionResize {
			return fmt.Errorf("unknown window %#x", a.WindowID)
		}
		g = winGeom{client: xproto.Window(a.WindowID)}
	}
	w := g.client
	switch a.Action {
	case protocol.ActionFocus:
		if g.override {
			return nil // popups cannot take focus
		}
		b.clientMessage(w, "_NET_ACTIVE_WINDOW", sourcePager, xproto.TimeCurrentTime, 0)
		if !b.wmSupports("_NET_ACTIVE_WINDOW") {
			xproto.ConfigureWindow(b.conn, w, xproto.ConfigWindowStackMode, []uint32{xproto.StackModeAbove})
			xproto.SetInputFocus(b.conn, xproto.InputFocusPointerRoot, w, xproto.TimeCurrentTime)
		}
	case protocol.ActionClose:
		b.clientMessage(w, "_NET_CLOSE_WINDOW", xproto.TimeCurrentTime, sourcePager)
	case protocol.ActionMinimize:
		b.clientMessage(w, "WM_CHANGE_STATE", iconicState)
	case protocol.ActionZoom:
		b.clientMessage(w, "_NET_WM_STATE", netWMStateToggle,
			uint32(b.atoms.get("_NET_WM_STATE_MAXIMIZED_VERT")), uint32(b.atoms.get("_NET_WM_STATE_MAXIMIZED_HORZ")), sourcePager)
	case protocol.ActionMove, protocol.ActionResize:
		if a.Frame == nil {
			return fmt.Errorf("%s without frame", a.Action)
		}
		b.moveResize(g, *a.Frame, a.Action == protocol.ActionResize)
	default:
		return fmt.Errorf("unknown action %q", a.Action)
	}
	return nil
}

// moveResize places the window so its reported frame (decorations included)
// lands on target (guest points).
func (b *Backend) moveResize(g winGeom, target protocol.Rect, resize bool) {
	s := b.scale()
	tx, ty := int(math.Round(target.X*s)), int(math.Round(target.Y*s))
	tw, th := int(math.Round(target.Width*s)), int(math.Round(target.Height*s))
	// Outer X window origin = target origin minus the CSD shadow inset.
	x := tx - (g.reported.x - g.outer.x)
	y := ty - (g.reported.y - g.outer.y)
	// The client grows by however much the reported frame should grow.
	cw := max(1, g.clientW+tw-g.reported.w)
	ch := max(1, g.clientH+th-g.reported.h)

	if g.override || !b.wmSupports("_NET_MOVERESIZE_WINDOW") {
		mask := uint16(xproto.ConfigWindowX | xproto.ConfigWindowY)
		vals := []uint32{uint32(int32(x)), uint32(int32(y))}
		if resize {
			mask |= xproto.ConfigWindowWidth | xproto.ConfigWindowHeight
			vals = append(vals, uint32(cw), uint32(ch))
		}
		xproto.ConfigureWindow(b.conn, g.client, mask, vals)
		return
	}
	if g.maximized {
		b.clientMessage(g.client, "_NET_WM_STATE", netWMStateRemove,
			uint32(b.atoms.get("_NET_WM_STATE_MAXIMIZED_VERT")), uint32(b.atoms.get("_NET_WM_STATE_MAXIMIZED_HORZ")), sourcePager)
	}
	// NorthWest gravity: x/y address the outer frame's top-left; width/height
	// are the client size (EWMH _NET_MOVERESIZE_WINDOW).
	flags := uint32(gravityNorthWest | moveResizeX | moveResizeY | moveResizeSrcBits)
	if resize {
		flags |= moveResizeW | moveResizeH
	}
	b.clientMessage(g.client, "_NET_MOVERESIZE_WINDOW", flags, uint32(int32(x)), uint32(int32(y)), uint32(cw), uint32(ch))
}

// clientMessage sends a 32-bit ClientMessage about w to the root window, as
// EWMH requires for requests to the window manager.
func (b *Backend) clientMessage(w xproto.Window, typ string, data ...uint32) {
	d := make([]uint32, 5)
	copy(d, data)
	ev := xproto.ClientMessageEvent{
		Format: 32,
		Window: w,
		Type:   b.atoms.get(typ),
		Data:   xproto.ClientMessageDataUnionData32New(d),
	}
	xproto.SendEvent(b.conn, false, b.root,
		xproto.EventMaskSubstructureRedirect|xproto.EventMaskSubstructureNotify, string(ev.Bytes()))
}

// wmSupports checks _NET_SUPPORTED on the root window.
func (b *Backend) wmSupports(name string) bool {
	r, err := b.getProp(b.root, "_NET_SUPPORTED").Reply()
	if err != nil {
		return false
	}
	want := uint32(b.atoms.get(name))
	for _, a := range propU32s(r) {
		if a == want {
			return true
		}
	}
	return false
}
