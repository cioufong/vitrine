package agent

import (
	"encoding/binary"
	"io"
	"sync"
)

// cameraPipeHeader is the size of a frame message's header on the Windows camera pipe.
const cameraPipeHeader = 8

// cameraPipeMessage frames one YUYV frame for the Windows media source: u32 width, u32 height
// (little-endian), then the pixels. guest/windows-camera/convert.h parses it.
func cameraPipeMessage(w, h int, yuyv []byte) []byte {
	b := make([]byte, cameraPipeHeader+len(yuyv))
	binary.LittleEndian.PutUint32(b[0:], uint32(w))
	binary.LittleEndian.PutUint32(b[4:], uint32(h))
	copy(b[cameraPipeHeader:], yuyv)
	return b
}

// cameraFanout copies frame messages to every connected reader (the Frame Server may run more
// than one instance of the media source), each through its own goroutine and a one-message
// slot: a reader that falls behind gets the newest frame when it's ready instead of slowing the
// agent's connection to the host.
type cameraFanout struct {
	mu      sync.Mutex
	clients map[*fanoutClient]struct{}
	closed  bool
	wg      sync.WaitGroup
}

type fanoutClient struct {
	w    io.WriteCloser
	slot chan []byte
}

func newCameraFanout() *cameraFanout {
	return &cameraFanout{clients: map[*fanoutClient]struct{}{}}
}

// add starts sending frames to w, which is closed when it fails or the fanout closes. It
// returns false (closing w) once the fanout is closed.
func (f *cameraFanout) add(w io.WriteCloser) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		w.Close()
		return false
	}
	c := &fanoutClient{w: w, slot: make(chan []byte, 1)}
	f.clients[c] = struct{}{}
	f.wg.Add(1)
	go f.serve(c)
	return true
}

func (f *cameraFanout) serve(c *fanoutClient) {
	defer f.wg.Done()
	for msg := range c.slot {
		if _, err := c.w.Write(msg); err != nil {
			break
		}
	}
	f.mu.Lock()
	delete(f.clients, c)
	f.mu.Unlock()
	c.w.Close()
}

// send queues a w×h frame for every reader, replacing a frame a reader hasn't taken yet. The
// message is built only when someone is connected.
func (f *cameraFanout) send(w, h int, yuyv []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.clients) == 0 {
		return
	}
	msg := cameraPipeMessage(w, h, yuyv)
	for c := range f.clients {
		select {
		case c.slot <- msg:
		default:
			select {
			case <-c.slot:
			default:
			}
			select {
			case c.slot <- msg:
			default:
			}
		}
	}
}

// close disconnects every reader, unblocking any write in progress, and waits for them.
func (f *cameraFanout) close() {
	f.mu.Lock()
	if f.closed {
		f.mu.Unlock()
		return
	}
	f.closed = true
	for c := range f.clients {
		close(c.slot)
		c.w.Close()
	}
	f.clients = nil
	f.mu.Unlock()
	f.wg.Wait()
}
