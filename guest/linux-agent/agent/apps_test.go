package agent

import (
	"fmt"
	"testing"
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// appBackend is a fakeBackend whose catalog and icon calls block until released.
type appBackend struct {
	fakeBackend
	release  chan struct{}
	catalogs chan int // icon sizes of the catalog calls, as they start
	icons    chan string
}

func (b *appBackend) AppCatalog(iconSize int) (protocol.AppCatalog, error) {
	b.catalogs <- iconSize
	<-b.release
	return protocol.AppCatalog{Apps: []protocol.CatalogApp{{ID: "x", Name: "X"}}}, nil
}

func (b *appBackend) AppIcon(key string) ([]byte, error) {
	b.icons <- key
	<-b.release
	return []byte("png"), nil
}

func (b *appBackend) LaunchApp(string) error { return nil }

func newAppBackend() *appBackend {
	return &appBackend{release: make(chan struct{}), catalogs: make(chan int, 64), icons: make(chan string, 64)}
}

func TestCatalogRequestsCoalesce(t *testing.T) {
	fb := newAppBackend()
	a := New(fb, false)
	h, _ := newHost(t, a)
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)

	for _, size := range []int{64, 96, 128, 160, 192} {
		h.send(protocol.AppCatalogRequest{IconSize: size})
	}
	h.send(protocol.Ping(1))
	expect[protocol.Pong](h) // all five were dispatched

	if size := <-fb.catalogs; size != 64 {
		t.Fatalf("first catalog built with size %d, want 64", size)
	}
	select {
	case size := <-fb.catalogs:
		t.Fatalf("a second catalog (size %d) was started while the first was still building", size)
	case <-time.After(50 * time.Millisecond):
	}
	close(fb.release)
	if size := <-fb.catalogs; size != 192 {
		t.Fatalf("catalog after the first built with size %d, want the newest request (192)", size)
	}
	select {
	case size := <-fb.catalogs:
		t.Fatalf("unexpected third catalog build (size %d)", size)
	case <-time.After(50 * time.Millisecond):
	}
	expect[protocol.AppCatalog](h)
	expect[protocol.AppCatalog](h)
}

func TestIconRequestsAreBoundedAndQueued(t *testing.T) {
	fb := newAppBackend()
	a := New(fb, false)
	h, _ := newHost(t, a)
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)

	// Entering Coherence with many apps whose icons aren't cached asks for all of them at once.
	n := maxIconRequests + 5
	for i := 0; i < n; i++ {
		h.send(protocol.AppIconRequest{Key: fmt.Sprintf("app%d", i)})
	}
	h.send(protocol.Ping(1))
	expect[protocol.Pong](h)
	started := 0
	for started < maxIconRequests {
		<-fb.icons
		started++
	}
	select {
	case <-fb.icons:
		t.Fatalf("more than %d icon requests ran at once", maxIconRequests)
	case <-time.After(50 * time.Millisecond):
	}
	close(fb.release)
	got := map[string]bool{}
	for i := 0; i < n; i++ {
		got[expect[protocol.AppIcon](h).Key] = true
	}
	if len(got) != n {
		t.Fatalf("answered %d distinct icon requests, want %d (none dropped)", len(got), n)
	}
}

func TestRepeatedIconRequestIsAnsweredOnce(t *testing.T) {
	fb := newAppBackend()
	a := New(fb, false)
	h, _ := newHost(t, a)
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)

	for i := 0; i < 3; i++ {
		h.send(protocol.AppIconRequest{Key: "k"})
	}
	h.send(protocol.Ping(1))
	expect[protocol.Pong](h) // the repeats have been handled
	<-fb.icons
	close(fb.release)
	expect[protocol.AppIcon](h)
	h.send(protocol.Ping(2))
	expect[protocol.Pong](h)
	// Asked again once answered: answered again.
	h.send(protocol.AppIconRequest{Key: "k"})
	expect[protocol.AppIcon](h)
}
