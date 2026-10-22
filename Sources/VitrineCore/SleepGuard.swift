import Foundation
import IOKit.pwr_mgt

/// Settings shared by the app and `vitrinectl` (one defaults domain, so both honour them).
public enum VitrinePreferences {
    public static let suiteName = "io.github.cioufong.vitrine"
    static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    /// Keep the Mac from idle-sleeping while any VM runs (the display may still sleep). On by
    /// default: a sleeping host freezes guests mid-work and drops their network connections.
    public static var keepAwakeWhileRunning: Bool {
        get { defaults.object(forKey: "keepAwakeWhileRunning") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepAwakeWhileRunning") }
    }
}

/// Holds one IOKit "prevent idle system sleep" assertion while at least one VM in this process
/// is running. Each VM registers under its own key; the assertion is released with the last one.
public final class SleepGuard: @unchecked Sendable {
    public static let shared = SleepGuard()

    private let lock = NSLock()
    private var holders = Set<String>()
    private var assertion: IOPMAssertionID = 0
    private var held = false

    /// Marks `key` (a VM) as running or not; takes or releases the assertion as needed.
    public func set(_ key: String, running: Bool) {
        lock.lock(); defer { lock.unlock() }
        if running && VitrinePreferences.keepAwakeWhileRunning { holders.insert(key) } else { holders.remove(key) }
        update()
    }

    /// Re-applies the preference to the VMs already running (after the setting changes).
    public func preferenceChanged() {
        lock.lock(); defer { lock.unlock() }
        if !VitrinePreferences.keepAwakeWhileRunning { holders.removeAll() }
        update()
    }

    public var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return held }

    private func update() {
        if !holders.isEmpty && !held {
            let reason = "Vitrine virtual machines are running" as CFString
            held = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess
        } else if holders.isEmpty && held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}
