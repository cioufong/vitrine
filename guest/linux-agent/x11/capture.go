//go:build linux

package x11

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/damage"
	"github.com/jezek/xgb/shm"
	"github.com/jezek/xgb/xfixes"
	"github.com/jezek/xgb/xproto"

	"github.com/cioufong/vitrine/guest/linux-agent/agent"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
	"github.com/cioufong/vitrine/guest/linux-agent/screen"
)

const (
	maxBandBytes      = 8 << 20  // largest frame message payload
	backPressureLimit = 48 << 20 // stop sending while this much is queued
	sizeCheckInterval = 250 * time.Millisecond
	pollInterval      = 200 * time.Millisecond // full-screen diff without Damage
	pollTile          = 64
)

// stream captures the root window on its own X connection so its event
// traffic (DamageNotify) never interferes with the main connection.
type stream struct {
	b    *Backend
	conn *xgb.Conn
	root xproto.Window
	sink agent.FrameSink
	fps  int

	stop     chan struct{}
	done     chan struct{}
	stopOnce sync.Once

	useDamage bool
	dmg       damage.Damage
	parts     xfixes.Region
	dirty     atomic.Bool

	seg *shmSegment

	w, h     int
	region   screen.Region
	cur      []byte // poll mode: latest full frame
	lastPoll time.Time
	grabErr  bool
}

// StartStream implements agent.Backend.
func (b *Backend) StartStream(fps int, sink agent.FrameSink) (agent.Stream, error) {
	if err := b.checkPixelFormat(); err != nil {
		return nil, err
	}
	conn, err := xgb.NewConnDisplay(b.display)
	if err != nil {
		return nil, err
	}
	s := &stream{b: b, conn: conn, root: b.root, sink: sink, fps: fps,
		stop: make(chan struct{}), done: make(chan struct{})}
	s.region.MaxRects = 32
	s.initDamage()
	if err := s.resize(); err != nil {
		conn.Close()
		return nil, err
	}
	mode := "XDamage"
	if !s.useDamage {
		mode = "polling (no XDamage)"
	}
	pix := "MIT-SHM"
	if s.seg == nil {
		pix = "GetImage"
	}
	sink.Logf("capture %dx%d via %s + %s", s.w, s.h, mode, pix)
	go s.events()
	go s.run()
	return s, nil
}

// checkPixelFormat ensures the root is 32bpp little-endian xRGB, i.e. BGRX
// in memory, which maps directly onto the protocol's BGRA.
func (b *Backend) checkPixelFormat() error {
	depth := b.screen.RootDepth
	bpp := 0
	for _, f := range b.setup.PixmapFormats {
		if f.Depth == depth {
			bpp = int(f.BitsPerPixel)
		}
	}
	if bpp != 32 || b.setup.ImageByteOrder != xproto.ImageOrderLSBFirst {
		return fmt.Errorf("unsupported framebuffer: depth %d, %d bpp, byte order %d (need 24/32-bit xRGB)",
			depth, bpp, b.setup.ImageByteOrder)
	}
	for _, d := range b.screen.AllowedDepths {
		for _, v := range d.Visuals {
			if v.VisualId == b.screen.RootVisual && (v.RedMask != 0xff0000 || v.BlueMask != 0xff) {
				return fmt.Errorf("unsupported root visual masks r=%#x b=%#x", v.RedMask, v.BlueMask)
			}
		}
	}
	return nil
}

