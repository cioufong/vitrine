package agent

import (
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

func TestIconRequestsAreBounded(t *testing.T) {
	fb := newAppBackend()
	a := New(fb, false)
	h, _ := newHost(t, a)
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)

	for i := 0; i < maxIconRequests+3; i++ {
		h.send(protocol.AppIconRequest{Key: "k"})
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
	for i := 0; i < maxIconRequests; i++ {
		expect[protocol.AppIcon](h)
	}
}
