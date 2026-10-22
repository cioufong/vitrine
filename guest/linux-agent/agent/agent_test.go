package agent

import (
	"io"
	"sync"
	"testing"
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

type fakeBackend struct {
	mu        sync.Mutex
	pointers  []protocol.Pointer
	keys      []protocol.Key
	actions   []protocol.WindowAction
	clipboard []protocol.Clipboard
	onClip    func(protocol.Clipboard)
	streams   int
	stopped   int
	resets    int
	events    []string // "key" / "reset" in order, to check teardown ordering
	flood     bool     // stream sends tiny frames until SendFrame fails; Stop joins it
	floodSent chan int // reports frames sent once the flood stops
}

func (f *fakeBackend) OS() string             { return "Linux Test" }
func (f *fakeBackend) Capabilities() []string { return []string{"coherence", "clipboard", "input"} }
func (f *fakeBackend) DisplayInfo() (protocol.DisplayInfo, error) {
	return protocol.DisplayInfo{WidthPoints: 4, HeightPoints: 2, Scale: 1}, nil
}
func (f *fakeBackend) Windows() ([]protocol.WindowInfo, error) {
	return []protocol.WindowInfo{{ID: 1, AppName: "XTerm", Kind: protocol.KindNormal,
		Frame: protocol.Rect{Width: 4, Height: 2}}}, nil
}
func (f *fakeBackend) StartStream(fps int, sink FrameSink) (Stream, error) {
	f.mu.Lock()
	f.streams++
	flood := f.flood
	f.mu.Unlock()
	if flood {
		done := make(chan struct{})
		go func() {
			defer close(done)
			n := 0
			for sink.SendFrame(protocol.Frame{SurfaceWidth: 4, SurfaceHeight: 2, Width: 1, Height: 1, Data: make([]byte, 4)}) {
				n++
			}
			if f.floodSent != nil {
				f.floodSent <- n
			}
		}()
		return stopFunc(func() { <-done; f.mu.Lock(); f.stopped++; f.mu.Unlock() }), nil
	}
	sink.SendFrame(protocol.Frame{SurfaceWidth: 4, SurfaceHeight: 2, Width: 4, Height: 2, Data: make([]byte, 32)})
	return stopFunc(func() { f.mu.Lock(); f.stopped++; f.mu.Unlock() }), nil
}
func (f *fakeBackend) Pointer(p protocol.Pointer) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pointers = append(f.pointers, p)
	return nil
}
func (f *fakeBackend) Key(k protocol.Key) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.keys = append(f.keys, k)
	f.events = append(f.events, "key")
	return nil
}
func (f *fakeBackend) WindowAction(a protocol.WindowAction) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.actions = append(f.actions, a)
	return nil
}
func (f *fakeBackend) SetClipboard(c protocol.Clipboard) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.clipboard = append(f.clipboard, c)
	return nil
}
func (f *fakeBackend) ResetInput() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.resets++
	f.events = append(f.events, "reset")
}
func (f *fakeBackend) OnClipboardChange(fn func(protocol.Clipboard)) { f.onClip = fn }

type stopFunc func()

func (s stopFunc) Stop() { s() }

// host is the test's side of the connection.
type host struct {
	t    *testing.T
	conn io.ReadWriteCloser
	msgs chan protocol.Message
}

// duplex is one end of an in-memory full-duplex stream (net.Pipe without
// importing net, which would force cgo-linked test binaries on darwin).
type duplex struct {
	r *io.PipeReader
	w *io.PipeWriter
}

func (d duplex) Read(p []byte) (int, error)  { return d.r.Read(p) }
func (d duplex) Write(p []byte) (int, error) { return d.w.Write(p) }
func (d duplex) Close() error                { d.r.Close(); return d.w.Close() }

func pipe() (duplex, duplex) {
	ar, bw := io.Pipe()
	br, aw := io.Pipe()
	return duplex{ar, aw}, duplex{br, bw}
}

