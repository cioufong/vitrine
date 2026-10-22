package win

import "net/netip"

// slirpHost is the address QEMU user networking (slirp) gives the host: a
// hostfwd connection from the Mac's 127.0.0.1 arrives from it.
var slirpHost = netip.AddrFrom4([4]byte{10, 0, 2, 2})

// FromSlirpHost reports whether remote, a TCP peer address ("ip:port", as
// net.Conn.RemoteAddr().String() formats it), is the slirp host: the
// connection was forwarded from the Mac, not made by another machine on the
// network or a program inside the guest. It is pure (no net import) so the
// check is tested on any OS.
func FromSlirpHost(remote string) bool {
	ap, err := netip.ParseAddrPort(remote)
	return err == nil && ap.Addr().Unmap() == slirpHost
}
