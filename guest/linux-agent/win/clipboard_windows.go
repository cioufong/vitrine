//go:build windows

package win

import (
	"errors"
	"runtime"
	"sync"
	"time"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

const (
	maxClipboardBytes = 32 << 20
	wmSetClipboard    = wmApp + 1
)

// clipboard owns a message-only window on a dedicated OS thread: it listens
// for WM_CLIPBOARDUPDATE and performs all clipboard reads and writes there.
type clipboard struct {
	logf   func(string, ...any)
	hwnd   uintptr
	pngFmt uintptr // registered "PNG" format

	mu       sync.Mutex
	lastFP   [32]byte
	hasFP    bool
	onChange func(protocol.Clipboard)

	reqs chan setReq
}

type setReq struct {
	content protocol.Clipboard
	done    chan error
}

// The window procedure is a process-wide C callback, so it reaches the
// (single) clipboard instance through this variable.
var (
	theClip     *clipboard
	wndProcAddr = windows.NewCallback(wndProc)
)

func wndProc(hwnd, message, wParam, lParam uintptr) uintptr {
	c := theClip
	if c != nil && hwnd == c.hwnd {
		switch message {
		case wmClipboardUpdate:
			c.onUpdate()
			return 0
		case wmSetClipboard:
			c.drain()
			return 0
		}
	}
	r, _, _ := procDefWindowProcW.Call(hwnd, message, wParam, lParam)
	return r
}

func newClipboard(logf func(string, ...any)) (*clipboard, error) {
	if theClip != nil {
		return nil, errors.New("clipboard already started")
	}
	c := &clipboard{logf: logf, reqs: make(chan setReq, 8)}
	name, _ := windows.UTF16PtrFromString("PNG")
	c.pngFmt, _, _ = procRegisterClipboardFormatW.Call(uintptr(unsafe.Pointer(name)))
	ready := make(chan error, 1)
	go c.run(ready)
	if err := <-ready; err != nil {
		return nil, err
	}
	return c, nil
}

func (c *clipboard) run(ready chan<- error) {
	runtime.LockOSThread() // the window and its message loop live on this thread
	var inst windows.Handle
	windows.GetModuleHandleEx(0, nil, &inst)
	cls, _ := windows.UTF16PtrFromString("VitrineAgentClipboard")
	wc := wndClassEx{WndProc: wndProcAddr, Instance: uintptr(inst), ClassName: cls}
	wc.Size = uint32(unsafe.Sizeof(wc))
	if a, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc))); a == 0 {
		ready <- errors.New("RegisterClassExW: " + err.Error())
		return
	}
	theClip = c
	hwnd, _, err := procCreateWindowExW.Call(0, uintptr(unsafe.Pointer(cls)), uintptr(unsafe.Pointer(cls)),
		0, 0, 0, 0, 0, hwndMessage, 0, uintptr(inst), 0)
	if hwnd == 0 {
		theClip = nil
		ready <- errors.New("CreateWindowExW: " + err.Error())
		return
	}
	c.hwnd = hwnd
	if !boolCall(procAddClipboardFormatListener, hwnd) {
		theClip = nil
		ready <- errors.New("AddClipboardFormatListener failed")
		return
	}
	ready <- nil
	var m msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			return
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
}

func (c *clipboard) close() {} // the listener lives as long as the process

func (c *clipboard) setHandler(fn func(protocol.Clipboard)) {
	c.mu.Lock()
	c.onChange = fn
	c.mu.Unlock()
}

// set hands host content to the window thread and waits for the write.
func (c *clipboard) set(content protocol.Clipboard) error {
	req := setReq{content: content, done: make(chan error, 1)}
	c.reqs <- req
	procPostMessageW.Call(c.hwnd, wmSetClipboard, 0, 0)
	select {
	case err := <-req.done:
		return err
	case <-time.After(5 * time.Second):
		return errors.New("clipboard write timed out")
	}
}

func (c *clipboard) drain() {
	for {
		select {
		case req := <-c.reqs:
			req.done <- c.write(req.content)
		default:
			return
		}
	}
}

// open retries OpenClipboard: another application may hold it briefly.
func (c *clipboard) open() bool {
	for i := 0; i < 20; i++ {
		if boolCall(procOpenClipboard, c.hwnd) {
			return true
		}
		time.Sleep(15 * time.Millisecond)
	}
	return false
}

