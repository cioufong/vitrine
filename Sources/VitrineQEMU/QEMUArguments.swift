import Foundation
import VitrineCore

/// Runtime socket paths for one QEMU instance.
public struct QEMUSockets: Sendable, Equatable {
    public var qmp: URL
    /// Second QMP monitor for external tools (QEMU allows one client per monitor socket).
    public var qmpTools: URL
    public var vnc: URL
    public var agent: URL
    public var tpm: URL
    /// Text file holding the forwarded SSH port while the VM runs.
    public var sshPortFile: URL
    /// Loopback port forwarded to the Windows agent, for other processes (vitrinectl agent probe).
    public var agentPortFile: URL
    /// The guest's first serial port (`vitrinectl console`); also logged to the bundle's console.log.
    public var serial: URL

    public init(directory: URL) {
        qmp = directory.appendingPathComponent("qmp.sock")
        qmpTools = directory.appendingPathComponent("qmp-tools.sock")
        vnc = directory.appendingPathComponent("vnc.sock")
        agent = directory.appendingPathComponent("agent.sock")
        tpm = directory.appendingPathComponent("tpm.sock")
        sshPortFile = directory.appendingPathComponent("ssh.port")
        agentPortFile = directory.appendingPathComponent("agent.port")
        serial = directory.appendingPathComponent("serial.sock")
    }
}

/// Builds the qemu-system command line for a VMConfig. Pure function — unit tested.
public enum QEMUArguments {
    public static let agentPortName = "org.vitrine.agent.0"
    /// Port the Windows agent listens on inside the guest.
    public static let agentGuestTCPPort: UInt16 = 0x5153

    public struct Options: Sendable {
        public var withTPM: Bool
        /// Resume from a saved state file (`-incoming`).
        public var incomingState: URL?
        /// Host loopback port forwarded to the guest agent's TCP port 5153: the fallback for Windows
        /// agents in guests without the vioser driver (agents prefer the virtio-serial port).
        public var agentTCPPort: UInt16?
        /// Host loopback port forwarded to the guest's SSH server (QEMU guests have no host-visible IP).
        public var sshPort: UInt16?
        /// Command serving SMB to the guest at \\10.0.2.4 (Windows shared folders, see SambaServer).
        public var smbCommand: String?
        /// Secret the TCP agent requires in the host's Hello, handed to the guest as an SMBIOS OEM string.
        public var agentToken: String?
        /// A `-netdev` backend replacing user-mode networking (vmnet and bridged networks), without
        /// `id`. Forwards, the SSH and agent ports and Samba ride on user networking and are left out.
        public var netdev: String?
        public init(withTPM: Bool, incomingState: URL? = nil, agentTCPPort: UInt16? = nil, sshPort: UInt16? = nil,
                    smbCommand: String? = nil) {
            self.withTPM = withTPM; self.incomingState = incomingState; self.agentTCPPort = agentTCPPort; self.sshPort = sshPort
            self.smbCommand = smbCommand
        }
    }

    public enum AudioModel { case intelHDA, virtioSound, usbAudio }
    public static let usbAudioDevice = "usb-audio,id=audio0,bus=xhci.0,audiodev=snd0"

    public static func audioModel(_ config: VMConfig) -> AudioModel {
        // virtio-sound isn't migratable in QEMU 11 either and PCI devices on the virt root bus can't be
        // hot-unplugged, so aarch64 guests get USB audio (hot-unpluggable around suspend).
        return config.effectiveArchitecture == .x86_64 ? .intelHDA : .usbAudio
    }

