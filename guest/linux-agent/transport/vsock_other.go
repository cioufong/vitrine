//go:build !linux

package transport

import "errors"

// ListenVsock is only available on Linux.
func ListenVsock(port uint32) (Listener, error) {
	return nil, errors.New("vsock is only supported on Linux; use --unix PATH")
}
