// Package agent implements the platform-independent side of the guest agent:
// the host connection, message dispatch and the coherence/window-list loops.
package agent

import (
	"io"
	"sync"
	"sync/atomic"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// Conn is one host connection. Sends are queued and written by a single
// goroutine; Pending reports queued bytes so producers can apply back-pressure.
type Conn struct {
	rw      io.ReadWriteCloser
	queue   chan outgoing
	done    chan struct{}
	pending atomic.Int64
	once    sync.Once
}

type outgoing struct{ head, body []byte }

// NewConn starts the writer goroutine for rw.
func NewConn(rw io.ReadWriteCloser) *Conn {
	c := &Conn{rw: rw, queue: make(chan outgoing, 4096), done: make(chan struct{})}
	go c.writeLoop()
	return c
}

func (c *Conn) writeLoop() {
	for {
		select {
		case <-c.done:
			return
		case o := <-c.queue:
			_, err := c.rw.Write(o.head)
			if err == nil && len(o.body) > 0 {
				_, err = c.rw.Write(o.body)
			}
			c.pending.Add(-int64(len(o.head) + len(o.body)))
			if err != nil {
				c.Close()
				return
			}
		}
	}
}

// Send queues a message. It returns false if the connection is closed or the
// message could not be encoded. Frame pixel buffers are not copied, so the
// caller must not reuse them after Send.
func (c *Conn) Send(m protocol.Message) bool { return c.SendCancel(m, nil) }

// SendCancel is Send that also gives up (returning false) when cancel is
// closed, so a producer blocked on a full queue — the host stopped reading —
// can be stopped without first closing the connection.
func (c *Conn) SendCancel(m protocol.Message, cancel <-chan struct{}) bool {
	head, body, err := protocol.EncodeParts(m)
	if err != nil {
		return false
	}
	n := int64(len(head) + len(body))
	c.pending.Add(n)
	select {
	case <-c.done:
	case <-cancel: // nil channel: never
	case c.queue <- outgoing{head, body}:
		return true
	}
	c.pending.Add(-n)
	return false
}

// TrySend queues a message only if the queue has room right now. Used for
// best-effort traffic (log lines) that must never stall the caller.
func (c *Conn) TrySend(m protocol.Message) bool {
	select {
	case <-c.done:
		return false
	default:
	}
	head, body, err := protocol.EncodeParts(m)
	if err != nil {
		return false
	}
	n := int64(len(head) + len(body))
	c.pending.Add(n)
	select {
	case c.queue <- outgoing{head, body}:
		return true
	default:
		c.pending.Add(-n)
		return false
	}
}

// Pending returns the number of queued, unwritten bytes.
func (c *Conn) Pending() int64 { return c.pending.Load() }

// Done is closed when the connection is closed.
func (c *Conn) Done() <-chan struct{} { return c.done }

// Close closes the connection (idempotent).
func (c *Conn) Close() {
	c.once.Do(func() {
		close(c.done)
		c.rw.Close()
	})
}

// ReadLoop decodes incoming messages until the connection fails or closes.
func (c *Conn) ReadLoop(fn func(protocol.Message)) error {
	return protocol.ReadLoop(c.rw, fn)
}