    public static func build(config: VMConfig, bundle: VMBundle, env: QEMUEnvironment, sockets: QEMUSockets,
                             options: Options) -> [String] {
        let arch = config.effectiveArchitecture
        let windows = config.guestOS == .windows
        // `-name` is a QemuOpts list: name the key and double commas so "Work, 2" stays one value.
        var a: [String] = ["-name", "guest=\(qemuEscape(config.name))", "-nodefaults", "-no-user-config"]
        if let token = options.agentToken {
            // OEM strings (SMBIOS type 11) are readable inside the guest without a driver.
            a += ["-smbios", "type=11,value=vitrine.token=\(token)"]
        }

        // Machine & acceleration: HVF for native aarch64; multithreaded TCG to emulate x86_64.
        switch arch {
        case .aarch64:
            a += ["-machine", "virt,highmem=on,gic-version=max", "-accel", "hvf", "-cpu", "host"]
        case .x86_64:
            // x86-64-v2 without AVX: Windows 11 under TCG crashed with AVX exposed (`max`: bugcheck 0x3B
            // in OOBE; Skylake: AppXSvc fail-fast inside ucrtbase's vectorised routines, so OOBE never
            // finished). TCG's SSE emulation is the mature path; Westmere adds AES-NI/PCLMUL.
            // Hyper-V enlightenments for Windows: no busy-waiting spinlocks or APIC EOI traps, and a
            // paravirtual clock instead of emulated timer reads. Measured on Windows 11 under TCG:
            // 7-Zip +10% (1 thread) / +18% (4 threads), and far less host CPU while the guest idles.
            let hv = windows ? ",hv-relaxed,hv-vapic,hv-spinlocks=0x1fff,hv-vpindex,hv-time" : ""
            a += ["-machine", "q35,smm=on", "-accel", "tcg,thread=multi,tb-size=1024", "-cpu", "Westmere-v2\(hv)"]
            a += ["-global", "driver=cfi.pflash01,property=secure,value=on"]
            // No guest S3/S4: an idle Windows (even mid-OOBE) would put the VM to sleep and look hung.
            // Suspending a VM is the host's job (saved state).
            a += ["-global", "ICH9-LPC.disable_s3=1", "-global", "ICH9-LPC.disable_s4=1"]
        }
        a += ["-smp", "\(config.cpuCount)", "-m", "\(config.memoryMiB)M"]

        // UEFI: read-only code + per-VM writable variable store.
        a += ["-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(qemuEscape(env.firmwareCode(arch).path))"]
        a += ["-drive", "if=pflash,format=raw,unit=1,file=\(qemuEscape(bundle.efiVarsURL.path))"]

        // Disks on NVMe: Windows (both architectures) and Linux have inbox NVMe drivers.
        for (i, d) in config.disks.enumerated() {
            let file = bundle.resolve(d.path).path
            let ro = d.readOnly ? ",readonly=on" : ""
            a += ["-drive", "id=disk\(i),if=none,format=raw,cache=writeback,discard=unmap,file=\(qemuEscape(file))\(ro)"]
            a += ["-device", "nvme,serial=vitrine\(i),drive=disk\(i)\(i == 0 ? ",bootindex=1" : "")"]
        }
        // Direct kernel boot: QEMU hands the kernel to the UEFI firmware through fw_cfg.
        if case .kernel(let kernel, let initrd, let commandLine)? = config.boot {
            a += ["-kernel", bundle.resolve(kernel).path, "-append", commandLine]
            if let initrd { a += ["-initrd", bundle.resolve(initrd).path] }
        }
        // Installer ISO: virtio-scsi on aarch64 Windows (USB mass storage reads at ~3 MB/s, which made
        // an install take over an hour; AArch64 EDK2 boots virtio-scsi but has no AHCI driver, and
        // WinPE gets vioscsi from the seed disc, which stays on USB), USB for other aarch64 guests,
        // AHCI CD-ROM on x86.
        // Plenty of ports so QEMU never auto-inserts a USB hub (that would break suspend/resume when
        // the audio device is hot-unplugged around migration).
        a += ["-device", "qemu-xhci,id=xhci,p2=15,p3=15"]
        if let media = config.installMedia {
            let iso = bundle.resolve(media).path
            a += ["-drive", "id=cd0,if=none,media=cdrom,readonly=on,file=\(qemuEscape(iso))"]
            if arch == .aarch64 && windows {
                a += ["-device", "virtio-scsi-pci,id=scsi0", "-device", "scsi-cd,bus=scsi0.0,drive=cd0,bootindex=0"]
            } else if arch == .aarch64 {
                a += ["-device", "usb-storage,bus=xhci.0,drive=cd0,removable=on,bootindex=0"]
            } else {
                a += ["-device", "ide-cd,drive=cd0,bus=ide.0,bootindex=0"] // q35 AHCI: one device per bus
            }
        }

        for (i, media) in (config.extraMedia ?? []).enumerated() {
            let iso = bundle.resolve(media).path
            a += ["-drive", "id=cdx\(i),if=none,media=cdrom,readonly=on,file=\(qemuEscape(iso))"]
            a += arch == .aarch64 ? ["-device", "usb-storage,bus=xhci.0,drive=cdx\(i),removable=on"]
                                  : ["-device", "ide-cd,drive=cdx\(i),bus=ide.\(i + 1)"]
        }

        // Shared folders for Linux (and other non-Windows) guests: one virtio-9p export per folder,
        // mounted in the guest by its tag. Windows gets them over SMB instead (SambaServer).
        // `security_model=none` keeps files on the Mac ordinary files owned by the Mac user.
        // While a 9p export is mounted QEMU refuses to migrate, so such a VM shuts down rather than
        // suspends (QEMUMachine reports the migration blocker).
        if !windows {
            for (i, share) in config.shares.enumerated() {
                let ro = share.readOnly ? ",readonly=on" : ""
                a += ["-fsdev", "local,id=fs\(i),path=\(bundle.resolve(share.hostPath).path),security_model=none\(ro)",
                      "-device", "virtio-9p-pci,fsdev=fs\(i),mount_tag=\(share.mountTag)"]
            }
        }

        // Input: absolute tablet so the host pointer maps 1:1.
        a += ["-device", "usb-kbd,bus=xhci.0", "-device", "usb-tablet,bus=xhci.0"]

        // Display. Windows on Arm boots and installs on ramfb (a linear framebuffer its basic display
        // driver can use); once the viogpudo driver from the seed disc loads, the desktop moves to
        // virtio-gpu, which supports real resolutions and resizing. Each output gets its own VNC
        // server and the host shows whichever is live.
        switch (arch, windows) {
        case (.aarch64, true):
            let gpu = "virtio-gpu-pci,id=gpu0,xres=\(config.display.widthPixels),yres=\(config.display.heightPixels)"
            if config.hasInstallMedia {
                // Installing: ramfb only. viogpudo is staged in the driver store by the first-logon
                // script; once setup finishes (media ejected) the guest boots with virtio-gpu alone
                // and Windows binds the staged driver. Having both outputs during setup made Windows
                // switch to virtio-gpu mid-install (DriverPaths) and treat them as two monitors.
                a += ["-device", "ramfb", "-display", "none", "-vnc", "unix:\(sockets.vnc.path)"]
            } else {
                a += ["-device", gpu, "-display", "none", "-vnc", "unix:\(sockets.vnc.path)"]
            }
        case (.aarch64, false):
            a += ["-device", "virtio-gpu-pci", "-display", "none", "-vnc", "unix:\(sockets.vnc.path)"]
        case (.x86_64, _):
            // Windows Setup needs a linear framebuffer, which OVMF only provides on standard VGA (on
            // virtio-vga it drives the virtio-gpu side and Setup runs on a black screen). After setup
            // the guest moves to virtio-vga, where the viogpudo driver gives it real resolutions.
            let display = windows && config.hasInstallMedia ? "VGA,vgamem_mb=64" : "virtio-vga"
            a += ["-device", display, "-display", "none", "-vnc", "unix:\(sockets.vnc.path)"]
        }

        // Network: user-mode NAT. Windows x86 has an inbox e1000e driver; Windows on Arm gets virtio-net
        // with the NetKVM driver from the unattended-setup seed disc. Host-only is the same network
        // with `restrict=on`: no route out, while forwarded ports and the Samba share keep working.
        let nic = (windows && arch == .x86_64) ? "e1000e" : "virtio-net-pci"
        if config.network.isConnected, let netdev = options.netdev {
            a += ["-netdev", "\(netdev),id=net0", "-device", "\(nic),netdev=net0,mac=\(config.network.macAddress)"]
        } else if config.network.isConnected {
            var fwd = config.network.mode == .hostOnly ? ",restrict=on" : ""
            fwd += options.agentTCPPort.map { ",hostfwd=tcp:127.0.0.1:\($0)-:\(agentGuestTCPPort)" } ?? ""
            for f in config.network.portForwards {
                fwd += ",hostfwd=\(f.proto.rawValue):\(f.hostAddress):\(f.hostPort)-:\(f.guestPort)"
            }
            fwd += options.sshPort.map { ",hostfwd=tcp:127.0.0.1:\($0)-:22" } ?? ""
            // QEMU option values escape commas by doubling them.
            fwd += options.smbCommand.map {
                ",guestfwd=tcp:\(SambaServer.guestAddress):445-cmd:\($0.replacingOccurrences(of: ",", with: ",,"))"
            } ?? ""
            a += ["-netdev", "user,id=net0\(fwd)"]
            if nic == "usb-net" {
                a += ["-device", "usb-net,bus=xhci.0,netdev=net0,mac=\(config.network.macAddress)"]
            } else {
                a += ["-device", "\(nic),netdev=net0,mac=\(config.network.macAddress)"]
            }
        }

        // Sound. intel-hda and virtio-sound are migratable; usb-audio (the only Windows-on-Arm option)
        // isn't, so it is hot-unplugged before suspend and re-plugged after resume (see QEMUMachine).
        if config.features.sound {
            // Without the microphone feature the backend opens no input stream at all, so macOS never
            // asks for (or uses) microphone access.
            let mic = config.features.microphone
            a += ["-audiodev", "coreaudio,id=snd0" + (mic ? "" : ",in.voices=0")]
            switch audioModel(config) {
            case .intelHDA: a += ["-device", "intel-hda", "-device", "\(mic ? "hda-duplex" : "hda-output"),audiodev=snd0"]
            case .virtioSound: a += ["-device", "virtio-sound-pci,id=audio0,audiodev=snd0"]
            case .usbAudio:
                if options.incomingState == nil { a += ["-device", usbAudioDevice] }
            }
        }

        // Guest agent channel (virtio-serial port, same wire protocol as vsock on VZ) + entropy.
        a += ["-device", "virtio-serial-pci",
              "-chardev", "socket,id=agent,path=\(sockets.agent.path),server=on,wait=off",
              "-device", "virtserialport,chardev=agent,name=\(agentPortName)"]
        a += ["-device", "virtio-rng-pci"]

        // TPM 2.0 (Windows 11 requirement) via swtpm.
        if options.withTPM {
            a += ["-chardev", "socket,id=chrtpm,path=\(sockets.tpm.path)",
                  "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                  // ppi=off on Arm: the PPI RAM region is smaller than a 16K host page, which HVF refuses to map.
                  "-device", arch == .aarch64 ? "tpm-tis-device,tpmdev=tpm0,ppi=off" : "tpm-tis,tpmdev=tpm0"]
        }

        // Serial console: the first UART (PL011 on aarch64 virt, COM1 on q35), on a socket for
        // `vitrinectl console` and copied to console.log.
        a += ["-chardev", "socket,id=ser0,path=\(sockets.serial.path),server=on,wait=off,logfile=\(qemuEscape(bundle.consoleLogURL.path)),logappend=on",
              "-serial", "chardev:ser0"]
        // GDB remote stub for kernel debugging, on loopback only.
        if let port = config.features.gdbPort { a += ["-gdb", "tcp:127.0.0.1:\(port)"] }

        // Control plane.
        a += ["-qmp", "unix:\(sockets.qmp.path),server=on,wait=off"]
        a += ["-qmp", "unix:\(sockets.qmpTools.path),server=on,wait=off"]
        // Windows keeps the RTC in local time, everything else in UTC.
        a += ["-rtc", windows ? "base=localtime" : "base=utc"]
        if let state = options.incomingState {
            a += ["-incoming", "file:\(state.path)"]
        }
        return a
    }
}

/// Escapes a value for QEMU's comma-separated option syntax (a literal comma is written twice).
func qemuEscape(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }
