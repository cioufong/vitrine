package agent

import (
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// jobBackend records share mappings and file drops in the order they start.
// Mapping server "slow" blocks until release is closed.
type jobBackend struct {
	fakeBackend
	jmu     sync.Mutex
	ran     []string
	started chan struct{}
	release chan struct{}
}

func newJobBackend() *jobBackend {
	return &jobBackend{started: make(chan struct{}, 1), release: make(chan struct{})}
}

func (b *jobBackend) record(s string) {
	b.jmu.Lock()
	b.ran = append(b.ran, s)
	b.jmu.Unlock()
}

func (b *jobBackend) runs() []string {
	b.jmu.Lock()
	defer b.jmu.Unlock()
	return slices.Clone(b.ran)
}

func (b *jobBackend) MountShares(m protocol.MountShares) error {
	b.record("mount " + m.Server)
	if m.Server == "slow" {
		b.started <- struct{}{}
		<-b.release
	}
	return nil
}

func (b *jobBackend) ReceiveFiles(d protocol.FileDrop) error {
	b.record("drop " + d.Files[0])
	return nil
}

func mount(server string) protocol.MountShares { return protocol.MountShares{Server: server} }
func drop(name string) protocol.FileDrop       { return protocol.FileDrop{Files: []string{name}} }

// sync waits until the agent has handled everything sent before.
func (h *host) sync() {
	h.t.Helper()
	h.send(protocol.Ping(42))
	expect[protocol.Pong](h)
}

// connect starts a session and reads the agent's announcement.
func connect(t *testing.T, a *Agent) (*host, chan struct{}) {
	h, done := newHost(t, a)
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)
	return h, done
}

func waitRuns(t *testing.T, b *jobBackend, want ...string) {
	t.Helper()
	waitFor(t, fmt.Sprint(want), func() bool { return slices.Equal(b.runs(), want) })
}

// Shares and drops run one at a time in arrival order; a mapping queued right
// behind another replaces it.
func TestJobsRunInOrder(t *testing.T) {
	b := newJobBackend()
	h, _ := connect(t, New(b, false))
	defer h.conn.Close()
	h.send(mount("slow"))
	<-b.started
	for _, m := range []protocol.Message{mount("a"), drop("1"), mount("b"), mount("c"), drop("2")} {
		h.send(m)
	}
	h.sync()
	if got := b.runs(); !slices.Equal(got, []string{"mount slow"}) {
		t.Fatalf("ran %v while the first mapping was still running", got)
	}
	close(b.release)
	waitRuns(t, b, "mount slow", "mount a", "drop 1", "mount c", "drop 2")
}

// A session that has since been replaced loses its queued share lists, not its file drops.
func TestReplacedSessionSkipsOnlyItsShareLists(t *testing.T) {
	b := newJobBackend()
	a := New(b, false)
	h1, done1 := connect(t, a)
	h1.send(mount("slow"))
	<-b.started
	h1.send(drop("old"))
	h1.send(mount("old"))
	h1.sync()

	h2, _ := connect(t, a)
	defer h2.conn.Close()
	<-done1
	h2.send(drop("new"))
	h2.sync()
	close(b.release)
	// The replaced session's share list is outdated and skipped; its file drop was already
	// reported delivered to the host, so it still runs (in order, before the new one).
	waitRuns(t, b, "mount slow", "drop old", "drop new")
}

// After a reconnect the new session's share list (fresh credentials) runs before
// drops left by the old session, and gets in even when the queue is full.
func TestNewShareListGoesAheadOfOldDrops(t *testing.T) {
	b := newJobBackend()
	a := New(b, false)
	h1, done1 := connect(t, a)
	h1.send(mount("slow"))
	<-b.started
	for i := 0; i < maxJobs; i++ {
		h1.send(drop(fmt.Sprint(i)))
	}
	h1.sync()

	h2, _ := connect(t, a)
	defer h2.conn.Close()
	<-done1
	h2.send(mount("new"))
	h2.sync()
	close(b.release)
	want := []string{"mount slow", "mount new"} // drop 0 made room for it
	for i := 1; i < maxJobs; i++ {
		want = append(want, fmt.Sprintf("drop %d", i))
	}
	waitRuns(t, b, want...)
}

// The queue is bounded: requests beyond it are dropped and reported, and the
// read loop keeps serving.
func TestJobQueueBounded(t *testing.T) {
	b := newJobBackend()
	h, _ := connect(t, New(b, false))
	defer h.conn.Close()
	h.send(mount("slow"))
	<-b.started
	for i := 0; i < maxJobs+5; i++ {
		h.send(drop(fmt.Sprint(i)))
	}
	for {
		if l := expect[protocol.Log](h); strings.Contains(string(l), "file drop: dropped") {
			break
		}
	}
	h.sync()
	close(b.release)
	want := []string{"mount slow"}
	for i := 0; i < maxJobs; i++ {
		want = append(want, fmt.Sprintf("drop %d", i))
	}
	waitRuns(t, b, want...)
}
