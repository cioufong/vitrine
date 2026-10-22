//go:build linux

package transport

import (
	"fmt"
	"io"
	"os"

	"golang.org/x/sys/unix"
)

type vsockListener struct {
	fd   int
	port uint32
}

// ListenVsock listens on AF_VSOCK (VMADDR_CID_ANY, port). Virtualization.framework's
// VZVirtioSocketDevice connects from the host to this port.
func ListenVsock(port uint32) (Listener, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("vsock socket: %w (is the vsock transport loaded? try `modprobe vmw_vsock_virtio_transport`)", err)
	}
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("vsock bind port %#x: %w", port, err)
	}
	if err := unix.Listen(fd, 4); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("vsock listen: %w", err)
	}
	return &vsockListener{fd: fd, port: port}, nil
}

func (v *vsockListener) Accept() (io.ReadWriteCloser, error) {
	for {
		nfd, _, err := unix.Accept4(v.fd, unix.SOCK_CLOEXEC)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return nil, err
		}
		// Non-blocking fds handed to os.NewFile use the runtime poller, so a
		// Close from another goroutine unblocks pending reads and writes.
		if err := unix.SetNonblock(nfd, true); err != nil {
			unix.Close(nfd)
			return nil, err
		}
		return os.NewFile(uintptr(nfd), "vsock"), nil
	}
}

func (v *vsockListener) Close() error { return unix.Close(v.fd) }
func (v *vsockListener) Addr() string { return fmt.Sprintf("vsock:%#x", v.port) }
