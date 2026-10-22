//go:build linux

package transport

import (
	"io"
	"os"

	"golang.org/x/sys/unix"
)

// OpenSerial opens a virtio-serial port (e.g. /dev/virtio-ports/org.vitrine.agent.0)
// as an already-connected byte stream. A read returning EOF means the host
// side is not (or no longer) attached; callers reopen with a backoff.
func OpenSerial(path string) (io.ReadWriteCloser, error) {
	fd, err := unix.Open(path, unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	// Non-blocking so the runtime poller owns it and Close interrupts a
	// writer blocked while the host side is detached.
	return os.NewFile(uintptr(fd), path), nil
}
