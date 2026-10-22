package win

import "testing"

func TestFromSlirpHost(t *testing.T) {
	for addr, want := range map[string]bool{
		"10.0.2.2:51000":          true,
		"[::ffff:10.0.2.2]:51000": true,
		"10.0.2.15:51000":         false, // the guest itself
		"127.0.0.1:51000":         false,
		"192.168.1.20:445":        false,
		"10.0.2.2":                false, // no port: not a peer address
		"[::1]:51000":             false,
		"":                        false,
		"garbage":                 false,
	} {
		if got := FromSlirpHost(addr); got != want {
			t.Errorf("%q: got %v", addr, got)
		}
	}
}
