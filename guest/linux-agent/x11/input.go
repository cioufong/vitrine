//go:build linux

package x11

import (
	"errors"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jezek/xgb/xproto"
	"github.com/jezek/xgb/xtest"

	"github.com/cioufong/vitrine/guest/linux-agent/keymap"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// XTEST fake event types (core event codes).
const (
	fakeKeyPress      = 2
	fakeKeyRelease    = 3
	fakeButtonPress   = 4
	fakeButtonRelease = 5
	fakeMotion        = 6
)

// preciseScrollStep is the trackpad pixel distance per wheel click.
const preciseScrollStep = 10

// keyGap is the minimum spacing between injected key events (xdotool types
// with 12 ms between keystrokes for the same reason).
const keyGap = 4 * time.Millisecond

var errNoXTest = errors.New("XTEST unavailable")

// inputState tracks what this agent holds down so it can reconcile modifier
// flags and release everything when the host goes away.
type inputState struct {
	mu        sync.Mutex
	mods      map[uint64]map[uint8]bool // host flag → X keycodes pressed for it
	keys      map[uint8]bool            // non-modifier keys held
	buttons   map[uint8]bool
	scrollX   float64
	scrollY   float64
	keymapMin uint8
	keysyms   []xproto.Keysym // core keyboard mapping cache (nil = stale)
	perCode   int
	scratch   []scratchSlot // spare keycodes used to type arbitrary keysyms (LRU)
	lastKey   time.Time

	// keymapStale is set by the event goroutine on MappingNotify. It is an
	// atomic, not guarded by mu: the event goroutine must never wait for the
	// input path, which may itself be waiting on an X reply that only arrives
	// once the (bounded) event queue is drained.
	keymapStale atomic.Bool
}

func (s *inputState) invalidateKeymap() { s.keymapStale.Store(true) }

const (
	// maxTypedRunes caps one synthesized-text event; longer text is truncated.
	maxTypedRunes = 4096
	// typeChunk is how many characters are typed per hold of the input lock,
	// so other input (and teardown) can interleave with a long paste.
	typeChunk = 32
)

// typeTextChunked types synthesized text in chunks, taking b.in.mu per chunk.
// Caller must not hold b.in.mu.
func (b *Backend) typeTextChunked(text string) {
	chunks, total := textChunks(text, maxTypedRunes, typeChunk)
	if total > maxTypedRunes {
		b.opts.Logf("synthesized text of %d characters truncated to %d", total, maxTypedRunes)
	}
	for _, c := range chunks {
		b.in.mu.Lock()
		b.typeText(c)
		b.in.mu.Unlock()
	}
}

func (b *Backend) fake(typ, detail uint8, x, y int16) {
	xtest.FakeInput(b.conn, typ, detail, 0, b.root, x, y, 0)
}

// keyEvent injects one key press/release. Events are paced at least keyGap
// apart and each is synced (round trip) so the server has processed it before
// the next one: toolkits (GTK/XIM) drop keys that arrive in a burst, and
// keycode-path and keysym-path (typeText) keys interleave when the host
// sends synthesized text. Caller holds b.in.mu, which serializes injection.
func (b *Backend) keyEvent(code uint8, down bool) {
	if wait := keyGap - time.Since(b.in.lastKey); wait > 0 {
		time.Sleep(wait)
	}
	if down {
		b.fake(fakeKeyPress, code, 0, 0)
	} else {
		b.fake(fakeKeyRelease, code, 0, 0)
	}
	b.conn.Sync()
	b.in.lastKey = time.Now()
}

// x11Code converts an evdev code (after ⌘ remapping) to an X keycode.
func (b *Backend) x11Code(evdev uint16) uint8 {
	return uint8(b.opts.CommandMode.Remap(evdev) + 8)
}

// syncModifiers presses/releases held modifiers so they match the host flags.
// Caller holds b.in.mu.
func (b *Backend) syncModifiers(flags uint64) {
	s := &b.in
	if s.mods == nil {
		s.mods = map[uint64]map[uint8]bool{}
	}
	for _, m := range keymap.SyncedModifiers {
		want := flags&m.Flag != 0
		held := s.mods[m.Flag]
		switch {
		case want && len(held) == 0:
			code := b.x11Code(m.Evdev)
			b.keyEvent(code, true)
			s.mods[m.Flag] = map[uint8]bool{code: true}
		case !want && len(held) > 0:
			for code := range held {
				b.keyEvent(code, false)
			}
			delete(s.mods, m.Flag)
		}
	}
}

// Pointer implements agent.Backend.
func (b *Backend) Pointer(p protocol.Pointer) error {
	if !b.hasXTest {
		return errNoXTest
	}
	s := b.scale()
	x := int16(math.Max(math.MinInt16, math.Min(math.MaxInt16, math.Round(float64(p.X)*s))))
	y := int16(math.Max(math.MinInt16, math.Min(math.MaxInt16, math.Round(float64(p.Y)*s))))
	button := map[uint8]uint8{protocol.ButtonLeft: 1, protocol.ButtonRight: 3, protocol.ButtonOther: 2}[p.Button]
	if button == 0 {
		button = 1
	}

	b.in.mu.Lock()
	defer b.in.mu.Unlock()
	if b.in.buttons == nil {
		b.in.buttons = map[uint8]bool{}
	}
	b.syncModifiers(p.Modifiers)
	b.fake(fakeMotion, 0, x, y)
	switch p.Kind {
	case protocol.PointerDown:
		b.fake(fakeButtonPress, button, x, y)
		b.in.buttons[button] = true
	case protocol.PointerUp:
		b.fake(fakeButtonRelease, button, x, y)
		delete(b.in.buttons, button)
	case protocol.PointerScroll:
		b.scroll(p, x, y)
	}
	return nil
}

// scroll emits wheel buttons: 4 up / 5 down / 6 left / 7 right. Host deltas
// follow AppKit: positive DY scrolls up, positive DX scrolls left. Caller holds b.in.mu.
func (b *Backend) scroll(p protocol.Pointer, x, y int16) {
	clicks := func(acc *float64, d float64) int {
		if !p.PreciseScroll {
			n := int(math.Round(d))
			if n == 0 && d != 0 {
				n = int(math.Copysign(1, d))
			}
			return n
		}
		*acc += d
		n := int(*acc / preciseScrollStep)
		*acc -= float64(n) * preciseScrollStep
		return n
	}
	emit := func(n int, pos, neg uint8) {
		btn := pos
		if n < 0 {
			btn, n = neg, -n
		}
		for i := 0; i < min(n, 30); i++ {
			b.fake(fakeButtonPress, btn, x, y)
			b.fake(fakeButtonRelease, btn, x, y)
		}
	}
	emit(clicks(&b.in.scrollY, float64(p.ScrollDY)), 4, 5)
	emit(clicks(&b.in.scrollX, float64(p.ScrollDX)), 6, 7)
}

// Key implements agent.Backend.
func (b *Backend) Key(k protocol.Key) error {
	if !b.hasXTest {
		return errNoXTest
	}
	if keymap.IsSynthesizedText(k.KeyCode, k.Text, k.Modifiers) {
		if k.Down {
			b.typeTextChunked(k.Text)
		}
		return nil
	}
	if _, ok := keymap.Evdev(k.KeyCode); !ok && k.KeyCode != keymap.VKFunction && k.KeyCode != keymap.VKCapsLock {
		if k.Down && k.Text != "" {
			b.typeTextChunked(k.Text) // unknown key code: best effort from text
		}
		return nil
	}
	b.in.mu.Lock()
	defer b.in.mu.Unlock()
	if b.in.keys == nil {
		b.in.keys = map[uint8]bool{}
	}
	switch k.KeyCode {
	case keymap.VKFunction:
		return nil // no X equivalent
	case keymap.VKCapsLock:
		// The host reports Caps Lock as a state change (down = on, up = off);
		// X toggles on each press, so tap it once per change.
		code, _ := keymap.X11(keymap.VKCapsLock)
		b.keyEvent(code, true)
		b.keyEvent(code, false)
		return nil
	}
	evdev, _ := keymap.Evdev(k.KeyCode) // known: unknown codes returned above
	code := b.x11Code(evdev)
	if flag := keymap.ModifierFlag(k.KeyCode); flag != 0 {
		if b.in.mods == nil {
			b.in.mods = map[uint64]map[uint8]bool{}
		}
		held := b.in.mods[flag]
		if k.Down && !held[code] {
			b.keyEvent(code, true)
			if held == nil {
				held = map[uint8]bool{}
				b.in.mods[flag] = held
			}
			held[code] = true
		} else if !k.Down && held[code] {
			b.keyEvent(code, false)
			delete(held, code)
			if len(held) == 0 {
				delete(b.in.mods, flag)
			}
		}
		return nil
	}
	b.syncModifiers(k.Modifiers)
	if k.Down && b.in.keys[code] {
		b.keyEvent(code, false) // lost release: a press of a held key would be ignored
	}
	b.keyEvent(code, k.Down)
	if k.Down {
		b.in.keys[code] = true
	} else {
		delete(b.in.keys, code)
	}
	return nil
}

// ResetInput releases every key and button this agent still holds (called
// when the host disconnects so nothing stays stuck).
func (b *Backend) ResetInput() {
	if !b.hasXTest {
		return
	}
	b.in.mu.Lock()
	defer b.in.mu.Unlock()
	for code := range b.in.keys {
		b.keyEvent(code, false)
	}
	for _, held := range b.in.mods {
		for code := range held {
			b.keyEvent(code, false)
		}
	}
	for btn := range b.in.buttons {
		b.fake(fakeButtonRelease, btn, 0, 0)
	}
	b.in.keys, b.in.mods, b.in.buttons = nil, nil, nil
	b.in.scrollX, b.in.scrollY = 0, 0
}
