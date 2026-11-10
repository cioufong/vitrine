import XCTest
import Virtualization
import VitrineCore
import VitrineAgentProtocol
@testable import VitrineVZ

@MainActor
final class LifecycleRobustnessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeBundle(disposable: Bool = false) throws -> VMBundle {
        var config = VMConfig(name: "vm", guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [.init(path: "disk.img")]
        config.features.disposable = disposable
        let bundle = try VMBundle.create(at: root.appendingPathComponent("vm.vitrinevm"), config: config)
        try Data("disk".utf8).write(to: bundle.resolve("disk.img"))
        return bundle
    }

    private func log(_ bundle: VMBundle) -> String {
        (try? String(contentsOf: bundle.logURL, encoding: .utf8)) ?? ""
    }

    // MARK: Disposable wording (5b)

    /// A pending run whose baseline is gone keeps the VM's state, but not because disposable mode
    /// is off: the log must not say it is.
    func testMissingBaselineIsNotReportedAsDisposableModeOff() throws {
        let bundle = try makeBundle(disposable: true)
        let marker = bundle.url.appendingPathComponent("disposable-session.json")
        try Data(#"{"snapshot":"\#(UUID().uuidString)"}"#.utf8).write(to: marker)
        let controller = try VirtualMachineController(bundle: bundle)
        try bundle.acquireRunLock(); defer { bundle.releaseRunLock() }

        try controller.beginDisposableRunIfNeeded()

        XCTAssertFalse(log(bundle).contains("disposable mode is off"), log(bundle))
        XCTAssertTrue(log(bundle).contains("baseline"), log(bundle))
    }

    /// Switched off during the crashed run: that is what the line says.
    func testDisposableSwitchedOffIsReportedAsSuch() throws {
        let bundle = try makeBundle(disposable: true)
        try bundle.acquireRunLock()
        try DisposableSession(bundle: bundle).begin()
        var c = try bundle.loadConfig(); c.features.disposable = false; try bundle.saveConfig(c)
        let controller = try VirtualMachineController(bundle: bundle)

        try controller.beginDisposableRunIfNeeded()
        bundle.releaseRunLock()

        XCTAssertTrue(log(bundle).contains("(disposable mode is off)"), log(bundle))
    }

    // MARK: QMP reconnect resync (5a)

    /// After QMP reconnects, the run state QEMU reports wins: a "stop" or "cont" that timed out
    /// may still have taken effect.
    func testControlReconnectResyncsPausedAndRunning() throws {
        let controller = try VirtualMachineController(bundle: try makeBundle())
        controller.state = .running
        controller.controlReconnected(status: "paused")
        XCTAssertEqual(controller.state, .paused)
        controller.controlReconnected(status: "running")
        XCTAssertEqual(controller.state, .running)
        controller.controlReconnected(status: nil)
        XCTAssertEqual(controller.state, .running, "unknown status changes nothing")
        controller.controlReconnected(status: "inmigrate")
        XCTAssertEqual(controller.state, .running)
    }

    /// Transitions own the state: suspending sends "stop" itself, starting passes through inmigrate.
    func testControlReconnectLeavesTransitionsAlone() throws {
        let controller = try VirtualMachineController(bundle: try makeBundle())
        for s in [VirtualMachineController.RunState.suspending, .starting, .stopping, .error, .stopped] {
            controller.state = s
            controller.controlReconnected(status: "paused")
            controller.controlReconnected(status: "running")
            XCTAssertEqual(controller.state, s)
        }
    }

    // MARK: A VM left in .error with a live backend (1)

    final class FakeBackend: MachineBackend {
        var stopRequests = 0
        var stopsWhenAsked = false
        var hasStopped = false
        func requestStop() async -> Bool { stopRequests += 1; if stopsWhenAsked { hasStopped = true }; return true }
        func pause() async throws {}
        func resume() async throws {}
        func setNetworkCable(connected: Bool) async throws -> Bool { true }
        func connectAgent() async -> AgentChannel? { nil }
        func attachUSB(_ attachment: USBAttachment, id: String) async throws -> String? { nil }
        func detachUSB(_ attachment: USBAttachment, id: String) async throws {}
        func updateShares(_ config: VMConfig) throws {}
    }

    /// After a failed suspend whose recovery couldn't be confirmed, the VM is in .error but its
    /// backend still runs: quitting must not count it as shut down, so the user is asked to force it off.
    func testShutDownOfAnErroredLiveVMReportsItStillRunning() async throws {
        let controller = try VirtualMachineController(bundle: try makeBundle())
        controller.backendOverride = FakeBackend()
        controller.state = .error
        let stopped = await controller.shutDown(timeout: 0.1)
        XCTAssertFalse(stopped)
        XCTAssertEqual(controller.state, .error)
    }

    /// Quitting suspends first: a no-op "success" would let Vitrine quit with the backend running.
    func testSuspendOfAnErroredLiveVMFails() async throws {
        let controller = try VirtualMachineController(bundle: try makeBundle())
        controller.backendOverride = FakeBackend()
        controller.state = .error
        do {
            try await controller.suspend()
            XCTFail("suspend must fail")
        } catch {}
    }

    func testAnErroredLiveVMCanBeForcedOff() throws {
        let controller = try VirtualMachineController(bundle: try makeBundle())
        XCTAssertFalse(controller.hasLiveBackend)
        controller.backendOverride = FakeBackend()
        controller.state = .error
        XCTAssertTrue(controller.hasLiveBackend)
    }

    /// A stopped VM with no backend still shuts down "successfully" (nothing to do).
    func testShutDownOfAStoppedVMIsDone() async throws {
        let controller = try VirtualMachineController(bundle: try makeBundle())
        let stopped = await controller.shutDown(timeout: 0.1)
        XCTAssertTrue(stopped)
    }

    /// VZ: the guest powered off while suspending (its stop is ignored then) or the save failed and
    /// the VM couldn't be resumed. A stopped VM must be torn down, not left in .error owning the lock.
    func testFailedVZSuspendOfAStoppedVMTearsDown() {
        typealias C = VirtualMachineController
        XCTAssertEqual(C.outcomeOfFailedSuspend(.running), .running)
        XCTAssertEqual(C.outcomeOfFailedSuspend(.stopped), .stopped)
        XCTAssertEqual(C.outcomeOfFailedSuspend(.error), .stopped)
        XCTAssertEqual(C.outcomeOfFailedSuspend(.paused), .stuck, "still live: owned, Force Stop offered")
    }
}
