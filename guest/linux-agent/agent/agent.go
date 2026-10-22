package agent

import (
	"bytes"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"slices"
	"sync"
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// Version is reported in Hello.
const Version = "0.1.0"

// Polling intervals.
var (
	WindowPollInterval  = 33 * time.Millisecond
	DisplayPollInterval = time.Second
)

// Agent serves one host connection at a time; a new connection replaces the old.
type Agent struct {
	backend Backend
	verbose bool

	// AnnounceOnHello re-sends Hello + DisplayInfo whenever the host says
	// hello. Used on virtio-serial, which has no connect signal: the host may
	// attach to an already-open port and would otherwise never see our hello.
	AnnounceOnHello bool

	// Token, when set, is the per-VM secret a host must present in its Hello
	// before its connection may replace the current session. Used on TCP,
	// where any program in the guest could otherwise connect and take over.
	Token string

	mu      sync.Mutex
	session *session
	gen     uint64 // generation of the newest session

	// Ordered backend jobs (share mapping, file drops); see enqueue.
	jobOnce sync.Once
	jobMu   sync.Mutex
	jobs    []job
	jobWake chan struct{}
}

// session is the state tied to one host connection. Its Serve goroutine is
// the only one that tears it down; others cancel it by closing conn.
type session struct {
	a    *Agent
	conn *Conn
	gen  uint64        // Agent.gen when this session became current
	done chan struct{} // closed once teardown (capture stopped, input released) finished

	coherenceMu  sync.Mutex
	mu           sync.Mutex
	stream       Stream
	streamCancel chan struct{} // closed before stream.Stop so blocked sends give up
	windowStop   chan struct{}
	lastWindows  []byte
	lastDisplay  protocol.DisplayInfo
	networkOnce  sync.Once
	statsOnce    sync.Once

	camMu sync.Mutex
	cam   cameraState

	btMu  sync.Mutex
	bt    net.Conn // the Bluetooth bridge, while the host's controller is attached
	btGen int      // bumped by every start and stop, so a stop beats a start still dialing
}

// New creates an agent for backend.
func New(backend Backend, verbose bool) *Agent {
	a := &Agent{backend: backend, verbose: verbose}
	backend.OnClipboardChange(func(c protocol.Clipboard) {
		if s := a.current(); s != nil {
			s.conn.Send(c)
		}
	})
	return a
}

func (a *Agent) current() *session {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.session
}

// Logf writes to stderr and, when connected, to the host as a log message.
func (a *Agent) Logf(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintf(os.Stderr, "vitrine-agent: %s\n", msg)
	if s := a.current(); s != nil {
		s.conn.TrySend(protocol.Log(msg)) // best effort: never stall on a slow host
	}
}

func (a *Agent) debugf(format string, args ...any) {
	if a.verbose {
		a.Logf(format, args...)
	}
}

// logf logs to stderr and to this session's host only (not to a newer
// session that may already have replaced it). Log lines are best effort and
// dropped when the send queue is full, so logging never blocks dispatch.
func (s *session) logf(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintf(os.Stderr, "vitrine-agent: %s\n", msg)
	s.conn.TrySend(protocol.Log(msg))
}

// Serve runs the protocol over rw until it closes or is replaced by a newer
// connection. It returns once the session has been torn down. With a Token,
// a connection that does not open with a matching host Hello is closed
// without disturbing the current session.
func (a *Agent) Serve(rw io.ReadWriteCloser) {
	if a.Token != "" {
		authed, err := authenticate(rw, a.Token)
		if err != nil {
			fmt.Fprintf(os.Stderr, "vitrine-agent: rejected connection: %v\n", err)
			rw.Close()
			return
		}
		rw = authed
	}
	s := &session{a: a, conn: NewConn(rw), done: make(chan struct{})}
	a.mu.Lock()
	old := a.session
	a.gen++
	s.gen = a.gen
	a.session = s
	a.mu.Unlock()
	if old != nil {
		// Cancel first — closing the connection unblocks the old reader and any
		// producer stuck on a full send queue — then wait until the old session
		// has stopped dispatching and released its input, so the two never
		// inject at the same time.
		old.conn.Close()
		<-old.done
	}

	s.announce()
	a.Logf("host connected (%s)", a.backend.OS())

	go s.displayLoop()
	err := s.conn.ReadLoop(s.handle)

	// The reader has returned: this session dispatches no more input.
	s.teardown()
	a.mu.Lock()
	replaced := a.session != s
	if !replaced {
		a.session = nil
	}
	a.mu.Unlock()
	close(s.done)
	if !replaced {
		if err != nil {
			fmt.Fprintf(os.Stderr, "vitrine-agent: host disconnected: %v\n", err)
		} else {
			fmt.Fprintln(os.Stderr, "vitrine-agent: host disconnected")
		}
	}
}

// AuthTimeout bounds how long a connection may take to send its first
// message when a Token is required (on transports with read deadlines).
var AuthTimeout = 10 * time.Second

// maxAuthHello bounds the one message read from a not yet trusted peer.
const maxAuthHello = 64 << 10

// authenticate reads exactly one message from rw, which must be a host Hello
// carrying token (compared in constant time), and returns rw with that message
// pushed back so the session still sees it.
func authenticate(rw io.ReadWriteCloser, token string) (io.ReadWriteCloser, error) {
	if d, ok := rw.(interface{ SetReadDeadline(time.Time) error }); ok {
		d.SetReadDeadline(time.Now().Add(AuthTimeout))
		defer d.SetReadDeadline(time.Time{})
	}
	head := make([]byte, 5) // u32 length · u8 type
	if _, err := io.ReadFull(rw, head); err != nil {
		return nil, err
	}
	length := binary.LittleEndian.Uint32(head)
	if protocol.MessageType(head[4]) != protocol.TypeHello || length < 1 || length > maxAuthHello {
		return nil, errors.New("first message is not a hello")
	}
	msg := make([]byte, 4+int(length))
	copy(msg, head)
	if _, err := io.ReadFull(rw, msg[5:]); err != nil {
		return nil, err
	}
	m, err := protocol.Decode(head[4], msg[5:])
	if err != nil {
		return nil, err
	}
	if h := m.(protocol.Hello); h.Role != "host" || subtle.ConstantTimeCompare([]byte(h.Token), []byte(token)) != 1 {
		return nil, errors.New("hello without the VM's token")
	}
	return &replayConn{ReadWriteCloser: rw, r: io.MultiReader(bytes.NewReader(msg), rw)}, nil
}

// replayConn is a connection whose first bytes were already consumed (by
// authenticate) and are served again before the rest of the stream.
type replayConn struct {
	io.ReadWriteCloser
	r io.Reader
}

func (c *replayConn) Read(p []byte) (int, error) { return c.r.Read(p) }

// teardown runs exactly once, from Serve: close the connection before
// joining producers (so none can stay blocked in Send), stop capture and
// polling, then release held keys and buttons.
func (s *session) teardown() {
	s.conn.Close()
	s.setCoherence(false, 0)
	s.closeCamera()
	s.closeBluetooth()
	s.a.backend.ResetInput()
}

// announce sends Hello followed by DisplayInfo.
func (s *session) announce() {
	a := s.a
	s.conn.Send(protocol.Hello{
		ProtocolVersion: protocol.Version, Role: "guest", OS: a.backend.OS(),
		AgentVersion: Version, Capabilities: a.capabilities(),
	})
	s.publishDisplay(true, nil)
}

// capabilities is the backend's list plus "time" when it can take TimeSync,
// "camera" where the guest can have a virtual camera and "bluetooth" where it
// can take the host's Bluetooth controller: hosts only send those
// messages to agents that announce them, because older agents reject unknown
// message types and drop the channel.
func (a *Agent) capabilities() []string {
	caps := slices.Clip(a.backend.Capabilities())
	if _, ok := a.backend.(ClockSetter); ok && !slices.Contains(caps, "time") {
		caps = append(caps, "time")
	}
	if cameraSupported() && !slices.Contains(caps, "camera") {
		caps = append(caps, "camera")
	}
	if bluetoothSupported() && !slices.Contains(caps, "bluetooth") {
		caps = append(caps, "bluetooth")
	}
	return caps
}

func (s *session) handle(m protocol.Message) {
	a := s.a
	var err error
	switch v := m.(type) {
	case protocol.Hello:
		a.debugf("host hello: %s caps=%v", v.OS, v.Capabilities)
		if slices.Contains(v.Capabilities, "network") {
			s.startNetworkReports()
		}
		if slices.Contains(v.Capabilities, "stats") {
			s.startStatsReports()
		}
		if a.AnnounceOnHello {
			s.announce()
		}
	case protocol.Ping:
		s.conn.Send(protocol.Pong(v))
	case protocol.SetCoherence:
		s.setCoherence(v.Enabled, v.MaxFPS)
	case protocol.Pointer:
		err = a.backend.Pointer(v)
	case protocol.Key:
		err = a.backend.Key(v)
	case protocol.WindowAction:
		err = a.backend.WindowAction(v)
		s.forceWindows()
	case protocol.Clipboard:
		err = a.backend.SetClipboard(v)
	case protocol.Log:
		a.debugf("host log: %s", string(v))
	case protocol.MountShares:
		if m, ok := a.backend.(ShareMounter); ok {
			// Mapping can wait on the network for a while: the job worker runs
			// it, keeping the session responsive and later drops behind it.
			s.enqueue(true, "shares", func() {
				if err := m.MountShares(v); err != nil {
					s.logf("shares: %v", err)
				}
			})
		}
	case protocol.TimeSync:
		if c, ok := a.backend.(ClockSetter); ok {
			iana, winTZ := "", ""
			if v.TimeZone != nil {
				iana = *v.TimeZone
			}
			if v.WindowsTimeZone != nil {
				winTZ = *v.WindowsTimeZone
			}
			if iana != "" || winTZ != "" {
				go func() {
					if err := c.SetTimeZone(iana, winTZ); err != nil {
						s.logf("time zone: %v", err)
					}
				}()
			}
			host := time.UnixMilli(v.UnixMillis)
			if d := time.Until(host); d > 2*time.Second || d < -2*time.Second {
				go func() {
					if err := c.SetClock(host); err != nil {
						s.logf("clock: %v", err)
					} else {
						s.logf("clock set from the host (was off by %v)", d.Round(time.Second))
					}
				}()
			}
		}
	case protocol.AppIconRequest:
		if p, ok := a.backend.(AppProvider); ok {
			go func() {
				png, err := p.AppIcon(v.Key)
				if err != nil {
					s.logf("icon %s: %v", v.Key, err)
				}
				s.conn.Send(protocol.AppIcon{Key: v.Key, PNG: png})
			}()
		}
	case protocol.AppCatalogRequest:
		if p, ok := a.backend.(AppProvider); ok {
			go func() {
				size := v.IconSize
				if size < 0 || size > 512 {
					size = 128
				}
				cat, err := p.AppCatalog(size)
				if err != nil {
					s.logf("app catalog: %v", err)
				}
				s.conn.Send(cat)
			}()
		}
	case protocol.LaunchApp:
		if p, ok := a.backend.(AppProvider); ok {
			go func() {
				if err := p.LaunchApp(v.ID); err != nil {
					s.logf("launch %s: %v", v.ID, err)
				}
			}()
		}
	case protocol.CameraStart:
		s.cameraStart(v)
	case protocol.CameraFrame:
		s.cameraFrame(v)
	case protocol.CameraStop:
		s.closeCamera()
	case protocol.BluetoothStart:
		// The generation is taken here, in order with the messages around it, so a stop (or the
		// teardown) handled before the worker runs still cancels it.
		gen := s.closeBluetooth()
		go s.bluetoothStart(gen) // may wait seconds for the bridge; keep reading meanwhile
	case protocol.BluetoothHCI:
		s.bluetoothHCI(v)
	case protocol.BluetoothStop:
		s.closeBluetooth()
	case protocol.FileDrop:
		if r, ok := a.backend.(FileReceiver); ok {
			s.enqueue(false, "file drop", func() {
				if err := r.ReceiveFiles(v); err != nil {
					s.logf("file drop: %v", err)
				}
			})
		}
	}
	if err != nil {
		s.logf("%T: %v", m, err)
	}
}

func (s *session) setCoherence(enabled bool, fps int) {
	// coherenceMu serializes start/stop; s.mu is never held while calling into
	// the backend because the stream calls back into the session.
	s.coherenceMu.Lock()
	defer s.coherenceMu.Unlock()
	s.mu.Lock()
	oldStream, oldCancel, oldStop := s.stream, s.streamCancel, s.windowStop
	s.stream, s.streamCancel, s.windowStop = nil, nil, nil
	s.mu.Unlock()
	if oldStop != nil {
		close(oldStop)
	}
	if oldCancel != nil {
		close(oldCancel) // a producer blocked in SendFrame returns false and exits
	}
	if oldStream != nil {
		oldStream.Stop()
	}
	if !enabled {
		if oldStream != nil || oldStop != nil {
			s.logf("coherence off")
		}
		return
	}
	if fps <= 0 || fps > 240 {
		fps = 60
	}
	select {
	case <-s.conn.Done():
		return
	default:
	}
	s.publishDisplay(true, nil)
	cancel := make(chan struct{})
	st, err := s.a.backend.StartStream(fps, streamSink{s: s, cancel: cancel})
	if err != nil {
		s.logf("capture failed: %v", err)
	}
	stop := make(chan struct{})
	s.mu.Lock()
	s.stream, s.streamCancel, s.windowStop, s.lastWindows = st, cancel, stop, nil
	s.mu.Unlock()
	go s.windowLoop(stop)
	s.logf("coherence on (%d fps)", fps)
}

func (s *session) windowLoop(stop chan struct{}) {
	t := time.NewTicker(WindowPollInterval)
	defer t.Stop()
	for {
		s.publishWindows(stop)
		select {
		case <-stop:
			return
		case <-s.conn.Done():
			return
		case <-t.C:
		}
	}
}

func (s *session) forceWindows() {
	s.mu.Lock()
	s.lastWindows = nil
	stop := s.windowStop
	s.mu.Unlock()
	if stop != nil {
		s.publishWindows(stop)
	}
}

func (s *session) publishWindows(cancel <-chan struct{}) {
	wins, err := s.a.backend.Windows()
	if err != nil {
		return
	}
	list := protocol.WindowList{Windows: wins}
	enc, _ := json.Marshal(list)
	s.mu.Lock()
	changed := !bytes.Equal(enc, s.lastWindows)
	if changed {
		s.lastWindows = enc
	}
	s.mu.Unlock()
	if changed && !s.conn.SendCancel(list, cancel) {
		s.mu.Lock()
		s.lastWindows = nil // not delivered: resend next time
		s.mu.Unlock()
	}
}

func (s *session) displayLoop() {
	t := time.NewTicker(DisplayPollInterval)
	defer t.Stop()
	for {
		select {
		case <-s.conn.Done():
			return
		case <-t.C:
			s.publishDisplay(false, nil)
		}
	}
}

func (s *session) publishDisplay(force bool, cancel <-chan struct{}) {
	info, err := s.a.backend.DisplayInfo()
	if err != nil {
		return
	}
	s.mu.Lock()
	changed := force || info != s.lastDisplay
	s.lastDisplay = info
	s.mu.Unlock()
	if changed {
		s.conn.SendCancel(info, cancel)
	}
}

// streamSink is the FrameSink handed to one capture stream. Every send it
// makes is abandoned once the stream is cancelled, so Stream.Stop can never
// wait on a host that stopped reading.
type streamSink struct {
	s      *session
	cancel chan struct{}
}

func (k streamSink) SendFrame(f protocol.Frame) bool { return k.s.conn.SendCancel(f, k.cancel) }
func (k streamSink) Pending() int64                  { return k.s.conn.Pending() }
func (k streamSink) DisplayChanged()                 { k.s.publishDisplay(false, k.cancel) }
func (k streamSink) Logf(format string, args ...any) { k.s.logf(format, args...) }