func (s *stream) initDamage() {
	if xfixes.Init(s.conn) != nil || damage.Init(s.conn) != nil {
		return
	}
	if _, err := xfixes.QueryVersion(s.conn, 5, 0).Reply(); err != nil {
		return
	}
	if _, err := damage.QueryVersion(s.conn, 1, 1).Reply(); err != nil {
		return
	}
	dmg, err := damage.NewDamageId(s.conn)
	if err != nil {
		return
	}
	parts, err := xfixes.NewRegionId(s.conn)
	if err != nil {
		return
	}
	if xfixes.CreateRegionChecked(s.conn, parts, nil).Check() != nil {
		return
	}
	// NonEmpty: one event when the region goes from empty to dirty; the
	// region itself is fetched with Subtract + FetchRegion.
	if damage.CreateChecked(s.conn, dmg, xproto.Drawable(s.root), damage.ReportLevelNonEmpty).Check() != nil {
		xfixes.DestroyRegion(s.conn, parts)
		return
	}
	s.dmg, s.parts, s.useDamage = dmg, parts, true
	s.dirty.Store(true)
}

func (s *stream) events() {
	for {
		ev, err := s.conn.WaitForEvent()
		if ev == nil && err == nil {
			return
		}
		if _, ok := ev.(damage.NotifyEvent); ok {
			s.dirty.Store(true)
		}
	}
}

// Stop implements agent.Stream.
func (s *stream) Stop() {
	s.stopOnce.Do(func() { close(s.stop) })
	<-s.done
}

// resize (re)reads the root geometry and schedules a full frame.
func (s *stream) resize() error {
	g, err := xproto.GetGeometry(s.conn, xproto.Drawable(s.root)).Reply()
	if err != nil {
		return err
	}
	s.w, s.h = int(g.Width), int(g.Height)
	s.region.AddFull()
	s.cur = nil
	need := max(maxBandBytes, s.w*4)
	if s.seg != nil && len(s.seg.data) < need {
		s.seg.close()
		s.seg = nil
	}
	if s.seg == nil && shm.Init(s.conn) == nil {
		if _, err := shm.QueryVersion(s.conn).Reply(); err == nil {
			if seg, err := newShmSegment(s.conn, need); err == nil {
				s.seg = seg
			}
		}
	}
	return nil
}

func (s *stream) run() {
	defer close(s.done)
	defer s.cleanup()
	ticker := time.NewTicker(time.Second / time.Duration(s.fps))
	defer ticker.Stop()
	lastSize := time.Now()
	for {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
		}
		if time.Since(lastSize) >= sizeCheckInterval {
			lastSize = time.Now()
			s.checkSize()
		}
		if s.useDamage {
			if s.dirty.Swap(false) {
				s.collectDamage()
			}
		} else if time.Since(s.lastPoll) >= pollInterval {
			s.lastPoll = time.Now()
			s.poll()
		}
		if s.region.Empty() || s.sink.Pending() > backPressureLimit {
			continue // dirty rects keep accumulating until the host catches up
		}
		if !s.flush() {
			return
		}
	}
}

// flush sends the accumulated dirty region as frame bands. It returns false
// once the connection is gone.
func (s *stream) flush() bool {
	rects := s.region.Take(screen.Rect{W: s.w, H: s.h})
	for i, r := range rects {
		for _, band := range screen.SplitBands(r, maxBandBytes) {
			data, err := s.pixels(band)
			if err != nil {
				// Usually a resize race (the rect no longer fits the root);
				// checkSize then schedules a full frame at the new size.
				if !s.checkSize() {
					if !s.grabErr {
						s.sink.Logf("capture error: %v", err)
						s.grabErr = true
					}
					for _, rest := range rects[i:] {
						s.region.Add(rest)
					}
				}
				return true
			}
			s.grabErr = false
			if !s.sink.SendFrame(protocol.Frame{
				SurfaceWidth: uint32(s.w), SurfaceHeight: uint32(s.h),
				X: uint32(band.X), Y: uint32(band.Y), Width: uint32(band.W), Height: uint32(band.H),
				Encoding: protocol.EncodingRaw, Data: data,
			}) {
				return false
			}
		}
	}
	return true
}

