package win

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/png"
	"testing"
	"unsafe"

	"github.com/cioufong/vitrine/guest/linux-agent/keymap"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

func TestScancodeTable(t *testing.T) {
	cases := []struct {
		name string
		vk   uint16
		code uint16
		ext  bool
	}{
		{"A", 0x00, 0x1E, false},
		{"1", 0x12, 0x02, false},
		{"Return", 0x24, 0x1C, false},
		{"Space", 0x31, 0x39, false},
		{"Backspace", 0x33, 0x0E, false},
		{"Escape", 0x35, 0x01, false},
		{"Tab", 0x30, 0x0F, false},
		{"F1", 0x7A, 0x3B, false},
		{"F12", 0x6F, 0x58, false},
		{"F13", 0x69, 0x64, false},
		{"Left", 0x7B, 0x4B, true},
		{"Right", 0x7C, 0x4D, true},
		{"Up", 0x7E, 0x48, true},
		{"Down", 0x7D, 0x50, true},
		{"Home", 0x73, 0x47, true},
		{"End", 0x77, 0x4F, true},
		{"PageUp", 0x74, 0x49, true},
		{"PageDown", 0x79, 0x51, true},
		{"ForwardDelete", 0x75, 0x53, true},
		{"Help→Insert", 0x72, 0x52, true},
		{"RightControl", 0x3E, 0x1D, true},
		{"RightOption→AltGr", 0x3D, 0x38, true},
		{"KeypadEnter", 0x4C, 0x1C, true},
		{"KeypadDivide", 0x4B, 0x35, true},
		{"KeypadClear→NumLock", 0x47, 0x45, true},
		{"Keypad7", 0x59, 0x47, false},
		{"Mute", 0x4A, 0x20, true},
		{"ContextMenu→Apps", 0x6E, 0x5D, true},
		{"Shift", 0x38, 0x2A, false},
		{"Option→Alt", 0x3A, 0x38, false},
		{"Control", 0x3B, 0x1D, false},
		{"Command→LWin (win mode)", 0x37, 0x5B, true},
	}
	for _, c := range cases {
		sc, ok := ScancodeFor(c.vk, keymap.CommandAsSuper)
		if !ok || sc.Code != c.code || sc.Extended != c.ext {
			t.Errorf("%s: got %+v,%v want %#x ext=%v", c.name, sc, ok, c.code, c.ext)
		}
	}
	// Default Windows mode: ⌘ → Ctrl.
	if sc, _ := ScancodeFor(0x37, keymap.CommandAsControl); sc != scLeftCtrl {
		t.Errorf("⌘ (ctrl mode) = %+v", sc)
	}
	if sc, _ := ScancodeFor(0x36, keymap.CommandAsControl); sc != scRightCtrl {
		t.Errorf("right ⌘ (ctrl mode) = %+v", sc)
	}
	if _, ok := ScancodeFor(keymap.VKFunction, keymap.CommandAsControl); ok {
		t.Error("fn must not map")
	}
	// Every key the X11 table knows (except the PowerBook keypad-Enter alias)
	// must also map on Windows, with distinct scancodes.
	seen := map[Scancode]uint16{}
	for _, vk := range keymap.VirtualKeys() {
		if vk == 0x34 {
			continue
		}
		sc, ok := ScancodeFor(vk, keymap.CommandAsSuper)
		if !ok {
			t.Errorf("kVK 0x%02X has no scancode", vk)
			continue
		}
		if sc.Code == 0 || sc.Code > 0x7F {
			t.Errorf("kVK 0x%02X → bad code %#x", vk, sc.Code)
		}
		if prev, dup := seen[sc]; dup {
			t.Errorf("kVK 0x%02X and 0x%02X share %+v", prev, vk, sc)
		}
		seen[sc] = vk
	}
	if modifierScancode(keymap.FlagCommand, keymap.CommandAsControl) != scLeftCtrl ||
		modifierScancode(keymap.FlagCommand, keymap.CommandAsSuper) != scLeftWin ||
		modifierScancode(keymap.FlagOption, keymap.CommandAsControl) != scLeftAlt {
		t.Error("modifierScancode")
	}
}

