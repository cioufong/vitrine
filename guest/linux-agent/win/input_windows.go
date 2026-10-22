//go:build windows

package win

import (
	"sync"
	"unicode/utf16"

	"github.com/cioufong/vitrine/guest/linux-agent/keymap"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// inputState tracks what the agent holds down, to reconcile modifier flags
// and release everything when the host disconnects.
type inputState struct {
	mu      sync.Mutex
	mods    map[uint64]map[Scancode]bool // host flag → scancodes pressed for it
	keys    map[Scancode]bool
	buttons map[uint8]bool
	scrollX float64
	scrollY float64
}

func keyInput(sc Scancode, down bool) keybdINPUT {
	flags := uint32(keyeventfScancode)
	if sc.Extended {
		flags |= keyeventfExtendedKey
	}
	if !down {
		flags |= keyeventfKeyUp
	}
	return keybdINPUT{Type: inputKeyboard, Ki: keybdInput{Scan: sc.Code, Flags: flags}}
}

func (b *Backend) sendKey(sc Scancode, down bool) { sendKeys([]keybdINPUT{keyInput(sc, down)}) }

// syncModifiers presses/releases held modifiers to match the host flags.
// Caller holds b.in.mu.
func (b *Backend) syncModifiers(flags uint64) {
	s := &b.in
	if s.mods == nil {
		s.mods = map[uint64]map[Scancode]bool{}
	}
	for _, m := range keymap.SyncedModifiers {
		want := flags&m.Flag != 0
		held := s.mods[m.Flag]
		switch {
		case want && len(held) == 0:
			sc := modifierScancode(m.Flag, b.opts.CommandMode)
			b.sendKey(sc, true)
			s.mods[m.Flag] = map[Scancode]bool{sc: true}
		case !want && len(held) > 0:
			for sc := range held {
				b.sendKey(sc, false)
			}
			delete(s.mods, m.Flag)
		}
	}
}

// Pointer implements agent.Backend.
func (b *Backend) Pointer(p protocol.Pointer) error {
	vs := virtualScreenRect()
	s := b.scale()
	px, py := toPixel(float64(p.X), s, vs.X), toPixel(float64(p.Y), s, vs.Y)

	b.in.mu.Lock()
	defer b.in.mu.Unlock()
	if b.in.buttons == nil {
		b.in.buttons = map[uint8]bool{}
	}
	b.syncModifiers(p.Modifiers)
	ev := []mouseINPUT{{Type: inputMouse, Mi: mouseInput{
		Dx: normalizeAbs(px, vs.X, vs.W), Dy: normalizeAbs(py, vs.Y, vs.H),
		Flags: mouseeventfMove | mouseeventfAbsolute | mouseeventfVirtualDesk,
	}}}
	button := func(down bool) uint32 {
		switch p.Button {
		case protocol.ButtonRight:
			if down {
				return mouseeventfRightDown
			}
			return mouseeventfRightUp
		case protocol.ButtonOther:
			if down {
				return mouseeventfMiddleDown
			}
			return mouseeventfMiddleUp
		}
		if down {
			return mouseeventfLeftDown
		}
		return mouseeventfLeftUp
	}
	switch p.Kind {
	case protocol.PointerDown:
		ev = append(ev, mouseINPUT{Type: inputMouse, Mi: mouseInput{Flags: button(true)}})
		b.in.buttons[p.Button] = true
	case protocol.PointerUp:
		ev = append(ev, mouseINPUT{Type: inputMouse, Mi: mouseInput{Flags: button(false)}})
		delete(b.in.buttons, p.Button)
	case protocol.PointerScroll:
		// AppKit: +DY scrolls up (Windows: positive wheel), +DX scrolls left
		// (Windows: negative hwheel).
		if n := wheelNotches(&b.in.scrollY, float64(p.ScrollDY), p.PreciseScroll); n != 0 {
			ev = append(ev, mouseINPUT{Type: inputMouse, Mi: mouseInput{Flags: mouseeventfWheel, MouseData: uint32(int32(n * wheelDelta))}})
		}
		if n := wheelNotches(&b.in.scrollX, float64(p.ScrollDX), p.PreciseScroll); n != 0 {
			ev = append(ev, mouseINPUT{Type: inputMouse, Mi: mouseInput{Flags: mouseeventfHWheel, MouseData: uint32(int32(-n * wheelDelta))}})
		}
	}
	sendMouse(ev)
	return nil
}

// Key implements agent.Backend.
func (b *Backend) Key(k protocol.Key) error {
	b.in.mu.Lock()
	defer b.in.mu.Unlock()
	if b.in.keys == nil {
		b.in.keys = map[Scancode]bool{}
	}
	if keymap.IsSynthesizedText(k.KeyCode, k.Text, k.Modifiers) {
		if k.Down {
			typeText(k.Text)
		}
		return nil
	}
	switch k.KeyCode {
	case keymap.VKFunction:
		return nil
	case keymap.VKCapsLock:
		// The host reports Caps Lock as a state change; Windows toggles per press.
		b.sendKey(scCapsLock, true)
		b.sendKey(scCapsLock, false)
		return nil
	}
	sc, ok := ScancodeFor(k.KeyCode, b.opts.CommandMode)
	if !ok {
		if k.Down && k.Text != "" {
			typeText(k.Text)
		}
		return nil
	}
	if flag := keymap.ModifierFlag(k.KeyCode); flag != 0 {
		if b.in.mods == nil {
			b.in.mods = map[uint64]map[Scancode]bool{}
		}
		held := b.in.mods[flag]
		if k.Down && !held[sc] {
			b.sendKey(sc, true)
			if held == nil {
				held = map[Scancode]bool{}
				b.in.mods[flag] = held
			}
			held[sc] = true
		} else if !k.Down && held[sc] {
			b.sendKey(sc, false)
			delete(held, sc)
			if len(held) == 0 {
				delete(b.in.mods, flag)
			}
		}
		return nil
	}
	b.syncModifiers(k.Modifiers)
	if k.Down && b.in.keys[sc] {
		b.sendKey(sc, false) // lost release
	}
	b.sendKey(sc, k.Down)
	if k.Down {
		b.in.keys[sc] = true
	} else {
		delete(b.in.keys, sc)
	}
	return nil
}

// typeText injects text as KEYEVENTF_UNICODE events (VK_PACKET), one
// down/up pair per UTF-16 code unit; surrogate pairs are recombined by the
// receiving window's WM_CHAR handling.
func typeText(text string) {
	units := utf16.Encode([]rune(text))
	ev := make([]keybdINPUT, 0, 2*len(units))
	for _, u := range units {
		ev = append(ev,
			keybdINPUT{Type: inputKeyboard, Ki: keybdInput{Scan: u, Flags: keyeventfUnicode}},
			keybdINPUT{Type: inputKeyboard, Ki: keybdInput{Scan: u, Flags: keyeventfUnicode | keyeventfKeyUp}})
	}
	sendKeys(ev)
}

// ResetInput implements agent.Backend: release everything still held.
func (b *Backend) ResetInput() {
	b.in.mu.Lock()
	defer b.in.mu.Unlock()
	for sc := range b.in.keys {
		b.sendKey(sc, false)
	}
	for _, held := range b.in.mods {
		for sc := range held {
			b.sendKey(sc, false)
		}
	}
	var ev []mouseINPUT
	for btn := range b.in.buttons {
		f := uint32(mouseeventfLeftUp)
		switch btn {
		case protocol.ButtonRight:
			f = mouseeventfRightUp
		case protocol.ButtonOther:
			f = mouseeventfMiddleUp
		}
		ev = append(ev, mouseINPUT{Type: inputMouse, Mi: mouseInput{Flags: f}})
	}
	sendMouse(ev)
	b.in.keys, b.in.mods, b.in.buttons = nil, nil, nil
	b.in.scrollX, b.in.scrollY = 0, 0
}
