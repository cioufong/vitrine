import Foundation
import AppKit
import Virtualization
import VitrineCore
import VitrineVZ
import VitrineQEMU
import VitrineAgentHost
import VitrineNet

// vitrinectl — command-line front end for Vitrine.

let usage = """
usage: vitrinectl <command> [options]

VMs
  list                                   List VMs and their state
  create <name> [--ipsw <path|latest>] [--cpus N] [--memory 8G] [--disk 80G]
                [--user NAME --password PW|--password-stdin [--full-name "Full Name"]]
                                         Create a macOS VM and install macOS
  create-linux <name> [--iso PATH] [--kernel K [--initrd I] [--cmdline "…"]] [--cpus N] [--memory 4G] [--disk 64G] [--rosetta]
                                         Create a Linux VM (UEFI + installer ISO, or direct kernel boot)
  create-linux <name> --iso PATH --backend qemu [--arch x86_64]
                                         Linux on the QEMU backend (x86_64 = full emulation)
  create-windows <name> --iso PATH [--arch x64] [--user NAME --password PW|--password-stdin] [--cpus N] [--memory 8G] [--disk 80G]
                                         Windows 11 on QEMU (Arm64 via HVF; x64 emulated)
  screenshot <name> <out.png>            Save the display of a running VM (full resolution PNG)
  create-linux <name> --distro debian-13 --user NAME --password PW|--password-stdin [--desktop no]
                                         One-click Linux from an official cloud image + cloud-init
  run <name> [--gui] [--recovery] [--console]
                                         Run a VM (headless unless --gui); --console streams the Linux serial console
  stop <name> [--force]                  Shut down a VM started by another vitrinectl/Vitrine process
  suspend <name>                         Save memory state to disk and stop
  display <name> WxH                     Change a QEMU guest's resolution (virtio-gpu guests)
  discard-state <name>                   Drop saved memory; the next start boots from disk
  info <name>                            Print config and paths
  set <name> [--cpus N] [--memory 8G] [--disk 128G] [--display WxH[@PPI]] [--eject]
             [--nested on|off]           Nested virtualization (Linux, VZ, M3+ / macOS 15+)
             [--disposable on|off]       Discard every run's changes when the VM stops
             [--gdb PORT|off]            QEMU GDB stub on 127.0.0.1:PORT
             [--secure-boot on|off]      x86_64 QEMU: Secure Boot with Microsoft keys (resets UEFI variables)
  clone <name> <new-name>                Instant APFS clone with a fresh identity
  import <disk.qcow2|.vmdk|.vhdx|.vdi|.img> --name N [--os linux|windows] [--arch aarch64|x86_64] [--cpus N] [--memory 4G]
                                         New VM booting a converted copy of another tool's disk
  import <VM.utm> [--name N]             Import a UTM virtual machine
         … [--user NAME --password PW]   Guest account for exec, push/pull and agent installs
                                         (--password-stdin reads it from stdin, out of sight of ps)
  disk add <name> <image> [--ro]         Attach a converted copy of a disk image (VM shut down)
  delete <name>                          Delete a stopped VM
  ip <name>                              Guest IP address (NAT)
  exec <name> [--] <command…>            Run a command in the guest over SSH
  push <name> <local-path> <guest-path>  Copy a file or folder into the guest (SSH)
  pull <name> <guest-path> <local-path>  Copy a file or folder out of the guest (SSH)
  keys <name> --text "…" [--via auto|keyboard|agent] | --combo NAME
                                     Type text (US keyboard, or the guest agent for other
                                     characters) or press a combination (e.g. ctrl+alt+delete)
  click <name> X Y [--button left|right|none] [--clicks 2]
                                         Click at a display pixel (origin top left; none = only move)
  console <name>                         Attach to the serial console (Ctrl-] detaches)
  console <name> [--send "…\n"] [--expect REGEX] [--timeout 10]
                                         Scripted: send text, print output until REGEX matches
                                         combos: ctrl-alt-delete, ctrl-alt-f1, alt-tab, … or qcodes a+b+c
  agent install <name>                   (Re)install the Vitrine Agent in the guest
  agent finalize <name>                  Mark macOS setup done so cold boots skip Setup Assistant
  agent camera <name>                    Install a guest's virtual camera (Linux v4l2loopback, Windows 11 media source)
  agent bluetooth <name>                 Install a Linux guest's Bluetooth bridge (BlueZ, hci_uart; experimental)
  agent permissions <name>               Ask in a running macOS guest to allow the agent Screen Recording and
                                         Accessibility for seamless mode; answer the prompts in the VM

Network
  set <name> --network nat|host-only|none|network:<NAME>|bridged:<INTERFACE>
  set <name> --ip <ADDRESS>|dhcp          Fixed address on a named network (DHCP reservation)
  network list                           Named networks (VMs on one reach each other and the Mac)
  network create <NAME> [--kind shared|host-only] [--subnet 192.168.100.0/24] [--dhcp on|off]
  network edit <NAME> [--kind …] [--subnet CIDR|auto] [--dhcp on|off]
  network delete <NAME>
  network interfaces                     Mac interfaces VMs can be bridged to, and who serves them
  network install-bridge-helper          Install the root helper bridged networking needs (asks for an admin password)
  network uninstall-bridge-helper
  port list <name>
  port add <name> [udp:][ADDR:]HOSTPORT:GUESTPORT   e.g. 8080:80, 0.0.0.0:2222:22 (next start)
  port remove <name> HOSTPORT

Shared folders
  share list <name>
  share add <name> <host-path> [--as <share-name>] [--ro]
  share remove <name> <share-name>

USB (running VMs)
  drop <name> <file…>                    Copy files to the guest's Desktop (like dragging onto its window)
  usb devices                            USB devices plugged into this Mac
  usb list <name>                        What is attached to the VM
  usb attach <name> <image> [--ro]       Plug a disk image (.img/.dmg/.iso) in as a USB drive
  usb attach <name> --device VID:PID     Pass a Mac USB device through (Windows/QEMU; macOS/Linux need a
                                         Developer-signed Vitrine on macOS 27)
  usb detach <name> <id>                 Unplug (ids from `usb list`)

Snapshots
  snapshot list <name>
  snapshot create <name> <snapshot-name>
  snapshot restore <name> <snapshot>
  snapshot delete <name> <snapshot>

Agents
  mcp                                    Model Context Protocol server on stdio (see docs/mcp.md)

Restore images
  ipsw latest                            Show the newest IPSW this Mac supports
  ipsw download [--url URL]              Download (resumable) into the cache

Environment: VITRINE_HOME overrides the VM library (\(VMLibrary.root.path)).
"""

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: ArraySlice<String>, flagNames: Set<String> = ["gui", "recovery", "force", "ro", "rosetta", "console", "all", "eject", "password-stdin"]) {
        var it = argv.makeIterator()
        while let a = it.next() {
            if a == "--" {
                // Everything after `--` is positional, e.g. `exec vm -- ls --color=auto`.
                while let rest = it.next() { positional.append(rest) }
            } else if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if flagNames.contains(key) { flags.insert(key) }
                else if let v = it.next() { options[key] = v }
                else { die("missing value for \(a)") }
            } else {
                positional.append(a)
            }
        }
    }

    func arg(_ i: Int, _ name: String) -> String {
        guard i < positional.count else { die("missing <\(name)>\n\n\(usage)") }
        return positional[i]
    }

    /// The guest account password: `--password PW`, or the first line of stdin with
    /// `--password-stdin` (which keeps it out of `ps`).
    func password() -> String? {
        if let pw = options["password"] { return pw }
        guard flags.contains("password-stdin") else { return nil }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else { die("--password-stdin: no password on stdin") }
        return line
    }
}

