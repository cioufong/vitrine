# Networking

A VM has one network adapter. Configuration ▸ Network (or `vitrinectl set NAME --network …`) picks
what it is plugged into:

| Source | `--network` | VZ | QEMU | Reaches |
|---|---|---|---|---|
| Shared Network (NAT) | `nat` | `VZNATNetworkDeviceAttachment` | user-mode (slirp) | internet, Mac; forwarded ports in |
| Host-only | `host-only` | vmnet host mode (macOS 26+) | slirp `restrict=on` | Mac and other host-only VMs (VZ); forwarded ports only (QEMU) |
| Named network | `network:NAME` | vmnet network (macOS 26+) | relayed into the same vmnet network | other VMs on NAME, Mac, internet if the network is shared |
| Bridged | `bridged:IF` | file-handle attachment ↔ relay ↔ bridge helper | socket ↔ relay ↔ bridge helper | the LAN the interface is on; own address from its router |
| Disconnected | `none` | no adapter | no adapter | nothing |

TCP and UDP port forwards work on every backend and mode except Disconnected. `--ip ADDR` on a named
network with DHCP reserves that address for the VM's MAC (`--ip dhcp` clears it).

```sh
vitrinectl network create lab --subnet 192.168.120.0/24     # shared; --kind host-only for no internet
vitrinectl set web --network network:lab --ip 192.168.120.50
vitrinectl set db  --network network:lab
vitrinectl network interfaces                                # what can be bridged
vitrinectl set web --network bridged:en0
```

Named networks live in `networks.json` in the library and are edited in Settings ▸ Networks. A
change applies once every VM on that network has stopped.

## How named networks are shared between processes

The Vitrine app and every `vitrinectl run` are separate processes, and a vmnet network made with
`vmnet_network_create` lives in the process that created it: when that process exits the network
goes away even if another process still holds it, and joining a network whose creator has gone
hangs. So the first VM to use a network starts a small owner process, `vitrinectl netd <key>`, in
its own session; it creates the network, writes its serialization (`vmnet_network_copy_serialization`)
next to a lock in `$TMPDIR/vitrine-networks/`, and every VM joins from that with
`vmnet_network_create_with_serialization`. Each VM registers its pid there; netd exits about six
seconds after the last one has gone, and the bridge interface disappears with it. Named networks
are defined per library, so their owners are too: two libraries (`VITRINE_HOME`) with a network of
the same name don't share it.

QEMU can't attach to vmnet itself, so the process running a QEMU VM starts a vmnet interface on the
network (`vmnet_interface_start_with_network`, which needs no root on macOS 26) and relays frames to
QEMU over a Unix stream socket (`-netdev stream`).

## Bridged networking

Bridging needs root on macOS: `vmnet_start_interface` in bridged mode fails for other users, and the
new vmnet network API has no bridged mode. Vitrine ships a helper, `vitrine-bridged`, that
Settings ▸ Networks ▸ Install Bridge Helper installs as a LaunchDaemon
(`/Library/LaunchDaemons/com.vitrine.bridged.plist`, binary in `/Library/PrivilegedHelperTools`,
log in `/var/log/vitrine-bridged.log`) after asking for an administrator's password. It runs as
root for one user and listens on `/var/run/vitrine/bridged.<interface>`, owned by that user, mode
0600; each connection gets its own bridged vmnet interface. The Uninstall button or
`vitrinectl network uninstall-bridge-helper` removes it.

If socket_vmnet already runs in bridged mode (`socket_vmnet.bridged.<interface>` under
`/opt/homebrew/var/run`, `/usr/local/var/run` or `/var/run`), Vitrine uses its socket instead.

Tested through the installed LaunchDaemon on an M1 Max with macOS 27.0.1: a Debian guest on VZ
bridged to Wi-Fi (`en0`) and to a USB Ethernet adapter, and a Windows 11 guest on QEMU bridged to
the USB Ethernet adapter, each getting an address from the office router, reachable over SSH from
the Mac and fetching https://www.apple.com. The helper notices adapters plugged in later within 15
seconds.

