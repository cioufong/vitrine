//go:build !windows

package win

import (
	"errors"

	"github.com/cioufong/vitrine/guest/linux-agent/agent"
	"github.com/cioufong/vitrine/guest/linux-agent/keymap"
)

// Options configures the backend.
type Options struct {
	CommandMode keymap.CommandMode
	Logf        func(format string, args ...any)
}

// Backend is unavailable on this platform.
type Backend struct{ agent.Backend }

// Open always fails outside Windows.
func Open(Options) (*Backend, error) {
	return nil, errors.New("the Windows backend is only supported on Windows")
}

// Close is a no-op.
func (*Backend) Close() {}

// StartAutoResize is unavailable.
func (*Backend) StartAutoResize() error { return errors.New("not supported") }
