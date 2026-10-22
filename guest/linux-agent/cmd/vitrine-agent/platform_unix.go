//go:build !windows

package main

import (
	"github.com/cioufong/vitrine/guest/linux-agent/agent"
	"github.com/cioufong/vitrine/guest/linux-agent/x11"
)

const (
	defaultCommandKey = "super"
	autoResizeDefault = true
)

func defaultLogPath() string { return "" } // stderr → journald

func openBackend(o backendOptions) (platformBackend, error) {
	b, err := x11.Open(x11.Options{Display: o.display, Scale: o.scale, CommandMode: o.mode, Logf: logf})
	if err != nil {
		return nil, err
	}
	return b, nil
}

func autoTransport(a *agent.Agent, port uint32) { vsockOrSerial(a, port) }

// tcpPeerAllowed: --tcp on Linux is for development and accepts any peer.
var tcpPeerAllowed func(remote string) bool

// setupAuth: vsock and virtio-serial are only reachable from the host.
func setupAuth(*agent.Agent) {}
