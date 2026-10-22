//go:build linux

package x11

import (
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// SetClock implements agent.ClockSetter. The agent runs as the desktop user, so this needs
// password-less sudo for date (Vitrine's one-click Linux VMs have it); NTP corrects it otherwise.
func (b *Backend) SetClock(t time.Time) error {
	out, err := exec.Command("sudo", "-n", "date", "-u", "-s", fmt.Sprintf("@%d.%03d", t.Unix(), t.Nanosecond()/1e6)).CombinedOutput()
	if err != nil {
		return fmt.Errorf("sudo date: %v %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

var ianaZone = regexp.MustCompile(`^[A-Za-z0-9_+\-]+(/[A-Za-z0-9_+\-]+)*$`)

// SetTimeZone implements agent.ClockSetter with timedatectl (IANA zone names).
func (b *Backend) SetTimeZone(iana, _ string) error {
	if iana == "" || !ianaZone.MatchString(iana) {
		return nil
	}
	if cur, err := exec.Command("timedatectl", "show", "-p", "Timezone", "--value").Output(); err == nil &&
		strings.TrimSpace(string(cur)) == iana {
		return nil
	}
	if out, err := exec.Command("sudo", "-n", "timedatectl", "set-timezone", iana).CombinedOutput(); err != nil {
		return fmt.Errorf("set-timezone %s: %v %s", iana, err, strings.TrimSpace(string(out)))
	}
	return nil
}
