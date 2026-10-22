// Command vitrine-agent is Vitrine's guest agent: it streams the guest screen
// and window list to the macOS host ("Coherence"), injects host input and
// syncs the clipboard. Linux guests use X11 over vsock or virtio-serial;
// Windows guests use GDI/SendInput over virtio-serial (TCP on older VMs).
package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/agent"
	"github.com/cioufong/vitrine/guest/linux-agent/btbridge"
	"github.com/cioufong/vitrine/guest/linux-agent/keymap"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
	"github.com/cioufong/vitrine/guest/linux-agent/transport"
)

// platformBackend is what each OS's backend provides beyond agent.Backend.
type platformBackend interface {
	agent.Backend
	Close()
	StartAutoResize() error
}

type backendOptions struct {
	display string
	scale   float64
	mode    keymap.CommandMode
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "bluetooth-bridge" {
		bluetoothBridge(os.Args[2:])
		return
	}
	var (
		unixPath   = flag.String("unix", "", "listen on a Unix socket at `PATH` (testing)")
		tcpAddr    = flag.String("tcp", "", "listen on TCP `ADDR`, e.g. 0.0.0.0:20819 (Windows without virtio-serial; less secure: guest programs can reach it too)")
		serialPath = flag.String("serial", "", "use the virtio-serial port at `PATH` (default: auto-detect "+transport.DefaultSerialPath+" on Linux, "+transport.DefaultWindowsSerialPath+" on Windows)")
		port       = flag.Uint("port", protocol.VsockPort, "vsock port (Linux)")
		display    = flag.String("display", "", "X display (Linux; default $DISPLAY)")
		scale      = flag.Float64("scale", 0, "points-to-pixels scale (Linux; 0 = auto from Xft.dpi)")
		commandKey = flag.String("command-key", defaultCommandKey, "what the Mac ⌘ key becomes: super (alias win) or ctrl")
		noResize   = flag.Bool("no-auto-resize", false, "do not switch X outputs to the host-requested (preferred) display mode")
		logPath    = flag.String("log", defaultLogPath(), "append logs to `FILE` (\"-\" = stderr)")
		verbose    = flag.Bool("verbose", false, "log more detail")
		version    = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()
	if *version {
		fmt.Println("vitrine-agent", agent.Version)
		return
	}
	if *logPath != "" && *logPath != "-" {
		redirectLog(*logPath)
	}

	mode := keymap.CommandAsSuper
	switch *commandKey {
	case "super", "win", "windows":
	case "ctrl", "control":
		mode = keymap.CommandAsControl
	default:
		fatalf("--command-key must be super/win or ctrl")
	}

	backend, err := openBackend(backendOptions{display: *display, scale: *scale, mode: mode})
	if err != nil {
		fatalf("%v", err)
	}
	defer backend.Close()
	a := agent.New(backend, *verbose)
	if autoResizeDefault && !*noResize {
		if err := backend.StartAutoResize(); err != nil {
			logf("display auto-resize disabled: %v", err)
		}
	}

	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		backend.ResetInput()
		os.Exit(0)
	}()

	// Transport selection: --unix > --tcp > --serial > platform default.
	// setupAuth (the Windows SMBIOS token) applies to the socket listeners
	// only: the virtio-serial port is driven by QEMU alone, so it needs no
	// token and a host without one still connects.
	switch {
	case *unixPath != "":
		l, err := transport.ListenUnix(*unixPath)
		if err != nil {
			fatalf("%v", err)
		}
		setupAuth(a)
		acceptLoop(a, l, nil)
	case *tcpAddr != "":
		l, err := transport.ListenTCP(*tcpAddr)
		if err != nil {
			fatalf("%v", err)
		}
		setupAuth(a)
		acceptLoop(a, l, tcpPeerAllowed)
	case *serialPath != "":
		serialLoop(a, *serialPath, nil)
	default:
		autoTransport(a, uint32(*port))
	}
}

// bluetoothBridge runs the root service that lets the agent add the host's
// Bluetooth controller to the guest (see package btbridge).
func bluetoothBridge(args []string) {
	fs := flag.NewFlagSet("bluetooth-bridge", flag.ExitOnError)
	socket := fs.String("socket", agent.BluetoothSocket, "listen on `PATH`")
	owner := fs.String("owner", "", "the `USER` (name or uid) whose agent may connect")
	fs.Parse(args)
	if *owner == "" {
		fatalf("bluetooth-bridge: --owner is required")
	}
	if err := btbridge.Serve(*socket, *owner); err != nil {
		fatalf("bluetooth-bridge: %v", err)
	}
}

// vsockOrSerial is the Linux default: the virtio-serial port only exists on
// the QEMU backend, so its presence decides; AF_VSOCK bind succeeds even
// without a vsock device and would leave the agent unreachable there.
func vsockOrSerial(a *agent.Agent, port uint32) {
	if _, err := os.Stat(transport.DefaultSerialPath); err == nil {
		serialLoop(a, transport.DefaultSerialPath, nil)
		return
	}
	l, err := transport.ListenVsock(port)
	if err != nil {
		fatalf("%v (and %s does not exist)", err, transport.DefaultSerialPath)
	}
	acceptLoop(a, l, nil)
}

// acceptLoop serves connections; each new one replaces the previous session
// (once authenticated, when the agent has a Token). allow, if set, vets the
// peer address ("ip:port") of network connections before anything is read.
func acceptLoop(a *agent.Agent, l transport.Listener, allow func(remote string) bool) {
	logf("listening on %s", l.Addr())
	for {
		rw, err := l.Accept()
		if err != nil {
			logf("accept: %v", err)
			time.Sleep(time.Second)
			continue
		}
		if c, ok := rw.(net.Conn); ok && allow != nil && !allow(c.RemoteAddr().String()) {
			logf("rejected connection from %v", c.RemoteAddr())
			rw.Close()
			continue
		}
		go a.Serve(rw)
	}
}

// serialLoop treats the port as an always-connected stream. The host may
// (re)attach at any time, so the agent announces itself on every (re)open and
// whenever the host says hello. EOF/EIO (or, on Windows, any read error) means
// the host side is detached: reopen with a short backoff. first, if not nil,
// is the port already opened by the caller and is served before any reopen.
func serialLoop(a *agent.Agent, path string, first io.ReadWriteCloser) {
	a.AnnounceOnHello = true
	logf("using virtio-serial port %s", path)
	const minBackoff, maxBackoff = 250 * time.Millisecond, 2 * time.Second
	backoff := minBackoff
	var lastErr string
	for {
		rw, err := first, error(nil)
		if rw == nil {
			rw, err = transport.OpenSerial(path)
		}
		first = nil
		if err != nil {
			if msg := err.Error(); msg != lastErr {
				logf("%v", err)
				lastErr = msg
			}
		} else {
			lastErr = ""
			start := time.Now()
			a.Serve(rw)
			if time.Since(start) > 5*time.Second {
				backoff = minBackoff
			}
		}
		time.Sleep(backoff)
		backoff = min(backoff*2, maxBackoff)
	}
}

// redirectLog sends all diagnostics (which go to os.Stderr) to a file. A GUI
// subsystem build launched by Task Scheduler has no usable stderr.
func redirectLog(path string) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		logf("log dir: %v", err)
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		logf("log file: %v", err)
		return
	}
	os.Stderr = f
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "vitrine-agent: "+format+"\n", args...)
}

func fatalf(format string, args ...any) {
	logf(format, args...)
	os.Exit(1)
}