func networkCommand(_ args: Args) throws {
    let sub = args.arg(0, "list|create|edit|delete|interfaces|install-bridge-helper|uninstall-bridge-helper")
    var networks = VirtualNetworks.load()
    func apply(_ n: inout VirtualNetwork) throws {
        if let k = args.options["kind"] {
            switch k.lowercased() {
            case "shared", "nat": n.kind = .shared
            case "host-only", "hostonly", "host": n.kind = .hostOnly
            default: throw VitrineError.invalidConfig("bad --kind, want shared or host-only")
            }
        }
        if let v = args.options["subnet"] { n.subnet = v.lowercased() == "auto" ? nil : v }
        if let v = args.options["dhcp"] { n.dhcp = try onOff(v, "--dhcp") }
    }
    switch sub {
    case "list":
        if networks.isEmpty { print("no networks (vitrinectl network create <name>)"); return }
        for n in networks {
            let users = VMLibrary.list().compactMap { b -> String? in
                guard let c = try? b.loadConfig(), c.network.mode == .network, c.network.networkName == n.name else { return nil }
                return c.network.fixedIPv4.map { "\(c.name) (\($0))" } ?? c.name
            }
            let subnet = n.subnet ?? VmnetNetworks.activeSubnet(networkName: n.name).map { "auto: \($0)" } ?? "auto"
            print("\(n.name)\t\(n.kind == .shared ? "shared" : "host-only")\t\(subnet)\tDHCP \(n.dhcp ? "on" : "off")\t\(users.joined(separator: ", "))")
        }
    case "create":
        var n = VirtualNetwork(name: args.arg(1, "network name"))
        try apply(&n)
        networks.append(n)
        try VirtualNetworks.save(networks)
        print("created network \(n.name)")
    case "edit":
        let name = args.arg(1, "network name")
        guard let i = networks.firstIndex(where: { $0.name == name }) else { die("there is no network named \(name)") }
        try apply(&networks[i])
        try VirtualNetworks.save(networks)
        print("updated \(name)" + (VmnetNetworks.activeSubnet(networkName: name) != nil ? " (applies once every VM on it has stopped)" : ""))
    case "delete":
        let name = args.arg(1, "network name")
        guard networks.contains(where: { $0.name == name }) else { die("there is no network named \(name)") }
        let users = VMLibrary.list().compactMap { try? $0.loadConfig() }.filter { $0.network.mode == .network && $0.network.networkName == name }
        guard users.isEmpty else { die("\(users.map(\.name).joined(separator: ", ")) still use \(name); move them to another network first") }
        try VirtualNetworks.save(networks.filter { $0.name != name })
        print("deleted network \(name)")
    case "interfaces":
        for i in VmnetInterfaces.bridgeable() {
            let served: String
            switch BridgeSockets.socket(for: i)?.provider {
            case .vitrine: served = "ready (Vitrine bridge helper)"
            case .socketVmnet: served = "ready (socket_vmnet)"
            case nil: served = BridgeHelper.isInstalled ? "helper installed, not serving yet" : "needs the bridge helper"
            }
            print("\(i)\t\(served)")
        }
    case "install-bridge-helper":
        try BridgeHelper.install()
        print("installed; bridged networking is ready for \(NSUserName())")
    case "uninstall-bridge-helper":
        try BridgeHelper.uninstall()
        print("removed the bridge helper")
    default:
        die("unknown network command \(sub)\n\n\(usage)")
    }
}

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("vitrinectl: \(message)\n".utf8))
    exit(code)
}

func need<T>(_ v: T?, _ message: String) -> T {
    guard let v else { die(message) }
    return v
}

