//go:build linux

package x11

import (
	"github.com/jezek/xgb/xproto"

	"github.com/cioufong/vitrine/guest/linux-agent/desktop"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// winGeom remembers how a reported window maps onto X windows, for actions.
type winGeom struct {
	client    xproto.Window
	outer     rect // top-level X window (WM frame) in pixels, including border
	reported  rect // frame sent to the host, in pixels (outer minus CSD shadows)
	clientW   int
	clientH   int
	maximized bool
	override  bool
}

type rect struct{ x, y, w, h int }

// candidate collects pipelined requests for one top-level window.
type candidate struct {
	top, client xproto.Window
	managed     bool
	attrs       xproto.GetWindowAttributesCookie
	geom        xproto.GetGeometryCookie
	clientGeom  xproto.GetGeometryCookie
	pid, class  xproto.GetPropertyCookie
	netName     xproto.GetPropertyCookie
	name        xproto.GetPropertyCookie
	wtype       xproto.GetPropertyCookie
	state       xproto.GetPropertyCookie
	gtkExtents  xproto.GetPropertyCookie
}

// Windows implements agent.Backend: managed clients (EWMH) and mapped
// override-redirect popups, in true stacking order, front-to-back.
func (b *Backend) Windows() ([]protocol.WindowInfo, error) {
	tree, err := xproto.QueryTree(b.conn, b.root).Reply()
	if err != nil {
		return nil, err
	}
	clientsCookie := b.getProp(b.root, "_NET_CLIENT_LIST")
	activeCookie := b.getProp(b.root, "_NET_ACTIVE_WINDOW")
	clientsReply, _ := clientsCookie.Reply()
	activeReply, _ := activeCookie.Reply()
	clients := propU32s(clientsReply)
	active, _ := propU32(activeReply)
	ewmh := len(clients) > 0

	topToClient := b.mapFrames(tree.Children, clients)

	// Root children are bottom-to-top; walk top-down for front-to-back output.
	cands := make([]*candidate, 0, len(tree.Children))
	for i := len(tree.Children) - 1; i >= 0; i-- {
		top := tree.Children[i]
		c := &candidate{top: top, client: top}
		if cl, ok := topToClient[top]; ok {
			c.client, c.managed = cl, true
		} else if ewmh {
			c.client = top // possible override-redirect popup; decided by attrs below
		} else {
			c.managed = true // no EWMH: treat every mapped top-level as a window
		}
		c.attrs = xproto.GetWindowAttributes(b.conn, top)
		c.geom = xproto.GetGeometry(b.conn, xproto.Drawable(top))
		cands = append(cands, c)
	}
	// Second round: properties for windows that are mapped (pipelined).
	live := cands[:0]
	attrsOf := map[xproto.Window]*xproto.GetWindowAttributesReply{}
	for _, c := range cands {
		a, err := c.attrs.Reply()
		if err != nil || a.MapState != xproto.MapStateViewable || a.Class == xproto.WindowClassInputOnly {
			c.geom.Reply() // consume
			continue
		}
		if !c.managed && !a.OverrideRedirect {
			c.geom.Reply()
			continue
		}
		attrsOf[c.top] = a
		w := c.client
		c.pid = b.getProp(w, "_NET_WM_PID")
		c.class = xproto.GetProperty(b.conn, false, w, xproto.AtomWmClass, xproto.AtomString, 0, 64)
		c.netName = b.getProp(w, "_NET_WM_NAME")
		c.name = xproto.GetProperty(b.conn, false, w, xproto.AtomWmName, xproto.AtomAny, 0, 256)
		c.wtype = b.getProp(w, "_NET_WM_WINDOW_TYPE")
		c.state = b.getProp(w, "_NET_WM_STATE")
		c.gtkExtents = b.getProp(w, "_GTK_FRAME_EXTENTS")
		c.clientGeom = xproto.GetGeometry(b.conn, xproto.Drawable(w))
		live = append(live, c)
	}

	scale := b.scale()
	sw, sh := int(b.screen.WidthInPixels), int(b.screen.HeightInPixels)
	if w, h, err := b.rootSize(); err == nil {
		sw, sh = w, h
	}
	geoms := make(map[uint32]winGeom, len(live))
	out := make([]protocol.WindowInfo, 0, len(live))
	for _, c := range live {
		info, g, ok := b.describe(c, attrsOf[c.top], sw, sh, uint32(c.client) == active)
		if !ok {
			continue
		}
		info.Frame = protocol.Rect{
			X: float64(g.reported.x) / scale, Y: float64(g.reported.y) / scale,
			Width: float64(g.reported.w) / scale, Height: float64(g.reported.h) / scale,
		}
		geoms[info.ID] = g
		out = append(out, info)
	}
	inheritOwner(out)
	b.winMu.Lock()
	b.geoms = geoms
	b.winMu.Unlock()
	return out, nil
}

// describe resolves one candidate's replies into a WindowInfo (frame unset).
func (b *Backend) describe(c *candidate, a *xproto.GetWindowAttributesReply, sw, sh int, focused bool) (protocol.WindowInfo, winGeom, bool) {
	geom, gerr := c.geom.Reply()
	cgeom, _ := c.clientGeom.Reply()
	pidR, _ := c.pid.Reply()
	classR, _ := c.class.Reply()
	netNameR, _ := c.netName.Reply()
	nameR, _ := c.name.Reply()
	typeR, _ := c.wtype.Reply()
	stateR, _ := c.state.Reply()
	extR, _ := c.gtkExtents.Reply()
	if gerr != nil {
		return protocol.WindowInfo{}, winGeom{}, false
	}

	bw := int(geom.BorderWidth)
	g := winGeom{client: c.client, override: a.OverrideRedirect,
		outer: rect{int(geom.X), int(geom.Y), int(geom.Width) + 2*bw, int(geom.Height) + 2*bw}}
	g.reported = g.outer
	g.clientW, g.clientH = int(geom.Width), int(geom.Height)
	if cgeom != nil {
		g.clientW, g.clientH = int(cgeom.Width), int(cgeom.Height)
	}
	// Client-side decorated windows without a WM frame include their drop
	// shadow in the X window; _GTK_FRAME_EXTENTS (left,right,top,bottom) tells how much.
	if ext := propU32s(extR); c.top == c.client && len(ext) == 4 {
		l, r, t, bt := int(ext[0]), int(ext[1]), int(ext[2]), int(ext[3])
		if l+r < g.outer.w && t+bt < g.outer.h {
			g.reported = rect{g.outer.x + l, g.outer.y + t, g.outer.w - l - r, g.outer.h - t - bt}
		}
	}
	if g.reported.w <= 2 || g.reported.h <= 2 {
		return protocol.WindowInfo{}, winGeom{}, false
	}
	// Skip windows entirely off-screen (GTK/Qt park helper windows at -100,-100).
	if g.reported.x+g.reported.w <= 0 || g.reported.y+g.reported.h <= 0 || g.reported.x >= sw || g.reported.y >= sh {
		return protocol.WindowInfo{}, winGeom{}, false
	}

	types := map[string]bool{}
	for _, t := range propU32s(typeR) {
		types[b.atomName(xproto.Atom(t))] = true
	}
	states := map[string]bool{}
	for _, s := range propU32s(stateR) {
		states[b.atomName(xproto.Atom(s))] = true
	}
	if types["_NET_WM_WINDOW_TYPE_DESKTOP"] || types["_NET_WM_WINDOW_TYPE_DOCK"] || states["_NET_WM_STATE_HIDDEN"] {
		return protocol.WindowInfo{}, winGeom{}, false
	}
	g.maximized = states["_NET_WM_STATE_MAXIMIZED_VERT"] && states["_NET_WM_STATE_MAXIMIZED_HORZ"]

	kind, layer := protocol.KindNormal, 0
	switch {
	case a.OverrideRedirect,
		types["_NET_WM_WINDOW_TYPE_MENU"], types["_NET_WM_WINDOW_TYPE_POPUP_MENU"],
		types["_NET_WM_WINDOW_TYPE_DROPDOWN_MENU"], types["_NET_WM_WINDOW_TYPE_TOOLTIP"],
		types["_NET_WM_WINDOW_TYPE_NOTIFICATION"], types["_NET_WM_WINDOW_TYPE_COMBO"],
		types["_NET_WM_WINDOW_TYPE_DND"]:
		kind, layer = protocol.KindMenu, 101
	case types["_NET_WM_WINDOW_TYPE_DIALOG"], types["_NET_WM_WINDOW_TYPE_UTILITY"],
		types["_NET_WM_WINDOW_TYPE_TOOLBAR"], types["_NET_WM_WINDOW_TYPE_SPLASH"]:
		kind = protocol.KindPanel
	}
	if kind != protocol.KindMenu && states["_NET_WM_STATE_ABOVE"] {
		layer = 3
	}

	pid, _ := propU32(pidR)
	title := propString(netNameR)
	if title == "" {
		title = propString(nameR)
	}
	class := wmClass(propString(classR))
	name := class
	if n := appNames.Lookup(class); n != "" {
		name = n // "Xfce Terminal" rather than "Xfce4-terminal"
	}
	var key *string
	if class != "" {
		key = &class // groups windows by app on the host (Dock icons, launchers)
	}
	return protocol.WindowInfo{
		ID:        uint32(c.client),
		PID:       int32(pid),
		AppName:   name,
		BundleID:  key,
		Title:     title,
		Kind:      kind,
		Layer:     layer,
		IsFocused: focused,
	}, g, true
}

// appNames resolves WM_CLASS classes to .desktop names.
var appNames desktop.Names

// mapFrames maps each root child that frames a managed client to that client.
// Reparenting WMs put clients inside frame windows; results are cached and
// revalidated against the current root children.
func (b *Backend) mapFrames(children []xproto.Window, clients []uint32) map[xproto.Window]xproto.Window {
	isChild := make(map[xproto.Window]bool, len(children))
	for _, c := range children {
		isChild[c] = true
	}
	b.winMu.Lock()
	defer b.winMu.Unlock()
	next := make(map[xproto.Window]xproto.Window, len(clients))
	out := make(map[xproto.Window]xproto.Window, len(clients))
	for _, id := range clients {
		cl := xproto.Window(id)
		top, ok := b.frames[cl]
		if !ok || !isChild[top] {
			top = b.topLevel(cl)
		}
		if top == 0 {
			continue
		}
		next[cl] = top
		out[top] = cl
	}
	b.frames = next
	return out
}

// topLevel walks up from w to the ancestor whose parent is the root.
func (b *Backend) topLevel(w xproto.Window) xproto.Window {
	for depth := 0; depth < 16; depth++ {
		t, err := xproto.QueryTree(b.conn, w).Reply()
		if err != nil {
			return 0
		}
		if t.Parent == b.root || t.Parent == 0 {
			return w
		}
		w = t.Parent
	}
	return 0
}

// atomName resolves atom names with a cache (window types/states repeat).
func (b *Backend) atomName(a xproto.Atom) string {
	b.atoms.mu.Lock()
	if b.atoms.names == nil {
		b.atoms.names = map[xproto.Atom]string{}
	}
	if n, ok := b.atoms.names[a]; ok {
		b.atoms.mu.Unlock()
		return n
	}
	b.atoms.mu.Unlock()
	r, err := xproto.GetAtomName(b.conn, a).Reply()
	if err != nil {
		return ""
	}
	b.atoms.mu.Lock()
	b.atoms.names[a] = r.Name
	b.atoms.mu.Unlock()
	return r.Name
}

// lookup returns the geometry recorded for a window id in the last snapshot,
// taking a fresh snapshot if the id is unknown.
func (b *Backend) lookup(id uint32) (winGeom, bool) {
	b.winMu.Lock()
	g, ok := b.geoms[id]
	b.winMu.Unlock()
	if ok {
		return g, true
	}
	if _, err := b.Windows(); err != nil {
		return winGeom{}, false
	}
	b.winMu.Lock()
	defer b.winMu.Unlock()
	g, ok = b.geoms[id]
	return g, ok
}