func newHost(t *testing.T, a *Agent) (*host, chan struct{}) {
	guest, hostSide := pipe()
	done := make(chan struct{})
	go func() { a.Serve(guest); close(done) }()
	h := &host{t: t, conn: hostSide, msgs: make(chan protocol.Message, 64)}
	go func() {
		protocol.ReadLoop(hostSide, func(m protocol.Message) { h.msgs <- m })
		close(h.msgs)
	}()
	return h, done
}

func (h *host) send(m protocol.Message) {
	b, err := protocol.Encode(m)
	if err != nil {
		h.t.Fatal(err)
	}
	if _, err := h.conn.Write(b); err != nil {
		h.t.Fatal(err)
	}
}

// expect waits for the next message of type T, skipping log messages.
func expect[T protocol.Message](h *host) T {
	h.t.Helper()
	timeout := time.After(2 * time.Second)
	for {
		select {
		case m, ok := <-h.msgs:
			if !ok {
				h.t.Fatal("connection closed")
			}
			if _, isLog := m.(protocol.Log); isLog {
				var zero T
				if _, wantLog := any(zero).(protocol.Log); !wantLog {
					continue
				}
			}
			v, ok := m.(T)
			if !ok {
				var zero T
				h.t.Fatalf("got %T, want %T", m, zero)
			}
			return v
		case <-timeout:
			var zero T
			h.t.Fatalf("timed out waiting for %T", zero)
		}
	}
}

func TestSessionFlow(t *testing.T) {
	fb := &fakeBackend{}
	a := New(fb, false)
	h, done := newHost(t, a)

	hello := expect[protocol.Hello](h)
	if hello.Role != "guest" || hello.ProtocolVersion != 1 || hello.AgentVersion != Version || len(hello.Capabilities) != 3+cameraCaps()+bluetoothCaps() {
		t.Fatalf("hello %+v", hello)
	}
	if d := expect[protocol.DisplayInfo](h); d.WidthPoints != 4 {
		t.Fatalf("display %+v", d)
	}

	h.send(protocol.Ping(77))
	if p := expect[protocol.Pong](h); p != 77 {
		t.Fatalf("pong %d", p)
	}

	h.send(protocol.SetCoherence{Enabled: true, MaxFPS: 30})
	expect[protocol.DisplayInfo](h)
	if f := expect[protocol.Frame](h); f.Width != 4 || f.Height != 2 {
		t.Fatalf("frame %+v", f)
	}
	if wl := expect[protocol.WindowList](h); len(wl.Windows) != 1 || wl.Windows[0].AppName != "XTerm" {
		t.Fatalf("windows %+v", wl)
	}

	h.send(protocol.Pointer{Kind: protocol.PointerDown, X: 1, Y: 2})
	h.send(protocol.Key{KeyCode: 0x24, Down: true})
	h.send(protocol.WindowAction{WindowID: 1, Action: protocol.ActionFocus})
	h.send(protocol.Clipboard{Items: []protocol.ClipboardItem{{Type: protocol.UTIPlainText, Data: []byte("x")}}})
	// Unchanged window list after the action is re-sent because it was forced.
	expect[protocol.WindowList](h)

	fb.onClip(protocol.Clipboard{Items: []protocol.ClipboardItem{{Type: protocol.UTIPlainText, Data: []byte("guest")}}})
	if c := expect[protocol.Clipboard](h); string(c.Items[0].Data) != "guest" {
		t.Fatalf("clipboard %+v", c)
	}

	h.send(protocol.Ping(1))
	expect[protocol.Pong](h) // everything before the ping has been handled
	fb.mu.Lock()
	if len(fb.pointers) != 1 || len(fb.keys) != 1 || len(fb.actions) != 1 || len(fb.clipboard) != 1 {
		t.Fatalf("backend saw %d pointers %d keys %d actions %d clipboards",
			len(fb.pointers), len(fb.keys), len(fb.actions), len(fb.clipboard))
	}
	fb.mu.Unlock()

	h.conn.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not return after disconnect")
	}
	fb.mu.Lock()
	defer fb.mu.Unlock()
	if fb.streams != 1 || fb.stopped != 1 {
		t.Fatalf("streams %d stopped %d", fb.streams, fb.stopped)
	}
}

