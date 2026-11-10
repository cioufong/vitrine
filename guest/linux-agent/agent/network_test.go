package agent

import (
	"fmt"
	"net"
	"testing"
)

// Hosts reject a report with more than 32 addresses of one family on an
// interface (and before clamping was added, closed the channel over it), so the
// agent keeps the first 32 of each.
func TestInterfaceEntryCapsAddressesPerFamily(t *testing.T) {
	mac, _ := net.ParseMAC("52:54:00:12:34:56")
	var addrs []net.Addr
	for i := 0; i < 40; i++ {
		addrs = append(addrs, &net.IPNet{IP: net.IPv4(10, 0, 0, byte(i)), Mask: net.CIDRMask(24, 32)})
		addrs = append(addrs, &net.IPNet{IP: net.ParseIP(fmt.Sprintf("fd00::%x", i)), Mask: net.CIDRMask(64, 128)})
	}
	addrs = append(addrs, &net.IPNet{IP: net.ParseIP("fe80::1"), Mask: net.CIDRMask(64, 128)})
	n := interfaceEntry("eth0", mac, addrs)
	if len(n.IPv4) != maxAddressesPerFamily || len(n.IPv6) != maxAddressesPerFamily {
		t.Fatalf("got %d IPv4 and %d IPv6 addresses, want %d each", len(n.IPv4), len(n.IPv6), maxAddressesPerFamily)
	}
	if n.IPv4[0] != "10.0.0.0" || n.IPv4[31] != "10.0.0.31" || n.IPv6[0] != "fd00::" || n.IPv6[31] != "fd00::1f" {
		t.Fatalf("first addresses not kept in order: %v %v", n.IPv4, n.IPv6)
	}
	if n.MAC != "52:54:00:12:34:56" || n.Name != "eth0" {
		t.Fatalf("bad identity %q %q", n.Name, n.MAC)
	}
}
