//go:build windows

package win

import (
	"sync"

	"golang.org/x/sys/windows"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// winGeom remembers a listed window's geometry for move/resize.
type winGeom struct {
	hwnd   windows.HWND
	frame  rect // DWMWA_EXTENDED_FRAME_BOUNDS (what the host sees)
	window rect // GetWindowRect (what SetWindowPos takes; includes invisible borders)
}

// EnumWindows needs a C callback; windows.NewCallback slots are limited, so
// one is created for the process and fed through a package-level slice.
var (
	enumMu   sync.Mutex
	enumOut  []windows.HWND
	enumProc = windows.NewCallback(func(hwnd uintptr, _ uintptr) uintptr {
		enumOut = append(enumOut, windows.HWND(hwnd))
		return 1 // continue
	})
)

// topLevelWindows returns all top-level windows in z-order, topmost first.
func topLevelWindows() []windows.HWND {
	enumMu.Lock()
	defer enumMu.Unlock()
	enumOut = enumOut[:0]
	windows.EnumWindows(enumProc, nil)
	return append([]windows.HWND(nil), enumOut...)
}

// Windows implements agent.Backend: visible top-level windows front-to-back,
// frames in guest points relative to the virtual screen's top-left.
func (b *Backend) Windows() ([]protocol.WindowInfo, error) {
	vs := virtualScreenRect()
	scale := b.scale()
	screen := pxRect{vs.X, vs.Y, vs.X + vs.W, vs.Y + vs.H}
	fg := windows.GetForegroundWindow()
	geoms := map[uint32]winGeom{}
	livePIDs := map[uint32]bool{}
	var out []protocol.WindowInfo
	for _, h := range topLevelWindows() {
		if !windows.IsWindowVisible(h) {
			continue // cheap rejection before the other queries
		}
		var pid uint32
		windows.GetWindowThreadProcessId(h, &pid)
		frame, ok := dwmRect(h)
		if !ok {
			if frame, ok = windowRect(h); !ok {
				continue
			}
		}
		owner, _, _ := procGetWindow.Call(uintptr(h), gwOwner)
		c := winCandidate{
			Class:    className(h),
			Title:    windowText(h),
			Style:    getWindowLong(h, gwlStyle),
			ExStyle:  getWindowLong(h, gwlExStyle),
			Visible:  true,
			Iconic:   boolCall(procIsIconic, uintptr(h)),
			Cloaked:  isCloaked(h),
			HasOwner: owner != 0,
			PID:      pid,
			SelfPID:  b.selfPID,
			Frame:    pxRect{int(frame.Left), int(frame.Top), int(frame.Right), int(frame.Bottom)},
			Screen:   screen,
		}
		kind, layer, ok := classify(c)
		if !ok {
			continue
		}
		wr, _ := windowRect(h)
		geoms[uint32(h)] = winGeom{hwnd: h, frame: frame, window: wr}
		livePIDs[pid] = true
		exe := b.exe(pid)
		if isFrameHost(exe.path) { // a UWP app: name it after the app in the frame
			if app := hostedAppPID(h, pid); app != 0 {
				livePIDs[app] = true
				exe = b.exe(app)
			}
		}
		var bundleID *string
		if exe.path != "" {
			p := exe.path
			bundleID = &p // groups windows by executable on the host (Dock icons)
		}
		out = append(out, protocol.WindowInfo{
			ID:       uint32(h),
			PID:      int32(pid),
			AppName:  b.displayName(exe),
			BundleID: bundleID,
			Title:    c.Title,
			Frame: protocol.Rect{
				X: toPoint(c.Frame.Left, scale, vs.X), Y: toPoint(c.Frame.Top, scale, vs.Y),
				Width: float64(c.Frame.width()) / scale, Height: float64(c.Frame.height()) / scale,
			},
			Layer:     layer,
			Kind:      kind,
			IsFocused: h == fg,
		})
	}
	b.winMu.Lock()
	b.geoms = geoms
	for pid := range b.exes {
		if !livePIDs[pid] {
			delete(b.exes, pid) // pids are recycled
		}
	}
	b.winMu.Unlock()
	return out, nil
}

// exeInfo is a process's executable: display name, full path and, for Store
// apps, the AppUserModelID (whose Start menu name wins once known).
type exeInfo struct{ name, path, aumid string }

// displayName prefers the Start menu name of a packaged app ("Paint").
func (b *Backend) displayName(e exeInfo) string {
	if e.aumid != "" {
		if n := b.startNames.lookup(e.aumid); n != "" {
			return n
		}
	}
	return e.name
}

// exe returns a process's executable info (FileDescription or base name), cached per pid.

func (b *Backend) exe(pid uint32) exeInfo {
	b.winMu.Lock()
	info, ok := b.exes[pid]
	b.winMu.Unlock()
	if ok {
		return info
	}
	if h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid); err == nil {
		buf := make([]uint16, windows.MAX_LONG_PATH)
		n := uint32(len(buf))
		if windows.QueryFullProcessImageName(h, 0, &buf[0], &n) == nil {
			info.path = windows.UTF16ToString(buf[:n])
			info.name = appNameFromImage(info.path)
			if d := fileDescription(info.path); usefulDescription(d, info.path) {
				info.name = d
			}
		}
		info.aumid = appUserModelID(h)
		windows.CloseHandle(h)
	}
	b.winMu.Lock()
	b.exes[pid] = info
	b.winMu.Unlock()
	return info
}

// lookup returns the geometry recorded for id, refreshing the snapshot if needed.
func (b *Backend) lookup(id uint32) (winGeom, bool) {
	b.winMu.Lock()
	g, ok := b.geoms[id]
	b.winMu.Unlock()
	if ok {
		return g, true
	}
	b.Windows()
	b.winMu.Lock()
	defer b.winMu.Unlock()
	g, ok = b.geoms[id]
	return g, ok
}
