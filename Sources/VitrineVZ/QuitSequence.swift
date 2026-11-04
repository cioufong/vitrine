import Foundation

/// A running VM as quitting Vitrine sees it.
@MainActor
public protocol QuitTarget: AnyObject {
    var name: String { get }
    /// Shut down instead of suspended: a drive is attached (the user already chose to shut it
    /// down), or the VM is disposable.
    var shutsDownOnQuit: Bool { get }
    /// Nothing is kept from this run, so forcing it off loses nothing.
    var isDisposable: Bool { get }
    func suspend() async throws
    /// Asks the guest to shut down; true once it has stopped. Never forces it off.
    func shutDown(timeout: TimeInterval) async -> Bool
    func forceStop() async
    /// A line for the VM's log.
    func note(_ line: String)
}

/// What the user is asked while quitting. Answering true goes on with quitting; false keeps
/// Vitrine open with the VMs that are still running.
public enum QuitQuestion: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let name: String, reason: String
        public init(name: String, reason: String) { self.name = name; self.reason = reason }
    }
    /// These VMs couldn't be suspended: shut them down?
    case suspendFailed([Failure])
    /// These VMs didn't shut down in time: force them off (like pulling the power cord)?
    case didNotShutDown([String])
}

/// Quitting suspends every running VM. A VM that can't be suspended is shut down, and one that
/// doesn't shut down is forced off, each only after the user agreed: nothing is powered off behind
/// their back, and they can keep Vitrine open instead.
@MainActor
public enum QuitSequence {
    /// Time a guest gets to shut down: slow (emulated) guests need minutes.
    public static var plannedShutdownTimeout: TimeInterval = 300
    public static var fallbackShutdownTimeout: TimeInterval = 120

    /// Returns whether Vitrine should quit.
    public static func run(_ targets: [QuitTarget], ask: (QuitQuestion) async -> Bool) async -> Bool {
        let planned = targets.filter(\.shutsDownOnQuit)
        let toSuspend = targets.filter { !$0.shutsDownOnQuit }

        var failures: [(QuitTarget, String)] = []
        var hanging: [QuitTarget] = []
        await withTaskGroup(of: (QuitTarget, String?, Bool).self) { group in
            for t in toSuspend {
                group.addTask { @MainActor in
                    do { try await t.suspend(); return (t, nil, true) } catch { return (t, error.localizedDescription, true) }
                }
            }
            for t in planned {
                group.addTask { @MainActor in (t, nil, await t.shutDown(timeout: plannedShutdownTimeout)) }
            }
            for await (t, failure, stopped) in group {
                if let failure { failures.append((t, failure)) } else if !stopped { hanging.append(t) }
            }
        }
        failures = ordered(failures, by: targets)

        if !failures.isEmpty {
            guard await ask(.suspendFailed(failures.map { .init(name: $0.0.name, reason: $0.1) })) else { return false }
            await withTaskGroup(of: (QuitTarget, Bool).self) { group in
                for (t, _) in failures {
                    group.addTask { @MainActor in (t, await t.shutDown(timeout: fallbackShutdownTimeout)) }
                }
                for await (t, stopped) in group where !stopped { hanging.append(t) }
            }
        }

        hanging = ordered(hanging.map { ($0, "") }, by: targets).map(\.0)
        let mustAsk = hanging.filter { !$0.isDisposable }
        if !mustAsk.isEmpty, await !ask(.didNotShutDown(mustAsk.map(\.name))) { return false }
        for t in hanging {
            t.note("did not shut down in time while Vitrine quit; forced off")
            await t.forceStop()
        }
        return true
    }

    private static func ordered<T>(_ items: [(QuitTarget, T)], by targets: [QuitTarget]) -> [(QuitTarget, T)] {
        items.sorted { a, b in
            (targets.firstIndex { $0 === a.0 } ?? 0) < (targets.firstIndex { $0 === b.0 } ?? 0)
        }
    }
}
