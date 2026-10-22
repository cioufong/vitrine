//go:build linux

package x11

import (
	"errors"
	"fmt"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xfixes"
	"github.com/jezek/xgb/xproto"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

const (
	maxClipboardBytes = 32 << 20
	convertTimeout    = 2 * time.Second
	incrTimeout       = 30 * time.Second
)

// clipboard owns a hidden window on its own X connection. It serves the
// CLIPBOARD selection for host content and reads the selection when another
// client takes ownership (XFixes notification, or polling without XFixes).
type clipboard struct {
	conn  *xgb.Conn
	win   xproto.Window
	atoms atomCache
	logf  func(string, ...any)
	chunk int // largest property write (requests are limited without BIG-REQUESTS)

	sel, targets, utf8, str, text, textPlain, textPlainUTF8, png, incr, timestamp, atom, prop xproto.Atom

	mu       sync.Mutex
	owned    *protocol.Clipboard
	lastFP   [32]byte
	hasFP    bool
	onChange func(protocol.Clipboard)

	fetch     chan struct{}
	incoming  chan xgb.Event       // SelectionNotify / PropertyNotify for our reads
	transfers map[incrKey]*incrOut // outgoing INCR transfers (event goroutine only)
	closed    chan struct{}
}

type incrKey struct {
	win  xproto.Window
	prop xproto.Atom
}

type incrOut struct {
	typ     xproto.Atom
	data    []byte
	off     int
	started time.Time
}

func newClipboard(display string, logf func(string, ...any)) (*clipboard, error) {
	conn, err := xgb.NewConnDisplay(display)
	if err != nil {
		return nil, err
	}
	setup := xproto.Setup(conn)
	screen := setup.DefaultScreen(conn)
	c := &clipboard{conn: conn, logf: logf, fetch: make(chan struct{}, 1), incoming: make(chan xgb.Event, 64),
		transfers: map[incrKey]*incrOut{}, closed: make(chan struct{})}
	c.atoms.conn = conn
	c.chunk = min(int(setup.MaximumRequestLength)*4-64, 256<<10)

	c.win, err = xproto.NewWindowId(conn)
	if err != nil {
		conn.Close()
		return nil, err
	}
	err = xproto.CreateWindowChecked(conn, 0, c.win, screen.Root, -10, -10, 1, 1, 0,
		xproto.WindowClassInputOnly, 0, xproto.CwEventMask, []uint32{xproto.EventMaskPropertyChange}).Check()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("create clipboard window: %v", err)
	}
	for name, p := range map[string]*xproto.Atom{
		"CLIPBOARD": &c.sel, "TARGETS": &c.targets, "UTF8_STRING": &c.utf8, "STRING": &c.str, "TEXT": &c.text,
		"text/plain": &c.textPlain, "text/plain;charset=utf-8": &c.textPlainUTF8, "image/png": &c.png,
		"INCR": &c.incr, "TIMESTAMP": &c.timestamp, "ATOM": &c.atom, "VITRINE_CLIPBOARD": &c.prop,
	} {
		if *p = c.atoms.get(name); *p == 0 {
			conn.Close()
			return nil, fmt.Errorf("intern atom %s failed", name)
		}
	}

	watching := false
	if xfixes.Init(conn) == nil {
		if _, err := xfixes.QueryVersion(conn, 5, 0).Reply(); err == nil {
			mask := uint32(xfixes.SelectionEventMaskSetSelectionOwner | xfixes.SelectionEventMaskSelectionWindowDestroy |
				xfixes.SelectionEventMaskSelectionClientClose)
			watching = xfixes.SelectSelectionInputChecked(conn, c.win, c.sel, mask).Check() == nil
		}
	}
	go c.eventLoop()
	go c.fetchLoop()
	if !watching {
		logf("XFixes unavailable: polling the clipboard owner")
		go c.pollOwner()
	}
	return c, nil
}