// checkSize resizes the capture (and schedules a full frame) when the root
// window size changed, e.g. after RandR. It reports whether it did.
func (s *stream) checkSize() bool {
	g, err := xproto.GetGeometry(s.conn, xproto.Drawable(s.root)).Reply()
	if err != nil || (int(g.Width) == s.w && int(g.Height) == s.h) {
		return false
	}
	if s.resize() != nil {
		return false
	}
	s.sink.Logf("screen resized to %dx%d", s.w, s.h)
	s.sink.DisplayChanged() // DisplayInfo goes out before the full frame
	return true
}

// collectDamage moves the server's accumulated damage into s.region.
func (s *stream) collectDamage() {
	damage.Subtract(s.conn, s.dmg, xfixes.Region(0), s.parts)
	r, err := xfixes.FetchRegion(s.conn, s.parts).Reply()
	if err != nil {
		s.region.AddFull()
		return
	}
	for _, rc := range r.Rectangles {
		s.region.Add(screen.Rect{X: int(rc.X), Y: int(rc.Y), W: int(rc.Width), H: int(rc.Height)})
	}
}

// poll grabs the whole screen and marks tiles that changed since last time.
func (s *stream) poll() {
	full := make([]byte, s.w*s.h*4)
	for _, band := range screen.SplitBands(screen.Rect{W: s.w, H: s.h}, maxBandBytes) {
		data, err := s.grab(band)
		if err != nil {
			return
		}
		copy(full[band.Y*s.w*4:], data)
	}
	if s.cur != nil {
		for _, r := range screen.DiffTiles(s.cur, full, s.w, s.h, pollTile) {
			s.region.Add(r)
		}
	}
	s.cur = full
}

// pixels returns tightly packed BGRA for r.
func (s *stream) pixels(r screen.Rect) ([]byte, error) {
	if !s.useDamage && s.cur != nil {
		return screen.Crop(s.cur, s.w, r), nil
	}
	return s.grab(r)
}

// grab reads r from the root window (MIT-SHM if possible, else GetImage).
func (s *stream) grab(r screen.Rect) ([]byte, error) {
	n := r.W * r.H * 4
	if s.seg != nil {
		_, err := shm.GetImage(s.conn, xproto.Drawable(s.root), int16(r.X), int16(r.Y), uint16(r.W), uint16(r.H),
			0xffffffff, xproto.ImageFormatZPixmap, s.seg.seg, 0).Reply()
		if err == nil {
			out := make([]byte, n)
			screen.BGRXToBGRA(out, s.seg.data, r.W, r.H, r.W*4)
			return out, nil
		}
		// Only give up on SHM if a plain GetImage of the same rect works;
		// otherwise the rect itself is bad (e.g. mid-resize).
		data, perr := s.getImage(r)
		if perr != nil {
			return nil, perr
		}
		s.sink.Logf("MIT-SHM GetImage failed (%v); using GetImage", err)
		s.seg.close()
		s.seg = nil
		return data, nil
	}
	return s.getImage(r)
}

// getImage reads r with a core GetImage request.
func (s *stream) getImage(r screen.Rect) ([]byte, error) {
	n := r.W * r.H * 4
	img, err := xproto.GetImage(s.conn, xproto.ImageFormatZPixmap, xproto.Drawable(s.root),
		int16(r.X), int16(r.Y), uint16(r.W), uint16(r.H), 0xffffffff).Reply()
	if err != nil {
		return nil, err
	}
	if len(img.Data) < n {
		return nil, fmt.Errorf("GetImage returned %d bytes, want %d", len(img.Data), n)
	}
	data := img.Data[:n]
	screen.BGRXToBGRA(data, data, r.W, r.H, r.W*4) // in place: rows are already tight
	return data, nil
}

func (s *stream) cleanup() {
	if s.useDamage {
		damage.Destroy(s.conn, s.dmg)
		xfixes.DestroyRegion(s.conn, s.parts)
	}
	if s.seg != nil {
		s.seg.close()
	}
	s.conn.Sync()
	s.conn.Close()
}
