package agent

import (
	"net"
	"reflect"
	"sort"
	"strings"
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// maxAddressesPerFamily is the host's limit per interface, for IPv4 and IPv6
// separately. Older hosts reject the whole report (and drop the
// connection) when an interface goes over it.
const maxAddressesPerFamily = 32

// NetworkPollInterval is how often the interface list is checked for changes.
var NetworkPollInterval = 10 * time.Second

// networkSnapshot lists the guest's non-loopback interfaces that have a MAC and
// at least one address. The host uses it to reach guests that aren't in the
// Mac's DHCP leases (vmnet and bridged networks).
func networkSnapshot() protocol.GuestNetwork {
	out := protocol.GuestNetwork{Interfaces: []protocol.NetInterface{}}
	ifs, err := net.Interfaces()
	if err != nil {
		return out
	}
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagLoopback != 0 || len(ifc.HardwareAddr) != 6 {
			continue
		}
		addrs, _ := ifc.Addrs()
		n := interfaceEntry(ifc.Name, ifc.HardwareAddr, addrs)
		if len(n.IPv4)+len(n.IPv6) > 0 {
			out.Interfaces = append(out.Interfaces, n)
		}
	}
	sort.Slice(out.Interfaces, func(i, j int) bool { return out.Interfaces[i].Name < out.Interfaces[j].Name })
	if len(out.Interfaces) > 16 {
		out.Interfaces = out.Interfaces[:16]
	}
	return out
}

// interfaceEntry is one interface's report: its first IPv4 addresses and its
// first non-link-local IPv6 addresses, up to maxAddressesPerFamily each.
func interfaceEntry(name string, mac net.HardwareAddr, addrs []net.Addr) protocol.NetInterface {
	n := protocol.NetInterface{Name: name, MAC: strings.ToLower(mac.String()),
		IPv4: []string{}, IPv6: []string{}}
	for _, a := range addrs {
		ipn, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		if v4 := ipn.IP.To4(); v4 != nil {
			if len(n.IPv4) < maxAddressesPerFamily {
				n.IPv4 = append(n.IPv4, v4.String())
			}
		} else if !ipn.IP.IsLinkLocalUnicast() && len(n.IPv6) < maxAddressesPerFamily {
			n.IPv6 = append(n.IPv6, ipn.IP.String())
		}
	}
	return n
}

// networkLoop reports the interface list now and whenever it changes, until
// the connection closes. Started once per session, when the host's Hello
// lists "network" (older hosts reject unknown message types).
func (s *session) networkLoop() {
	var last *protocol.GuestNetwork
	report := func() {
		now := networkSnapshot()
		if last != nil && reflect.DeepEqual(*last, now) {
			return
		}
		if s.conn.Send(now) {
			last = &now
		}
	}
	report()
	t := time.NewTicker(NetworkPollInterval)
	defer t.Stop()
	for {
		select {
		case <-s.conn.Done():
			return
		case <-t.C:
			report()
		}
	}
}

// startNetworkReports runs networkLoop once per session.
func (s *session) startNetworkReports() {
	s.networkOnce.Do(func() { go s.networkLoop() })
}
