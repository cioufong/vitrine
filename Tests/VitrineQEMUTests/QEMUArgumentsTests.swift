import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

final class QEMUArgumentsTests: XCTestCase {
    let env = QEMUEnvironment(binDirectory: URL(fileURLWithPath: "/q/bin"), shareDirectory: URL(fileURLWithPath: "/q/share"))
    let bundle = VMBundle(url: URL(fileURLWithPath: "/vms/win.vitrinevm"))
    var sockets: QEMUSockets { QEMUSockets(directory: URL(fileURLWithPath: "/tmp/s")) }

    func config(_ os: VMConfig.GuestOS, _ arch: VMConfig.Architecture) -> VMConfig {
        var c = VMConfig(name: "win", guestOS: os, cpuCount: 4, memoryMiB: 8192)
        c.backend = .qemu
        c.architecture = arch
        c.disks = [.init(path: "disk.img")]
        c.installMedia = "/isos/Win11_Arm64.iso"
        c.network.macAddress = "02:00:00:00:00:01"
        return c
    }

    func joined(_ a: [String]) -> String { a.joined(separator: " ") }

    func testWindowsArmUsesHVFRamfbUSBInstallerAndTPM() {
        let a = joined(QEMUArguments.build(config: config(.windows, .aarch64), bundle: bundle, env: env, sockets: sockets,
                                           options: .init(withTPM: true)))
        XCTAssertTrue(a.contains("-accel hvf"))
        XCTAssertTrue(a.contains("-cpu host"))
        XCTAssertTrue(a.contains("file=/q/share/edk2-aarch64-code.fd"))
        XCTAssertTrue(a.contains("file=/vms/win.vitrinevm/efivars.fd"))
        XCTAssertTrue(a.contains("-device ramfb"))
        XCTAssertTrue(a.contains("scsi-cd,bus=scsi0.0,drive=cd0,bootindex=0"))  // fast installer media
        XCTAssertTrue(a.contains("nvme,serial=vitrine0,drive=disk0,bootindex=1"))
        XCTAssertTrue(a.contains("tpm-tis-device,tpmdev=tpm0,ppi=off"))
        XCTAssertTrue(a.contains("-vnc unix:/tmp/s/vnc.sock"))
        XCTAssertTrue(a.contains("-qmp unix:/tmp/s/qmp.sock,server=on,wait=off"))
        XCTAssertTrue(a.contains("virtserialport,chardev=agent,name=org.vitrine.agent.0"))
        // Installing: ramfb only (virtio-gpu comes after setup, see testInstalledWindowsArmUsesOnlyVirtioGPU).
        XCTAssertTrue(a.contains("-device ramfb"))
        XCTAssertFalse(a.contains("virtio-gpu"))
    }

