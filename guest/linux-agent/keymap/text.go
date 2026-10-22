package keymap

import "unicode/utf8"

// Keysyms for control characters that commonly appear in synthesized text.
const (
	XKBackSpace = 0xff08
	XKTab       = 0xff09
	XKReturn    = 0xff0d
	XKEscape    = 0xff1b
	XKDelete    = 0xffff
)

// KeysymForRune returns the X11 keysym producing r (see X11 keysymdef.h:
// Latin-1 maps directly, other Unicode code points use 0x01000000 | cp).
func KeysymForRune(r rune) (uint32, bool) {
	switch {
	case r == '\n' || r == '\r':
		return XKReturn, true
	case r == '\t':
		return XKTab, true
	case r == '\b':
		return XKBackSpace, true
	case r == 0x1b:
		return XKEscape, true
	case r == 0x7f:
		return XKDelete, true
	case r < 0x20, r >= 0x80 && r < 0xa0, r == utf8.RuneError, r > 0x10ffff:
		return 0, false
	case r < 0x100:
		return uint32(r), true
	default:
		return 0x01000000 | uint32(r), true
	}
}

// IsSynthesizedText decides whether a key event should be typed from its text
// instead of its key code: the host sends keyCode 0 (kVK_ANSI_A) for input that
// did not come from a physical key (emoji picker, text expanders, automation).
// A real A key ("a"/"A"), shortcuts (⌘/⌃ held) and control characters / AppKit
// function-key characters (U+F700–U+F8FF) keep key-code semantics.
//
// "A" without Shift/Caps Lock cannot come from the A key, so it is typed as
// text too (automation often posts capitals without modifier flags).
func IsSynthesizedText(keyCode uint16, text string, modifiers uint64) bool {
	if keyCode != 0 || text == "" || text == "a" {
		return false
	}
	if text == "A" && modifiers&(FlagShift|FlagCapsLock) != 0 {
		return false
	}
	if modifiers&(FlagCommand|FlagControl) != 0 {
		return false
	}
	for _, r := range text {
		if r < 0x20 || r == 0x7f || (r >= 0xF700 && r <= 0xF8FF) {
			return false
		}
	}
	return true
}
