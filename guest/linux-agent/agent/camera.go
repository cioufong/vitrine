package agent

import (
	"errors"
	"fmt"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// cameraOutput is where the host camera's frames go in the guest: a
// v4l2loopback device on Linux, a Media Foundation virtual camera on Windows 11.
type cameraOutput interface {
	// Write takes one packed YUYV frame of the size the output was opened with.
	Write(frame []byte) error
	Close() error
	// Device names the guest device, e.g. /dev/video0.
	Device() string
}

// cameraFixError is an open failure that the host's "Install Camera Support" can't fix (the guest
// is too old, a privacy setting blocks cameras, ...), so CameraStatus reports installable=false.
// Any other error leaves it unset: installing would help.
type cameraFixError struct{ msg string }

func (e *cameraFixError) Error() string { return e.msg }

// openCameraOutput opens the guest's virtual camera for frames of this size.
// Replaced in tests; platforms without one return errNoCamera.
var openCameraOutput = openPlatformCamera

// cameraState is the zero value while the camera is off. Frames are taken only while active:
// from a CameraStart that opened the output until CameraStop or a failure, so a frame the host
// sent just before stopping can't open the camera again.
type cameraState struct {
	out           cameraOutput
	width, height uint32
	active        bool
}

// cameraStart opens the virtual camera and tells the host whether it worked.
func (s *session) cameraStart(v protocol.CameraStart) {
	s.closeCamera()
	st := s.openCamera(uint32(v.Width), uint32(v.Height))
	if st.Ready {
		s.logf("camera on: %dx%d → %s", v.Width, v.Height, st.Device)
	}
	s.conn.Send(st)
}

func (s *session) openCamera(w, h uint32) protocol.CameraStatus {
	out, err := openCameraOutput(int(w), int(h))
	s.camMu.Lock()
	defer s.camMu.Unlock()
	if err != nil {
		s.cam = cameraState{}
		st := protocol.CameraStatus{Error: err.Error()}
		var fixed *cameraFixError
		if errors.As(err, &fixed) {
			no := false
			st.Installable = &no
		}
		return st
	}
	s.cam = cameraState{out: out, width: w, height: h, active: true}
	return protocol.CameraStatus{Ready: true, Device: out.Device()}
}

// cameraFrame writes one frame; a frame of another size reopens the device at
// that size first (the host's camera changed resolution).
func (s *session) cameraFrame(f protocol.CameraFrame) {
	s.camMu.Lock()
	cam := s.cam
	s.camMu.Unlock()
	if !cam.active {
		return
	}
	if cam.width != f.Width || cam.height != f.Height {
		s.closeCamera()
		st := s.openCamera(f.Width, f.Height)
		s.conn.TrySend(st)
		if !st.Ready {
			return
		}
		s.camMu.Lock()
		cam = s.cam
		s.camMu.Unlock()
	}
	if err := cam.out.Write(f.Data); err != nil {
		s.closeCamera()
		s.conn.TrySend(protocol.CameraStatus{Error: fmt.Sprintf("writing to %s: %v", cam.out.Device(), err)})
	}
}

func (s *session) closeCamera() {
	s.camMu.Lock()
	out := s.cam.out
	s.cam = cameraState{}
	s.camMu.Unlock()
	if out != nil {
		out.Close()
		s.logf("camera off")
	}
}
