//go:build windows

package win

import (
	"fmt"
	"runtime"

	"golang.org/x/sys/windows"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// WindowAction implements agent.Backend.
func (b *Backend) WindowAction(a protocol.WindowAction) error {
	h := windows.HWND(uintptr(a.WindowID))
	if !windows.IsWindow(h) {
		return fmt.Errorf("unknown window %#x", a.WindowID)
	}
	switch a.Action {
	case protocol.ActionFocus:
		b.focus(h)
	case protocol.ActionClose:
		procPostMessageW.Call(uintptr(h), wmClose, 0, 0)
	case protocol.ActionMinimize:
		procShowWindowAsync.Call(uintptr(h), swMinimize)
	case protocol.ActionZoom:
		if boolCall(procIsZoomed, uintptr(h)) {
			procShowWindowAsync.Call(uintptr(h), swRestore)
		} else {
			procShowWindowAsync.Call(uintptr(h), swMaximize)
		}
	case protocol.ActionMove, protocol.ActionResize:
		if a.Frame == nil {
			return fmt.Errorf("%s without frame", a.Action)
		}
		g, ok := b.lookup(a.WindowID)
		if !ok {
			return fmt.Errorf("unknown window %#x", a.WindowID)
		}
		b.moveResize(g, *a.Frame, a.Action == protocol.ActionResize)
	default:
		return fmt.Errorf("unknown action %q", a.Action)
	}
	return nil
}

// focus brings h to the foreground. SetForegroundWindow usually succeeds
// because the agent injected the user's last input; otherwise the calling
// thread temporarily attaches to the foreground thread's input queue, which
// lifts the foreground lock.
func (b *Backend) focus(h windows.HWND) {
	if boolCall(procIsIconic, uintptr(h)) {
		procShowWindowAsync.Call(uintptr(h), swRestore)
	}
	if boolCall(procSetForegroundWindow, uintptr(h)) && windows.GetForegroundWindow() == h {
		return
	}
	runtime.LockOSThread() // AttachThreadInput is per thread
	defer runtime.UnlockOSThread()
	fgThread, _ := windows.GetWindowThreadProcessId(windows.GetForegroundWindow(), nil)
	self := windows.GetCurrentThreadId()
	if fgThread != 0 && fgThread != self {
		procAttachThreadInput.Call(uintptr(self), uintptr(fgThread), 1)
		defer procAttachThreadInput.Call(uintptr(self), uintptr(fgThread), 0)
	}
	procBringWindowToTop.Call(uintptr(h))
	if boolCall(procSetForegroundWindow, uintptr(h)) && windows.GetForegroundWindow() == h {
		return
	}
	// Foreground lock (real Windows enforces it; Wine doesn't): a process may take the foreground
	// while it is the source of the latest input. Hold Alt across the call — and tap Ctrl before
	// releasing it, so the Alt press/release can't activate the target window's menu bar.
	alt, ctrl := Scancode{Code: 0x38}, Scancode{Code: 0x1D}
	sendKeys([]keybdINPUT{keyInput(alt, true)})
	ok := boolCall(procSetForegroundWindow, uintptr(h))
	sendKeys([]keybdINPUT{keyInput(ctrl, true), keyInput(ctrl, false), keyInput(alt, false)})
	if !ok || windows.GetForegroundWindow() != h {
		b.opts.Logf("could not focus window %#x (foreground lock)", uintptr(h))
	}
}

// moveResize places the window so its visible frame lands on target (points).
func (b *Backend) moveResize(g winGeom, target protocol.Rect, resize bool) {
	vs := virtualScreenRect()
	s := b.scale()
	x, y := toPixel(target.X, s, vs.X), toPixel(target.Y, s, vs.Y)
	frame := pxRect{int(g.frame.Left), int(g.frame.Top), int(g.frame.Right), int(g.frame.Bottom)}
	w, h := frame.width(), frame.height()
	if resize {
		w, h = toPixel(target.Width, s, 0), toPixel(target.Height, s, 0)
	}
	outer := outerFromFrame(pxRect{x, y, x + w, y + h}, frame,
		pxRect{int(g.window.Left), int(g.window.Top), int(g.window.Right), int(g.window.Bottom)})
	if boolCall(procIsZoomed, uintptr(g.hwnd)) {
		procShowWindowAsync.Call(uintptr(g.hwnd), swRestore)
	}
	flags := uintptr(swpNoZOrder | swpNoActivate | swpAsyncWindowPos)
	if !resize {
		flags |= swpNoSize
	}
	procSetWindowPos.Call(uintptr(g.hwnd), 0,
		uintptr(int32(outer.Left)), uintptr(int32(outer.Top)),
		uintptr(int32(outer.width())), uintptr(int32(outer.height())), flags)
}
