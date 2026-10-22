package win

import (
	"strconv"
	"strings"
)

// osName formats Hello.os as "Windows <product> <display version> (build N.UBR)"
// from the CurrentVersion registry values. Windows 11 still reports
// ProductName "Windows 10 …", so builds ≥ 22000 are corrected.
func osName(product, displayVersion, build string, ubr uint64) string {
	product = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(product), "Windows"))
	if n, err := strconv.Atoi(build); err == nil && n >= 22000 && strings.HasPrefix(product, "10") {
		product = "11" + strings.TrimPrefix(product, "10")
	}
	parts := []string{"Windows"}
	if product != "" {
		parts = append(parts, product)
	}
	if displayVersion != "" {
		parts = append(parts, displayVersion)
	}
	s := strings.Join(parts, " ")
	if build != "" {
		b := build
		if ubr > 0 {
			b += "." + strconv.FormatUint(ubr, 10)
		}
		s += " (build " + b + ")"
	}
	return s
}
