package win

import (
	"path/filepath"
	"strings"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// Window style bits (winuser.h).
const (
	wsPopup         = 0x80000000
	wsChild         = 0x40000000
	wsExTopmost     = 0x00000008
	wsExTransparent = 0x00000020
	wsExToolWindow  = 0x00000080
	wsExLayered     = 0x00080000
)

// pxRect is a rectangle in physical desktop pixels (right/bottom exclusive).
type pxRect struct{ Left, Top, Right, Bottom int }

func (r pxRect) width() int  { return r.Right - r.Left }
func (r pxRect) height() int { return r.Bottom - r.Top }

func (r pxRect) intersects(o pxRect) bool {
	return r.Left < o.Right && o.Left < r.Right && r.Top < o.Bottom && o.Top < r.Bottom
}

// winCandidate is everything the filter needs to know about one top-level
// window, gathered by EnumWindows on Windows.
type winCandidate struct {
	Class    string
	Title    string
	Style    uint32
	ExStyle  uint32
	Visible  bool
	Iconic   bool
	Cloaked  bool // DWMWA_CLOAKED: hidden UWP / other-virtual-desktop windows
	HasOwner bool // GetWindow(GW_OWNER) != 0
	PID      uint32
	SelfPID  uint32
	Frame    pxRect // DWMWA_EXTENDED_FRAME_BOUNDS
	Screen   pxRect // virtual screen
}

// Shell surfaces never mirrored as windows.
var shellClasses = map[string]bool{
	"Shell_TrayWnd":          true, // taskbar
	"Shell_SecondaryTrayWnd": true, // taskbar on other monitors
	"Progman":                true, // desktop
	"WorkerW":                true, // desktop wallpaper host
	"SysShadow":              true, // drop shadow behind menus (would mirror as a dark box)
}

// Popup classes that behave like menus / tooltips.
var menuClasses = map[string]bool{
	"#32768":                              true, // standard popup menu
	"tooltips_class32":                    true,
	"Xaml_WindowedPopupClass":             true, // WinUI flyouts / context menus
	"NotifyIconOverflowWindow":            true,
	"TopLevelWindowForOverflowXamlIsland": true, // Windows 11 tray overflow
}

// classify decides whether a top-level window is mirrored and how. It
// returns the protocol kind and layer, or ok=false to skip the window.
func classify(c winCandidate) (kind string, layer int, ok bool) {
	switch {
	case !c.Visible, c.Iconic, c.Cloaked:
		return "", 0, false
	case c.Style&wsChild != 0:
		return "", 0, false
	case c.PID != 0 && c.PID == c.SelfPID:
		return "", 0, false // the agent's own windows
	case shellClasses[c.Class]:
		return "", 0, false
	case c.Frame.width() <= 0 || c.Frame.height() <= 0:
		return "", 0, false
	case !c.Frame.intersects(c.Screen):
		return "", 0, false // parked off-screen (e.g. -32000,-32000)
	case c.ExStyle&wsExTransparent != 0 && c.ExStyle&wsExLayered != 0 && c.Title == "" && !menuClasses[c.Class]:
		return "", 0, false // click-through overlays
	}
	switch {
	case menuClasses[c.Class], c.ExStyle&wsExToolWindow != 0:
		return protocol.KindMenu, 101, true
	case c.HasOwner:
		kind = protocol.KindPanel
	default:
		kind = protocol.KindNormal
	}
	if c.ExStyle&wsExTopmost != 0 {
		layer = 3
	}
	return kind, layer, true
}

// appNameFromImage turns a process image path into an app name:
// `C:\Windows\System32\notepad.exe` → "notepad".
func appNameFromImage(path string) string {
	base := filepath.Base(strings.ReplaceAll(path, `\`, "/"))
	if ext := filepath.Ext(base); strings.EqualFold(ext, ".exe") {
		base = base[:len(base)-len(ext)]
	}
	if base == "." || base == "/" {
		return ""
	}
	return base
}
