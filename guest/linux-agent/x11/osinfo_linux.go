//go:build linux

package x11

import (
	"bufio"
	"os"
	"strings"

	"golang.org/x/sys/unix"
)

// osDescription returns e.g. "Linux Debian GNU/Linux 13 (trixie) (kernel 6.12.48-arm64)".
func osDescription() string {
	name := "Linux"
	if f, err := os.Open("/etc/os-release"); err == nil {
		defer f.Close()
		s := bufio.NewScanner(f)
		for s.Scan() {
			if v, ok := strings.CutPrefix(s.Text(), "PRETTY_NAME="); ok {
				name = "Linux " + strings.Trim(v, `"'`)
				break
			}
		}
	}
	var u unix.Utsname
	if unix.Uname(&u) == nil {
		name += " (kernel " + unix.ByteSliceToString(u.Release[:]) + ")"
	}
	return name
}
