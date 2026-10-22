package x11

import "testing"

func TestPreferredMode(t *testing.T) {
	all := map[uint32]modeInfo{
		10: {10, 1920, 1080}, 11: {11, 1280, 800}, 12: {12, 2560, 1600}, 13: {13, 0, 0},
	}
	// Preferred (and first listed) wins even if not the largest.
	if m, ok := preferredMode([]uint32{11, 10, 12}, 1, all); !ok || m.ID != 11 {
		t.Fatalf("preferred: %+v %v", m, ok)
	}
	// No preferred flag: first listed, like `xrandr --auto`.
	if m, ok := preferredMode([]uint32{10, 12}, 0, all); !ok || m.ID != 10 {
		t.Fatalf("unflagged: %+v %v", m, ok)
	}
	// Unknown / degenerate modes are skipped.
	if m, ok := preferredMode([]uint32{99, 13, 12}, 1, all); !ok || m.ID != 12 {
		t.Fatalf("skip unknown: %+v %v", m, ok)
	}
	if _, ok := preferredMode(nil, 0, all); ok {
		t.Fatal("empty list")
	}
}

func TestShouldApply(t *testing.T) {
	big, small, other := modeInfo{1, 1920, 1200}, modeInfo{2, 1280, 800}, modeInfo{3, 1024, 768}
	cases := []struct {
		name               string
		seen               bool
		last, pref, cur    modeInfo
		active, wantChange bool
	}{
		{"startup mismatch", false, modeInfo{}, big, small, true, true},
		{"startup match", false, modeInfo{}, big, big, true, false},
		{"same size, other id", true, big, big, modeInfo{9, 1920, 1200}, true, false},
		{"host resized (preferred changed)", true, small, big, small, true, true},
		{"user picked another mode", true, big, big, other, true, false},
		{"unlit output", true, big, big, modeInfo{}, false, true},
	}
	for _, c := range cases {
		if got := shouldApply(c.seen, c.last, c.pref, c.cur, c.active); got != c.wantChange {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

func TestScreenSize(t *testing.T) {
	if w, h := screenSizeFor(1920, 1080, nil); w != 1920 || h != 1080 {
		t.Fatalf("single: %dx%d", w, h)
	}
	if w, h := screenSizeFor(1280, 800, []crtcBox{{1280, 0, 1024, 768}}); w != 2304 || h != 800 {
		t.Fatalf("side by side: %dx%d", w, h)
	}
	if mw, mh := screenMM(1920, 1080); mw != 508 || mh != 286 {
		t.Fatalf("mm: %dx%d", mw, mh)
	}
}
