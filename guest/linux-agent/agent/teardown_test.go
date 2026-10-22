package agent

import (
	"strings"
	"testing"
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// deafHost connects a host that writes but never reads: the agent's writer
// blocks on the pipe and its send queue fills up.
func deafHost(t *testing.T, a *Agent) (send func(protocol.Message), done chan struct{}) {
	guest, hostSide := pipe()
	done = make(chan struct{})
	go func() { a.Serve(guest); close(done) }()
	return func(m protocol.Message) {
		b, _ := protocol.Encode(m)
		hostSide.w.Write(b)
	}, done
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// Replacing a session runs the old session's teardown exactly once, and its
// input reset completes before the new session injects anything.
func TestReplacementTearsDownOnceBeforeNewInput(t *testing.T) {
	fb := &fakeBackend{}
	a := New(fb, false)
	h1, done1 := newHost(t, a)
	expect[protocol.Hello](h1)
	expect[protocol.DisplayInfo](h1)
	h1.send(protocol.SetCoherence{Enabled: true, MaxFPS: 30})
	expect[protocol.DisplayInfo](h1)
	expect[protocol.Frame](h1)

	h2, _ := newHost(t, a)
	expect[protocol.Hello](h2)
	expect[protocol.DisplayInfo](h2)
	select {
	case <-done1:
	case <-time.After(2 * time.Second):
		t.Fatal("old session not torn down")
	}
	h2.send(protocol.Key{KeyCode: 0x00, Down: true, Text: "a"})
	h2.send(protocol.Ping(1))
	expect[protocol.Pong](h2)

	fb.mu.Lock()
	events := strings.Join(fb.events, ",")
	resets, stopped := fb.resets, fb.stopped
	fb.mu.Unlock()
	if resets != 1 || events != "reset,key" {
		t.Fatalf("want exactly one reset before the new key, got resets=%d events=%s", resets, events)
	}
	if stopped != 1 {
		t.Fatalf("old stream stopped %d times", stopped)
	}
	h2.conn.Close()
}

// A host that stops reading fills the send queue; the capture producer then
// blocks in SendFrame. Disabling coherence must still return (the stream's
// sends are cancelled), and so must replacing the session.
func TestBlockedProducerDoesNotDeadlock(t *testing.T) {
	fb := &fakeBackend{flood: true, floodSent: make(chan int, 4)}
	a := New(fb, false)
	send, done1 := deafHost(t, a)
	send(protocol.SetCoherence{Enabled: true, MaxFPS: 30})
	// Wait until the queue is full (the flood stops making progress).
	waitFor(t, "queue to fill", func() bool {
		s := a.current()
		return s != nil && len(s.conn.queue) == cap(s.conn.queue)
	})

	// Host still writes: turning coherence off must cancel the blocked producer.
	send(protocol.SetCoherence{Enabled: false})
	select {
	case n := <-fb.floodSent:
		if n < 4000 {
			t.Fatalf("flood stopped early after %d frames", n)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("stream producer still blocked after coherence off")
	}

	_ = done1
}

// Replacing a session whose producer is blocked on a full queue completes:
// the old connection is closed before capture is joined.
func TestReplacementWithBlockedProducer(t *testing.T) {
	fb := &fakeBackend{flood: true, floodSent: make(chan int, 4)}
	a := New(fb, false)
	send, done1 := deafHost(t, a)
	send(protocol.SetCoherence{Enabled: true, MaxFPS: 30})
	waitFor(t, "queue to fill", func() bool {
		s := a.current()
		return s != nil && len(s.conn.queue) == cap(s.conn.queue)
	})
	fb.mu.Lock()
	fb.flood = false // the new session gets a normal stream
	fb.mu.Unlock()

	h2, _ := newHost(t, a)
	select {
	case <-done1:
	case <-time.After(3 * time.Second):
		t.Fatal("replacement deadlocked on the deaf session")
	}
	expect[protocol.Hello](h2)
	expect[protocol.DisplayInfo](h2)
	h2.send(protocol.Ping(3))
	if p := expect[protocol.Pong](h2); p != 3 {
		t.Fatal("new session not serving")
	}
	fb.mu.Lock()
	if fb.stopped != 1 || fb.resets != 1 {
		t.Fatalf("stopped=%d resets=%d", fb.stopped, fb.resets)
	}
	fb.mu.Unlock()
	h2.conn.Close()
}

func TestSendCancel(t *testing.T) {
	_, hostSide := pipe()
	c := NewConn(hostSide) // nobody reads the other end: the writer blocks
	for i := 0; i < cap(c.queue)+1; i++ {
		if !c.Send(protocol.Ping(uint64(i))) {
			t.Fatal("send failed early")
		}
	}
	cancel := make(chan struct{})
	res := make(chan bool)
	go func() { res <- c.SendCancel(protocol.Ping(0), cancel) }()
	select {
	case <-res:
		t.Fatal("SendCancel returned while the queue is full")
	case <-time.After(50 * time.Millisecond):
	}
	before := c.Pending()
	close(cancel)
	if <-res {
		t.Fatal("cancelled SendCancel reported success")
	}
	if c.Pending() >= before {
		t.Fatal("pending bytes not released on cancel")
	}
	c.Close()
	if c.Send(protocol.Ping(1)) {
		t.Fatal("send after close succeeded")
	}
}
