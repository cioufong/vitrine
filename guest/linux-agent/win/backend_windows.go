//go:build windows

package win

import (
	"errors"
	"fmt"
	"os"
	"sync"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"github.com/cioufong/vitrine/guest/linux-agent/keymap"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// Options configures the backend.
type Options struct {
	CommandMode keymap.CommandMode // what ⌘ becomes (Windows default: Ctrl)
	Logf        func(format string, args ...any)
}

// Backend drives the interactive Windows session. It satisfies agent.Backend.
type Backend struct {
	opts    Options
	selfPID uint32

	winMu sync.Mutex
	geoms map[uint32]winGeom // last snapshot, for window actions
	exes  map[uint32]exeInfo // pid → executable cache

	in   inputState
	clip *clipboard

	startNames startNames // Start menu names by AppUserModelID

	shareMu     sync.Mutex
	shareServer string                // SMB server of the last MountShares (file drops come from its transfer share)
	lastMount   *protocol.MountShares // last MountShares, with Shares cut to what is actually mapped (nil: unknown)
}

// Open makes the process per-monitor DPI aware (so every coordinate is in
// physical pixels) and starts the clipboard listener.
func Open(opts Options) (*Backend, error) {
	if opts.Logf == nil {
		opts.Logf = func(f string, a ...any) { fmt.Fprintf(os.Stderr, "vitrine-agent: "+f+"\n", a...) }
	}
	if procSetProcessDpiAwarenessContext.Find() == nil {
		if !boolCall(procSetProcessDpiAwarenessContext, dpiAwarenessContextPerMonitorAwareV2) {
			opts.Logf("SetProcessDpiAwarenessContext failed (already set by a manifest?)")
		}
	} else {
		procSetProcessDPIAware.Call()
	}
	if vs := virtualScreenRect(); vs.W <= 0 || vs.H <= 0 {
		return nil, errors.New("no interactive desktop (is the agent running in the user's session?)")
	}
	b := &Backend{opts: opts, selfPID: windows.GetCurrentProcessId(),
		geoms: map[uint32]winGeom{}, exes: map[uint32]exeInfo{}}
	b.startNames.load() // Start menu names for Store apps, ready before the first window list
	var err error
	if b.clip, err = newClipboard(opts.Logf); err != nil {
		opts.Logf("clipboard disabled: %v", err)
		b.clip = nil
	}
	return b, nil
}

// Close stops the clipboard listener.
func (b *Backend) Close() {
	if b.clip != nil {
		b.clip.close()
	}
}

// StartAutoResize is not needed on Windows (the display driver applies host
// resolution changes itself).
func (b *Backend) StartAutoResize() error { return errors.New("not supported on Windows") }

// OS implements agent.Backend.
func (b *Backend) OS() string {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion`, registry.QUERY_VALUE)
	if err != nil {
		return "Windows"
	}
	defer k.Close()
	product, _, _ := k.GetStringValue("ProductName")
	display, _, _ := k.GetStringValue("DisplayVersion")
	build, _, _ := k.GetStringValue("CurrentBuildNumber")
	ubr, _, _ := k.GetIntegerValue("UBR")
	return osName(product, display, build, ubr)
}

// Capabilities implements agent.Backend.
func (b *Backend) Capabilities() []string {
	caps := []string{"coherence", "input", "shares", "files", "apps"}
	if b.clip != nil {
		caps = append(caps, "clipboard")
	}
	return caps
}

// scale is the system DPI scale (GetDpiForSystem / 96).
func (b *Backend) scale() float64 {
	if procGetDpiForSystem.Find() != nil {
		return 1
	}
	dpi, _, _ := procGetDpiForSystem.Call()
	return scaleForDPI(uint32(dpi))
}

// DisplayInfo implements agent.Backend.
func (b *Backend) DisplayInfo() (protocol.DisplayInfo, error) {
	vs := virtualScreenRect()
	if vs.W <= 0 || vs.H <= 0 {
		return protocol.DisplayInfo{}, errors.New("virtual screen unavailable")
	}
	s := b.scale()
	return protocol.DisplayInfo{WidthPoints: float64(vs.W) / s, HeightPoints: float64(vs.H) / s, Scale: s}, nil
}

// OnClipboardChange implements agent.Backend.
func (b *Backend) OnClipboardChange(fn func(protocol.Clipboard)) {
	if b.clip != nil {
		b.clip.setHandler(fn)
	}
}

// SetClipboard implements agent.Backend.
func (b *Backend) SetClipboard(c protocol.Clipboard) error {
	if b.clip == nil {
		return errors.New("clipboard unavailable")
	}
	return b.clip.set(c)
}
