// Package transport provides the listening sockets the host connects to:
// AF_VSOCK in production, a Unix-domain socket for tests and development.
package transport

import (
	"io"
	"net"
	"os"
)

// DefaultSerialPath is the virtio-serial port the QEMU backend exposes.
const DefaultSerialPath = "/dev/virtio-ports/org.vitrine.agent.0"

// DefaultWindowsSerialPath is the same port in a Windows guest, as the Red Hat
// VirtIO Serial driver (vioser) names it.
const DefaultWindowsSerialPath = `\\.\Global\org.vitrine.agent.0`

// Listener accepts host connections.
type Listener interface {
	Accept() (io.ReadWriteCloser, error)
	Close() error
	Addr() string
}

type unixListener struct {
	l    net.Listener
	path string
}

// ListenUnix listens on a Unix-domain stream socket at path, replacing a stale socket file.
func ListenUnix(path string) (Listener, error) {
	if fi, err := os.Lstat(path); err == nil && fi.Mode()&os.ModeSocket != 0 {
		os.Remove(path)
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	return &unixListener{l: l, path: path}, nil
}

type tcpListener struct{ l net.Listener }

// ListenTCP listens on a TCP address (Windows guests: 0.0.0.0:20819, reached
// through QEMU user-net hostfwd).
func ListenTCP(addr string) (Listener, error) {
	l, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	return &tcpListener{l: l}, nil
}

func (t *tcpListener) Accept() (io.ReadWriteCloser, error) { return t.l.Accept() }
func (t *tcpListener) Close() error                        { return t.l.Close() }
func (t *tcpListener) Addr() string                        { return "tcp:" + t.l.Addr().String() }

func (u *unixListener) Accept() (io.ReadWriteCloser, error) { return u.l.Accept() }
func (u *unixListener) Close() error                        { return u.l.Close() }
func (u *unixListener) Addr() string                        { return "unix:" + u.path }
