package agent

import (
	"bytes"
	"encoding/binary"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestCameraPipeMessage(t *testing.T) {
	pix := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	b := cameraPipeMessage(2, 2, pix)
	if len(b) != cameraPipeHeader+len(pix) {
		t.Fatalf("len %d", len(b))
	}
	if w, h := binary.LittleEndian.Uint32(b), binary.LittleEndian.Uint32(b[4:]); w != 2 || h != 2 {
		t.Fatalf("header %dx%d", w, h)
	}
	if !bytes.Equal(b[cameraPipeHeader:], pix) {
		t.Fatalf("pixels %v", b[cameraPipeHeader:])
	}
	// 1280×720, as convert.h's test reads it.
	if b := cameraPipeMessage(1280, 720, nil); !bytes.Equal(b, []byte{0x00, 0x05, 0, 0, 0xd0, 0x02, 0, 0}) {
		t.Fatalf("header % x", b)
	}
}

// pipeReader is a fake pipe client: Write blocks while gate is held, and fails after Close.
type pipeReader struct {
	mu     sync.Mutex
	gate   sync.Mutex
	frames [][]byte
	closed chan struct{}
	once   sync.Once
}

func newPipeReader() *pipeReader { return &pipeReader{closed: make(chan struct{})} }

func (r *pipeReader) Write(p []byte) (int, error) {
	done := make(chan struct{})
	go func() { r.gate.Lock(); r.gate.Unlock(); close(done) }()
	select {
	case <-done:
	case <-r.closed:
		return 0, errors.New("closed")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.frames = append(r.frames, append([]byte(nil), p...))
	return len(p), nil
}

func (r *pipeReader) Close() error { r.once.Do(func() { close(r.closed) }); return nil }

func (r *pipeReader) got() [][]byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([][]byte(nil), r.frames...)
}

func TestCameraFanoutBroadcast(t *testing.T) {
	f := newCameraFanout()
	f.send(2, 2, make([]byte, 8)) // nobody connected: dropped
	a, b := newPipeReader(), newPipeReader()
	f.add(a)
	f.add(b)
	f.send(2, 2, bytes.Repeat([]byte{7}, 8))
	for _, r := range []*pipeReader{a, b} {
		waitFor(t, "frame", func() bool { return len(r.got()) == 1 })
		if g := r.got()[0]; len(g) != cameraPipeHeader+8 || g[cameraPipeHeader] != 7 {
			t.Fatalf("frame % x", g)
		}
	}
	f.close()
	if f.add(newPipeReader()) {
		t.Fatal("add after close")
	}
}

// A reader that stalls doesn't hold up the others, skips the frames it missed and gets the
// newest one when it resumes.
func TestCameraFanoutSlowReader(t *testing.T) {
	f := newCameraFanout()
	slow, fast := newPipeReader(), newPipeReader()
	slow.gate.Lock()
	f.add(slow)
	f.add(fast)
	for i := byte(1); i <= 5; i++ {
		f.send(2, 2, bytes.Repeat([]byte{i}, 8))
		waitFor(t, "fast reader", func() bool { return len(fast.got()) == int(i) })
	}
	slow.gate.Unlock()
	waitFor(t, "slow reader", func() bool {
		g := slow.got()
		return len(g) > 0 && g[len(g)-1][cameraPipeHeader] == 5
	})
	if n := len(slow.got()); n > 2 {
		t.Fatalf("slow reader got %d frames, want the first and the newest", n)
	}
	f.close()
}

// close unblocks a reader stuck in Write.
func TestCameraFanoutCloseUnblocks(t *testing.T) {
	f := newCameraFanout()
	r := newPipeReader()
	r.gate.Lock()
	f.add(r)
	f.send(2, 2, make([]byte, 8))
	time.Sleep(10 * time.Millisecond)
	done := make(chan struct{})
	go func() { f.close(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("close blocked on a stuck reader")
	}
}