func onOff(_ s: String, _ option: String) throws -> Bool {
    switch s.lowercased() {
    case "on", "yes", "true", "1": return true
    case "off", "no", "false", "0": return false
    default: throw VitrineError.invalidConfig("bad \(option), want on or off")
    }
}

func parseMiB(_ s: String) -> UInt64 {
    guard let bytes = UInt64(sizeString: s) else { die("bad size \(s)") }
    return bytes < 1 << 20 ? bytes : bytes >> 20  // bare numbers are MiB
}

/// Runs async work from top-level code while keeping the main run loop alive.
func runAsync(_ body: @escaping @MainActor () async throws -> Void) -> Never {
    Task { @MainActor in
        do { try await body(); exit(0) } catch { die(error.localizedDescription) }
    }
    RunLoop.main.run()
    exit(0)
}

/// Tells the VM's owner to apply edited shared folders now; returns a note for the user.
func liveReloadShares(_ b: VMBundle) -> String {
    guard b.runningPID() != nil else { return "" }
    if let r = try? VMControl.send(.init(op: .reloadShares), to: b, timeout: 10), r.ok { return " (applied to the running VM)" }
    return " (applies on next start)"
}

/// Asks whichever process runs `b` to shut it down (or suspend it) and waits up to 90 s.
func stopVM(_ b: VMBundle, suspend: Bool, force: Bool) throws -> String {
    guard let owner = b.lockOwner() else { throw VitrineError.invalidConfig("\(b.name) is not running") }
    if owner.role == .operation { throw VitrineError.invalidConfig("\(b.name) is busy (snapshot or clone in progress)") }
    let op: VMControl.Request.Op = suspend ? .suspend : force ? .forceStop : .stop
    guard FileManager.default.fileExists(atPath: VMControl.socketURL(for: b).path) else {
        throw VitrineError.backend("\(b.name) (pid \(owner.pid)) has no control socket: it may still be starting, or run in a Vitrine build too old for vitrinectl to stop")
    }
    let r = try VMControl.send(.init(op: op), to: b, timeout: 10)
    // The owner refuses a suspend up front when it can tell it would fail (e.g. a writable USB drive).
    if r.refused == true { throw VitrineError.invalidConfig("can't suspend \(b.name): \(r.error ?? "refused")") }
    // Owners answer lifecycle requests with ok or a refusal; anything else is a build from before them.
    guard r.ok else {
        let verb = suspend ? "suspend" : "stop"
        throw VitrineError.backend("\(b.name) runs in an older Vitrine build (pid \(owner.pid)) that vitrinectl can't ask to \(verb); \(verb) it there instead (\(r.error ?? "request not understood"))")
    }
    let deadline = Date().addingTimeInterval(90)
    while b.runningPID() != nil, Date() < deadline { usleep(200_000) }
    if b.runningPID() != nil { throw VitrineError.backend("\(b.name) did not stop within 90s; try force") }
    return suspend ? "suspended \(b.name)" : "stopped \(b.name)"
}

func status(of bundle: VMBundle) -> String {
    if bundle.runningPID() != nil { return "running" }
    if bundle.hasSavedState { return "suspended" }
    return "stopped"
}

func progressBar(_ fraction: Double, _ label: String) {
    let width = 30
    let filled = Int((fraction * Double(width)).rounded())
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    FileHandle.standardError.write(Data("\r\(label) \(bar) \(Int(fraction * 100))%  ".utf8))
}

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)
let argv = CommandLine.arguments
guard argv.count >= 2 else { print(usage); exit(0) }
let command = argv[1]
let args = Args(argv.dropFirst(2))

