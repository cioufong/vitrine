package win

// Win32 structures passed to the API, laid out for 64-bit Windows
// (amd64/arm64). Kept free of build tags so their sizes and offsets are
// checked by tests on any 64-bit host against the MSDN layouts.

// mouseInput is MOUSEINPUT.
type mouseInput struct {
	Dx        int32
	Dy        int32
	MouseData uint32
	Flags     uint32
	Time      uint32
	ExtraInfo uintptr
}

// keybdInput is KEYBDINPUT.
type keybdInput struct {
	Vk        uint16
	Scan      uint16
	Flags     uint32
	Time      uint32
	ExtraInfo uintptr
}

// mouseINPUT is INPUT with type INPUT_MOUSE. MOUSEINPUT is the union's
// largest member, so this is exactly sizeof(INPUT) (40 bytes).
type mouseINPUT struct {
	Type uint32
	Mi   mouseInput
}

// keybdINPUT is INPUT with type INPUT_KEYBOARD, padded to sizeof(INPUT).
type keybdINPUT struct {
	Type uint32
	Ki   keybdInput
	_    [8]byte
}

const (
	inputMouse    = 0
	inputKeyboard = 1
)

// rect is RECT.
type rect struct{ Left, Top, Right, Bottom int32 }

// point is POINT.
type point struct{ X, Y int32 }

// msg is MSG.
type msg struct {
	Hwnd     uintptr
	Message  uint32
	WParam   uintptr
	LParam   uintptr
	Time     uint32
	Pt       point
	LPrivate uint32
}

// wndClassEx is WNDCLASSEXW.
type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   uintptr
	Icon       uintptr
	Cursor     uintptr
	Background uintptr
	MenuName   *uint16
	ClassName  *uint16
	IconSm     uintptr
}

// bitmapInfoHeader is BITMAPINFOHEADER (a BITMAPINFO with no colour table
// is enough for 32-bit BI_RGB DIB sections).
type bitmapInfoHeader struct {
	Size          uint32
	Width         int32
	Height        int32
	Planes        uint16
	BitCount      uint16
	Compression   uint32
	SizeImage     uint32
	XPelsPerMeter int32
	YPelsPerMeter int32
	ClrUsed       uint32
	ClrImportant  uint32
}
