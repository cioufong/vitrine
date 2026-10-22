import Foundation
import VitrineCore

/// One-click Linux desktops from official cloud images + cloud-init:
/// downloads the image, grows the disk, and builds a NoCloud seed ISO that creates the user, enables
/// SSH and installs a desktop with clipboard support. No installer UI to click through.
public enum CloudImageInstaller {
    public struct Distro: Sendable, Identifiable, Hashable {
        public var id: String
        public var name: String
        public var url: URL
        /// File inside the archive that holds the raw disk (nil when `url` is already raw).
        public var rawMember: String?
        public var desktopPackages: [String]
        public var displayManagerSetup: [String]
    }

    public static let debian13 = Distro(
        id: "debian-13", name: "Debian 13 “Trixie” (Xfce)",
        url: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.tar.xz")!,
        rawMember: "disk.raw",
        desktopPackages: ["task-xfce-desktop", "lightdm", "spice-vdagent", "xserver-xorg-video-fbdev", "fonts-noto-cjk"],
        displayManagerSetup: ["systemctl set-default graphical.target", "systemctl enable lightdm"])

    public static let all = [debian13]

    public struct Options {
        public var name: String
        public var distro: Distro = debian13
        public var cpuCount = max(2, ProcessInfo.processInfo.processorCount / 2)
        public var memoryMiB: UInt64 = 4096
        public var diskBytes: UInt64 = 32 << 30
        public var fullName: String
        public var username: String
        public var password: String
        public var desktop = true
        public var display = VMConfig.DisplayConfig(widthPixels: 1920, heightPixels: 1200, pixelsPerInch: 110)
        public init(name: String, fullName: String, username: String, password: String) {
            self.name = name; self.fullName = fullName; self.username = username; self.password = password
        }
    }

    public enum Phase: Equatable { case downloading(Double), extracting, configuring }

    @discardableResult
    public static func create(_ o: Options, progress: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> VMBundle {
        let archive = try await RestoreImages.downloadToCache(o.distro.url, subdirectory: "linux/\(o.distro.id)") { f, _, _ in
            progress(.downloading(f))
        }
        var config = VMConfig(name: o.name, guestOS: .linux, cpuCount: o.cpuCount, memoryMiB: o.memoryMiB)
        config.boot = .efi
        config.display = o.display
        config.installedOS = o.distro.name
        config.disks = [.init(path: "disk.img"), .init(path: "seed.iso", readOnly: true)]
        config.account = .init(fullName: o.fullName, username: o.username)
        config.account?.setupFinalized = true // cloud-init handles setup; nothing like macOS Setup Assistant

        return try await VMBundle.create(at: VMLibrary.bundleURL(named: o.name), config: config) { bundle, config in
            progress(.extracting)
            try await extractDisk(archive: archive, member: o.distro.rawMember, to: bundle.resolve("disk.img"))
            try DiskImage.resize(at: bundle.resolve("disk.img"), to: max(o.diskBytes, 8 << 30))
            progress(.configuring)
            let hostname = GuestNetwork.hostname(forVMName: o.name)
            try makeSeedISO(at: bundle.resolve("seed.iso"), options: o, hostname: hostname, mac: config.network.macAddress)
            config.guestHostname = hostname
            try GuestCredentialStore.setPassword(o.password, in: bundle)
            try config.validate(bundle: bundle)
        }
    }

    static func extractDisk(archive: URL, member: String?, to dest: URL) async throws {
        guard let member else {
            try DiskImage.clone(archive, to: dest)
            return
        }
        let dir = dest.deletingLastPathComponent().appendingPathComponent(".extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xSf", archive.path, "-C", dir.path, member] // -S keeps the raw image sparse
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw VitrineError.io("could not extract \(member) from \(archive.lastPathComponent)") }
        }.value
        try FileManager.default.moveItem(at: dir.appendingPathComponent(member), to: dest)
    }

    /// cloud-init user-data (YAML). Values are JSON-encoded, which is valid YAML, to avoid quoting bugs.
    public static func userData(_ o: Options, hostname: String) -> String {
        func q(_ s: String) -> String {
            String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
        }
        var packages = ["openssh-server", "curl", "ca-certificates"]
        var runcmd: [String] = []
        if o.desktop {
            packages += o.distro.desktopPackages
            runcmd += o.distro.displayManagerSetup
            // Autologin into an X11 session (the Linux agent needs X11).
            runcmd.append("mkdir -p /etc/lightdm/lightdm.conf.d && printf '[Seat:*]\\nautologin-user=\(o.username)\\nautologin-session=xfce\\n' > /etc/lightdm/lightdm.conf.d/50-vitrine.conf")
            runcmd.append("groupadd -f autologin && usermod -aG autologin \(o.username)")
            if o.display.pixelsPerInch >= 200 {
                // Retina host: run Xfce at 2× so text is crisp (the Vitrine agent reports scale 2).
                runcmd.append("mkdir -p /home/\(o.username)/.config/xfce4/xfconf/xfce-perchannel-xml && printf '%s\\n' '<?xml version=\"1.0\" encoding=\"UTF-8\"?>' '<channel name=\"xsettings\" version=\"1.0\">' '  <property name=\"Gdk\" type=\"empty\"><property name=\"WindowScalingFactor\" type=\"int\" value=\"2\"/></property>' '  <property name=\"Xft\" type=\"empty\"><property name=\"DPI\" type=\"int\" value=\"192\"/></property>' '</channel>' > /home/\(o.username)/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml && chown -R \(o.username): /home/\(o.username)/.config")
            }
            // The user's systemd instance started (first SSH login) before apt installed
            // dbus-user-session, so it has no session bus; Xfce would come up without one.
            runcmd.append("systemctl try-restart user@$(id -u \(o.username)).service || true")
            runcmd.append("systemctl restart lightdm || true")
        }
        // Shared folders: mount the "vitrine" virtiofs tag at boot (nofail so a VM without shares still boots).
        runcmd.append("mkdir -p /mnt/vitrine && grep -q virtiofs /etc/fstab || echo 'vitrine /mnt/vitrine virtiofs rw,nofail 0 0' >> /etc/fstab && mount -a || true")
        return """
        #cloud-config
        hostname: \(q(hostname))
        users:
          - name: \(q(o.username))
            gecos: \(q(o.fullName))
            groups: [sudo, adm, audio, video, input]
            shell: /bin/bash
            sudo: "ALL=(ALL) NOPASSWD:ALL"
            lock_passwd: false
            passwd: \(q(PasswordHash.sha512Crypt(o.password)))
        ssh_pwauth: true
        package_update: true
        packages: [\(packages.map(q).joined(separator: ", "))]
        growpart: {mode: auto, devices: ["/"]}
        runcmd:
        \(runcmd.map { "  - \(q($0))" }.joined(separator: "\n"))
        final_message: "vitrine: cloud-init finished"

        """
    }

    static func makeSeedISO(at url: URL, options: Options, hostname: String, mac: String) throws {
        let dir = url.deletingLastPathComponent().appendingPathComponent(".seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try userData(options, hostname: hostname).write(to: dir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try "instance-id: \(UUID().uuidString)\nlocal-hostname: \(hostname)\n"
            .write(to: dir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        // DHCP with the MAC as client identifier so the host can find the guest's lease by MAC.
        try """
        version: 2
        ethernets:
          primary:
            match: {name: "e*"}
            dhcp4: true
            dhcp-identifier: mac
        """.write(to: dir.appendingPathComponent("network-config"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", url.path, dir.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw VitrineError.io("hdiutil could not build the cloud-init seed") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) // contains the password
    }
}
