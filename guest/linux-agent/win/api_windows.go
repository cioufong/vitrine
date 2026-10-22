//go:build windows

package win

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// Lazily bound Win32 entry points not wrapped by x/sys/windows. All of them
// exist on Windows 10 1703+ (SetProcessDpiAwarenessContext) and Windows 11.
var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	gdi32    = windows.NewLazySystemDLL("gdi32.dll")
	dwmapi   = windows.NewLazySystemDLL("dwmapi.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")

	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procSetProcessDPIAware            = user32.NewProc("SetProcessDPIAware")
	procGetDpiForSystem               = user32.NewProc("GetDpiForSystem")
	procGetSystemMetrics              = user32.NewProc("GetSystemMetrics")
	procGetWindowLongPtrW             = user32.NewProc("GetWindowLongPtrW")
	procGetWindow                     = user32.NewProc("GetWindow")
	procIsIconic                      = user32.NewProc("IsIconic")
	procIsZoomed                      = user32.NewProc("IsZoomed")
	procGetWindowRect                 = user32.NewProc("GetWindowRect")
	procGetWindowTextW                = user32.NewProc("GetWindowTextW")
	procGetWindowTextLengthW          = user32.NewProc("GetWindowTextLengthW")
	procSendInput                     = user32.NewProc("SendInput")
	procSetForegroundWindow           = user32.NewProc("SetForegroundWindow")
	procBringWindowToTop              = user32.NewProc("BringWindowToTop")
	procAttachThreadInput             = user32.NewProc("AttachThreadInput")
	procShowWindowAsync               = user32.NewProc("ShowWindowAsync")
	procPostMessageW                  = user32.NewProc("PostMessageW")
	procSetWindowPos                  = user32.NewProc("SetWindowPos")
	procGetDC                         = user32.NewProc("GetDC")
	procReleaseDC                     = user32.NewProc("ReleaseDC")
	procOpenClipboard                 = user32.NewProc("OpenClipboard")
	procCloseClipboard                = user32.NewProc("CloseClipboard")
	procEmptyClipboard                = user32.NewProc("EmptyClipboard")
	procGetClipboardData              = user32.NewProc("GetClipboardData")
	procSetClipboardData              = user32.NewProc("SetClipboardData")
	procIsClipboardFormatAvailable    = user32.NewProc("IsClipboardFormatAvailable")
	procRegisterClipboardFormatW      = user32.NewProc("RegisterClipboardFormatW")
	procGetClipboardOwner             = user32.NewProc("GetClipboardOwner")
	procAddClipboardFormatListener    = user32.NewProc("AddClipboardFormatListener")
	procRegisterClassExW              = user32.NewProc("RegisterClassExW")
	procCreateWindowExW               = user32.NewProc("CreateWindowExW")
	procDefWindowProcW                = user32.NewProc("DefWindowProcW")
	procGetMessageW                   = user32.NewProc("GetMessageW")
	procTranslateMessage              = user32.NewProc("TranslateMessage")
	procDispatchMessageW              = user32.NewProc("DispatchMessageW")

	procCreateCompatibleDC = gdi32.NewProc("CreateCompatibleDC")
	procCreateDIBSection   = gdi32.NewProc("CreateDIBSection")
	procSelectObject       = gdi32.NewProc("SelectObject")
	procBitBlt             = gdi32.NewProc("BitBlt")
	procDeleteObject       = gdi32.NewProc("DeleteObject")
	procDeleteDC           = gdi32.NewProc("DeleteDC")

	procDwmGetWindowAttribute = dwmapi.NewProc("DwmGetWindowAttribute")

	procGlobalAlloc  = kernel32.NewProc("GlobalAlloc")
	procGlobalFree   = kernel32.NewProc("GlobalFree")
	procGlobalLock   = kernel32.NewProc("GlobalLock")
	procGlobalUnlock = kernel32.NewProc("GlobalUnlock")
	procGlobalSize   = kernel32.NewProc("GlobalSize")
)