func TestCoordinates(t *testing.T) {
	// Single 1920x1080 monitor.
	if v := normalizeAbs(0, 0, 1920); v != 0 {
		t.Errorf("left edge %d", v)
	}
	if v := normalizeAbs(1919, 0, 1920); v != 65535 {
		t.Errorf("right edge %d", v)
	}
	if v := normalizeAbs(960, 0, 1920); v != 32785 {
		t.Errorf("middle %d", v)
	}
	// Virtual desktop starting left of the primary monitor.
	if v := normalizeAbs(-1280, -1280, 3200); v != 0 {
		t.Errorf("negative origin %d", v)
	}
	if v := normalizeAbs(5000, 0, 1920); v != 65535 {
		t.Errorf("clamp %d", v)
	}
	// 150 % scaling: points ↔ pixels.
	s := scaleForDPI(144)
	if s != 1.5 || scaleForDPI(0) != 1 || scaleForDPI(96) != 1 {
		t.Errorf("scale %v", s)
	}
	if px := toPixel(100, s, -1280); px != -1130 {
		t.Errorf("toPixel %d", px)
	}
	if pt := toPoint(-1130, s, -1280); pt != 100 {
		t.Errorf("toPoint %v", pt)
	}
	// SetWindowPos rect keeps the 7 px invisible borders around the DWM frame.
	frame := pxRect{100, 100, 900, 700}
	window := pxRect{93, 100, 907, 707}
	got := outerFromFrame(pxRect{10, 20, 610, 420}, frame, window)
	if got != (pxRect{3, 20, 617, 427}) {
		t.Errorf("outerFromFrame %+v", got)
	}
}

func TestWheelNotches(t *testing.T) {
	var acc float64
	if n := wheelNotches(&acc, 3, false); n != 3 {
		t.Errorf("lines %d", n)
	}
	if n := wheelNotches(&acc, 0.2, false); n != 1 {
		t.Errorf("small line delta %d", n)
	}
	if n := wheelNotches(&acc, -25, true); n != -2 || acc != -5 {
		t.Errorf("precise %d acc %v", n, acc)
	}
	if n := wheelNotches(&acc, -5, true); n != -1 || acc != 0 {
		t.Errorf("precise carry %d acc %v", n, acc)
	}
}

func TestClassify(t *testing.T) {
	screen := pxRect{0, 0, 1920, 1080}
	base := winCandidate{Class: "Notepad", Title: "Untitled - Notepad", Visible: true, PID: 10, SelfPID: 99,
		Frame: pxRect{100, 100, 900, 700}, Screen: screen}
	with := func(f func(*winCandidate)) winCandidate { c := base; f(&c); return c }
	cases := []struct {
		name  string
		c     winCandidate
		ok    bool
		kind  string
		layer int
	}{
		{"normal", base, true, protocol.KindNormal, 0},
		{"topmost", with(func(c *winCandidate) { c.ExStyle = wsExTopmost }), true, protocol.KindNormal, 3},
		{"owned dialog", with(func(c *winCandidate) { c.HasOwner = true }), true, protocol.KindPanel, 0},
		{"popup menu", with(func(c *winCandidate) { c.Class = "#32768"; c.Title = "" }), true, protocol.KindMenu, 101},
		{"tooltip", with(func(c *winCandidate) { c.Class = "tooltips_class32" }), true, protocol.KindMenu, 101},
		{"tool window", with(func(c *winCandidate) { c.ExStyle = wsExToolWindow }), true, protocol.KindMenu, 101},
		{"hidden", with(func(c *winCandidate) { c.Visible = false }), false, "", 0},
		{"minimized", with(func(c *winCandidate) { c.Iconic = true }), false, "", 0},
		{"cloaked", with(func(c *winCandidate) { c.Cloaked = true }), false, "", 0},
		{"taskbar", with(func(c *winCandidate) { c.Class = "Shell_TrayWnd" }), false, "", 0},
		{"desktop", with(func(c *winCandidate) { c.Class = "Progman" }), false, "", 0},
		{"wallpaper", with(func(c *winCandidate) { c.Class = "WorkerW" }), false, "", 0},
		{"menu shadow", with(func(c *winCandidate) { c.Class = "SysShadow" }), false, "", 0},
		{"agent itself", with(func(c *winCandidate) { c.PID = 99 }), false, "", 0},
		{"zero size", with(func(c *winCandidate) { c.Frame = pxRect{5, 5, 5, 50} }), false, "", 0},
		{"off-screen", with(func(c *winCandidate) { c.Frame = pxRect{-32000, -32000, -31840, -31973} }), false, "", 0},
		{"click-through overlay", with(func(c *winCandidate) { c.Title = ""; c.ExStyle = wsExTransparent | wsExLayered }), false, "", 0},
		{"child", with(func(c *winCandidate) { c.Style = wsChild }), false, "", 0},
	}
	for _, c := range cases {
		kind, layer, ok := classify(c.c)
		if ok != c.ok || kind != c.kind || layer != c.layer {
			t.Errorf("%s: got %q %d %v", c.name, kind, layer, ok)
		}
	}
	if appNameFromImage(`C:\Windows\System32\notepad.exe`) != "notepad" ||
		appNameFromImage(`C:\Program Files\App\Tool.EXE`) != "Tool" || appNameFromImage("") != "" {
		t.Error("appNameFromImage")
	}
}

