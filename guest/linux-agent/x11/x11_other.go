//go:build !linux

// Package x11 implements the agent backend for X11 sessions. It is only
// functional on Linux; elsewhere Open fails so the rest of the module (and its
// tests) still builds.
package x11

import (
	"errors"

	"github.com/cioufong/vitrine/guest/linux-agent/agent"
	"github.com/cioufong/vitrine/guest/linux-agent/keymap"
)

// Options configures the backend.
type Options struct {
	Display     string
	Scale       float64
	CommandMode keymap.CommandMode
	Logf        func(format string, args ...any)
}

// Backend is unavailable on this platform.
type Backend struct{ agent.Backend }

// Open always fails outside Linux.
func Open(Options) (*Backend, error) {
	return nil, errors.New("the X11 backend is only supported on Linux")
}

// Close is a no-op.
func (*Backend) Close() {}

// StartAutoResize is unavailable outside Linux.
func (*Backend) StartAutoResize() error { return errors.New("RandR is only supported on Linux") }
