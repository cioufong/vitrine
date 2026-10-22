import Foundation

/// How a QEMU process ended.
public struct QEMUExit: Sendable {
    public let status: Int32
    /// The end of what QEMU wrote during this run, for error messages.
    public let tail: String?
    /// QEMU quit because something on the host signalled it (`kill`, Activity Monitor, logout, …)
    /// rather than because the guest powered off. QEMU catches SIGTERM/SIGINT/SIGHUP and exits with
    /// status 0 either way; only its "terminating on signal" line tells the two apart.
    public let killedByHost: Bool

    public init(status: Int32, output: String?, uncaughtSignal: Bool) {
        self.status = status
        self.tail = output.map { String($0.suffix(600)) }
        self.killedByHost = uncaughtSignal || Self.reportsSignal(output)
    }

    static func reportsSignal(_ output: String?) -> Bool {
        output?.contains(": terminating on signal ") ?? false
    }

    /// The guest shut itself down (ACPI power-off from inside), as opposed to a crash or a host kill.
    public var isGuestPowerOff: Bool { status == 0 && !killedByHost }
}
