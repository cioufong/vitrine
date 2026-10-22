//go:build linux

// Package x11 implements the agent backend for X11 sessions using the
// pure-Go jezek/xgb client: XDamage/MIT-SHM screen capture, EWMH window
// tracking and actions, XTest input injection and CLIPBOARD selection sync.
package x11

import (
	"fmt"
	"io"
	"log"
	"math"
	"os"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xproto"
	"github.com/jezek/xgb/xtest"

	"github.com/cioufong/vitrine/guest/linux-agent/keymap"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// Options configures the backend.
type Options struct {
	Display     string             // X display; empty uses $DISPLAY
	Scale       float64            // 0 = auto-detect from Xft.dpi
	CommandMode keymap.CommandMode // what ⌘ becomes in the guest
	Logf        func(format string, args ...any)
}

// Backend talks to one X server. It satisfies agent.Backend.
type Backend struct {
	opts    Options
	display string
	conn    *xgb.Conn // windows, actions, input and display queries
	setup   *xproto.SetupInfo
	screen  *xproto.ScreenInfo
	root    xproto.Window
	atoms   atomCache

	hasXTest bool
	scaleV   atomic.Uint64 // math.Float64bits of the current scale

	winMu  sync.Mutex
	geoms  map[uint32]winGeom              // last snapshot, for window actions
	frames map[xproto.Window]xproto.Window // client → top-level frame cache

	in   inputState
	clip *clipboard
}

// Open connects to the X server and initializes extensions.
func Open(opts Options) (*Backend, error) {
	if opts.Logf == nil {
		opts.Logf = func(f string, a ...any) { fmt.Fprintf(os.Stderr, "vitrine-agent: "+f+"\n", a...) }
	}
	display := opts.Display
	if display == "" {
		display = os.Getenv("DISPLAY")
	}
	if display == "" {
		return nil, fmt.Errorf("DISPLAY is not set (an X11 session is required; Wayland is not supported)")
	}
	// xgb logs every connection made without ~/.Xauthority; that is normal
	// for local sessions, so keep only its other (fatal) diagnostics.
	xgb.Logger = log.New(dropLines{os.Stderr, "authority info"}, "XGB: ", 0)
	conn, err := xgb.NewConnDisplay(display)
	if err != nil {
		return nil, fmt.Errorf("connect to X display %q: %w", display, err)
	}
	setup := xproto.Setup(conn)
	screen := setup.DefaultScreen(conn)
	b := &Backend{
		opts: opts, display: display, conn: conn, setup: setup, screen: screen, root: screen.Root,
		geoms: map[uint32]winGeom{}, frames: map[xproto.Window]xproto.Window{},
	}
	b.atoms.conn = conn
	b.setScale(1)

	if err := xtest.Init(conn); err == nil {
		if _, err := xtest.GetVersion(conn, 2, 2).Reply(); err == nil {
			b.hasXTest = true
		}
	}
	if !b.hasXTest {
		opts.Logf("XTEST extension unavailable: input injection disabled")
	}
	go b.drainEvents()

	b.clip, err = newClipboard(display, opts.Logf)
	if err != nil {
		opts.Logf("clipboard disabled: %v", err)
	}
	b.DisplayInfo() // prime the scale used by input conversion
	return b, nil
}

// dropLines is a log writer that discards lines containing substr.
type dropLines struct {
	w      io.Writer
	substr string
}

func (d dropLines) Write(p []byte) (int, error) {
	if strings.Contains(string(p), d.substr) {
		return len(p), nil
	}
	return d.w.Write(p)
}

// drainEvents consumes events and async errors on the main connection; xgb
// stalls a connection whose event queue is never read.
func (b *Backend) drainEvents() {
	for {
		ev, err := b.conn.WaitForEvent()
		if ev == nil && err == nil {
			return // connection closed
		}
		if _, ok := ev.(xproto.MappingNotifyEvent); ok {
			b.in.invalidateKeymap()
		}
	}
}

// Close disconnects from the X server.
func (b *Backend) Close() {
	if b.clip != nil {
		b.clip.close()
	}
	b.conn.Close()
}

// OS implements agent.Backend.
func (b *Backend) OS() string { return osDescription() }

// Capabilities implements agent.Backend.
func (b *Backend) Capabilities() []string {
	caps := []string{"coherence", "apps"}
	if b.clip != nil {
		caps = append(caps, "clipboard")
	}
	if b.hasXTest {
		caps = append(caps, "input")
	}
	if transferAvailable() {
		caps = append(caps, "files")
	}
	return caps
}

// OnClipboardChange implements agent.Backend.
func (b *Backend) OnClipboardChange(fn func(protocol.Clipboard)) {
	if b.clip != nil {
		b.clip.setHandler(fn)
	}
}

// SetClipboard implements agent.Backend.
func (b *Backend) SetClipboard(c protocol.Clipboard) error {
	if b.clip == nil {
		return fmt.Errorf("clipboard unavailable")
	}
	return b.clip.set(c)
}

func (b *Backend) scale() float64     { return math.Float64frombits(b.scaleV.Load()) }
func (b *Backend) setScale(s float64) { b.scaleV.Store(math.Float64bits(s)) }

// atomCache interns atoms once per name.
type atomCache struct {
	conn  *xgb.Conn
	mu    sync.Mutex
	m     map[string]xproto.Atom
	names map[xproto.Atom]string
}

func (a *atomCache) get(name string) xproto.Atom {
	a.mu.Lock()
	defer a.mu.Unlock()
	if v, ok := a.m[name]; ok {
		return v
	}
	r, err := xproto.InternAtom(a.conn, false, uint16(len(name)), name).Reply()
	if err != nil {
		return xproto.AtomNone
	}
	if a.m == nil {
		a.m = map[string]xproto.Atom{}
	}
	a.m[name] = r.Atom
	return r.Atom
}

// Property helpers.

const maxPropLongs = 1 << 20 // 4 MiB per GetProperty

func propU32s(r *xproto.GetPropertyReply) []uint32 {
	if r == nil || r.Format != 32 {
		return nil
	}
	out := make([]uint32, r.ValueLen)
	for i := range out {
		out[i] = xgb.Get32(r.Value[i*4:])
	}
	return out
}

func propU32(r *xproto.GetPropertyReply) (uint32, bool) {
	v := propU32s(r)
	if len(v) == 0 {
		return 0, false
	}
	return v[0], true
}

func propString(r *xproto.GetPropertyReply) string {
	if r == nil || r.Format != 8 {
		return ""
	}
	return string(r.Value[:r.ValueLen])
}

func (b *Backend) getProp(w xproto.Window, name string) xproto.GetPropertyCookie {
	return xproto.GetProperty(b.conn, false, w, b.atoms.get(name), xproto.AtomAny, 0, maxPropLongs)
}
