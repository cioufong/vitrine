//go:build !linux && !windows

package agent

import "errors"

// Only Linux (v4l2loopback) and Windows 11 (a Media Foundation virtual camera) guests get a
// virtual camera from this agent.
func cameraSupported() bool { return false }

func openPlatformCamera(w, h int) (cameraOutput, error) {
	return nil, errors.New("this guest has no virtual camera")
}
