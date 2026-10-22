package x11

import (
	"testing"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

func TestParseXftDPI(t *testing.T) {
	res := "Xcursor.size:\t24\nXft.antialias:\t1\nXft.dpi:\t192\nXft.hinting:\t1\n"
	if got := parseXftDPI(res); got != 192 {
		t.Fatalf("got %v", got)
	}
	if got := parseXftDPI("Xft.hinting: 1"); got != 0 {
		t.Fatalf("absent: %v", got)
	}
}

func TestWMClass(t *testing.T) {
	cases := map[string]string{"xterm\x00XTerm\x00": "XTerm", "Navigator\x00firefox-esr\x00": "firefox-esr", "solo": "solo", "": ""}
	for in, want := range cases {
		if got := wmClass(in); got != want {
			t.Errorf("wmClass(%q)=%q want %q", in, got, want)
		}
	}
}

func TestTextChunks(t *testing.T) {
	chunks, total := textChunks("héllo✓世界", 100, 3)
	if total != 8 || len(chunks) != 3 || chunks[0] != "hél" || chunks[1] != "lo✓" || chunks[2] != "世界" {
		t.Fatalf("got %q total %d", chunks, total)
	}
	long := make([]rune, 10000)
	for i := range long {
		long[i] = 'é'
	}
	chunks, total = textChunks(string(long), 4096, 32)
	n := 0
	for _, c := range chunks {
		r := []rune(c)
		if len(r) > 32 {
			t.Fatalf("chunk of %d runes", len(r))
		}
		n += len(r)
	}
	if total != 10000 || n != 4096 || len(chunks) != 128 {
		t.Fatalf("total %d kept %d chunks %d", total, n, len(chunks))
	}
	if c, _ := textChunks("", 10, 3); len(c) != 0 {
		t.Fatal("empty text")
	}
}

func TestInheritOwner(t *testing.T) {
	wins := []protocol.WindowInfo{
		{ID: 1, Kind: protocol.KindMenu},
		{ID: 2, Kind: protocol.KindMenu, PID: 5, AppName: "Own"},
		{ID: 3, Kind: protocol.KindNormal, PID: 42, AppName: "XTerm", IsFocused: true},
	}
	inheritOwner(wins)
	if wins[0].PID != 42 || wins[0].AppName != "XTerm" || wins[1].AppName != "Own" {
		t.Fatalf("got %+v", wins)
	}
}
