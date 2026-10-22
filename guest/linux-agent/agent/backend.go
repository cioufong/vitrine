package agent

import (
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// Backend is the windowing-system integration (X11 on Linux).
// Methods may be called concurrently from different goroutines.
type Backend interface {
	// OS describes the guest, e.g. "Linux Debian GNU/Linux 13 (kernel 6.12.0)".
	OS() string
	// Capabilities lists what this backend supports ("coherence", "clipboard", "input").
	Capabilities() []string
	DisplayInfo() (protocol.DisplayInfo, error)
	// Windows returns visible windows front-to-back, frames in guest points.
	Windows() ([]protocol.WindowInfo, error)
	// StartStream begins sending dirty rects of the whole screen to sink.
	// The first frame must cover the full screen.
	StartStream(maxFPS int, sink FrameSink) (Stream, error)
	Pointer(protocol.Pointer) error
	Key(protocol.Key) error
	WindowAction(protocol.WindowAction) error
	// SetClipboard publishes host clipboard contents in the guest.
	SetClipboard(protocol.Clipboard) error
	// ResetInput releases any keys/buttons still held by injected input
	// (called when the host disconnects).
	ResetInput()
	// OnClipboardChange registers fn for guest-originated clipboard changes
	// (already filtered against echoes of SetClipboard content).
	OnClipboardChange(fn func(protocol.Clipboard))
}

// ShareMounter is implemented by backends that map the host's SMB shares
// (Windows). Called from the agent's job worker, one call at a time and in
// order with ReceiveFiles; a request superseded by a newer one before it
// started may be skipped.
type ShareMounter interface {
	MountShares(protocol.MountShares) error
}

// FileReceiver is implemented by backends that take files dropped on the VM
// window from the host's transfer folder. Called from the agent's job worker,
// after any MountShares received before the drop has finished.
type FileReceiver interface {
	ReceiveFiles(protocol.FileDrop) error
}

// AppProvider is implemented by backends that know the guest's installed apps
// (for host Dock icons and launchers). Called from its own goroutine.
type AppProvider interface {
	AppCatalog(iconSize int) (protocol.AppCatalog, error)
	// AppIcon returns a PNG for the app whose windows report key (nil = none).
	AppIcon(key string) ([]byte, error)
	LaunchApp(id string) error
}

// ClockSetter is implemented by backends that can set the guest clock.
type ClockSetter interface {
	SetClock(t time.Time) error
	// SetTimeZone adopts the host's zone (IANA and Windows IDs); a no-op if already set.
	SetTimeZone(iana, windows string) error
}

// Stream is a running frame capture.
type Stream interface{ Stop() }

// FrameSink receives captured frames.
type FrameSink interface {
	// SendFrame queues a frame; false means the connection is gone.
	SendFrame(protocol.Frame) bool
	// Pending is the number of bytes queued for the host (for back-pressure).
	Pending() int64
	// DisplayChanged tells the agent the screen geometry changed so it can
	// re-announce DisplayInfo before the next (full) frame.
	DisplayChanged()
	// Logf reports diagnostics to stderr and the host.
	Logf(format string, args ...any)
}
