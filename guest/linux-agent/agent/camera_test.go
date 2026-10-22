package agent

import (
	"bytes"
	"errors"
	"sync"
	"testing"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// cameraCaps is how many capabilities the camera adds on this platform.
func cameraCaps() int {
	if cameraSupported() {
		return 1
	}
	return 0
}

type fakeCamera struct {
	mu     sync.Mutex
	w, h   int
	frames [][]byte
	closed bool
}

func (c *fakeCamera) Write(b []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.frames = append(c.frames, append([]byte(nil), b...))
	return nil
}
func (c *fakeCamera) Close() error   { c.mu.Lock(); c.closed = true; c.mu.Unlock(); return nil }
func (c *fakeCamera) Device() string { return "/dev/video9" }

func (c *fakeCamera) snapshot() (frames [][]byte, closed bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([][]byte(nil), c.frames...), c.closed
}

// fakeCameras replaces openCameraOutput for one test and records every open.
func fakeCameras(t *testing.T, fail error) *[]*fakeCamera {
	var mu sync.Mutex
	opened := &[]*fakeCamera{}
	old := openCameraOutput
	openCameraOutput = func(w, h int) (cameraOutput, error) {
		if fail != nil {
			return nil, fail
		}
		c := &fakeCamera{w: w, h: h}
		mu.Lock()
		*opened = append(*opened, c)
		mu.Unlock()
		return c, nil
	}
	t.Cleanup(func() { openCameraOutput = old })
	return opened
}

func yuyv(w, h int, fill byte) protocol.CameraFrame {
	return protocol.CameraFrame{Width: uint32(w), Height: uint32(h), Data: bytes.Repeat([]byte{fill}, w*h*2)}
}

func TestCameraStream(t *testing.T) {
	opened := fakeCameras(t, nil)
	h, _ := newHost(t, New(&fakeBackend{}, false))
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)

	h.send(protocol.CameraStart{Width: 4, Height: 2, FPS: 30})
	if st := expect[protocol.CameraStatus](h); !st.Ready || st.Device != "/dev/video9" {
		t.Fatalf("status %+v", st)
	}
	h.send(yuyv(4, 2, 7))
	h.send(yuyv(4, 2, 8))
	cam := (*opened)[0]
	waitFor(t, "two frames", func() bool { f, _ := cam.snapshot(); return len(f) == 2 })
	if f, _ := cam.snapshot(); f[1][0] != 8 || len(f[1]) != 16 {
		t.Fatalf("frame %v", f[1])
	}

	// The Mac's camera changed resolution: the device is reopened at the new size.
	h.send(yuyv(2, 2, 9))
	if st := expect[protocol.CameraStatus](h); !st.Ready {
		t.Fatalf("status %+v", st)
	}
	waitFor(t, "reopen", func() bool { return len(*opened) == 2 })
	if _, closed := cam.snapshot(); !closed {
		t.Fatal("old device left open")
	}
	if c := (*opened)[1]; c.w != 2 || c.h != 2 {
		t.Fatalf("reopened at %dx%d", c.w, c.h)
	}

	h.send(protocol.CameraStop{})
	waitFor(t, "stop", func() bool { _, closed := (*opened)[1].snapshot(); return closed })
	h.conn.Close()
}

// A frame the host sent just before CameraStop must not open the camera again.
func TestCameraFrameAfterStopIsDropped(t *testing.T) {
	opened := fakeCameras(t, nil)
	h, _ := newHost(t, New(&fakeBackend{}, false))
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)
	h.send(protocol.CameraStart{Width: 2, Height: 2, FPS: 30})
	expect[protocol.CameraStatus](h)
	h.send(protocol.CameraStop{})
	h.send(yuyv(2, 2, 1))
	h.send(yuyv(4, 2, 1))
	h.send(protocol.Ping(6))
	if p := expect[protocol.Pong](h); p != 6 { // also fails on a CameraStatus from a reopen
		t.Fatalf("pong %d", p)
	}
	if len(*opened) != 1 {
		t.Fatalf("camera opened %d times", len(*opened))
	}
	if f, closed := (*opened)[0].snapshot(); !closed || len(f) != 0 {
		t.Fatalf("frames %d, closed %v", len(f), closed)
	}
	h.conn.Close()
}

func TestCameraClosedWithSession(t *testing.T) {
	opened := fakeCameras(t, nil)
	h, done := newHost(t, New(&fakeBackend{}, false))
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)
	h.send(protocol.CameraStart{Width: 2, Height: 2, FPS: 30})
	expect[protocol.CameraStatus](h)
	h.conn.Close()
	<-done
	if _, closed := (*opened)[0].snapshot(); !closed {
		t.Fatal("camera left open after the host went away")
	}
}

func TestCameraUnavailable(t *testing.T) {
	fakeCameras(t, errors.New("no \"Vitrine Camera\" device"))
	h, _ := newHost(t, New(&fakeBackend{}, false))
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)
	h.send(protocol.CameraStart{Width: 2, Height: 2, FPS: 30})
	if st := expect[protocol.CameraStatus](h); st.Ready || st.Error == "" {
		t.Fatalf("status %+v", st)
	}
	// Frames after a failed start are dropped without another status per frame.
	h.send(yuyv(2, 2, 1))
	h.send(protocol.Ping(5))
	if p := expect[protocol.Pong](h); p != 5 {
		t.Fatalf("pong %d", p)
	}
	h.conn.Close()
}
