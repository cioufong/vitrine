package keymap

import "testing"

func TestKnownKeys(t *testing.T) {
	cases := []struct {
		name  string
		vk    uint16
		evdev uint16
		x11   uint8
	}{
		{"A", 0x00, 30, 38},
		{"S", 0x01, 31, 39},
		{"Q", 0x0C, 16, 24},
		{"Z", 0x06, 44, 52},
		{"1", 0x12, 2, 10},
		{"5", 0x17, 6, 14},
		{"6", 0x16, 7, 15},
		{"0", 0x1D, 11, 19},
		{"Return", 0x24, 28, 36},
		{"Tab", 0x30, 15, 23},
		{"Space", 0x31, 57, 65},
		{"Backspace", 0x33, 14, 22},
		{"Escape", 0x35, 1, 9},
		{"ForwardDelete", 0x75, 111, 119},
		{"Home", 0x73, 102, 110},
		{"End", 0x77, 107, 115},
		{"PageUp", 0x74, 104, 112},
		{"PageDown", 0x79, 109, 117},
		{"Left", 0x7B, 105, 113},
		{"Right", 0x7C, 106, 114},
		{"Down", 0x7D, 108, 116},
		{"Up", 0x7E, 103, 111},
		{"Command→Super_L", 0x37, 125, 133},
		{"Option→Alt_L", 0x3A, 56, 64},
		{"Control→Control_L", 0x3B, 29, 37},
		{"Shift", 0x38, 42, 50},
		{"CapsLock", 0x39, 58, 66},
		{"F1", 0x7A, 59, 67},
		{"F12", 0x6F, 88, 96},
		{"F13", 0x69, 183, 191},
		{"F20", 0x5A, 190, 198},
		{"KP0", 0x52, 82, 90},
		{"KPEnter", 0x4C, 96, 104},
		{"Grave", 0x32, 41, 49},
	}
	for _, c := range cases {
		e, ok := Evdev(c.vk)
		if !ok || e != c.evdev {
			t.Errorf("%s: evdev %d,%v want %d", c.name, e, ok, c.evdev)
		}
		x, ok := X11(c.vk)
		if !ok || x != c.x11 {
			t.Errorf("%s: x11 %d,%v want %d", c.name, x, ok, c.x11)
		}
	}
}

func TestTableCoverage(t *testing.T) {
	// Every documented kVK code except kVK_Function must be mapped.
	required := []uint16{
		0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
		0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
		0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
		0x30, 0x31, 0x32, 0x33, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
		0x40, 0x41, 0x43, 0x45, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4E, 0x4F,
		0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
		0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6D, 0x6F,
		0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E,
	}
	for _, vk := range required {
		if _, ok := X11(vk); !ok {
			t.Errorf("kVK 0x%02X not mapped", vk)
		}
	}
	if _, ok := X11(VKFunction); ok {
		t.Error("kVK_Function should not map (no X11 keycode)")
	}
	// The table must be injective apart from the two keypad-Enter aliases.
	seen := map[uint16]uint16{}
	for _, vk := range VirtualKeys() {
		e, _ := Evdev(vk)
		if prev, dup := seen[e]; dup && !(e == 96 && (vk == 0x34 || prev == 0x34)) {
			t.Errorf("evdev %d mapped from both 0x%02X and 0x%02X", e, prev, vk)
		}
		seen[e] = vk
		if x, ok := X11(vk); !ok || x < 8 {
			t.Errorf("kVK 0x%02X → invalid X keycode %d", vk, x)
		}
	}
}

func TestModifiers(t *testing.T) {
	if ModifierFlag(VKRightCommand) != FlagCommand || ModifierFlag(VKShift) != FlagShift || ModifierFlag(0x00) != 0 {
		t.Error("ModifierFlag")
	}
	if !IsModifierKey(VKCapsLock) || IsModifierKey(VKReturn) {
		t.Error("IsModifierKey")
	}
	if CommandAsControl.Remap(KeyLeftMeta) != KeyLeftCtrl || CommandAsSuper.Remap(KeyLeftMeta) != KeyLeftMeta {
		t.Error("Remap")
	}
}

func TestKeysymForRune(t *testing.T) {
	cases := map[rune]uint32{'a': 'a', 'Z': 'Z', ' ': 0x20, 'é': 0xe9, '€': 0x010020ac, '😀': 0x0101f600, '\n': XKReturn, '\t': XKTab}
	for r, want := range cases {
		if got, ok := KeysymForRune(r); !ok || got != want {
			t.Errorf("%q: %#x,%v want %#x", r, got, ok, want)
		}
	}
	if _, ok := KeysymForRune(0x01); ok {
		t.Error("control char should not map")
	}
}

func TestIsSynthesizedText(t *testing.T) {
	cases := []struct {
		code uint16
		text string
		mods uint64
		want bool
	}{
		{0, "a", 0, false},
		{0, "A", FlagShift, false},
		{0, "A", FlagCapsLock, false},
		{0, "A", 0, true},
		{0, "", 0, false},
		{0, "😀", 0, true},
		{0, "hello", 0, true},
		{0, "å", FlagOption, true},
		{0, "\x01", FlagControl, false},
		{0, "x", FlagCommand, false},
		{0, "", 0, false},
		{0x24, "\r", 0, false},
		{0x0B, "b", 0, false},
	}
	for _, c := range cases {
		if got := IsSynthesizedText(c.code, c.text, c.mods); got != c.want {
			t.Errorf("IsSynthesizedText(%d,%q,%#x)=%v", c.code, c.text, c.mods, got)
		}
	}
}