func (c *clipboard) close() {
	select {
	case <-c.closed:
	default:
		close(c.closed)
		c.conn.Close()
	}
}

func (c *clipboard) setHandler(fn func(protocol.Clipboard)) {
	c.mu.Lock()
	c.onChange = fn
	c.mu.Unlock()
}

func (c *clipboard) requestFetch() {
	select {
	case c.fetch <- struct{}{}:
	default:
	}
}

// set publishes host content: we take CLIPBOARD ownership and answer requests.
func (c *clipboard) set(content protocol.Clipboard) error {
	var keep []protocol.ClipboardItem
	for _, it := range content.Items {
		if (it.Type == protocol.UTIPlainText || it.Type == protocol.UTIPNG) && len(it.Data) > 0 {
			keep = append(keep, it)
		}
	}
	if len(keep) == 0 {
		return nil // nothing we can represent in X11
	}
	content = protocol.Clipboard{Items: keep}
	c.mu.Lock()
	c.owned = &content
	c.lastFP, c.hasFP = content.Fingerprint(), true
	c.mu.Unlock()
	xproto.SetSelectionOwner(c.conn, c.win, c.sel, xproto.TimeCurrentTime)
	owner, err := xproto.GetSelectionOwner(c.conn, c.sel).Reply()
	if err != nil || owner.Owner != c.win {
		return errors.New("could not take CLIPBOARD ownership")
	}
	return nil
}

func (c *clipboard) eventLoop() {
	for {
		ev, err := c.conn.WaitForEvent()
		if ev == nil && err == nil {
			return
		}
		switch e := ev.(type) {
		case xproto.SelectionRequestEvent:
			c.serve(e)
		case xproto.SelectionClearEvent:
			c.mu.Lock()
			c.owned = nil
			c.mu.Unlock()
		case xfixes.SelectionNotifyEvent:
			if e.Owner != c.win && e.Owner != 0 {
				c.requestFetch()
			}
		case xproto.SelectionNotifyEvent:
			c.forward(e)
		case xproto.PropertyNotifyEvent:
			if e.Window == c.win {
				if e.State == xproto.PropertyNewValue {
					c.forward(e)
				}
			} else if e.State == xproto.PropertyDelete {
				c.continueIncr(e)
			}
		}
	}
}

func (c *clipboard) forward(ev xgb.Event) {
	select {
	case c.incoming <- ev:
	default: // reader not waiting; drop
	}
}

func (c *clipboard) pollOwner() {
	t := time.NewTicker(500 * time.Millisecond)
	defer t.Stop()
	var last xproto.Window
	for {
		select {
		case <-c.closed:
			return
		case <-t.C:
		}
		r, err := xproto.GetSelectionOwner(c.conn, c.sel).Reply()
		if err != nil {
			continue
		}
		if r.Owner != last && r.Owner != c.win && r.Owner != 0 {
			c.requestFetch()
		}
		last = r.Owner
	}
}

// fetchLoop reads the selection whenever another client takes ownership and
// reports it unless it matches the last content we applied or sent.
func (c *clipboard) fetchLoop() {
	for {
		select {
		case <-c.closed:
			return
		case <-c.fetch:
		}
		content, err := c.read()
		if err != nil || len(content.Items) == 0 {
			continue
		}
		fp := content.Fingerprint()
		c.mu.Lock()
		dup := c.hasFP && fp == c.lastFP
		c.lastFP, c.hasFP = fp, true
		fn := c.onChange
		c.mu.Unlock()
		if !dup && fn != nil {
			fn(content)
		}
	}
}