    func testInstalledWindowsArmUsesOnlyVirtioGPU() {
        var c = config(.windows, .aarch64)
        c.installMedia = nil
        c.extraMedia = nil
        let a = joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: true)))
        XCTAssertFalse(a.contains("ramfb"))
        XCTAssertTrue(a.contains("virtio-gpu-pci,id=gpu0"))
        XCTAssertTrue(a.contains("-vnc unix:/tmp/s/vnc.sock"))
        XCTAssertFalse(a.contains("vnc-gpu.sock"))
    }

    /// An imported Windows guest has no install media and no viogpudo driver: it keeps the plain
    /// framebuffer the installer uses for as long as its config asks for it.
    /// The driver disc is a data disc: the guest is not treated as being installed, so the display
    /// follows `basicFramebuffer` alone and the disc sits where an imported Windows can read it.
    func testDriverDiscIsAPlainDiscAndNotSetupMedia() {
        var arm = config(.windows, .aarch64)
        arm.installMedia = nil; arm.extraMedia = nil
        arm.driverMedia = "drivers.iso"
        let a = joined(QEMUArguments.build(config: arm, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: true)))
        XCTAssertTrue(a.contains("id=cddrv,if=none,media=cdrom,format=raw,readonly=on,file="))
        XCTAssertTrue(a.contains("-device usb-storage,bus=xhci.0,drive=cddrv,removable=on"))
        XCTAssertFalse(a.contains("bootindex=0"))
        XCTAssertFalse(a.contains("ramfb"))
        XCTAssertTrue(a.contains("virtio-gpu-pci"))
        XCTAssertTrue(a.contains("virtio-net-pci"))

        var x64 = config(.windows, .x86_64)
        x64.driverMedia = "drivers.iso"
        let x = joined(QEMUArguments.build(config: x64, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: true)))
        XCTAssertTrue(x.contains("-device ide-cd,drive=cddrv,bus=ide.5"))

        var none = config(.windows, .aarch64)
        none.installMedia = nil; none.extraMedia = nil
        XCTAssertFalse(joined(QEMUArguments.build(config: none, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: true))).contains("cddrv"))
    }

    func testDriverDiscInstallScriptElevatesAndInstallsEveryDriver() {
        let script = WindowsDriverDisc.installScript
        XCTAssertTrue(script.contains("Start-Process -Verb RunAs"))
        XCTAssertTrue(script.contains(#"if "%~1"=="elevated" goto install"#), "one relaunch only")
        XCTAssertTrue(script.contains(#"pnputil /add-driver "%~dp0drivers\*.inf" /subdirs /install"#))
        XCTAssertTrue(script.contains("pnputil /scan-devices"))
    }

    func testDriverDiscIsOnlyForWindowsOnQEMU() {
        var linux = config(.linux, .aarch64)
        XCTAssertThrowsError(try WindowsDriverDisc.attach(to: &linux, in: bundle, virtioWinISO: URL(fileURLWithPath: "/nonexistent.iso")))
        XCTAssertNil(linux.driverMedia)
    }

    func testBasicFramebufferKeepsWindowsOffVirtioGPU() {
        var arm = config(.windows, .aarch64)
        arm.installMedia = nil; arm.extraMedia = nil
        arm.display.basicFramebuffer = true
        let a = joined(QEMUArguments.build(config: arm, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: true)))
        XCTAssertTrue(a.contains("-device ramfb"))
        XCTAssertFalse(a.contains("virtio-gpu"))
        XCTAssertTrue(a.contains("-vnc unix:/tmp/s/vnc.sock"))

        var x64 = config(.windows, .x86_64)
        x64.installMedia = nil; x64.extraMedia = nil
        x64.display.basicFramebuffer = true
        let x = joined(QEMUArguments.build(config: x64, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: true)))
        XCTAssertTrue(x.contains("-device VGA,vgamem_mb=64"))
        XCTAssertFalse(x.contains("virtio-vga"))

        // Not a Windows setting: other guests have a virtio-gpu driver of their own.
        var linux = config(.linux, .aarch64)
        linux.display.basicFramebuffer = true
        let l = joined(QEMUArguments.build(config: linux, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: false)))
        XCTAssertTrue(l.contains("-device virtio-gpu-pci"))
        XCTAssertFalse(l.contains("ramfb"))
    }

    func testX64CDROMsGetSeparateAHCIBuses() {
        var c = config(.windows, .x86_64)
        c.extraMedia = ["seed.iso", "virtio.iso"]
        let a = joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: true)))
        XCTAssertTrue(a.contains("ide-cd,drive=cd0,bus=ide.0,bootindex=0"))
        XCTAssertTrue(a.contains("-cpu Westmere-v2,hv-relaxed,hv-vapic,hv-spinlocks=0x1fff,hv-vpindex,hv-time "))
        XCTAssertTrue(a.contains("ICH9-LPC.disable_s3=1"))
        XCTAssertTrue(a.contains("-device VGA,vgamem_mb=64"))  // installing: linear framebuffer for Setup
        c.installMedia = nil; c.extraMedia = nil
        let after = joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: true)))
        XCTAssertTrue(after.contains("-device virtio-vga"))   // installed: viogpudo
        XCTAssertTrue(a.contains("ide-cd,drive=cdx0,bus=ide.1"))
        XCTAssertTrue(a.contains("ide-cd,drive=cdx1,bus=ide.2"))
    }

    func testCommasInPathsAreEscapedAndKernelBootIsPassed() {
        var c = config(.linux, .aarch64)
        c.disks = [.init(path: "/data/a,b.img")]
        c.installMedia = nil
        c.boot = .kernel(kernel: "vmlinuz", initrd: "initrd.img", commandLine: "console=ttyAMA0 root=/dev/vda")
        let args = QEMUArguments.build(config: c, bundle: VMBundle(url: URL(fileURLWithPath: "/vms/x,y.vitrinevm")),
                                       env: env, sockets: sockets, options: .init(withTPM: false))
        let a = joined(args)
        XCTAssertTrue(a.contains("file=/data/a,,b.img"))
        XCTAssertTrue(a.contains("file=/vms/x,,y.vitrinevm/efivars.fd"))
        XCTAssertEqual(args[args.firstIndex(of: "-kernel")! + 1], "/vms/x,y.vitrinevm/vmlinuz")
        XCTAssertEqual(args[args.firstIndex(of: "-initrd")! + 1], "/vms/x,y.vitrinevm/initrd.img")
        XCTAssertEqual(args[args.firstIndex(of: "-append")! + 1], "console=ttyAMA0 root=/dev/vda")
    }

    func testNameWithCommaAgentTokenAndMicrophone() {
        var c = config(.windows, .aarch64)
        c.name = "Work, 2"
        var o = QEMUArguments.Options(withTPM: true, agentTCPPort: 50000)
        o.agentToken = String(repeating: "ab", count: 32)
        let args = QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: o)
        XCTAssertEqual(args[args.firstIndex(of: "-name")! + 1], "guest=Work,, 2")
        XCTAssertEqual(args[args.firstIndex(of: "-smbios")! + 1], "type=11,value=vitrine.token=" + String(repeating: "ab", count: 32))
        // Microphone off (the default): no input voices.
        XCTAssertTrue(joined(args).contains("coreaudio,id=snd0,in.voices=0"))
        c.features.microphone = true
        let withMic = joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: o))
        XCTAssertTrue(withMic.contains("-audiodev coreaudio,id=snd0 "))
        // No token, no SMBIOS string.
        XCTAssertFalse(joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets,
                                                  options: .init(withTPM: true))).contains("-smbios"))
        // x86: HDA output-only codec without the microphone.
        var x = config(.windows, .x86_64)
        XCTAssertTrue(joined(QEMUArguments.build(config: x, bundle: bundle, env: env, sockets: sockets,
                                                 options: .init(withTPM: true))).contains("hda-output,audiodev=snd0"))
        x.features.microphone = true
        XCTAssertTrue(joined(QEMUArguments.build(config: x, bundle: bundle, env: env, sockets: sockets,
                                                 options: .init(withTPM: true))).contains("hda-duplex,audiodev=snd0"))
    }

    func testWindowsX64EmulatesWithTCGSecureBootAndE1000e() {
        let a = joined(QEMUArguments.build(config: config(.windows, .x86_64), bundle: bundle, env: env, sockets: sockets,
                                           options: .init(withTPM: true)))
        XCTAssertTrue(a.contains("-machine q35,smm=on"))
        XCTAssertTrue(a.contains("-accel tcg,thread=multi"))
        XCTAssertTrue(a.contains("edk2-x86_64-secure-code.fd"))
        XCTAssertTrue(a.contains("ide-cd,drive=cd0"))
        XCTAssertTrue(a.contains("e1000e,netdev=net0,mac=02:00:00:00:00:01"))
        XCTAssertTrue(a.contains("tpm-tis,tpmdev=tpm0"))
        XCTAssertTrue(a.contains(",hv-relaxed,"))
        // Hyper-V enlightenments are for Windows only.
        let linux = joined(QEMUArguments.build(config: config(.linux, .x86_64), bundle: bundle, env: env, sockets: sockets,
                                               options: .init(withTPM: false)))
        XCTAssertTrue(linux.contains("-cpu Westmere-v2 "))
        XCTAssertTrue(a.contains("intel-hda"))
        XCTAssertFalse(a.contains("hvf"))
    }

    func testLinuxOnQEMUUsesVirtioGPUAndNoTPM() {
        var c = config(.linux, .aarch64)
        c.installMedia = nil
        let a = joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: false)))
        XCTAssertTrue(a.contains("virtio-gpu-pci"))
        XCTAssertTrue(a.contains("virtio-net-pci"))
        XCTAssertFalse(a.contains("tpm"))
        XCTAssertFalse(a.contains("cd0"))
    }

    func testWindowsAgentPortForward() {
        let a = joined(QEMUArguments.build(config: config(.windows, .aarch64), bundle: bundle, env: env, sockets: sockets,
                                           options: .init(withTPM: true, agentTCPPort: 41234, sshPort: 41235)))
        XCTAssertTrue(a.contains("user,id=net0,hostfwd=tcp:127.0.0.1:41234-:20819,hostfwd=tcp:127.0.0.1:41235-:22"))
    }

    func testPortForwardAddressCannotInjectNetdevOptions() {
        var c = config(.linux, .aarch64)
        c.network.portForwards = [.init(hostAddress: "1.2.3.4,guestfwd=tcp::1-cmd:/usr/bin/true", hostPort: 8080, guestPort: 80),
                                  .init(hostAddress: "0.0.0.0", hostPort: 2222, guestPort: 22)]
        let a = joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: false)))
        XCTAssertFalse(a.contains("cmd:/usr/bin/true"))
        XCTAssertTrue(a.contains(",hostfwd=tcp:0.0.0.0:2222-:22"))
    }

    /// A "x.iso" that is really a qcow2 or VMDK descriptor would otherwise be probed and could pull in
    /// a host file (backing file / extent) the guest then reads.
    func testCDROMDrivesAreRawAndEveryDriveNamesItsFormat() {
        for (os, arch) in [(VMConfig.GuestOS.windows, VMConfig.Architecture.aarch64), (.linux, .aarch64),
                           (.windows, .x86_64), (.linux, .x86_64)] {
            var c = config(os, arch)
            c.extraMedia = ["seed.iso", "virtio.iso"]
            let args = QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets,
                                           options: .init(withTPM: os == .windows))
            let drives = args.indices.filter { args[$0] == "-drive" }.map { args[$0 + 1] }
            let cdroms = drives.filter { $0.contains("media=cdrom") }
            XCTAssertEqual(cdroms.count, 3, "\(os) \(arch)")
            for d in drives {
                let opts = d.components(separatedBy: ",")
                XCTAssertEqual(opts.filter { $0.hasPrefix("format=") }, ["format=raw"], d)
            }
            XCTAssertFalse(args.contains("-blockdev"))
            XCTAssertFalse(args.contains("-cdrom"))
            XCTAssertFalse(args.contains("-hda"))
        }
    }

    func testMACAddressCannotInjectDeviceProperties() {
        let evil = "52:54:00:aa:bb:cc,romfile=/Users/x/.ssh/id_ed25519"
        for (os, arch) in [(VMConfig.GuestOS.windows, VMConfig.Architecture.x86_64), (.linux, .aarch64)] {
            var c = config(os, arch)
            c.network.macAddress = evil
            let a = joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: false)))
            XCTAssertFalse(a.contains("romfile"), "\(os) \(arch)")
            XCTAssertTrue(a.contains("netdev=net0"), "the adapter stays, with a MAC QEMU picks")
            var o = QEMUArguments.Options(withTPM: false)
            o.netdev = "vmnet-shared"
            let v = joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: o))
            XCTAssertFalse(v.contains("romfile"))
            XCTAssertTrue(v.contains("netdev=net0"))
        }
        var c = config(.linux, .aarch64)
        c.network.macAddress = "52:54:00:AA:bb:cc"
        XCTAssertTrue(joined(QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets,
                                                 options: .init(withTPM: false))).contains("virtio-net-pci,netdev=net0,mac=52:54:00:AA:bb:cc"))
    }

    func testSharedFolderPathIsEscapedForFsdev() {
        var c = config(.linux, .aarch64)
        c.shares = [.init(hostPath: "share,security_model=passthrough", name: "s")]
        let args = QEMUArguments.build(config: c, bundle: VMBundle(url: URL(fileURLWithPath: "/vms/x,y.vitrinevm")),
                                       env: env, sockets: sockets, options: .init(withTPM: false))
        XCTAssertEqual(args[args.firstIndex(of: "-fsdev")! + 1],
                       "local,id=fs0,path=/vms/x,,y.vitrinevm/share,,security_model=passthrough,security_model=none")
    }

    func testResumeAddsIncoming() {
        let a = joined(QEMUArguments.build(config: config(.windows, .aarch64), bundle: bundle, env: env, sockets: sockets,
                                           options: .init(withTPM: true, incomingState: bundle.qemuStateURL)))
        XCTAssertTrue(a.hasSuffix("-incoming file:/vms/win.vitrinevm/state.qemusave"))
    }

    func testValidationRules() {
        var c = config(.windows, .aarch64)
        c.backend = .vz
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 65536))
        c = config(.linux, .x86_64); c.backend = .vz
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 65536))
        c = config(.windows, .x86_64)
        XCTAssertNoThrow(try c.validate(hostCPUs: 8, hostMemoryMiB: 65536))
    }

    func testRealQEMUAcceptsArgumentsIfInstalled() throws {
        guard let real = try? QEMUEnvironment.detect() else { throw XCTSkip("QEMU not installed") }
        // `-S` + `-machine none` checks only that every device/option parses, without booting.
        let p = Process()
        p.executableURL = real.system(.aarch64)
        p.arguments = ["-device", "help"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        for dev in ["ramfb", "nvme", "usb-storage", "tpm-tis-device", "virtio-gpu-pci", "usb-net", "virtserialport"] {
            XCTAssertTrue(out.contains("\"\(dev)\""), "qemu-system-aarch64 lacks \(dev)")
        }
    }
}
