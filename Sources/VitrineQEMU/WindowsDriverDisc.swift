import Foundation
import VitrineCore

/// A disc of virtio drivers for a Windows guest that was not installed by Vitrine (an imported one).
/// Such a guest has no driver for Vitrine's network adapter, so it cannot download them itself; the
/// disc sits on a bus Windows always has a driver for, and `install.cmd` on it installs them all.
public enum WindowsDriverDisc {
    /// The script at the root of the disc. It asks for administrator rights itself (pnputil needs
    /// them), then stages and installs every driver on the disc; ones without a device stay staged.
    static let installScript = #"""
    @echo off
    rem Relaunch elevated once: the argument keeps a failing check from relaunching forever.
    if "%~1"=="elevated" goto install
    net session >nul 2>&1
    if errorlevel 1 (
        powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList elevated"
        exit /b
    )
    :install
    echo Installing the virtio drivers for Vitrine...
    pnputil /add-driver "%~dp0drivers\*.inf" /subdirs /install
    rem The network adapter can stay missing until devices are enumerated again.
    pnputil /scan-devices
    echo.
    echo Done. The network adapter works from now on. For the full display, shut Windows down and turn
    echo off Basic display in Vitrine's Configuration, under Graphics. The disc can be ejected.
    pause
    """#

    /// Builds the disc at `url` from a virtio-win ISO: `drivers\` for `arch` and `install.cmd`.
    public static func make(at url: URL, virtioWinISO: URL, arch: VMConfig.Architecture) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().appendingPathComponent(".windrivers-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItemForcibly(at: dir) }
        try WindowsCreator.extractDrivers(iso: virtioWinISO, arch: arch, to: dir.appendingPathComponent("drivers"))
        try installScript.replacingOccurrences(of: "\n", with: "\r\n")
            .write(to: dir.appendingPathComponent("install.cmd"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["makehybrid", "-quiet", "-iso", "-joliet", "-udf", "-default-volume-name", "VITRINE_DRIVERS", "-o", url.path, dir.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw VitrineError.io("hdiutil could not build the driver disc") }
    }

    /// Builds the disc inside `bundle` and attaches it to `config`. The caller holds the bundle's
    /// lock and saves the config. Only for a VM that is shut down: a saved state expects its devices.
    public static func attach(to config: inout VMConfig, in bundle: VMBundle, virtioWinISO: URL) throws {
        guard config.guestOS == .windows, config.effectiveBackend == .qemu else {
            throw VitrineError.invalidConfig("the driver disc is for Windows guests on QEMU")
        }
        try make(at: bundle.resolve(VMConfig.driverDiscFileName), virtioWinISO: virtioWinISO,
                 arch: config.architecture ?? .aarch64)
        config.driverMedia = VMConfig.driverDiscFileName
    }
}