// read converts the current CLIPBOARD into text and/or PNG items.
func (c *clipboard) read() (protocol.Clipboard, error) {
	var out protocol.Clipboard
	has := map[xproto.Atom]bool{}
	if data, typ, err := c.convert(c.targets); err == nil && typ == c.atom {
		for i := 0; i+4 <= len(data); i += 4 {
			has[xproto.Atom(xgb.Get32(data[i:]))] = true
		}
	} else {
		has[c.utf8] = true // owner without TARGETS: just try text
	}
	for _, t := range []xproto.Atom{c.utf8, c.textPlainUTF8, c.str, c.textPlain} {
		if !has[t] {
			continue
		}
		data, _, err := c.convert(t)
		if err != nil || len(data) == 0 {
			continue
		}
		if t == c.str && !utf8.Valid(data) {
			data = latin1ToUTF8(data)
		}
		out.Items = append(out.Items, protocol.ClipboardItem{Type: protocol.UTIPlainText, Data: data})
		break
	}
	if has[c.png] {
		if data, _, err := c.convert(c.png); err == nil && len(data) > 0 {
			out.Items = append(out.Items, protocol.ClipboardItem{Type: protocol.UTIPNG, Data: data})
		}
	}
	return out, nil
}

func latin1ToUTF8(b []byte) []byte {
	r := make([]rune, len(b))
	for i, c := range b {
		r[i] = rune(c)
	}
	return []byte(string(r))
}

// wait returns the next forwarded event matching ok, or an error on timeout.
func (c *clipboard) wait(timeout time.Duration, ok func(xgb.Event) bool) (xgb.Event, error) {
	deadline := time.After(timeout)
	for {
		select {
		case ev := <-c.incoming:
			if ok(ev) {
				return ev, nil
			}
		case <-deadline:
			return nil, errors.New("selection transfer timed out")
		case <-c.closed:
			return nil, errors.New("closed")
		}
	}
}

// convert asks the owner for target and reads the reply, including INCR.
func (c *clipboard) convert(target xproto.Atom) ([]byte, xproto.Atom, error) {
	for len(c.incoming) > 0 { // drop stale events from an abandoned transfer
		<-c.incoming
	}
	xproto.DeleteProperty(c.conn, c.win, c.prop)
	xproto.ConvertSelection(c.conn, c.win, c.sel, target, c.prop, xproto.TimeCurrentTime)
	ev, err := c.wait(convertTimeout, func(ev xgb.Event) bool {
		e, ok := ev.(xproto.SelectionNotifyEvent)
		return ok && e.Target == target
	})
	if err != nil {
		return nil, 0, err
	}
	if ev.(xproto.SelectionNotifyEvent).Property == xproto.AtomNone {
		return nil, 0, errors.New("conversion refused")
	}
	r, err := xproto.GetProperty(c.conn, true, c.win, c.prop, xproto.AtomAny, 0, maxPropLongs).Reply()
	if err != nil {
		return nil, 0, err
	}
	if r.Type != c.incr {
		return r.Value[:valueBytes(r)], r.Type, nil
	}
	// INCR: deleting the property (done above) asks for the first chunk; each
	// chunk arrives as a new value, and a zero-length chunk ends the transfer.
	var data []byte
	var typ xproto.Atom
	for {
		_, err := c.wait(incrTimeout, func(ev xgb.Event) bool {
			e, ok := ev.(xproto.PropertyNotifyEvent)
			return ok && e.Atom == c.prop && e.State == xproto.PropertyNewValue
		})
		if err != nil {
			return nil, 0, err
		}
		r, err := xproto.GetProperty(c.conn, true, c.win, c.prop, xproto.AtomAny, 0, maxPropLongs).Reply()
		if err != nil {
			return nil, 0, err
		}
		n := valueBytes(r)
		if n == 0 {
			return data, typ, nil
		}
		typ = r.Type
		if len(data)+n > maxClipboardBytes {
			return nil, 0, errors.New("clipboard content too large")
		}
		data = append(data, r.Value[:n]...)
	}
}

func valueBytes(r *xproto.GetPropertyReply) int {
	return int(r.ValueLen) * int(r.Format) / 8
}

