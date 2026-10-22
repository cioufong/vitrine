//go:build !linux && !windows

package transport

import (
	"errors"
	"io"
)

// OpenSerial is only available on Linux and Windows.
func OpenSerial(path string) (io.ReadWriteCloser, error) {
	return nil, errors.New("virtio-serial ports are only supported on Linux and Windows")
}