// Constants (winuser.h, wingdi.h, dwmapi.h, winbase.h).
const (
	dpiAwarenessContextPerMonitorAwareV2 = ^uintptr(3) // (DPI_AWARENESS_CONTEXT)-4

	smXVirtualScreen  = 76
	smYVirtualScreen  = 77
	smCXVirtualScreen = 78
	smCYVirtualScreen = 79

	gwlStyle   = -16
	gwlExStyle = -20
	gwOwner    = 4

	dwmwaExtendedFrameBounds = 9
	dwmwaCloaked             = 14

	mouseeventfMove        = 0x0001
	mouseeventfLeftDown    = 0x0002
	mouseeventfLeftUp      = 0x0004
	mouseeventfRightDown   = 0x0008
	mouseeventfRightUp     = 0x0010
	mouseeventfMiddleDown  = 0x0020
	mouseeventfMiddleUp    = 0x0040
	mouseeventfWheel       = 0x0800
	mouseeventfHWheel      = 0x1000
	mouseeventfVirtualDesk = 0x4000
	mouseeventfAbsolute    = 0x8000

	keyeventfExtendedKey = 0x0001
	keyeventfKeyUp       = 0x0002
	keyeventfUnicode     = 0x0004
	keyeventfScancode    = 0x0008

	swMaximize = 3
	swMinimize = 6
	swRestore  = 9

	swpNoSize          = 0x0001
	swpNoZOrder        = 0x0004
	swpNoActivate      = 0x0010
	swpAsyncWindowPos  = 0x4000
	wmClose            = 0x0010
	wmClipboardUpdate  = 0x031D
	wmApp              = 0x8000
	hwndMessage        = ^uintptr(2) // (HWND)-3
	cfUnicodeText      = 13
	cfDIB              = 8
	cfDIBV5            = 17
	gmemMoveable       = 0x0002
	srcCopy            = 0x00CC0020
	captureBlt         = 0x40000000
	dibRGBColors       = 0
	attachThreadInputs = 1
)

func getSystemMetrics(i int) int {
	r, _, _ := procGetSystemMetrics.Call(uintptr(i))
	return int(int32(r))
}

func virtualScreenRect() virtualScreen {
	return virtualScreen{
		X: getSystemMetrics(smXVirtualScreen), Y: getSystemMetrics(smYVirtualScreen),
		W: getSystemMetrics(smCXVirtualScreen), H: getSystemMetrics(smCYVirtualScreen),
	}
}

func getWindowLong(h windows.HWND, index int) uint32 {
	r, _, _ := procGetWindowLongPtrW.Call(uintptr(h), uintptr(index)) // index is sign-extended
	return uint32(r)
}

func boolCall(p *windows.LazyProc, args ...uintptr) bool {
	r, _, _ := p.Call(args...)
	return r != 0
}

func dwmRect(h windows.HWND) (rect, bool) {
	var r rect
	hr, _, _ := procDwmGetWindowAttribute.Call(uintptr(h), dwmwaExtendedFrameBounds,
		uintptr(unsafe.Pointer(&r)), unsafe.Sizeof(r))
	return r, hr == 0
}

func windowRect(h windows.HWND) (rect, bool) {
	var r rect
	ok := boolCall(procGetWindowRect, uintptr(h), uintptr(unsafe.Pointer(&r)))
	return r, ok
}

func isCloaked(h windows.HWND) bool {
	var v uint32
	hr, _, _ := procDwmGetWindowAttribute.Call(uintptr(h), dwmwaCloaked, uintptr(unsafe.Pointer(&v)), unsafe.Sizeof(v))
	return hr == 0 && v != 0
}

func windowText(h windows.HWND) string {
	n, _, _ := procGetWindowTextLengthW.Call(uintptr(h))
	if n == 0 {
		return ""
	}
	buf := make([]uint16, n+1)
	r, _, _ := procGetWindowTextW.Call(uintptr(h), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	return windows.UTF16ToString(buf[:r])
}

func className(h windows.HWND) string {
	buf := make([]uint16, 256)
	n, err := windows.GetClassName(h, &buf[0], int32(len(buf)))
	if err != nil {
		return ""
	}
	return windows.UTF16ToString(buf[:n])
}

func sendMouse(in []mouseINPUT) {
	if len(in) > 0 {
		procSendInput.Call(uintptr(len(in)), uintptr(unsafe.Pointer(&in[0])), unsafe.Sizeof(in[0]))
	}
}

func sendKeys(in []keybdINPUT) {
	if len(in) > 0 {
		procSendInput.Call(uintptr(len(in)), uintptr(unsafe.Pointer(&in[0])), unsafe.Sizeof(in[0]))
	}
}
