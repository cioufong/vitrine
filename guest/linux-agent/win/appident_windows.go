//go:build windows

package win

import (
	"path/filepath"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Store (packaged) apps: their executables carry no useful FileDescription
// ("mspaint.exe"), and UWP windows belong to ApplicationFrameHost.exe. The
// display name comes from the Start menu instead, matched by AppUserModelID.

var (
	procGetApplicationUserModelId = kernel32.NewProc("GetApplicationUserModelId")
	procEnumChildWindows          = user32.NewProc("EnumChildWindows")

	childMu   sync.Mutex
	childOut  []windows.HWND
	childProc = windows.NewCallback(func(hwnd uintptr, _ uintptr) uintptr {
		childOut = append(childOut, windows.HWND(hwnd))
		return 1
	})
)

// startNames maps lower-cased Start menu AppIDs to display names. Loaded once in
// the background (Get-StartApps takes a second or two).
type startNames struct {
	once  sync.Once
	mu    sync.Mutex
	names map[string]string
}

func (s *startNames) load() {
	s.once.Do(func() {
		go func() {
			apps, err := startApps()
			if err != nil {
				return
			}
			m := map[string]string{}
			for _, a := range apps {
				if a.AppID != "" && a.Name != "" {
					m[strings.ToLower(a.AppID)] = a.Name
				}
			}
			s.mu.Lock()
			s.names = m
			s.mu.Unlock()
		}()
	})
}

func (s *startNames) lookup(aumid string) string {
	s.load()
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.names[strings.ToLower(aumid)]
}

// appUserModelID returns a packaged process's AUMID ("Microsoft.Paint_8wekyb3d8bbwe!App"), or "".
func appUserModelID(h windows.Handle) string {
	buf := make([]uint16, 256)
	n := uint32(len(buf))
	if r, _, _ := procGetApplicationUserModelId.Call(uintptr(h), uintptr(unsafe.Pointer(&n)),
		uintptr(unsafe.Pointer(&buf[0]))); r != 0 {
		return ""
	}
	return windows.UTF16ToString(buf[:n])
}

// isFrameHost reports whether an executable is the UWP window host.
func isFrameHost(path string) bool {
	return strings.EqualFold(filepath.Base(path), "ApplicationFrameHost.exe")
}

// hostedAppPID returns the process of the app inside an ApplicationFrameHost
// window (its CoreWindow child), or 0 when the app is suspended or not found.
func hostedAppPID(frame windows.HWND, framePID uint32) uint32 {
	childMu.Lock()
	childOut = childOut[:0]
	procEnumChildWindows.Call(uintptr(frame), childProc, 0)
	kids := append([]windows.HWND(nil), childOut...)
	childMu.Unlock()
	for _, k := range kids {
		var pid uint32
		windows.GetWindowThreadProcessId(k, &pid)
		if pid != 0 && pid != framePID {
			return pid
		}
	}
	return 0
}

// usefulDescription filters FileDescriptions that are just the file name.
func usefulDescription(desc, path string) bool {
	if desc == "" || len(desc) > 64 {
		return false
	}
	base := filepath.Base(path)
	return !strings.EqualFold(desc, base) && !strings.EqualFold(desc, strings.TrimSuffix(base, filepath.Ext(base)))
}
