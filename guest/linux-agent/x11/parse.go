package x11

import (
	"strconv"
	"strings"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// Platform-independent helpers (tested on any OS).

// parseXftDPI extracts Xft.dpi from RESOURCE_MANAGER contents (0 if absent).
func parseXftDPI(resources string) float64 {
	for _, line := range strings.Split(resources, "\n") {
		k, v, ok := strings.Cut(line, ":")
		if ok && strings.TrimSpace(k) == "Xft.dpi" {
			if f, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil {
				return f
			}
		}
	}
	return 0
}

// inheritOwner fills in pid/appName for menus that carry neither (many
// toolkits set no WM_CLASS / _NET_WM_PID on override-redirect popups). A popup
// almost always belongs to the focused application, so it inherits from the
// focused window; the host can then group it with that app.
func inheritOwner(wins []protocol.WindowInfo) {
	var owner *protocol.WindowInfo
	for i := range wins {
		if wins[i].IsFocused {
			owner = &wins[i]
			break
		}
	}
	if owner == nil {
		return
	}
	for i := range wins {
		w := &wins[i]
		if w.Kind == protocol.KindMenu && w.PID == 0 && w.AppName == "" {
			w.PID, w.AppName = owner.PID, owner.AppName
		}
	}
}

// textChunks splits text into chunks of at most chunk runes, keeping only the
// first maxRunes runes. It also returns the original rune count.
func textChunks(text string, maxRunes, chunk int) ([]string, int) {
	runes := []rune(text)
	total := len(runes)
	if len(runes) > maxRunes {
		runes = runes[:maxRunes]
	}
	var out []string
	for i := 0; i < len(runes); i += chunk {
		out = append(out, string(runes[i:min(i+chunk, len(runes))]))
	}
	return out, total
}

// wmClass returns the class part of WM_CLASS ("instance\0Class\0").
func wmClass(v string) string {
	parts := strings.Split(strings.TrimRight(v, "\x00"), "\x00")
	return parts[len(parts)-1]
}