func TestOSName(t *testing.T) {
	cases := []struct {
		product, display, build string
		ubr                     uint64
		want                    string
	}{
		{"Windows 10 Pro", "24H2", "26100", 2033, "Windows 11 Pro 24H2 (build 26100.2033)"},
		{"Windows 10 Enterprise", "22H2", "19045", 0, "Windows 10 Enterprise 22H2 (build 19045)"},
		{"", "", "", 0, "Windows"},
	}
	for _, c := range cases {
		if got := osName(c.product, c.display, c.build, c.ubr); got != c.want {
			t.Errorf("osName = %q want %q", got, c.want)
		}
	}
}

// Struct layouts must match the 64-bit Windows ABI (MSDN sizes).
func TestStructLayouts(t *testing.T) {
	if unsafe.Sizeof(uintptr(0)) != 8 {
		t.Skip("layout checks assume a 64-bit host")
	}
	checks := []struct {
		name      string
		got, want uintptr
	}{
		{"sizeof(INPUT) mouse", unsafe.Sizeof(mouseINPUT{}), 40},
		{"sizeof(INPUT) keyboard", unsafe.Sizeof(keybdINPUT{}), 40},
		{"offsetof(INPUT.mi)", unsafe.Offsetof(mouseINPUT{}.Mi), 8},
		{"offsetof(INPUT.ki)", unsafe.Offsetof(keybdINPUT{}.Ki), 8},
		{"sizeof(MOUSEINPUT)", unsafe.Sizeof(mouseInput{}), 32},
		{"offsetof(MOUSEINPUT.dwExtraInfo)", unsafe.Offsetof(mouseInput{}.ExtraInfo), 24},
		{"sizeof(KEYBDINPUT)", unsafe.Sizeof(keybdInput{}), 24},
		{"offsetof(KEYBDINPUT.dwFlags)", unsafe.Offsetof(keybdInput{}.Flags), 4},
		{"offsetof(KEYBDINPUT.dwExtraInfo)", unsafe.Offsetof(keybdInput{}.ExtraInfo), 16},
		{"sizeof(RECT)", unsafe.Sizeof(rect{}), 16},
		{"sizeof(MSG)", unsafe.Sizeof(msg{}), 48},
		{"offsetof(MSG.pt)", unsafe.Offsetof(msg{}.Pt), 36},
		{"sizeof(WNDCLASSEXW)", unsafe.Sizeof(wndClassEx{}), 80},
		{"offsetof(WNDCLASSEXW.lpszClassName)", unsafe.Offsetof(wndClassEx{}.ClassName), 64},
		{"sizeof(BITMAPINFOHEADER)", unsafe.Sizeof(bitmapInfoHeader{}), 40},
	}
	for _, c := range checks {
		if c.got != c.want {
			t.Errorf("%s = %d, want %d", c.name, c.got, c.want)
		}
	}
}

