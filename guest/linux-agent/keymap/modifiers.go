package keymap

// NSEvent.ModifierFlags / CGEventFlags bits carried in pointer and key events.
const (
	FlagCapsLock uint64 = 1 << 16
	FlagShift    uint64 = 1 << 17
	FlagControl  uint64 = 1 << 18
	FlagOption   uint64 = 1 << 19
	FlagCommand  uint64 = 1 << 20
	FlagNumPad   uint64 = 1 << 21
	FlagHelp     uint64 = 1 << 22
	FlagFunction uint64 = 1 << 23
)

// Modifier pairs a host flag with the evdev key that produces it in the guest.
type Modifier struct {
	Flag  uint64
	Evdev uint16
}

// SyncedModifiers are the held modifiers reconciled before injecting a key or
// button so that e.g. ⌘-click works even if a flagsChanged event was lost.
// Caps Lock is a toggle and is deliberately excluded.
var SyncedModifiers = []Modifier{
	{FlagShift, KeyLeftShift},
	{FlagControl, KeyLeftCtrl},
	{FlagOption, KeyLeftAlt},
	{FlagCommand, KeyLeftMeta},
}

// ModifierFlag returns the host flag a modifier key toggles (0 if none).
func ModifierFlag(vk uint16) uint64 {
	switch vk {
	case VKShift, VKRightShift:
		return FlagShift
	case VKControl, VKRightControl:
		return FlagControl
	case VKOption, VKRightOption:
		return FlagOption
	case VKCommand, VKRightCommand:
		return FlagCommand
	case VKCapsLock:
		return FlagCapsLock
	case VKFunction:
		return FlagFunction
	}
	return 0
}

// CommandMode selects what the Mac Command key becomes in the guest.
type CommandMode int

const (
	// CommandAsSuper maps ⌘ to Super_L (default, matches the Linux keyboard layout).
	CommandAsSuper CommandMode = iota
	// CommandAsControl maps ⌘ to Control_L so Mac shortcuts (⌘C/⌘V) work as Ctrl shortcuts.
	CommandAsControl
)

// Remap applies the command mode to an evdev code.
func (m CommandMode) Remap(evdev uint16) uint16 {
	if m == CommandAsControl {
		switch evdev {
		case KeyLeftMeta:
			return KeyLeftCtrl
		case KeyRightMeta:
			return KeyRightCtrl
		}
	}
	return evdev
}
