//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/agent"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
	"github.com/cioufong/vitrine/guest/linux-agent/transport"
	"github.com/cioufong/vitrine/guest/linux-agent/win"
)

const (
	// Windows users expect ⌘C/⌘V to act like Ctrl+C/Ctrl+V.
	defaultCommandKey = "ctrl"
	autoResizeDefault = false
)

// defaultLogPath is %LOCALAPPDATA%\Vitrine\vitrine-agent.log: the agent is
// built as a GUI-subsystem exe (no console window) and has no stderr.
func defaultLogPath() string {
	if d := os.Getenv("LOCALAPPDATA"); d != "" {
		return filepath.Join(d, "Vitrine", "vitrine-agent.log")
	}
	return ""
}

func openBackend(o backendOptions) (platformBackend, error) {
	b, err := win.Open(win.Options{CommandMode: o.mode, Logf: logf})
	if err != nil {
		return nil, err
	}
	return b, nil
}

// autoTransport prefers the QEMU virtio-serial port (vioser): only QEMU on
// the Mac drives its other end, so guest programs cannot pose as the host
// there, and the TCP listener is then never opened. The port is opened here
// and handed to serialLoop, so there is no gap in which another process could
// take it. There is no automatic TCP fallback: guest programs can reach the
// host's forwarded TCP port through QEMU user networking and read the SMBIOS
// token, so TCP is used only when asked for explicitly (--tcp). Without the
// port (no vioser driver yet) the agent waits for it.
func autoTransport(a *agent.Agent, _ uint32) {
	path := transport.DefaultWindowsSerialPath
	for {
		rw, err := transport.OpenSerial(path)
		if win.UseSerial(err) {
			if err != nil {
				logf("transport: virtio-serial %s present but not openable yet (%v); retrying", path, err)
			} else {
				logf("transport: virtio-serial %s", path)
			}
			serialLoop(a, path, rw)
			return
		}
		logf("transport: virtio-serial %s not present (%v): install the VirtIO Serial driver, or run with --tcp %s (less secure); checking again in 30s",
			path, err, fmt.Sprintf("0.0.0.0:%d", protocol.VsockPort))
		time.Sleep(30 * time.Second)
	}
}

// tcpPeerAllowed admits only connections forwarded by QEMU from the Mac: the
// port listens on every interface, so the LAN and other guest programs reach it too.
var tcpPeerAllowed = win.FromSlirpHost

// setupAuth requires the host's Hello to carry the per-VM token from SMBIOS.
// Without one (an older host) any connection from the slirp host is accepted.
// It is called for the socket listeners only, never for virtio-serial.
func setupAuth(a *agent.Agent) {
	tok, err := win.AgentToken()
	switch {
	case err != nil:
		logf("no host token: %v", err)
	case tok == "":
		logf("no host token in SMBIOS; accepting unauthenticated host connections")
	default:
		a.Token = tok
		logf("host token found in SMBIOS; host connections must present it")
	}
}
