//go:build windows

package win

import (
	"errors"
	"runtime"
	"sync"
	"time"
	"unsafe"

	"github.com/cioufong/vitrine/guest/linux-agent/agent"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
	"github.com/cioufong/vitrine/guest/linux-agent/screen"
)

const (
	maxBandBytes      = 8 << 20
	backPressureLimit = 48 << 20
	diffTile          = 64
	// maxCaptureFPS bounds full-screen GDI grabs (each is a whole-desktop
	// BitBlt plus a diff); the host's maxFPS lowers it further.
	maxCaptureFPS = 30
)

// stream grabs the whole virtual screen with GDI and sends the tiles that
// changed since the previous grab.
type stream struct {
	b        *Backend
	sink     agent.FrameSink
	fps      int
	stop     chan struct{}
	done     chan struct{}
	stopOnce sync.Once
}

// StartStream implements agent.Backend.
func (b *Backend) StartStream(fps int, sink agent.FrameSink) (agent.Stream, error) {
	if vs := virtualScreenRect(); vs.W <= 0 || vs.H <= 0 {
		return nil, errors.New("virtual screen unavailable")
	}
	s := &stream{b: b, sink: sink, fps: min(fps, maxCaptureFPS), stop: make(chan struct{}), done: make(chan struct{})}
	go s.run()
	return s, nil
}

// Stop implements agent.Stream.
func (s *stream) Stop() {
	s.stopOnce.Do(func() { close(s.stop) })
	<-s.done
}

// gdiSurface is a top-down 32-bit DIB section selected into a memory DC.
type gdiSurface struct {
	screenDC, memDC, bitmap, old uintptr
	bits                         []byte
	w, h                         int
}

func newGDISurface(w, h int) (*gdiSurface, error) {
	g := &gdiSurface{w: w, h: h}
	g.screenDC, _, _ = procGetDC.Call(0)
	if g.screenDC == 0 {
		return nil, errors.New("GetDC(NULL) failed")
	}
	g.memDC, _, _ = procCreateCompatibleDC.Call(g.screenDC)
	if g.memDC == 0 {
		g.close()
		return nil, errors.New("CreateCompatibleDC failed")
	}
	bmi := bitmapInfoHeader{
		Size: uint32(unsafe.Sizeof(bitmapInfoHeader{})), Width: int32(w), Height: -int32(h), // negative: top-down rows
		Planes: 1, BitCount: 32, Compression: biRGB,
	}
	var bits unsafe.Pointer
	g.bitmap, _, _ = procCreateDIBSection.Call(g.memDC, uintptr(unsafe.Pointer(&bmi)), dibRGBColors,
		uintptr(unsafe.Pointer(&bits)), 0, 0)
	if g.bitmap == 0 || bits == nil {
		g.close()
		return nil, errors.New("CreateDIBSection failed")
	}
	g.old, _, _ = procSelectObject.Call(g.memDC, g.bitmap)
	g.bits = unsafe.Slice((*byte)(bits), w*h*4)
	return g, nil
}

// grab copies the screen region at (x, y) into the DIB. CAPTUREBLT includes
// layered (translucent / per-pixel alpha) windows.
func (g *gdiSurface) grab(x, y int) bool {
	ok, _, _ := procBitBlt.Call(g.memDC, 0, 0, uintptr(g.w), uintptr(g.h), g.screenDC,
		uintptr(int32(x)), uintptr(int32(y)), srcCopy|captureBlt)
	return ok != 0
}

func (g *gdiSurface) close() {
	if g.memDC != 0 {
		if g.old != 0 {
			procSelectObject.Call(g.memDC, g.old)
		}
		procDeleteDC.Call(g.memDC)
	}
	if g.bitmap != 0 {
		procDeleteObject.Call(g.bitmap)
	}
	if g.screenDC != 0 {
		procReleaseDC.Call(0, g.screenDC)
	}
	g.bits = nil
}

func (s *stream) run() {
	// GetDC/ReleaseDC must happen on one thread.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	defer close(s.done)

	var (
		surf        *gdiSurface
		vs          virtualScreen
		cur, prev   []byte
		region      = screen.Region{MaxRects: 32}
		grabFailing bool
	)
	defer func() {
		if surf != nil {
			surf.close()
		}
	}()
	ticker := time.NewTicker(time.Second / time.Duration(max(1, s.fps)))
	defer ticker.Stop()
	for first := true; ; first = false {
		if !first {
			select {
			case <-s.stop:
				return
			case <-ticker.C:
			}
		}
		if now := virtualScreenRect(); surf == nil || now != vs {
			if surf != nil {
				surf.close()
				surf = nil
			}
			var err error
			if surf, err = newGDISurface(now.W, now.H); err != nil {
				s.sink.Logf("capture: %v", err)
				continue
			}
			if !first {
				s.sink.Logf("screen resized to %dx%d", now.W, now.H)
				s.sink.DisplayChanged() // DisplayInfo goes out before the full frame
			} else {
				s.sink.Logf("capture %dx%d via GDI", now.W, now.H)
			}
			vs, prev = now, nil
			cur = make([]byte, vs.W*vs.H*4)
			region.AddFull()
		}
		if !surf.grab(vs.X, vs.Y) {
			// Secure desktop (UAC, lock screen) or a session switch.
			if !grabFailing {
				s.sink.Logf("capture: BitBlt failed (secure desktop?)")
				grabFailing = true
			}
			continue
		}
		grabFailing = false
		screen.BGRXToBGRA(cur, surf.bits, vs.W, vs.H, vs.W*4)
		if prev != nil {
			for _, r := range screen.DiffTiles(prev, cur, vs.W, vs.H, diffTile) {
				region.Add(r)
			}
		}
		if prev == nil {
			prev = make([]byte, len(cur))
		}
		cur, prev = prev, cur // prev now holds the latest frame
		if region.Empty() || s.sink.Pending() > backPressureLimit {
			continue // dirty tiles accumulate until the host catches up
		}
		for _, r := range region.Take(screen.Rect{W: vs.W, H: vs.H}) {
			for _, band := range screen.SplitBands(r, maxBandBytes) {
				if !s.sink.SendFrame(protocol.Frame{
					SurfaceWidth: uint32(vs.W), SurfaceHeight: uint32(vs.H),
					X: uint32(band.X), Y: uint32(band.Y), Width: uint32(band.W), Height: uint32(band.H),
					Encoding: protocol.EncodingRaw, Data: screen.Crop(prev, vs.W, band),
				}) {
					return
				}
			}
		}
	}
}
