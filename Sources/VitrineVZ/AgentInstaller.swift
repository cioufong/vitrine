import Foundation
import VitrineCore
import VitrineQEMU

/// Installs VitrineAgent.app into a running macOS guest over SSH, using the provisioned account.
public enum AgentInstaller {
    public static let launchAgentLabel = "io.github.cioufong.vitrine.agent"

    /// The agent package for a guest OS: VitrineAgent.app (macOS) or a linux-agent directory with
    /// `vitrine-agent` + `install.sh` (Linux).
    public static func agentPackage(for os: VMConfig.GuestOS) -> URL? {
        switch os {
        case .macOS: return agentBundle()
        case .linux: return linuxAgentPackage()
        case .windows: return nil // installed by the unattended setup; updated with installWindows
        }
    }

    public static func linuxAgentPackage() -> URL? {
        if let env = ProcessInfo.processInfo.environment["VITRINE_LINUX_AGENT"] { return URL(fileURLWithPath: env) }
        return BuildLayout.distItem("linux-agent") {
            // One binary per guest architecture (scripts/build-linux-agent.sh).
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("vitrine-agent-arm64").path)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("install.sh").path)
        }
    }

    /// Windows agent executable for the guest architecture (dist/windows-agent/vitrine-agent-<arch>.exe).
    public static func windowsAgentExecutable(arch: VMConfig.Architecture) -> URL? {
        windowsAgentFile(arch == .aarch64 ? "vitrine-agent-arm64.exe" : "vitrine-agent-amd64.exe")
    }

    /// A file of the Windows agent package (dist/windows-agent).
    static func windowsAgentFile(_ name: String) -> URL? {
        BuildLayout.distItem("windows-agent/\(name)")
    }

    /// Locates the agent bundle shipped with this build.
    public static func agentBundle() -> URL? {
        let isAgent = { (app: URL) in FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/vitrine-agent").path) }
        if let env = ProcessInfo.processInfo.environment["VITRINE_AGENT_APP"], isAgent(URL(fileURLWithPath: env)) {
            return URL(fileURLWithPath: env)
        }
        return BuildLayout.distItem("VitrineAgent.app", where: isAgent)
    }

    public struct Target {
        public var host: String
        public var port: UInt16 = 22
        public var username: String
        public var password: String
        /// Per-VM host key store and alias: the first connection pins the guest's key, and a
        /// different machine answering on a recycled IP is refused instead of receiving the password.
        public var knownHosts: URL? = nil
        public var hostKeyAlias: String? = nil
    }

    public static func target(for bundle: VMBundle) throws -> Target {
        let config = try bundle.loadConfig()
        guard let owner = bundle.lockOwner(), owner.role != .operation else {
            throw VitrineError.backend("VM is not running")
        }
        guard let account = config.account else {
            throw VitrineError.invalidConfig("VM has no provisioned account; install the agent manually from the Vitrine Tools share")
        }
        guard let password = GuestCredentialStore.password(in: bundle) else {
            throw VitrineError.invalidConfig("no stored password for \(account.username)")
        }
        let knownHosts = bundle.url.appendingPathComponent("ssh_known_hosts")
        let alias = "vitrine-\(config.id.uuidString.lowercased())"
        // QEMU on user networking forwards a loopback port to SSH; on a vmnet or bridged network
        // the guest has its own address like a VZ guest.
        if config.effectiveBackend == .qemu, let port = QEMUMachine.sshPort(for: bundle) {
            return Target(host: "127.0.0.1", port: port, username: account.username, password: password,
                          knownHosts: knownHosts, hostKeyAlias: alias)
        }
        guard let ip = bundle.guestIPAddress(config) else {
            throw VitrineError.backend("guest has no IP address bound to its MAC or agent yet — wait for it to finish booting")
        }
        return Target(host: ip, username: account.username, password: password, knownHosts: knownHosts, hostKeyAlias: alias)
    }

    static let installScript = #"""
    set -e
    APP="$HOME/\#(MacOSAgentPayload.appRelativePath)"
    \#(MacOSAgentPayload.remoteExecutableGuard)
    # Camera support moved the agent to /Applications (macOS adds camera extensions only from
    # there): keep updating that copy.
    SYSAPP="/\#(MacOSAgentPayload.systemAppRelativePath)"
    if [ -d "$SYSAPP" ] && rm -rf "$SYSAPP" 2>/dev/null && ditto "$APP" "$SYSAPP"; then
      rm -rf "$APP"
      APP="$SYSAPP"
    fi
    PLIST="$HOME/Library/LaunchAgents/io.github.cioufong.vitrine.agent.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>io.github.cioufong.vitrine.agent</string>
      <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/vitrine-agent</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>LimitLoadToSessionType</key><string>Aqua</string>
      <key>StandardErrorPath</key><string>/tmp/vitrine-agent.log</string>
    </dict></plist>
    PLIST
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    # Agents from before the project was renamed (Silica) listen on the same port.
    if [ -f "$HOME/Library/LaunchAgents/dev.silica.agent.plist" ]; then
      launchctl bootout "gui/$(id -u)/dev.silica.agent" 2>/dev/null || true
      rm -rf "$HOME/Library/LaunchAgents/dev.silica.agent.plist" "$HOME/Applications/SilicaAgent.app"
    fi
    launchctl bootout "gui/$(id -u)/io.github.cioufong.vitrine.agent" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo installed
    """#

    /// Copies the agent and (re)starts it. Returns the remote output.
    @discardableResult
    public static func install(into bundle: VMBundle) async throws -> String {
        let config = try? bundle.loadConfig()
        if config?.guestOS == .linux { return try await installLinux(into: bundle) }
        if config?.guestOS == .windows { return try await installWindows(into: bundle, arch: config?.effectiveArchitecture ?? .aarch64) }
        guard let app = agentBundle() else {
            throw VitrineError.fileNotFound("VitrineAgent.app (run scripts/build-agent.sh)")
        }
        let t = try target(for: bundle)
        return try await Task.detached {
            // Two sessions: tar may read past its end-of-archive marker, so the script can't share stdin.
            // Prepare and validate the complete payload before SSH can remove the previous app.
            let payload = try MacOSAgentPayload.archive(from: app)
            try run(t, command: MacOSAgentPayload.receiveCommand, stdin: payload)
            return try run(t, command: "/bin/bash -s", stdin: Data(installScript.utf8))
        }.value
    }

    /// Linux: copies the linux-agent package to ~/.local/share/vitrine-agent and runs its install.sh
    /// (installs the binary and enables the systemd user service in the graphical session).
    static func installLinux(into bundle: VMBundle) async throws -> String {
        guard let pkg = linuxAgentPackage() else {
            throw VitrineError.fileNotFound("linux-agent package (run scripts/build-linux-agent.sh)")
        }
        let t = try target(for: bundle)
        return try await Task.detached {
            try run(t, command: "rm -rf ~/.local/share/vitrine-agent && mkdir -p ~/.local/share && tar -C ~/.local/share -xf - && mv ~/.local/share/\(pkg.lastPathComponent) ~/.local/share/vitrine-agent",
                    stdin: tarArchive(of: pkg))
            // DISPLAY/XAUTHORITY let install.sh start the user service in the running X session right away.
            return try run(t, command: "case $(uname -m) in x86_64|amd64) a=amd64;; *) a=arm64;; esac; cd ~/.local/share/vitrine-agent && DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority sh ./install.sh $HOME/.local/share/vitrine-agent/vitrine-agent-$a")
        }.value
    }

    /// Windows: replaces %ProgramFiles%\Vitrine\vitrine-agent.exe and restarts it in the user's session
    /// through the "Vitrine Agent" logon task created by the unattended setup.
    static func installWindows(into bundle: VMBundle, arch: VMConfig.Architecture) async throws -> String {
        guard let exe = windowsAgentExecutable(arch: arch) else {
            throw VitrineError.fileNotFound("Windows agent (run scripts/build-windows-agent.sh)")
        }
        let t = try target(for: bundle)
        return try await Task.detached {
            // scp lands in the user's home (Windows OpenSSH's sftp root); then swap it in with cmd.
            try upload(t, exe, to: "vitrine-agent.new.exe")
            return try run(t, command: windowsSwapCommand)
        }.value
    }

    /// Swaps in the uploaded agent. The killed process holds its executable open for a moment, so
    /// the move is retried; the agent is restarted either way (the old one if the swap failed),
    /// and a failed swap is reported instead of leaving the guest without an agent.
    static let windowsSwapScript = #"""
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue' # progress records would reach the caller as CLIXML
    $dst = Join-Path $env:ProgramFiles 'Vitrine\vitrine-agent.exe'
    $src = Join-Path $env:USERPROFILE 'vitrine-agent.new.exe'
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Get-Process vitrine-agent -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process vitrine-agent -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    $ok = $false
    for ($i = 0; $i -lt 40 -and -not $ok; $i++) {
      try { Move-Item -Force $src $dst; $ok = $true } catch { Start-Sleep -Milliseconds 250 }
    }
    Start-ScheduledTask -TaskName 'Vitrine Agent'
    if (-not $ok) { [Console]::Error.WriteLine('could not replace vitrine-agent.exe (still in use)'); exit 1 }
    'Vitrine Agent updated and restarted'
    """#

    static var windowsSwapCommand: String {
        var utf16le = Data()
        for unit in windowsSwapScript.utf16 { utf16le.append(UInt8(unit & 0xff)); utf16le.append(UInt8(unit >> 8)) }
        return "powershell -NoProfile -NonInteractive -EncodedCommand \(utf16le.base64EncodedString())"
    }

    /// Marks macOS setup as complete so later cold boots skip Setup Assistant. Provisioning only
    /// covers the first boot; without this the guest shows Setup Assistant again on the next start.
    /// Also sets the guest's time zone to `timeZone` (the Mac's): a fresh install stays on Pacific
    /// time, and the agent, running as the user, can't change it later.
    static func finalizeSetupScript(timeZone: String) -> String {
        // An IANA name such as Asia/Taipei; anything else is left out of the shell script.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_+-")
        let zone = !timeZone.isEmpty && timeZone.unicodeScalars.allSatisfy(allowed.contains) && !timeZone.contains("..") ? timeZone : ""
        return #"""
    set -e
    touch /private/var/db/.AppleSetupDone
    Z="\#(zone)"
    if [ -n "$Z" ]; then
      for d in /var/db/timezone/zoneinfo /usr/share/zoneinfo; do
        if [ -f "$d/$Z" ]; then ln -sf "$d/$Z" /etc/localtime; break; fi
      done
    fi
    U="$SUDO_USER"
    H=$(dscl . -read "/Users/$U" NFSHomeDirectory | awk '{print $2}')
    V=$(sw_vers -productVersion)
    B=$(sw_vers -buildVersion)
    for k in DidSeeCloudSetup DidSeeSiriSetup DidSeePrivacy DidSeeScreenTime DidSeeAppearanceSetup \
             DidSeeTouchIDSetup DidSeeAccessibility DidSeeApplePaySetup DidSeeiCloudLoginForStorageServices \
             DidSeeTrueTonePrivacy DidSeeIntelligence DidSeeWallpaperSetup SkipFirstLoginOptimization; do
      sudo -u "$U" defaults write com.apple.SetupAssistant "$k" -bool true
    done
    sudo -u "$U" defaults write com.apple.SetupAssistant LastSeenCloudProductVersion "$V"
    sudo -u "$U" defaults write com.apple.SetupAssistant LastSeenBuddyBuildVersion "$B"
    sudo -u "$U" defaults write com.apple.SetupAssistant LastPreLoginTasksPerformedVersion "$V"
    sudo -u "$U" defaults write com.apple.SetupAssistant LastPreLoginTasksPerformedBuild "$B"
    echo finalized
    """#
    }

    public static func finalizeSetup(in bundle: VMBundle) async throws {
        guard (try bundle.loadConfig()).guestOS == .macOS else {
            throw VitrineError.unsupported("setup finalization only applies to macOS guests")
        }
        let t = try target(for: bundle)
        _ = try await Task.detached { try runScript(t, finalizeSetupScript(timeZone: TimeZone.current.identifier), asRoot: true, on: .macOS) }.value
    }

    /// The v4l2loopback card label the Linux agent looks for (agent/camera_linux.go: CameraLabel).
    public static let cameraLabel = "Vitrine Camera"

    /// Run as root in a Linux guest: installs v4l2loopback and makes it load at boot as one
    /// "Vitrine Camera" device that apps see as a webcam once the agent writes to it.
    /// macOS guests: system extensions such as the agent's Vitrine Camera are only activated for
    /// apps in /Applications, so this moves the agent there and restarts it.
    static let macOSCameraSupportScript = #"""
    set -e
    SRC="$HOME/\#(MacOSAgentPayload.appRelativePath)"
    DST="/\#(MacOSAgentPayload.systemAppRelativePath)"
    PLIST="$HOME/Library/LaunchAgents/io.github.cioufong.vitrine.agent.plist"
    if [ ! -d "$SRC" ]; then
      if [ -d "$DST" ]; then echo "$DST"; exit 0; fi
      echo "the Vitrine agent isn't installed in the guest" >&2; exit 1
    fi
    if [ ! -d "$SRC/Contents/Library/SystemExtensions" ]; then
      echo "this Vitrine agent was built without its camera extension (rebuild it with scripts/build-agent.sh)" >&2; exit 1
    fi
    sudo -S -p '' /bin/sh -c 'rm -rf "$2" && ditto "$1" "$2" && chown -R "$3" "$2"' sh "$SRC" "$DST" "$(id -u):$(id -g)"
    rm -rf "$SRC"
    sed -i '' "s#$SRC/#$DST/#" "$PLIST"
    launchctl bootout "gui/$(id -u)/io.github.cioufong.vitrine.agent" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "$DST"
    """#

    static let cameraSupportScript = #"""
    set -e
    label="Vitrine Camera"
    have_device() { grep -qx "$label" /sys/class/video4linux/video*/name 2>/dev/null; }
    if ! modinfo v4l2loopback >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq "linux-headers-$(uname -r)" v4l2loopback-dkms || apt-get install -y -qq v4l2loopback-dkms
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y v4l2loopback || dnf install -y akmod-v4l2loopback
      elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm --needed v4l2loopback-dkms linux-headers
      elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install v4l2loopback-kmp-default
      else
        echo "no supported package manager (apt, dnf, pacman, zypper): install v4l2loopback yourself" >&2; exit 2
      fi
    fi
    mkdir -p /etc/modules-load.d /etc/modprobe.d /etc/udev/rules.d
    echo v4l2loopback > /etc/modules-load.d/vitrine-camera.conf
    echo "options v4l2loopback card_label=\"$label\" exclusive_caps=1 devices=1" > /etc/modprobe.d/vitrine-camera.conf
    # The desktop user's session (and so the agent) may open the device.
    echo "SUBSYSTEM==\"video4linux\", ATTR{name}==\"$label\", TAG+=\"uaccess\"" > /etc/udev/rules.d/70-vitrine-camera.rules
    command -v udevadm >/dev/null 2>&1 && udevadm control --reload-rules || true
    if ! have_device; then
      if lsmod | grep -q '^v4l2loopback '; then
        # Loaded already for something else (OBS…): add a device rather than unloading theirs.
        v4l2loopback-ctl add -n "$label" -x 1 >/dev/null 2>&1 || v4l2loopback-ctl add --name "$label" --exclusive-caps 1 >/dev/null 2>&1 \
          || { echo "v4l2loopback is already loaded without a \"$label\" device; restart the VM" >&2; exit 3; }
      else
        modprobe v4l2loopback
      fi
    fi
    command -v udevadm >/dev/null 2>&1 && { udevadm trigger --subsystem-match=video4linux || true; udevadm settle || true; }
    have_device || { echo "the \"$label\" device didn't appear" >&2; exit 4; }
    for d in /sys/class/video4linux/video*; do [ "$(cat "$d/name")" = "$label" ] && echo "/dev/${d##*/}"; done
    exit 0  # not the last comparison's status
    """#

    /// Installs the guest half of camera sharing and returns where it went (the Linux device,
    /// the macOS agent's new place, or the Windows media source).
    public static func installCameraSupport(in bundle: VMBundle) async throws -> String {
        let config = try bundle.loadConfig()
        let os = config.guestOS
        let t = try target(for: bundle)
        if os == .windows {
            // The Vitrine Camera media source (guest/windows-camera) for the guest's CPU, installed
            // and registered machine-wide by install.ps1; the running agent picks it up next start.
            let dllName = config.effectiveArchitecture == .aarch64 ? "vitrine-camera-arm64.dll" : "vitrine-camera-amd64.dll"
            guard let dll = windowsAgentFile(dllName), let script = windowsAgentFile("install.ps1") else {
                throw VitrineError.fileNotFound("Windows camera support (run scripts/build-windows-agent.sh with zig installed)")
            }
            return try await Task.detached {
                try upload(t, dll, to: "vitrine-camera.dll")
                try upload(t, script, to: "vitrine-install.ps1")
                let out = try run(t, command: "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File vitrine-install.ps1 -CameraOnly -CameraDll vitrine-camera.dll")
                if out.contains("skipped") { throw VitrineError.unsupported("camera sharing needs Windows 11 in the guest") }
                return out.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            }.value
        }
        guard os == .linux || os == .macOS else {
            throw VitrineError.unsupported("camera sharing needs a Linux, macOS or Windows guest")
        }
        if os == .macOS {
            // Runs as the guest user; stdin carries the password for the one sudo inside.
            let out = try await Task.detached { try runScript(t, macOSCameraSupportScript, asRoot: false, on: .macOS) }.value
            return out.split(separator: "\n").last.map(String.init) ?? ""
        }
        let out = try await Task.detached {
            // DKMS builds the module for the running kernel, which takes a few minutes on small VMs.
            try runScript(t, cameraSupportScript, asRoot: true, on: .linux, timeout: 1200)
        }.value
        return out.split(separator: "\n").last.map(String.init) ?? ""
    }

    /// Run as root (through sudo, from the desktop user) in a Linux guest: installs BlueZ and the
    /// root service that adds the Mac's Bluetooth to the kernel as an HCI controller
    /// (`vitrine-agent bluetooth-bridge`, guest/linux-agent/btbridge), reachable by that user only.
    static let bluetoothSupportScript = #"""
    set -e
    user="${SUDO_USER:-}"
    [ -n "$user" ] && [ "$user" != root ] || { echo "run this through sudo from the desktop user" >&2; exit 1; }
    agent=/usr/local/bin/vitrine-agent
    [ -x "$agent" ] || { echo "the Vitrine agent isn't installed in the guest" >&2; exit 1; }
    grep -q bluetooth-bridge "$agent" || { echo "the guest's Vitrine agent is too old for Bluetooth: update it first" >&2; exit 1; }
    modinfo hci_uart >/dev/null 2>&1 || { echo "this guest's kernel has no hci_uart module (CONFIG_BT_HCIUART)" >&2; exit 2; }
    if ! command -v bluetoothctl >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq bluez
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bluez
      elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm --needed bluez bluez-utils
      elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install bluez
      else
        echo "no supported package manager (apt, dnf, pacman, zypper): install BlueZ yourself" >&2; exit 2
      fi
    fi
    mkdir -p /etc/modules-load.d
    echo hci_uart > /etc/modules-load.d/vitrine-bluetooth.conf
    modprobe hci_uart
    cat > /etc/systemd/system/vitrine-bluetooth.service <<EOF
    [Unit]
    Description=Vitrine Bluetooth bridge (the Mac's Bluetooth LE as a controller in this guest)
    Before=bluetooth.service

    [Service]
    ExecStart=$agent bluetooth-bridge --owner $user --socket \#(bluetoothSocket)
    Restart=on-failure
    RestartSec=2

    [Install]
    WantedBy=multi-user.target
    EOF
    systemctl daemon-reload
    systemctl enable --now bluetooth.service >/dev/null 2>&1 || true
    systemctl enable vitrine-bluetooth.service >/dev/null 2>&1
    systemctl restart vitrine-bluetooth.service
    for i in $(seq 1 20); do [ -S \#(bluetoothSocket) ] && break; sleep 0.5; done
    [ -S \#(bluetoothSocket) ] || { echo "the Bluetooth bridge didn't start: $(journalctl -u vitrine-bluetooth -n 3 --no-pager 2>/dev/null)" >&2; exit 4; }
    echo \#(bluetoothSocket)
    """#

    /// Where the guest's Bluetooth bridge listens (agent/bluetooth.go: BluetoothSocket).
    public static let bluetoothSocket = "/run/vitrine/bluetooth.sock"

    /// Installs the guest half of Bluetooth sharing (Linux only) and returns the bridge's socket.
    public static func installBluetoothSupport(in bundle: VMBundle) async throws -> String {
        guard try bundle.loadConfig().guestOS == .linux else {
            throw VitrineError.unsupported("Bluetooth sharing needs a Linux guest")
        }
        let t = try target(for: bundle)
        let out = try await Task.detached { try runScript(t, bluetoothSupportScript, asRoot: true, on: .linux, timeout: 900) }.value
        return out.split(separator: "\n").last.map(String.init) ?? ""
    }

    /// Runs a PowerShell script in a Windows guest: copied over first and run as a file (a script
    /// passed with -EncodedCommand grows 2.7× and soon exceeds cmd.exe's 8191-character limit).
    public static func runPowerShell(in bundle: VMBundle, script: String, name: String) async throws -> String {
        let t = try target(for: bundle)
        return try await Task.detached {
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-\(UUID().uuidString).ps1")
            try script.write(to: local, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: local) }
            do {
                try upload(t, local, to: name)
            } catch SSHError.commandFailed(let m) {
                // scp failing (full disk, …) says nothing about the script: report it as "couldn't
                // get there yet", so callers retry instead of taking it as the script's verdict.
                throw SSHError.unreachable("copying \(name) failed: \(m)")
            }
            return try run(t, command: "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \(name)")
        }.value
    }

    /// Runs a command in the guest (e.g. for diagnostics).
    public static func run(in bundle: VMBundle, command: String) async throws -> String {
        let t = try target(for: bundle)
        return try await Task.detached { try run(t, command: command) }.value
    }

    /// Copies a file or folder from the Mac into the guest (scp over the guest's SSH server).
    public static func push(in bundle: VMBundle, local: URL, remote: String) async throws {
        let t = try target(for: bundle)
        _ = try await Task.detached {
            try upload(t, local, to: remote, timeout: 3600)
        }.value
    }

    /// Copies a file or folder from the guest to the Mac.
    public static func pull(in bundle: VMBundle, remote: String, local: URL) async throws {
        let t = try target(for: bundle)
        _ = try await Task.detached {
            try download(t, remote, to: local, timeout: 3600)
        }.value
    }

    /// Runs `command` in the guest with `stdin` as its input; returns what it printed (stdout and stderr).
    @discardableResult
    static func run(_ t: Target, command: String, stdin: Data? = nil, timeout: TimeInterval = 600) throws -> String {
        try ssh(t, tool: "/usr/bin/ssh", ["-p", "\(t.port)", "\(t.username)@\(t.host)", command], stdin: stdin, timeout: timeout)
    }

    /// A command that writes `script` to a temporary file in a macOS or Linux guest and runs it with
    /// bash, as root through `sudo -S -p ''` when `asRoot`. The script travels in the command as
    /// base64 and runs from the file, so stdin carries only the password for sudo: if sudo doesn't
    /// ask, the password is never read as shell input. macOS's base64 decodes with -D, GNU's with -d.
    static func scriptCommand(_ script: String, asRoot: Bool, on os: VMConfig.GuestOS) -> String {
        let b64 = Data(script.utf8).base64EncodedString()
        let decode = os == .macOS ? "/usr/bin/base64 -D" : "base64 -d"
        let bash = asRoot ? "sudo -S -p '' /bin/bash" : "/bin/bash"
        return "f=$(mktemp) && echo \(b64) | \(decode) > \"$f\" && \(bash) \"$f\" </dev/stdin; rc=$?; rm -f \"$f\"; exit $rc"
    }

    /// Runs `script` (see `scriptCommand`) with the user's password on stdin, for the sudo that
    /// runs it (`asRoot`) or one inside it.
    static func runScript(_ t: Target, _ script: String, asRoot: Bool, on os: VMConfig.GuestOS,
                          timeout: TimeInterval = 600) throws -> String {
        try run(t, command: scriptCommand(script, asRoot: asRoot, on: os), stdin: Data((t.password + "\n").utf8), timeout: timeout)
    }

    /// Copies a file or folder into the guest with scp (same options and password as `run`).
    @discardableResult
    static func upload(_ t: Target, _ local: URL, to remote: String, timeout: TimeInterval = 600) throws -> String {
        try ssh(t, tool: "/usr/bin/scp", ["-r", "-P", "\(t.port)", local.path, "\(t.username)@\(t.host):\(remote)"],
                stdin: nil, timeout: timeout)
    }

    /// Copies a file or folder from the guest with scp.
    @discardableResult
    static func download(_ t: Target, _ remote: String, to local: URL, timeout: TimeInterval = 600) throws -> String {
        try ssh(t, tool: "/usr/bin/scp", ["-r", "-P", "\(t.port)", "\(t.username)@\(t.host):\(remote)", local.path],
                stdin: nil, timeout: timeout)
    }

    /// A tar stream of `item` (as one entry at the archive's root), for `tar -xf -` in the guest.
    static func tarArchive(of item: URL) throws -> Data {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--no-mac-metadata", "-C", item.deletingLastPathComponent().path, "-cf", "-", item.lastPathComponent]
        let tarOut = Pipe()
        tar.standardOutput = tarOut
        try tar.run()
        let archive = tarOut.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw VitrineError.io("tar failed") }
        return archive
    }

    /// Runs ssh or scp (`tool`) with the password from an askpass helper (never in argv) and the
    /// VM's pinned host key, writing `stdin` to it, under a hard deadline for the whole operation.
    private static func ssh(_ t: Target, tool: String, _ arguments: [String], stdin: Data?,
                            timeout: TimeInterval) throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-askpass-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf '%s\\n' \"$VITRINE_SSH_PASSWORD\"\n".write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: tool)
        var hostKeyOptions = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
        if let known = t.knownHosts, let alias = t.hostKeyAlias {
            hostKeyOptions = ["-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\"\(known.path)\"", // quoted: the path has spaces
                              "-o", "HostKeyAlias=\(alias)"]
        }
        ssh.arguments = hostKeyOptions + ["-o", "LogLevel=ERROR",
                         "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
                         "-o", "PubkeyAuthentication=no",
                         "-o", "PreferredAuthentications=password,keyboard-interactive"] + arguments
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = tmp.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env["VITRINE_SSH_PASSWORD"] = t.password
        ssh.environment = env
        let outPipe = Pipe(), inPipe = Pipe()
        ssh.standardOutput = outPipe
        ssh.standardError = outPipe
        ssh.standardInput = inPipe
        try ssh.run()
        // Hard deadline for the whole operation: a stalled remote command must not hang forever.
        let watchdog = DispatchWorkItem { if ssh.isRunning { ssh.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let payload = stdin ?? Data()
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: payload) // throws (not SIGPIPE/NSException) if ssh exited early
            try? inPipe.fileHandleForWriting.close()
        }
        let output = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ssh.waitUntilExit()
        guard ssh.terminationStatus == 0 else {
            let message = "ssh \(t.username)@\(t.host) failed (\(ssh.terminationStatus)): \(output.suffix(400))"
            // 255 is ssh's own failure (no connection, auth); anything else is the remote command's status.
            throw ssh.terminationStatus == 255 ? SSHError.unreachable(message) : SSHError.commandFailed(message)
        }
        return output
    }

    public enum SSHError: LocalizedError {
        case unreachable(String)
        case commandFailed(String)
        public var errorDescription: String? {
            switch self { case .unreachable(let m), .commandFailed(let m): return m }
        }
    }
}