do {
    switch command {
    case "help", "-h", "--help":
        print(usage)

    case "mcp":
        MCPServer.run()

    case "list":
        let vms = VMLibrary.list()
        if vms.isEmpty { print("No VMs in \(VMLibrary.root.path)"); exit(0) }
        print("NAME".padding(toLength: 24, withPad: " ", startingAt: 0) + "STATE      CPU  MEMORY   DISK")
        for b in vms {
            guard let c = try? b.loadConfig() else { continue }
            let disk = c.disks.first.map { DiskImage.allocatedSize(of: b.resolve($0.path)) } ?? 0
            print(b.name.padding(toLength: 24, withPad: " ", startingAt: 0)
                  + status(of: b).padding(toLength: 11, withPad: " ", startingAt: 0)
                  + "\(c.cpuCount)".padding(toLength: 5, withPad: " ", startingAt: 0)
                  + "\(c.memoryMiB / 1024) GiB".padding(toLength: 9, withPad: " ", startingAt: 0)
                  + formatBytes(disk))
        }

    case "info":
        let b = try VMLibrary.find(args.arg(0, "name"))
        let c = try b.loadConfig()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print("path:  \(b.url.path)\nstate: \(status(of: b))")
        print(String(decoding: try enc.encode(c), as: UTF8.self))

    case "set":
        let b = try VMLibrary.find(args.arg(0, "name"))
        let growTo: UInt64? = args.options["disk"].map {
            guard let bytes = UInt64(sizeString: $0) else { die("bad --disk, want e.g. 128G") }
            return bytes
        }
        try b.withExclusiveLock {
            // Re-read only after locking: no start/snapshot/config transaction may race this edit.
            var c = try b.loadConfig()
            let changingHardware = growTo != nil || args.flags.contains("eject")
                || ["cpus", "memory", "display", "nested", "network", "secure-boot"].contains(where: { args.options[$0] != nil })
            if changingHardware, b.hasSavedState {
                throw VitrineError.invalidConfig("shut \(b.name) down (not suspend) before changing hardware or ejecting media")
            }
            if let v = args.options["cpus"] { c.cpuCount = need(Int(v), "bad --cpus") }
            if let v = args.options["memory"] { c.memoryMiB = parseMiB(v) }
            if let v = args.options["nested"] { c.features.nestedVirtualization = try onOff(v, "--nested") }
            if let v = args.options["disposable"] { c.features.disposable = try onOff(v, "--disposable") }
            if let v = args.options["network"] {
                if v.lowercased().hasPrefix("network:") {
                    let name = String(v.dropFirst("network:".count))
                    guard VirtualNetworks.named(name) != nil else {
                        throw VitrineError.invalidConfig("there is no network named “\(name)” (vitrinectl network list)")
                    }
                    c.network.mode = .network
                    c.network.networkName = name
                } else if v.lowercased().hasPrefix("bridged:") {
                    let interface = String(v.dropFirst("bridged:".count))
                    guard !interface.isEmpty else { throw VitrineError.invalidConfig("bad --network, want bridged:en0") }
                    c.network.mode = .bridged
                    c.network.bridgeInterface = interface
                } else {
                    switch v.lowercased() {
                    case "nat", "shared": c.network.mode = .nat
                    case "host-only", "hostonly", "host": c.network.mode = .hostOnly
                    case "none", "off": c.network.mode = .none
                    default: throw VitrineError.invalidConfig("bad --network, want nat, host-only, none, network:<name> or bridged:<interface>")
                    }
                }
            }
            if let v = args.options["ip"] {
                if v.lowercased() == "dhcp" || v.lowercased() == "auto" {
                    c.network.fixedIPv4 = nil
                } else {
                    guard IPv4Subnet.parse(v) != nil else { throw VitrineError.invalidConfig("bad --ip, want an IPv4 address or dhcp") }
                    c.network.fixedIPv4 = v
                }
            }
            if let v = args.options["secure-boot"] { c.features.secureBoot = try onOff(v, "--secure-boot") }
            if let v = args.options["gdb"] { c.features.gdbPort = v.lowercased() == "off" ? nil : need(Int(v), "bad --gdb, want a port or off") }
            if let v = args.options["display"] {
                let parts = v.split(separator: "@", omittingEmptySubsequences: false)
                guard (1...2).contains(parts.count) else { throw VitrineError.invalidConfig("bad --display, want 2560x1600[@220]") }
                let wh = parts[0].split(separator: "x", omittingEmptySubsequences: false)
                guard wh.count == 2, let width = Int(wh[0]), let height = Int(wh[1]) else {
                    throw VitrineError.invalidConfig("bad --display, want 2560x1600[@220]")
                }
                c.display.widthPixels = width; c.display.heightPixels = height
                if parts.count == 2 {
                    guard let ppi = Int(parts[1]), ppi > 0 else { throw VitrineError.invalidConfig("bad --display pixels per inch") }
                    c.display.pixelsPerInch = ppi
                }
            }
            var mediaToEject = c
            if args.flags.contains("eject") {
                c.installMedia = nil
                c.extraMedia = nil
                c.windowsSetupAgentSeen = nil
                c.windowsSetupOffline = nil
            }
            // Validate the proposal before either disk growth or deleting generated media.
            try c.validate(bundle: b)
            if let bytes = growTo {
                c = try MainActor.assumeIsolated {
                    try VirtualMachineController(bundle: b).growSystemDiskWhileLocked(to: bytes, proposedConfig: c)
                }
            }
            try b.saveConfig(c)
            if args.flags.contains("eject") {
                let media = mediaToEject.ejectInstallMedia(in: b)
                print("ejected \(media.joined(separator: ", "))")
            }
            if let bytes = growTo { print("grew the system disk to \(formatBytes(bytes)); the guest partition is extended on next start") }
        }
        print("updated \(b.name)")

    case "ip":
        let b = try VMLibrary.find(args.arg(0, "name"))
        let c = try b.loadConfig()
        if args.flags.contains("all") {
            for ip in GuestNetwork.candidates(mac: c.network.macAddress,
                                              hostname: c.dhcpHostname) {
                print(ip, GuestNetwork.tcpReachable(ip, port: 22, timeoutMs: 500) ? "ssh-reachable" : "-")
            }
        }
        guard let ip = b.guestIPAddress(c) else {
            die("no DHCP lease for \(c.network.macAddress) yet (is the VM booted?)")
        }
        print(ip)

    case "netd":
        // Internal: owner process of one vmnet network (see VmnetNetworks).
        guard #available(macOS 26, *) else { die("vmnet networks need macOS 26 or later") }
        VmnetNetworks.serve(key: args.arg(0, "key"))

    case "network":
        try networkCommand(args)

    case "delete":
        let b = try VMLibrary.find(args.arg(0, "name"))
        try b.deleteSafely()
        print("deleted \(b.name)")

    case "clone":
        let src = try VMLibrary.find(args.arg(0, "name"))
        let newName = args.arg(1, "new-name")
        let out = try VMCloner.clone(src, to: VMLibrary.bundleURL(named: newName), newName: newName)
        print("cloned \(src.name) → \(out.url.path)")

    case "import":
        let src = URL(fileURLWithPath: (args.arg(0, "path") as NSString).expandingTildeInPath).standardizedFileURL
        let b: VMBundle
        if src.pathExtension.lowercased() == "utm" {
            let r = try UTMImporter.importVM(src, name: args.options["name"])
            b = r.bundle
            print("imported \(src.lastPathComponent) as \(b.name) → \(b.url.path)")
            for note in r.notes { print("note: \(note)") }
        } else {
            var o = VMImporter.DiskOptions(name: args.options["name"] ?? src.deletingPathExtension().lastPathComponent)
            if let v = args.options["os"] { o.guestOS = need(VMConfig.GuestOS(rawValue: v.lowercased()), "bad --os, want linux or windows") }
            if let v = args.options["arch"] { o.architecture = need(VMConfig.Architecture(rawValue: v.lowercased() == "x64" ? "x86_64" : v.lowercased()), "bad --arch") }
            if let v = args.options["cpus"] { o.cpuCount = need(Int(v), "bad --cpus") }
            if let v = args.options["memory"] { o.memoryMiB = parseMiB(v) }
            b = try VMImporter.importDisk(src, o)
            let c = try b.loadConfig()
            print("imported \(src.lastPathComponent) as \(b.name) (\(c.guestOS.rawValue), \(c.effectiveArchitecture.rawValue), \(c.effectiveBackend.rawValue)) → \(b.url.path)")
        }
        // The guest account lets vitrinectl exec/push/pull and agent installs log in over SSH.
        if let user = args.options["user"] {
            var c = try b.loadConfig()
            c.account = .init(fullName: user, username: user)
            c.account?.setupFinalized = true
            try b.saveConfig(c)
            if let pw = args.password() { try GuestCredentialStore.setPassword(pw, in: b) }
        }

    case "disk":
        guard args.arg(0, "add") == "add" else { die("usage: vitrinectl disk add <name> <image> [--ro]") }
        let b = try VMLibrary.find(args.arg(1, "name"))
        let src = URL(fileURLWithPath: (args.arg(2, "image") as NSString).expandingTildeInPath).standardizedFileURL
        let name = try VMImporter.addDisk(src, to: b, readOnly: args.flags.contains("ro"))
        print("added \(name) to \(b.name)")

    case "port":
        let sub = args.arg(0, "list|add|remove")
        let b = try VMLibrary.find(args.arg(1, "name"))
        if sub == "list" {
            let c = try b.loadConfig()
            if c.network.portForwards.isEmpty { print("no port forwards") }
            for f in c.network.portForwards { print("\(f.proto.rawValue)\t\(f.hostAddress):\(f.hostPort) → guest \(f.guestPort)") }
            break
        }
        let request: VMControl.Request
        switch sub {
        case "add":
            let spec = args.arg(2, "[udp:][ADDR:]HOSTPORT:GUESTPORT")
            guard let f = VMConfig.PortForward(spec: spec) else { throw VitrineError.invalidConfig("bad port forward \(spec), want e.g. 8080:80") }
            request = .init(op: .portAdd, portForward: f)
        case "remove":
            request = .init(op: .portRemove, hostPort: need(Int(args.arg(2, "HOSTPORT")), "bad port"))
        default:
            die("usage: vitrinectl port list|add|remove <name> …")
        }
        if let owner = b.lockOwner(), owner.role != .operation {
            let response = try VMControl.send(request, to: b)
            guard response.ok else { throw VitrineError.backend(response.error ?? "could not edit port forwards") }
        } else {
            try b.withExclusiveLockIfStopped {
                var c = try b.loadConfig()
                if let f = request.portForward {
                    c.network.portForwards.removeAll { $0.hostPort == f.hostPort && $0.proto == f.proto }
                    c.network.portForwards.append(f)
                } else if let port = request.hostPort {
                    c.network.portForwards.removeAll { $0.hostPort == port }
                }
                try c.validate(bundle: b)
                try b.saveConfig(c)
            }
        }
        if let f = request.portForward {
            print("forwarding \(f.hostAddress):\(f.hostPort) → guest \(f.guestPort) (\(f.proto.rawValue)); takes effect when \(b.name) next starts")
        } else if let port = request.hostPort {
            print("removed port \(port); takes effect when \(b.name) next starts")
        }

    case "share":
        let sub = args.arg(0, "list|add|remove")
        let b = try VMLibrary.find(args.arg(1, "name"))
        var c = try b.loadConfig()
        switch sub {
        case "list":
            if c.shares.isEmpty { print("no shared folders") }
            for s in c.shares { print("\(s.name)\t\(s.hostPath)\(s.readOnly ? "\t(read-only)" : "")") }
            switch c.guestOS {
            case .macOS: print("Guest path: /Volumes/My Shared Files/<name>")
            case .linux where c.effectiveBackend == .qemu:
                for s in c.shares { print("mount -t 9p -o trans=virtio,version=9p2000.L \(s.mountTag) /mnt/\(s.mountTag)") }
            case .linux: print("Guest path: /mnt/vitrine/<name>")
            case .windows: print("Guest path: drives Z:, Y:, … labelled \"<name> (Mac)\" (needs `brew install samba`)")
            }
        case "add":
            let path = URL(fileURLWithPath: (args.arg(2, "host-path") as NSString).expandingTildeInPath).standardizedFileURL.path
            let name = args.options["as"] ?? URL(fileURLWithPath: path).lastPathComponent
            // Replacing a folder of the same name keeps its drive letter.
            let letter = c.shares.first { $0.name == name }?.driveLetter
            c.shares.removeAll { $0.name == name }
            var share = VMConfig.SharedDirectory(hostPath: path, name: name, readOnly: args.flags.contains("ro"))
            share.driveLetter = letter
            c.shares.append(share)
            if c.guestOS == .windows { c.assignDriveLetters() }
            try c.validate(bundle: b)
            try b.saveConfig(c)
            print("shared \(path) as \(name)\(liveReloadShares(b))")
        case "remove":
            let name = args.arg(2, "share-name")
            c.shares.removeAll { $0.name == name }
            try b.saveConfig(c)
            print("removed \(name)\(liveReloadShares(b))")
        default: die("unknown share subcommand \(sub)")
        }

    case "drop":
        let b = try VMLibrary.find(args.arg(0, "name"))
        let files = args.positional.dropFirst().map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        guard !files.isEmpty else { die("missing <file>") }
        for f in files where !FileManager.default.fileExists(atPath: f) { die("no such file: \(f)") }
        let r = try VMControl.send(.init(op: .dropFiles, paths: files), to: b)
        guard r.ok else { die(r.error ?? "failed") }
        print("dropped \(files.count) file(s) into \(b.name)")

    case "usb":
        let sub = args.arg(0, "devices|list|attach|detach")
        if sub == "devices" {
            let devices = HostUSB.devices()
            if devices.isEmpty { print("no USB devices plugged into this Mac") }
            for d in devices { print(String(format: "%04x:%04x", d.vendorID, d.productID) + "\tbus \(d.busNumber) addr \(d.address)\t\(d.displayName)") }
            break
        }
        let b = try VMLibrary.find(args.arg(1, "name"))
        func control(_ r: VMControl.Request) throws -> VMControl.Response {
            let resp = try VMControl.send(r, to: b)
            guard resp.ok else { die(resp.error ?? "failed") }
            return resp
        }
        func show(_ list: [AttachedUSB]?) {
            let list = list ?? []
            if list.isEmpty { print("nothing attached") }
            for a in list { print("\(a.id)\t\(a.attachment.label)") }
        }
        switch sub {
        case "list":
            show(try control(.init(op: .usbList)).usb)
        case "attach":
            let attachment: USBAttachment
            if let spec = args.options["device"] {
                let matches = HostUSB.devices().filter { $0.matches(spec) }
                guard let d = matches.first else { die("no USB device \(spec) plugged in (see `vitrinectl usb devices`)") }
                if matches.count > 1 { die("\(matches.count) devices match \(spec); use the full id, e.g. \(d.id)") }
                attachment = .host(d)
            } else {
                let path = URL(fileURLWithPath: (args.arg(2, "image") as NSString).expandingTildeInPath).standardizedFileURL.path
                guard FileManager.default.isReadableFile(atPath: path) else { die("can't read \(path)") }
                attachment = .image(path: path, readOnly: args.flags.contains("ro"))
            }
            let r = try control(.init(op: .usbAttach, attachment: attachment))
            print("attached \(r.attached?.id ?? "?")\t\(attachment.label)")
            if let warning = r.error { print("warning: \(warning)") }
        case "detach":
            _ = try control(.init(op: .usbDetach, id: args.arg(2, "id")))
            print("detached \(args.arg(2, "id"))")
        default: die("unknown usb subcommand \(sub)")
        }

    case "snapshot":
        let sub = args.arg(0, "list|create|restore|delete")
        let b = try VMLibrary.find(args.arg(1, "name"))
        let store = SnapshotStore(bundle: b)
        switch sub {
        case "list":
            let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
            let snaps = store.list()
            if snaps.isEmpty { print("no snapshots") }
            for s in snaps {
                print("\(s.id.uuidString.prefix(8))  \(fmt.string(from: s.createdAt))  \(s.name)\(s.includesMemory ? "  [memory]" : "")")
            }
        case "create":
            let s = try store.create(name: args.arg(2, "snapshot-name"))
            print("snapshot \(s.name) (\(s.id.uuidString.prefix(8))) created\(s.includesMemory ? " with memory state" : "")")
        case "restore", "delete":
            let key = args.arg(2, "snapshot")
            guard let s = store.find(key) ?? store.list().first(where: { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) })
            else { die("no snapshot \(key)") }
            if sub == "restore" { try store.restore(s.id); print("restored \(s.name)") }
            else { try store.delete(s.id); print("deleted snapshot \(s.name)") }
        default: die("unknown snapshot subcommand \(sub)")
        }

    case "ipsw":
        let sub = args.arg(0, "latest|download")
        runAsync {
            switch sub {
            case "latest":
                let info = try await RestoreImages.latestSupported()
                print("macOS \(info.osVersion) (\(info.buildVersion))\n\(info.url.absoluteString)")
            case "download":
                let url: URL
                if let u = args.options["url"] { url = need(URL(string: u), "bad --url") }
                else { url = try await RestoreImages.latestSupported().url }
                print("downloading \(url.lastPathComponent)")
                let path = try await RestoreImages.download(url) { f, got, total in
                    progressBar(f, "\(formatBytes(UInt64(got)))/\(formatBytes(UInt64(max(total, 0))))")
                }
                print("\n\(path.path)")
            default: die("unknown ipsw subcommand \(sub)")
            }
        }

    case "create":
        let name = args.arg(0, "name")
        var opts = MacInstaller.Options(name: name)
        if let v = args.options["cpus"] { opts.cpuCount = need(Int(v), "bad --cpus") }
        if let v = args.options["memory"] { opts.memoryMiB = parseMiB(v) }
        if let v = args.options["disk"] { opts.diskBytes = need(UInt64(sizeString: v), "bad --disk") }
        if let user = args.options["user"] {
            guard let pw = args.password() else { die("--user needs --password or --password-stdin") }
            guard #available(macOS 27, *) else { die("automatic account setup needs a macOS 27 host") }
            opts.account = (args.options["full-name"] ?? user, user, pw)
        }
        if let screen = NSScreen.main {
            let px = CoherenceDisplay.pixels(for: screen)
            opts.display = VMConfig.DisplayConfig(widthPixels: px.width, heightPixels: px.height, pixelsPerInch: px.ppi)
        }
        runAsync {
            let source = args.options["ipsw"] ?? "latest"
            let ipswPath: URL
            if source == "latest" {
                let info = try await RestoreImages.latestSupported()
                print("latest: macOS \(info.osVersion) (\(info.buildVersion))")
                ipswPath = try await RestoreImages.download(info.url) { f, got, total in
                    progressBar(f, "download \(formatBytes(UInt64(got)))/\(formatBytes(UInt64(max(total, 0))))")
                }
                FileHandle.standardError.write(Data("\n".utf8))
            } else {
                ipswPath = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
            }
            let image = try await RestoreImages.load(ipswPath)
            let installer = MacInstaller()
            let bundle = try installer.createBundle(options: opts, restoreImage: image)
            print("created \(bundle.url.path)")
            do {
                try await installer.install(bundle: bundle, ipsw: ipswPath) { phase in
                    if case .installing(let f) = phase { progressBar(f, "install") }
                }
            } catch {
                try? FileManager.default.removeItem(at: bundle.url)
                throw error
            }
            print("\ninstalled macOS into \(bundle.name). Start it with: vitrinectl run \(bundle.name) --gui")
        }

    case "create-linux" where args.options["distro"] != nil:
        let id = args.options["distro"]!
        guard let distro = CloudImageInstaller.all.first(where: { $0.id == id }) else {
            die("unknown distro \(id); available: \(CloudImageInstaller.all.map(\.id).joined(separator: ", "))")
        }
        guard let user = args.options["user"], let pw = args.password() else { die("--distro needs --user and --password (or --password-stdin)") }
        var o = CloudImageInstaller.Options(name: args.arg(0, "name"), fullName: args.options["full-name"] ?? user,
                                            username: user, password: pw)
        o.distro = distro
        if let v = args.options["cpus"] { o.cpuCount = need(Int(v), "bad --cpus") }
        if let v = args.options["memory"] { o.memoryMiB = parseMiB(v) }
        if let v = args.options["disk"] { o.diskBytes = need(UInt64(sizeString: v), "bad --disk") }
        if args.options["desktop"] == "no" { o.desktop = false }
        let options = o
        runAsync {
            let b = try await CloudImageInstaller.create(options) { phase in
                switch phase {
                case .downloading(let f): progressBar(f, "download")
                case .extracting: FileHandle.standardError.write(Data("\nextracting disk image…\n".utf8))
                case .configuring: FileHandle.standardError.write(Data("building cloud-init seed…\n".utf8))
                }
            }
            print("created \(b.url.path)\nFirst boot installs the desktop (several minutes). Start: vitrinectl run \(b.name) --gui")
        }

    case "create-linux":
        var o = LinuxCreator.Options(name: args.arg(0, "name"))
        if let v = args.options["cpus"] { o.cpuCount = need(Int(v), "bad --cpus") }
        if let v = args.options["memory"] { o.memoryMiB = parseMiB(v) }
        if let v = args.options["disk"] { o.diskBytes = need(UInt64(sizeString: v), "bad --disk") }
        func path(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL }
        if let iso = args.options["iso"] { o.installISO = path(iso) }
        if let k = args.options["kernel"] {
            o.kernel = (path(k), args.options["initrd"].map(path), args.options["cmdline"] ?? "console=hvc0")
        }
        o.rosetta = args.flags.contains("rosetta")
        if args.options["backend"] == "qemu" || args.options["arch"] == "x86_64" {
            o.backend = .qemu
            o.architecture = args.options["arch"] == "x86_64" ? .x86_64 : .aarch64
        }
        if o.installISO == nil && o.kernel == nil { die("create-linux needs --iso or --kernel") }
        let b = try LinuxCreator.create(o)
        print("created \(b.url.path)\nStart it with: vitrinectl run \(b.name) --gui   (or --console for a headless serial console)")

    case "create-windows":
        guard let iso = args.options["iso"] else { die("create-windows needs --iso PATH (\(WindowsCreator.downloadPageArm))") }
        var o = WindowsCreator.Options(name: args.arg(0, "name"),
                                       installISO: URL(fileURLWithPath: (iso as NSString).expandingTildeInPath))
        if args.options["arch"] == "x86_64" || args.options["arch"] == "x64" { o.architecture = .x86_64 }
        if let v = args.options["cpus"] { o.cpuCount = need(Int(v), "bad --cpus") }
        if let v = args.options["memory"] { o.memoryMiB = parseMiB(v) }
        if let v = args.options["disk"] { o.diskBytes = need(UInt64(sizeString: v), "bad --disk") }
        if let user = args.options["user"] {
            guard let pw = args.password() else { die("--user needs --password or --password-stdin") }
            o.account = (args.options["full-name"] ?? user, user, pw)
        }
        o.agentExecutable = AgentInstaller.windowsAgentExecutable(arch: o.architecture)
        let options = o
        runAsync {
            let opts = try await WindowsCreator.prepare(options: options) { phase in
                switch phase {
                case .fetchingVirtioWin: FileHandle.standardError.write(Data("fetching virtio-win drivers…\n".utf8))
                case .virtioWin(let f): progressBar(f, "virtio-win")
                case .fetchingOpenSSH: FileHandle.standardError.write(Data("\nfetching OpenSSH…\n".utf8))
                case .openSSH(let f): progressBar(f, "OpenSSH")
                case .openSSHUnavailable(let why):
                    FileHandle.standardError.write(Data("\nOpenSSH download failed (\(why)); Setup will use Windows Update\n".utf8))
                }
            }
            if opts.account != nil { FileHandle.standardError.write(Data("\n".utf8)) }
            let b = try WindowsCreator.create(opts)
            print("created \(b.url.path) (\(opts.architecture == .aarch64 ? "Arm64, HVF" : "x64, emulated"))")
            print(opts.account != nil ? "Unattended setup: Windows installs and signs in by itself. Start it in Vitrine.app."
                                      : "Start it in Vitrine.app (the installer needs a display).")
        }

    case "console":
        let b = try VMLibrary.find(args.arg(0, "name"))
        if args.options["send"] == nil && args.options["expect"] == nil {
            try SerialConsole.attach(b)
        }
        let timeout = args.options["timeout"].flatMap(Double.init) ?? 10
        exit(try SerialConsole.exchange(b, send: args.options["send"], expect: args.options["expect"], timeout: timeout))

    case "keys":
        let b = try VMLibrary.find(args.arg(0, "name"))
        if let text = args.options["text"] {
            let raw = args.options["via"] ?? "auto"
            guard let method = VMAutomation.TypingMethod(rawValue: raw) else { die("--via is auto, keyboard or agent") }
            let typed = text.replacingOccurrences(of: "\\n", with: "\n")
            let used = try VMAutomation.type(b, typed, method: method)
            print("typed \(typed.count) character(s) into \(b.name) \(used)")
        } else if let name = args.options["combo"] {
            try VMAutomation.keys(b, [try KeyNames.chord(named: name)])
            print("sent 1 key chord to \(b.name)")
        } else {
            die("keys needs --text \"…\" or --combo NAME")
        }

    case "click":
        let b = try VMLibrary.find(args.arg(0, "name"))
        guard let x = Int(args.arg(1, "x")), let y = Int(args.arg(2, "y")) else { die("usage: vitrinectl click <name> X Y") }
        let button = args.options["button"] ?? "left"
        try VMAutomation.pointer(b, x: x, y: y, button: button == "none" ? nil : button,
                                 clicks: args.options["clicks"].flatMap(Int.init) ?? 1)
        print(button == "none" ? "moved to (\(x), \(y))" : "clicked \(button) at (\(x), \(y))")

    case "screenshot":
        let b = try VMLibrary.find(args.arg(0, "name"))
        let out = URL(fileURLWithPath: (args.arg(1, "out.png") as NSString).expandingTildeInPath).standardizedFileURL
        let size = try VMAutomation.screenshot(b, to: out)
        print("\(out.path) (\(size.width)×\(size.height))")

    case "stop", "suspend":
        let b = try VMLibrary.find(args.arg(0, "name"))
        print(try stopVM(b, suspend: command == "suspend", force: args.flags.contains("force")))

    case "display":
        // QEMU guests with a resizable display (virtio-gpu + driver): `vitrinectl display win 2560x1440`.
        let b = try VMLibrary.find(args.arg(0, "name"))
        let wh = args.arg(1, "WIDTHxHEIGHT").split(separator: "x").compactMap { Int($0) }
        guard wh.count == 2 else { die("usage: vitrinectl display <name> 2560x1440") }
        runAsync {
            let (w, h) = try await QEMUMachine.setDisplaySize(bundle: b, width: wh[0], height: wh[1])
            print("\(b.name) display is now \(w)x\(h)")
        }

    case "discard-state":
        // Drops a suspended VM's saved memory so the next start boots from disk.
        let b = try VMLibrary.find(args.arg(0, "name"))
        try b.withExclusiveLock { b.discardSavedState() }
        print("discarded the saved state of \(b.name)")

    case "push":
        let b = try VMLibrary.find(args.arg(0, "name"))
        let local = URL(fileURLWithPath: (args.arg(1, "local-path") as NSString).expandingTildeInPath).standardizedFileURL
        let remote = args.arg(2, "guest-path")
        guard FileManager.default.fileExists(atPath: local.path) else { die("\(local.path) not found") }
        runAsync { try await AgentInstaller.push(in: b, local: local, remote: remote); print("copied \(local.lastPathComponent) to \(b.name):\(remote)") }

    case "pull":
        let b = try VMLibrary.find(args.arg(0, "name"))
        let remote = args.arg(1, "guest-path")
        let local = URL(fileURLWithPath: (args.arg(2, "local-path") as NSString).expandingTildeInPath).standardizedFileURL
        runAsync { try await AgentInstaller.pull(in: b, remote: remote, local: local); print("copied \(b.name):\(remote) to \(local.path)") }

    case "exec":
        let b = try VMLibrary.find(args.arg(0, "name"))
        let cmd = args.positional.dropFirst().joined(separator: " ")
        guard !cmd.isEmpty else { die("usage: vitrinectl exec <name> <command…>") }
        runAsync { print(try await AgentInstaller.run(in: b, command: cmd), terminator: "") }

    case "agent":
        let sub = args.arg(0, "install")
        let b = try VMLibrary.find(args.arg(1, "name"))
        switch sub {
        case "install": runAsync { print(try await AgentInstaller.install(into: b), terminator: "") }
        case "finalize": runAsync { try await AgentInstaller.finalizeSetup(in: b); print("setup marked complete") }
        case "camera":
            runAsync { print("virtual camera ready: \(try await AgentInstaller.installCameraSupport(in: b))") }
        case "bluetooth":
            runAsync { print("Bluetooth bridge ready: \(try await AgentInstaller.installBluetoothSupport(in: b))") }
        case "permissions":
            let r = try VMControl.send(.init(op: .requestPermissions), to: b, timeout: 10)
            guard r.ok else { die(r.error ?? "failed") }
            print(r.error ?? "asked in \(b.name): allow Vitrine Agent in both prompts there (Screen Recording, Accessibility); the agent then restarts by itself to use them")
        case "probe":
            let png = args.positional.count > 2 ? URL(fileURLWithPath: (args.positional[2] as NSString).expandingTildeInPath) : nil
            runAsync { try await AgentProbe.run(bundle: b, framePNG: png, editorTitle: args.options["editor"]) }
        default: die("unknown agent subcommand \(sub)")
        }

    case "run":
        let b = try VMLibrary.find(args.arg(0, "name"))
        VMRunner.run(bundle: b, gui: args.flags.contains("gui"), recovery: args.flags.contains("recovery"),
                     console: args.flags.contains("console"))

    default:
        die("unknown command \(command)\n\n\(usage)")
    }
} catch {
    die(error.localizedDescription)
}