**Bridge to a wired interface when you can.** Wi-Fi access points accept frames only from the
Mac's own MAC address, so macOS bridges Wi-Fi with MAC translation (the `MACNAT` flag on the
bridge member): the guest's frames leave with the Mac's MAC, and the router sees the guest as
another address of the Mac. DHCP still works (the request carries the guest's MAC) and the guest
is reachable, but anything that tells devices apart by MAC (a router's device list, MAC filtering)
won't see it as a machine of its own. On Ethernet there is no translation.

## Finding the guest's address

The Mac's DHCP lease file only knows NAT guests. For the other modes the guest agent reports its
addresses (Linux and macOS agents, protocol message `guestNetwork`); the process running the VM
writes the one matching the adapter's MAC to the bundle's `guest-ip`. Port forwards and SSH
connect to that address, and the guest is not trusted, so a report is used only if a guest could
own the address: IPv4, not loopback, unspecified, link-local, multicast or broadcast, not one of
the Mac's own addresses, and inside the network's subnet when Vitrine knows it (a named network
with a subnet set, or the Mac's subnet on the bridged interface).

Without an agent, Vitrine learns the address from the guest's own frames wherever they pass
through its relay (bridged on both backends, QEMU on a named network): the sender of an ARP packet
or the source of an IPv4 packet sent from the adapter's MAC, checked the same way before it is
written. That works seconds after the guest's DHCP client finishes, before the Mac has talked to
the guest. While an address is in use (seen in the last 30 seconds) another one doesn't replace
it, so a guest with two addresses or a spoofed source doesn't make it flap.

Elsewhere (VZ on host-only and named networks, and VZ bridged with `com.apple.vm.networking`, where
Virtualization.framework moves the frames itself) Vitrine falls back to the reserved address on a
named network or the Mac's ARP cache. **macOS's Local Network privacy hides the ARP cache from
Vitrine's processes**: for a process that isn't Apple's, the neighbour-table sysctl returns
nothing, and so does `/usr/sbin/arp` when such a process runs it, while the same command in a
Terminal sees the entries. So on those networks, give the VM a fixed address or install the agent.

## Measured throughput

SSH `dd` from a Debian guest to the Mac, M1 Max, macOS 27.0.1:

| Path | MB/s |
|---|---|
| VZ on a vmnet network (direct) | ~234 |
| VZ bridged through the relay | ~185 |
| QEMU bridged (straight to the helper, before the relay) | ~165 |
| QEMU on a vmnet network (relay) | ~155 |

The relay itself handles about 209k packets/s (316 MB/s) in isolation.

## Known limitations and recommendations

- **Networks are per process in vmnet.** Solved by netd as described above. Anything else that
  creates vmnet networks (a future XPC service, a privileged helper) should follow the same rule:
  one long-lived owner per network, joiners only ever use the serialization, and joiners check the
  owner is alive before joining, because joining a dead network blocks instead of failing.
- **Pass the gateway address as the subnet.** `vmnet_network_configuration_set_ipv4_subnet` wants
  the Mac's address on the network (x.x.x.1), not the network address. Given x.x.x.0 the network is
  created but starting an interface on it fails with 1001 (`EADDRNOTAVAIL`).
- **`com.apple.security.virtualization` is required** for `vmnet_network_create`; an unsigned
  binary gets 1002.
- **Auto-subnet shared networks in long-lived processes** can fail with InternetSharing `err 16`
  (`EBUSY`) after many other networks have been created and torn down in the same process. Owners
  that exit when idle (netd) don't run into it; it affected only the helper's `--serve-shared` test
  mode.
- **Headless Linux guests don't report an address**: the Linux agent exits when there is no X
  display. Bridged guests are found from their frames anyway; on VZ host-only and named networks
  give such VMs a fixed address, or use NAT. A headless agent mode is future work.
- **Duplicate MACs.** Cloned VMs get new MACs, but VMs copied by hand may not; two adapters with
  one MAC on the same network will break each other.
- **Windows guests**: shared folders and drag and drop go through the NAT gateway, so they need the
  Shared Network.
- **QEMU NAT DNS needs an IPv4 resolver among the Mac's first three.** libslirp forwards the guest's
  IPv4 DNS server (10.0.2.3) to the first IPv4 server `res_ninit`/`res_getservers` return, and those
  read at most three (`MAXNS`) from `/etc/resolv.conf`. When the network the Mac is on lists three
  IPv6 resolvers first (an IPv6-first ISP, seen 2026-10-21 on a wired adapter: Google's two IPv6
  servers and HiNet's), libslirp finds no IPv4 server, sends the query to 127.0.0.1:53 and the guest's
  lookups time out. Everything else keeps working: TCP and UDP by address, port forwards, the IPv6
  DNS server fec0::3 and any public resolver the guest asks directly. Guests that also take DNS from
  router advertisements (Windows, NetworkManager) know fec0::3 too, but Windows asks 10.0.2.3 first and
  falls back only after a timeout, so some programs still fail: in a Windows 11 guest on 2026-10-21,
  `Resolve-DnsName` succeeded while `curl.exe` and `Invoke-WebRequest` reported names that "could not
  be resolved" in two of four tries. Fixes: put an IPv4
  resolver in the first three on the Mac (System Settings › Network › the interface › DNS), give the
  guest a resolver itself, or run the VM on a named network (vmnet's DNS proxy uses mDNSResponder,
  like VZ NAT). Virtualization.framework guests are not affected.
