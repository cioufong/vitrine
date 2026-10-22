import Foundation
import VitrineCore

/// How far a Windows VM's unattended setup has got. Read from its configuration (the install media
/// and the two setup keys recorded there), so every process sees the same phase.
public enum WindowsSetup: Equatable, Sendable {
    /// No setup under way: not Windows, or the install media are gone.
    case inactive
    /// Setup runs from the install media; the agent its first-logon script installs hasn't connected
    /// yet. `offline`: emulated x64 setup, run with the network cable unplugged (see `runsOffline`).
    case installing(offline: Bool)
    /// That agent has connected: setup got that far, so the media go at the next stop even if
    /// setup's own power-off didn't happen.
    case agentSeen
    /// Setup powered the VM off and its media were ejected; the VM is starting again. Only the
    /// controller doing the restart reports this (it isn't recorded in the configuration).
    case restarting

    public init(_ config: VMConfig) {
        if config.guestOS != .windows || !config.hasInstallMedia {
            self = .inactive
        } else if config.windowsSetupAgentSeen == true {
            self = .agentSeen
        } else {
            self = .installing(offline: Self.installsOffline(config))
        }
    }

    /// Emulated x64 Setup with the network plugged in times out on OOBE's zero-day-update check
    /// ("OOBEZDP", needs a click), so it runs with the virtual cable unplugged until it finishes and
    /// the VM restarts without the media. Only when the seed carries OpenSSH (otherwise setup needs
    /// Windows Update); Windows on Arm installs fast enough online, and an interactive setup (no
    /// seed) may want the network.
    public var runsOffline: Bool { self == .installing(offline: true) }

    private static func installsOffline(_ config: VMConfig) -> Bool {
        config.effectiveArchitecture == .x86_64 && config.network.mode == .nat
            && config.installMedia != nil && config.extraMedia?.contains("seed.iso") == true
            && config.windowsSetupOffline == true
    }

    /// The first-logon script powers Windows off once drivers, SSH and the agent are in place. WinPE
    /// can also shut down cleanly before Windows has been installed, and a host-side kill exits 0
    /// too: only a guest power-off of a running VM whose setup agent connected completes setup.
    public func isFinished(by exit: QEMUExit, isRunning: Bool) -> Bool {
        self == .agentSeen && exit.isGuestPowerOff && isRunning
    }
}
