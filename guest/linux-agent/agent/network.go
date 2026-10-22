package agent

import (
	"net"
	"reflect"
	"sort"
	"strings"
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

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
		n := protocol.NetInterface{Name: ifc.Name, MAC: strings.ToLower(ifc.HardwareAddr.String()),
			IPv4: []string{}, IPv6: []string{}}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			if v4 := ipn.IP.To4(); v4 != nil {
				n.IPv4 = append(n.IPv4, v4.String())
			} else if !ipn.IP.IsLinkLocalUnicast() {
				n.IPv6 = append(n.IPv6, ipn.IP.String())
			}
		}
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
