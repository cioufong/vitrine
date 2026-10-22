//go:build linux

package x11

import (
	"time"

	"github.com/jezek/xgb/xproto"

	"github.com/cioufong/vitrine/guest/linux-agent/keymap"
)

const shiftCode = keymap.KeyLeftShift + 8

// remapSettle is how long clients get to refetch the keymap after we bind a
// scratch keycode (they do so lazily on MappingNotify) before we press it.
const remapSettle = 30 * time.Millisecond

// scratchSlot is a spare keycode (no symbols in the layout) that we bind to
// arbitrary keysyms, reused least-recently-used first.
type scratchSlot struct {
	code    uint8
	keysym  xproto.Keysym
	lastUse time.Time
}

// loadKeymap fetches the core keyboard mapping if stale. Caller holds b.in.mu.
func (b *Backend) loadKeymap() bool {
	s := &b.in
	if s.keymapStale.Swap(false) {
		s.keysyms = nil // a MappingNotify arrived since the last fetch
	}
	if s.keysyms != nil {
		return true
	}
	lo, hi := b.setup.MinKeycode, b.setup.MaxKeycode
	r, err := xproto.GetKeyboardMapping(b.conn, lo, byte(hi-lo+1)).Reply()
	if err != nil || r.KeysymsPerKeycode == 0 {
		return false
	}
	s.keysyms, s.perCode, s.keymapMin = r.Keysyms, int(r.KeysymsPerKeycode), uint8(lo)
	// Spare keycodes become scratch slots, highest first, as xdotool does.
	// They are found once: after we bind them they are no longer empty.
	if len(s.scratch) > 0 {
		return true
	}
	n := len(r.Keysyms) / s.perCode
	for i := n - 1; i >= 0 && len(s.scratch) < 8; i-- {
		empty := true
		for _, ks := range r.Keysyms[i*s.perCode : (i+1)*s.perCode] {
			if ks != 0 {
				empty = false
				break
			}
		}
		if empty {
			s.scratch = append(s.scratch, scratchSlot{code: uint8(i) + s.keymapMin})
		}
	}
	return true
}

// findKeysym returns a keycode producing ks and whether Shift is needed.
// Scratch slots already bound to ks are reused (and refreshed in the LRU).
func (b *Backend) findKeysym(ks xproto.Keysym) (uint8, bool, bool) {
	s := &b.in
	for i := range s.scratch {
		if s.scratch[i].keysym == ks {
			s.scratch[i].lastUse = time.Now()
			return s.scratch[i].code, false, true
		}
	}
	n := len(s.keysyms) / s.perCode
	for col := 0; col < 2 && col < s.perCode; col++ {
		for i := 0; i < n; i++ {
			if s.keysyms[i*s.perCode+col] == ks {
				return uint8(i) + s.keymapMin, col == 1, true
			}
		}
	}
	return 0, false, false
}

// typeText injects text by keysym (for input with no physical key, e.g.
// emoji). Characters missing from the layout are bound to a scratch keycode
// first. Caller holds b.in.mu, so this never interleaves with other keys.
func (b *Backend) typeText(text string) {
	if !b.loadKeymap() {
		return
	}
	s := &b.in
	shiftHeld := len(s.mods[keymap.FlagShift]) > 0
	for _, r := range text {
		sym, ok := keymap.KeysymForRune(r)
		if !ok {
			continue
		}
		ks := xproto.Keysym(sym)
		code, needShift, found := b.findKeysym(ks)
		isScratch := false
		if !found {
			if code, ok = b.bindScratch(ks); !ok {
				continue
			}
		}
		for _, sl := range s.scratch {
			isScratch = isScratch || sl.code == code
		}
		if isScratch {
			needShift = shiftHeld // every column holds ks: shift state is irrelevant
		}
		if needShift && !shiftHeld {
			b.keyEvent(shiftCode, true)
		} else if !needShift && shiftHeld {
			for c := range s.mods[keymap.FlagShift] {
				b.keyEvent(c, false)
			}
		}
		b.keyEvent(code, true)
		b.keyEvent(code, false)
		if needShift && !shiftHeld {
			b.keyEvent(shiftCode, false)
		} else if !needShift && shiftHeld {
			for c := range s.mods[keymap.FlagShift] {
				b.keyEvent(c, true)
			}
		}
	}
}

// bindScratch maps ks onto the least recently used spare keycode, then waits
// for the change to reach the server and clients before it is pressed.
// Bindings are left in place (restored lazily by reuse): undoing them right
// after the key event races with clients that refresh their keymap late.
func (b *Backend) bindScratch(ks xproto.Keysym) (uint8, bool) {
	s := &b.in
	if len(s.scratch) == 0 {
		return 0, false
	}
	lru := 0
	for i := range s.scratch {
		if s.scratch[i].lastUse.Before(s.scratch[lru].lastUse) {
			lru = i
		}
	}
	slot := &s.scratch[lru]
	syms := make([]xproto.Keysym, s.perCode)
	for i := range syms {
		syms[i] = ks
	}
	if err := xproto.ChangeKeyboardMappingChecked(b.conn, 1, xproto.Keycode(slot.code), byte(s.perCode), syms).Check(); err != nil {
		return 0, false
	}
	slot.keysym, slot.lastUse = ks, time.Now()
	// Update the cache in place; the MappingNotify that follows will also
	// invalidate it, which is harmless.
	if s.keysyms != nil {
		i := int(slot.code-s.keymapMin) * s.perCode
		copy(s.keysyms[i:i+s.perCode], syms)
	}
	b.conn.Sync()
	time.Sleep(remapSettle)
	return slot.code, true
}