// serve answers a SelectionRequest from another client.
func (c *clipboard) serve(e xproto.SelectionRequestEvent) {
	c.mu.Lock()
	content := c.owned
	c.mu.Unlock()
	prop := e.Property
	if prop == xproto.AtomNone {
		prop = e.Target // obsolete clients (ICCCM)
	}
	ok := false
	if content != nil && e.Selection == c.sel {
		ok = c.answer(e, prop, content)
	}
	notify := xproto.SelectionNotifyEvent{Time: e.Time, Requestor: e.Requestor, Selection: e.Selection, Target: e.Target}
	if ok {
		notify.Property = prop
	}
	xproto.SendEvent(c.conn, false, e.Requestor, 0, string(notify.Bytes()))
}

func (c *clipboard) answer(e xproto.SelectionRequestEvent, prop xproto.Atom, content *protocol.Clipboard) bool {
	var text, png []byte
	for _, it := range content.Items {
		switch it.Type {
		case protocol.UTIPlainText:
			text = it.Data
		case protocol.UTIPNG:
			png = it.Data
		}
	}
	switch e.Target {
	case c.targets:
		list := []xproto.Atom{c.targets, c.timestamp}
		if text != nil {
			list = append(list, c.utf8, c.textPlainUTF8, c.str, c.text, c.textPlain)
		}
		if png != nil {
			list = append(list, c.png)
		}
		buf := make([]byte, 4*len(list))
		for i, a := range list {
			xgb.Put32(buf[i*4:], uint32(a))
		}
		xproto.ChangeProperty(c.conn, xproto.PropModeReplace, e.Requestor, prop, c.atom, 32, uint32(len(list)), buf)
		return true
	case c.timestamp:
		buf := make([]byte, 4) // CurrentTime: we took ownership with CurrentTime
		xproto.ChangeProperty(c.conn, xproto.PropModeReplace, e.Requestor, prop, xproto.AtomInteger, 32, 1, buf)
		return true
	case c.utf8, c.textPlainUTF8, c.text:
		if text != nil {
			c.put(e.Requestor, prop, c.utf8, text)
			return true
		}
	case c.str, c.textPlain:
		if text != nil {
			c.put(e.Requestor, prop, xproto.AtomString, text)
			return true
		}
	case c.png:
		if png != nil {
			c.put(e.Requestor, prop, c.png, png)
			return true
		}
	}
	return false
}

// put writes data to the requestor's property, switching to INCR when it does
// not fit in one request.
func (c *clipboard) put(w xproto.Window, prop, typ xproto.Atom, data []byte) {
	if len(data) <= c.chunk {
		xproto.ChangeProperty(c.conn, xproto.PropModeReplace, w, prop, typ, 8, uint32(len(data)), data)
		return
	}
	for k, t := range c.transfers { // forget transfers whose requestor vanished
		if time.Since(t.started) > incrTimeout {
			delete(c.transfers, k)
		}
	}
	xproto.ChangeWindowAttributes(c.conn, w, xproto.CwEventMask, []uint32{xproto.EventMaskPropertyChange})
	size := make([]byte, 4)
	xgb.Put32(size, uint32(len(data)))
	xproto.ChangeProperty(c.conn, xproto.PropModeReplace, w, prop, c.incr, 32, 1, size)
	c.transfers[incrKey{w, prop}] = &incrOut{typ: typ, data: data, started: time.Now()}
}

// continueIncr sends the next chunk after the requestor deleted the property.
func (c *clipboard) continueIncr(e xproto.PropertyNotifyEvent) {
	k := incrKey{e.Window, e.Atom}
	t := c.transfers[k]
	if t == nil {
		return
	}
	end := min(t.off+c.chunk, len(t.data))
	chunk := t.data[t.off:end]
	xproto.ChangeProperty(c.conn, xproto.PropModeReplace, e.Window, e.Atom, t.typ, 8, uint32(len(chunk)), chunk)
	t.off = end
	if len(chunk) == 0 { // the empty chunk just written terminates the transfer
		delete(c.transfers, k)
		xproto.ChangeWindowAttributes(c.conn, e.Window, xproto.CwEventMask, []uint32{0})
	}
}