func TestNewConnectionReplacesOld(t *testing.T) {
	a := New(&fakeBackend{}, false)
	h1, done1 := newHost(t, a)
	expect[protocol.Hello](h1)
	h2, _ := newHost(t, a)
	expect[protocol.Hello](h2)
	expect[protocol.DisplayInfo](h2)
	select {
	case <-done1:
	case <-time.After(2 * time.Second):
		t.Fatal("old session not torn down")
	}
	h2.send(protocol.Ping(9))
	if p := expect[protocol.Pong](h2); p != 9 {
		t.Fatal("new session not serving")
	}
	h2.conn.Close()
}

func TestAnnounceOnHello(t *testing.T) {
	a := New(&fakeBackend{}, false)
	a.AnnounceOnHello = true
	h, _ := newHost(t, a)
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)
	h.send(protocol.Hello{ProtocolVersion: 1, Role: "host", OS: "macOS", AgentVersion: "1", Capabilities: []string{}})
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)
	h.conn.Close()
}

type clockBackend struct{ fakeBackend }

func (*clockBackend) SetClock(time.Time) error         { return nil }
func (*clockBackend) SetTimeZone(string, string) error { return nil }

func TestTimeCapability(t *testing.T) {
	h, _ := newHost(t, New(&clockBackend{}, false))
	caps := expect[protocol.Hello](h).Capabilities
	if len(caps) != 4+cameraCaps()+bluetoothCaps() || caps[3] != "time" {
		t.Fatalf("caps %v", caps)
	}
	h.conn.Close()
}

// trySend writes m, ignoring errors: the agent may hang up mid-message.
func (h *host) trySend(m protocol.Message) {
	b, _ := protocol.Encode(m)
	h.conn.Write(b)
}

// expectClosed waits until the agent closes the connection without having
// sent it anything but log lines.
func expectClosed(h *host) {
	h.t.Helper()
	timeout := time.After(2 * time.Second)
	for {
		select {
		case m, ok := <-h.msgs:
			if !ok {
				return
			}
			if _, isLog := m.(protocol.Log); !isLog {
				h.t.Fatalf("got %T from an unauthenticated connection", m)
			}
		case <-timeout:
			h.t.Fatal("connection not closed")
		}
	}
}

// With a token, only a connection whose host Hello carries it may replace the
// current session; anything else is closed and the session keeps serving.
func TestTokenGuardsReplacement(t *testing.T) {
	a := New(&fakeBackend{}, false)
	a.Token = "secret"
	hostHello := func(token string) protocol.Hello {
		return protocol.Hello{ProtocolVersion: 1, Role: "host", OS: "macOS", AgentVersion: "1", Capabilities: []string{}, Token: token}
	}

	h1, done1 := newHost(t, a)
	h1.send(hostHello("secret"))
	expect[protocol.Hello](h1)
	expect[protocol.DisplayInfo](h1)

	for _, first := range []protocol.Message{protocol.Ping(1), hostHello(""), hostHello("wrong"),
		protocol.Hello{Role: "guest", Token: "secret"}} {
		bad, _ := newHost(t, a)
		bad.trySend(first)
		expectClosed(bad)
		h1.send(protocol.Ping(2))
		if p := expect[protocol.Pong](h1); p != 2 {
			t.Fatal("session disturbed")
		}
	}

	h2, _ := newHost(t, a)
	h2.send(hostHello("secret"))
	expect[protocol.Hello](h2)
	expect[protocol.DisplayInfo](h2)
	select {
	case <-done1:
	case <-time.After(2 * time.Second):
		t.Fatal("old session not replaced")
	}
	h2.send(protocol.Ping(3))
	if p := expect[protocol.Pong](h2); p != 3 {
		t.Fatal("new session not serving")
	}
	h2.conn.Close()
}