// write replaces the clipboard with text and/or PNG (+ CF_DIBV5 for apps
// that do not read PNG). Runs on the window thread.
func (c *clipboard) write(content protocol.Clipboard) error {
	var text, img []byte
	for _, it := range content.Items {
		switch it.Type {
		case protocol.UTIPlainText:
			text = it.Data
		case protocol.UTIPNG:
			img = it.Data
		}
	}
	if text == nil && img == nil {
		return nil // nothing representable
	}
	c.mu.Lock()
	c.lastFP, c.hasFP = content.Fingerprint(), true
	c.mu.Unlock()
	if !c.open() {
		return errors.New("OpenClipboard failed")
	}
	defer procCloseClipboard.Call()
	procEmptyClipboard.Call() // makes our window the owner
	if text != nil {
		u := utf16.Encode([]rune(string(text)))
		u = append(u, 0)
		setData(cfUnicodeText, unsafe.Slice((*byte)(unsafe.Pointer(&u[0])), len(u)*2))
	}
	if img != nil {
		if c.pngFmt != 0 {
			setData(c.pngFmt, img)
		}
		if dib, err := pngToDIBV5(img); err == nil {
			setData(cfDIBV5, dib)
		}
	}
	return nil
}

// setData copies b into a movable global block owned by the clipboard.
func setData(format uintptr, b []byte) {
	h, _, _ := procGlobalAlloc.Call(gmemMoveable, uintptr(len(b)))
	if h == 0 {
		return
	}
	p, _, _ := procGlobalLock.Call(h)
	if p == 0 {
		procGlobalFree.Call(h)
		return
	}
	copy(unsafe.Slice((*byte)(ptr(p)), len(b)), b)
	procGlobalUnlock.Call(h)
	if r, _, _ := procSetClipboardData.Call(format, h); r == 0 {
		procGlobalFree.Call(h) // ownership only transfers on success
	}
}

// getData copies a clipboard format's global block (clipboard must be open).
func getData(format uintptr) []byte {
	h, _, _ := procGetClipboardData.Call(format)
	if h == 0 {
		return nil
	}
	size, _, _ := procGlobalSize.Call(h)
	if size == 0 || size > maxClipboardBytes {
		return nil
	}
	p, _, _ := procGlobalLock.Call(h)
	if p == 0 {
		return nil
	}
	defer procGlobalUnlock.Call(h)
	return append([]byte(nil), unsafe.Slice((*byte)(ptr(p)), size)...)
}

// ptr turns a handle-derived address (memory not managed by Go) into a
// pointer without tripping vet's uintptr→unsafe.Pointer check.
func ptr(u uintptr) unsafe.Pointer { return *(*unsafe.Pointer)(unsafe.Pointer(&u)) }

// onUpdate runs on WM_CLIPBOARDUPDATE: read and forward foreign content.
func (c *clipboard) onUpdate() {
	if owner, _, _ := procGetClipboardOwner.Call(); owner == c.hwnd {
		return // our own write
	}
	content := c.read()
	if len(content.Items) == 0 {
		return
	}
	fp := content.Fingerprint()
	c.mu.Lock()
	dup := c.hasFP && fp == c.lastFP
	c.lastFP, c.hasFP = fp, true
	fn := c.onChange
	c.mu.Unlock()
	if !dup && fn != nil {
		fn(content)
	}
}

func (c *clipboard) read() protocol.Clipboard {
	var out protocol.Clipboard
	if !c.open() {
		return out
	}
	defer procCloseClipboard.Call()
	if boolCall(procIsClipboardFormatAvailable, cfUnicodeText) {
		if b := getData(cfUnicodeText); len(b) >= 2 {
			u := unsafe.Slice((*uint16)(unsafe.Pointer(&b[0])), len(b)/2)
			for i, v := range u {
				if v == 0 {
					u = u[:i]
					break
				}
			}
			if len(u) > 0 {
				out.Items = append(out.Items, protocol.ClipboardItem{Type: protocol.UTIPlainText,
					Data: []byte(string(utf16.Decode(u)))})
			}
		}
	}
	var png []byte
	if c.pngFmt != 0 && boolCall(procIsClipboardFormatAvailable, c.pngFmt) {
		png = getData(c.pngFmt)
	}
	if png == nil {
		for _, f := range []uintptr{cfDIBV5, cfDIB} {
			if boolCall(procIsClipboardFormatAvailable, f) {
				if dib := getData(f); dib != nil {
					if p, err := dibToPNG(dib); err == nil {
						png = p
						break
					}
				}
			}
		}
	}
	if len(png) > 0 {
		out.Items = append(out.Items, protocol.ClipboardItem{Type: protocol.UTIPNG, Data: png})
	}
	return out
}
