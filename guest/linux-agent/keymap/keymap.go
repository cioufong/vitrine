// Package keymap translates macOS virtual key codes (kVK_* from Carbon's
// Events.h) and modifier flags into Linux evdev / X11 keycodes and keysyms.
package keymap

// Linux evdev key codes (linux/input-event-codes.h) used by the table.
const (
	KeyEsc        = 1
	KeyBackspace  = 14
	KeyTab        = 15
	KeyEnter      = 28
	KeyLeftCtrl   = 29
	KeyLeftShift  = 42
	KeyRightShift = 54
	KeyLeftAlt    = 56
	KeySpace      = 57
	KeyCapsLock   = 58
	KeyRightCtrl  = 97
	KeyRightAlt   = 100
	KeyUp         = 103
	KeyLeft       = 105
	KeyRight      = 106
	KeyDown       = 108
	KeyLeftMeta   = 125
	KeyRightMeta  = 126
)

// macOS virtual key codes for the modifier keys.
const (
	VKReturn       = 0x24
	VKSpace        = 0x31
	VKCommand      = 0x37
	VKShift        = 0x38
	VKCapsLock     = 0x39
	VKOption       = 0x3A
	VKControl      = 0x3B
	VKRightCommand = 0x36
	VKRightShift   = 0x3C
	VKRightOption  = 0x3D
	VKRightControl = 0x3E
	VKFunction     = 0x3F
)

// toEvdev maps kVK_* → evdev code. Keys with no Linux equivalent (kVK_Function)
// are intentionally absent.
var toEvdev = map[uint16]uint16{
	// Letters (ANSI positions).
	0x00: 30, // A
	0x01: 31, // S
	0x02: 32, // D
	0x03: 33, // F
	0x04: 35, // H
	0x05: 34, // G
	0x06: 44, // Z
	0x07: 45, // X
	0x08: 46, // C
	0x09: 47, // V
	0x0A: 86, // ISO_Section → KEY_102ND
	0x0B: 48, // B
	0x0C: 16, // Q
	0x0D: 17, // W
	0x0E: 18, // E
	0x0F: 19, // R
	0x10: 21, // Y
	0x11: 20, // T
	0x1F: 24, // O
	0x20: 22, // U
	0x22: 23, // I
	0x23: 25, // P
	0x25: 38, // L
	0x26: 36, // J
	0x28: 37, // K
	0x2D: 49, // N
	0x2E: 50, // M

	// Digits row.
	0x12: 2,  // 1
	0x13: 3,  // 2
	0x14: 4,  // 3
	0x15: 5,  // 4
	0x17: 6,  // 5
	0x16: 7,  // 6
	0x1A: 8,  // 7
	0x1C: 9,  // 8
	0x19: 10, // 9
	0x1D: 11, // 0
	0x1B: 12, // Minus
	0x18: 13, // Equal

	// Punctuation.
	0x21: 26, // LeftBracket
	0x1E: 27, // RightBracket
	0x29: 39, // Semicolon
	0x27: 40, // Quote
	0x32: 41, // Grave
	0x2A: 43, // Backslash
	0x2B: 51, // Comma
	0x2F: 52, // Period
	0x2C: 53, // Slash

	// Editing / whitespace.
	0x24: KeyEnter,     // Return
	0x30: KeyTab,       // Tab
	0x31: KeySpace,     // Space
	0x33: KeyBackspace, // Delete (backspace)
	0x35: KeyEsc,       // Escape
	0x75: 111,          // ForwardDelete → KEY_DELETE
	0x72: 110,          // Help → KEY_INSERT (same position on Apple extended keyboards)
	0x73: 102,          // Home
	0x77: 107,          // End
	0x74: 104,          // PageUp
	0x79: 109,          // PageDown
	0x6E: 127,          // ContextualMenu → KEY_COMPOSE (Menu)

	// Arrows.
	0x7B: KeyLeft,
	0x7C: KeyRight,
	0x7D: KeyDown,
	0x7E: KeyUp,

	// Modifiers.
	VKCommand:      KeyLeftMeta,
	VKRightCommand: KeyRightMeta,
	VKShift:        KeyLeftShift,
	VKRightShift:   KeyRightShift,
	VKOption:       KeyLeftAlt,
	VKRightOption:  KeyRightAlt,
	VKControl:      KeyLeftCtrl,
	VKRightControl: KeyRightCtrl,
	VKCapsLock:     KeyCapsLock,

	// Function keys.
	0x7A: 59,  // F1
	0x78: 60,  // F2
	0x63: 61,  // F3
	0x76: 62,  // F4
	0x60: 63,  // F5
	0x61: 64,  // F6
	0x62: 65,  // F7
	0x64: 66,  // F8
	0x65: 67,  // F9
	0x6D: 68,  // F10
	0x67: 87,  // F11
	0x6F: 88,  // F12
	0x69: 183, // F13
	0x6B: 184, // F14
	0x71: 185, // F15
	0x6A: 186, // F16
	0x40: 187, // F17
	0x4F: 188, // F18
	0x50: 189, // F19
	0x5A: 190, // F20

	// Keypad.
	0x52: 82,  // 0
	0x53: 79,  // 1
	0x54: 80,  // 2
	0x55: 81,  // 3
	0x56: 75,  // 4
	0x57: 76,  // 5
	0x58: 77,  // 6
	0x59: 71,  // 7
	0x5B: 72,  // 8
	0x5C: 73,  // 9
	0x41: 83,  // Decimal → KEY_KPDOT
	0x43: 55,  // Multiply → KEY_KPASTERISK
	0x45: 78,  // Plus
	0x4E: 74,  // Minus
	0x4B: 98,  // Divide → KEY_KPSLASH
	0x4C: 96,  // Enter → KEY_KPENTER
	0x34: 96,  // Powerbook keypad Enter (undocumented, sent by some laptops)
	0x51: 117, // Equals → KEY_KPEQUAL
	0x47: 69,  // Clear → KEY_NUMLOCK (sits where Num Lock is)

	// Media.
	0x48: 115, // VolumeUp
	0x49: 114, // VolumeDown
	0x4A: 113, // Mute

	// JIS.
	0x5D: 124, // Yen → KEY_YEN
	0x5E: 89,  // Underscore → KEY_RO
	0x5F: 95,  // KeypadComma → KEY_KPJPCOMMA
	0x66: 123, // Eisu (HID LANG2) → KEY_HANJA
	0x68: 122, // Kana (HID LANG1) → KEY_HANGEUL
}

// Evdev returns the Linux evdev code for a macOS virtual key code.
func Evdev(vk uint16) (uint16, bool) {
	c, ok := toEvdev[vk]
	return c, ok
}

// X11 returns the X11 keycode (evdev + 8, as used by the xkb "evdev" rules).
func X11(vk uint16) (uint8, bool) {
	c, ok := toEvdev[vk]
	if !ok || c+8 > 255 {
		return 0, false
	}
	return uint8(c + 8), true
}

// VirtualKeys lists every mapped kVK code (for tests and diagnostics).
func VirtualKeys() []uint16 {
	out := make([]uint16, 0, len(toEvdev))
	for k := range toEvdev {
		out = append(out, k)
	}
	return out
}

// IsModifierKey reports whether vk is a modifier (sent by the host as flagsChanged).
func IsModifierKey(vk uint16) bool {
	switch vk {
	case VKCommand, VKRightCommand, VKShift, VKRightShift, VKOption, VKRightOption,
		VKControl, VKRightControl, VKCapsLock, VKFunction:
		return true
	}
	return false
}