func testImage() *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, 3, 2))
	img.SetNRGBA(0, 0, color.NRGBA{255, 0, 0, 255})
	img.SetNRGBA(1, 0, color.NRGBA{0, 255, 0, 128})
	img.SetNRGBA(2, 0, color.NRGBA{0, 0, 255, 255})
	img.SetNRGBA(0, 1, color.NRGBA{10, 20, 30, 255})
	img.SetNRGBA(1, 1, color.NRGBA{40, 50, 60, 0})
	img.SetNRGBA(2, 1, color.NRGBA{70, 80, 90, 255})
	return img
}

func decodePNG(t *testing.T, b []byte) *image.NRGBA {
	t.Helper()
	img, err := png.Decode(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	out := image.NewNRGBA(img.Bounds())
	for y := 0; y < img.Bounds().Dy(); y++ {
		for x := 0; x < img.Bounds().Dx(); x++ {
			out.Set(x, y, img.At(x, y))
		}
	}
	return out
}

func TestPNGDIBRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	png.Encode(&buf, testImage())
	dib, err := pngToDIBV5(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if len(dib) != bitmapV5Size+3*2*4 || binary.LittleEndian.Uint32(dib) != bitmapV5Size {
		t.Fatalf("DIBV5 size %d", len(dib))
	}
	// Bottom-up: the first stored row is the image's last row; BGRA order.
	if px := dib[bitmapV5Size : bitmapV5Size+4]; !bytes.Equal(px, []byte{30, 20, 10, 255}) {
		t.Fatalf("first stored pixel % x", px)
	}
	back, err := dibToPNG(dib)
	if err != nil {
		t.Fatal(err)
	}
	if got := decodePNG(t, back); !bytes.Equal(got.Pix, testImage().Pix) {
		t.Fatalf("round trip pixels\n got %v\nwant %v", got.Pix, testImage().Pix)
	}
}

func TestDIB24BitPadded(t *testing.T) {
	// 3x2 24-bit bottom-up BI_RGB: rows are 9 bytes padded to 12.
	hdr := make([]byte, bitmapInfoSize)
	le := binary.LittleEndian
	le.PutUint32(hdr[0:], bitmapInfoSize)
	le.PutUint32(hdr[4:], 3)
	le.PutUint32(hdr[8:], 2)
	le.PutUint16(hdr[12:], 1)
	le.PutUint16(hdr[14:], 24)
	bottom := []byte{30, 20, 10, 60, 50, 40, 90, 80, 70, 0, 0, 0}
	top := []byte{0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0}
	out, err := dibToPNG(append(append(hdr, bottom...), top...))
	if err != nil {
		t.Fatal(err)
	}
	img := decodePNG(t, out)
	want := []color.NRGBA{{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {10, 20, 30, 255}, {40, 50, 60, 255}, {70, 80, 90, 255}}
	for i, w := range want {
		if got := img.NRGBAAt(i%3, i/3); got != w {
			t.Errorf("pixel %d = %v want %v", i, got, w)
		}
	}
	// 32-bit BI_RGB with all-zero alpha bytes is opaque, top-down variant.
	le.PutUint16(hdr[14:], 32)
	le.PutUint32(hdr[8:], uint32(0xFFFFFFFF)) // height -1
	le.PutUint32(hdr[4:], 1)
	out, err = dibToPNG(append(append([]byte(nil), hdr...), 1, 2, 3, 0))
	if err != nil {
		t.Fatal(err)
	}
	if got := decodePNG(t, out).NRGBAAt(0, 0); got != (color.NRGBA{3, 2, 1, 255}) {
		t.Errorf("32-bit BI_RGB pixel %v", got)
	}
	if _, err := dibToPNG(hdr[:10]); err == nil {
		t.Error("short DIB must fail")
	}
}
