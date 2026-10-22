import Foundation
import VitrineAgentHost
import VitrineAgentProtocol

/// Sharing one of the Mac's devices (the camera, Bluetooth LE) with the guest, for this run only.
public enum GuestShareState: Equatable {
    case off
    case starting
    /// The guest has the device as `device` (e.g. /dev/video0, hci0).
    case on(device: String)
    /// The Mac's side couldn't be opened (`guestSide` false) or the guest's half is missing, which
    /// installing support sets up (`guestSide` true).
    case failed(String, guestSide: Bool)
    case installing
}

/// Why the Mac's side of a share can't be opened, as the status bar shows it.
struct ShareUnavailable: LocalizedError {
    let errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}

/// Shares one of the Mac's devices with the guest through its agent. The Mac's side (`Device`) is
/// opened and the agent asked to take it; the agent answers with a `ShareStatus`; the share stops
/// when it is switched off or refused, and when the agent or the VM goes away. What differs per
/// device comes as closures.
@MainActor
final class GuestShare<Device: AnyObject> {
    /// Opens the Mac's side, hands it to `adopt` and, if taken, tells the guest to start. Throws when
    /// the Mac's side can't be opened.
    typealias Start = (_ share: GuestShare, _ session: AgentSession) async throws -> Void
    /// Closes the Mac's side; `session`, nil when the guest isn't to be told, gets the stop message.
    typealias Stop = (_ device: Device, _ session: AgentSession?) -> Void

    private(set) var state: GuestShareState = .off {
        willSet { owner?.objectWillChange.send() }
    }
    /// The running share; nil when it's off.
    private(set) var device: Device?

    private weak var owner: VirtualMachineController?
    /// For the log: "camera", "bluetooth".
    private let name: String
    /// What the agent's Hello lists when its guest can take the device.
    private let capability: String
    /// Why it failed when the guest doesn't say.
    private let refusal: String
    private let startDevice: Start
    private let stopDevice: Stop
    /// Sets up the guest's half over SSH; returns where it went, for the log.
    private let installGuestSide: () async throws -> String
    /// Whether the agent restarts once the guest's half is installed (then wait for it).
    private let installRestartsAgent: () -> Bool
    private let onReady: (ShareStatus) -> Void

    init(owner: VirtualMachineController, name: String, capability: String, refusal: String,
         start: @escaping Start, stop: @escaping Stop, install: @escaping () async throws -> String,
         installRestartsAgent: @escaping () -> Bool = { false }, onReady: @escaping (ShareStatus) -> Void = { _ in }) {
        self.owner = owner; self.name = name; self.capability = capability; self.refusal = refusal
        startDevice = start; stopDevice = stop; installGuestSide = install
        self.installRestartsAgent = installRestartsAgent; self.onReady = onReady
    }

    private var agent: AgentSession? { owner?.agent }
    private func log(_ line: String) { owner?.log.write(line) }

    /// The guest's agent can take the device.
    var offered: Bool { agent?.guestHello?.capabilities.contains(capability) == true }

    func set(_ on: Bool) async {
        guard on else { stop(tellGuest: true); return }
        guard let session = agent, offered, device == nil else { return }
        state = .starting
        do {
            try await startDevice(self, session)
        } catch {
            state = .failed(error.localizedDescription, guestSide: false)
        }
    }

    /// Makes the opened device the running share, before the guest is told to start; false (the
    /// caller drops it) when the switch went off or the agent changed while it opened.
    func adopt(_ opened: Device, for session: AgentSession) -> Bool {
        guard agent === session, state == .starting else { return false }
        device = opened
        return true
    }

    /// The guest's answer to the start message (the caller has checked it comes from the current agent).
    func statusArrived(_ status: ShareStatus) {
        guard device != nil else { return }
        if status.ready {
            state = .on(device: status.device ?? "")
            onReady(status)
        } else {
            fail(status.error ?? refusal, guestSide: status.installable ?? true)
        }
    }

    /// Stops the share and says why.
    func fail(_ reason: String, guestSide: Bool) {
        log("\(name): \(reason)")
        stop(tellGuest: true)
        state = .failed(reason, guestSide: guestSide)
    }

    /// `tellGuest` false when the agent or the VM is gone.
    func stop(tellGuest: Bool) {
        if let running = device {
            device = nil
            stopDevice(running, tellGuest ? agent.flatMap { $0.isReady ? $0 : nil } : nil)
            log("\(name) sharing stopped")
        }
        if state != .installing { state = .off }
    }

    /// Sets up the guest's half over SSH, then shares.
    func install() async throws {
        stop(tellGuest: true)
        state = .installing
        let before = agent
        do {
            let installed = try await installGuestSide()
            log("\(name) support installed in the guest (\(installed))")
        } catch {
            state = .failed(error.localizedDescription, guestSide: true)
            throw error
        }
        if installRestartsAgent() {
            // The agent restarted from its new place: wait for it to connect again.
            var waited = 0
            while waited < 60, !(agent !== before && agent?.isReady == true) {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
        }
        state = .off
        await set(true)
    }
}
