//go:build windows

package win

import (
	"fmt"
	"os/exec"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var procSetSystemTime = kernel32.NewProc("SetSystemTime")

// SetClock implements agent.ClockSetter (the agent runs elevated, which holds SeSystemtimePrivilege).
func (b *Backend) SetClock(t time.Time) error {
	u := t.UTC()
	st := windows.Systemtime{Year: uint16(u.Year()), Month: uint16(u.Month()), DayOfWeek: uint16(u.Weekday()),
		Day: uint16(u.Day()), Hour: uint16(u.Hour()), Minute: uint16(u.Minute()), Second: uint16(u.Second()),
		Milliseconds: uint16(u.Nanosecond() / 1e6)}
	if r, _, err := procSetSystemTime.Call(uintptr(unsafe.Pointer(&st))); r == 0 {
		return err
	}
	return nil
}

// SetTimeZone implements agent.ClockSetter with tzutil (Windows time zone IDs).
func (b *Backend) SetTimeZone(_, id string) error {
	if id == "" || len(id) > 64 || strings.ContainsAny(id, "\"\r\n&|<>^%") {
		return nil
	}
	cur, err := hiddenCommand("tzutil.exe", "/g").Output()
	if err == nil && strings.EqualFold(strings.TrimSpace(string(cur)), id) {
		return nil
	}
	if out, err := hiddenCommand("tzutil.exe", "/s", id).CombinedOutput(); err != nil {
		return fmt.Errorf("tzutil /s %q: %v %s", id, err, strings.TrimSpace(string(out)))
	}
	b.opts.Logf("time zone set to %s", id)
	return nil
}

// hiddenCommand runs a console tool without flashing a window (the agent is a GUI app).
func hiddenCommand(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	return cmd
}
