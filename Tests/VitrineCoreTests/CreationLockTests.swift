import Foundation
import XCTest
@testable import VitrineCore

/// A VM being created (files copied, macOS installing) is not a VM yet: it is locked against
/// starts, snapshots and deletion, hidden from the library, and a creation that never finished
/// (crash, quit, Ctrl-C) is moved to the Trash later, never deleted outright.
final class CreationLockTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vitrine-create-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("VITRINE_HOME", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("VITRINE_HOME")
        try? fm.removeItem(at: root)
    }

    private var marker: String { ".installing" }

    func testABundleBeingPopulatedIsLockedAndHidden() throws {
        let url = VMLibrary.bundleURL(named: "new")
        var seen: (locked: Bool, listed: Bool, started: Bool, marked: Bool)?
        let bundle = try VMBundle.create(at: url, config: VMConfig(name: "new", guestOS: .linux)) { bundle, _ in
            let other = VMBundle(url: bundle.url) // as another process sees it
            var started = true
            do { try other.acquireRunLock(role: .cli) } catch { started = false }
            seen = (other.isLocked, VMLibrary.list().contains(other), started,
                    self.fm.fileExists(atPath: bundle.url.appendingPathComponent(self.marker).path))
        }
        XCTAssertEqual(seen?.locked, true)
        XCTAssertEqual(seen?.listed, false)
        XCTAssertEqual(seen?.started, false)
        XCTAssertEqual(seen?.marked, true)
        // Finished: an ordinary VM.
        XCTAssertFalse(bundle.isLocked)
        XCTAssertTrue(VMLibrary.list().contains(bundle))
        XCTAssertFalse(fm.fileExists(atPath: bundle.url.appendingPathComponent(marker).path))
    }

    func testAsyncCreationToo() async throws {
        let url = VMLibrary.bundleURL(named: "async")
        var lockedDuring = false
        _ = try await VMBundle.create(at: url, config: VMConfig(name: "async", guestOS: .linux)) { bundle, _ async throws in
            lockedDuring = VMBundle(url: bundle.url).isLocked && !VMLibrary.list().contains(bundle)
        }
        XCTAssertTrue(lockedDuring)
    }

    /// What a crash during creation leaves: the marker, no lock holder.
    private func interruptedCreation(_ name: String) throws -> VMBundle {
        let bundle = try VMBundle.create(at: VMLibrary.bundleURL(named: name), config: VMConfig(name: name, guestOS: .linux))
        XCTAssertTrue(fm.createFile(atPath: bundle.url.appendingPathComponent(marker).path, contents: nil))
        return bundle
    }

    func testAnInterruptedCreationCantBeStartedAndIsHidden() throws {
        let bundle = try interruptedCreation("half")
        XCTAssertThrowsError(try bundle.acquireRunLock(role: .app))
        XCTAssertFalse(VMLibrary.list().contains(bundle))
        XCTAssertTrue(VMLibrary.list(includingInstalling: true).contains(bundle))
    }

    func testAnInterruptedCreationGoesToTheTrash() throws {
        let bundle = try interruptedCreation("Half Installed \(UUID().uuidString.prefix(6))")
        let trashed = try XCTUnwrap(try bundle.trashAbandonedCreation())
        defer { try? fm.removeItem(at: trashed) }
        XCTAssertFalse(fm.fileExists(atPath: bundle.url.path))
        XCTAssertTrue(fm.fileExists(atPath: trashed.appendingPathComponent("config.json").path))
    }

    func testACreationInProgressIsNotTrashed() throws {
        _ = try VMBundle.create(at: VMLibrary.bundleURL(named: "busy"), config: VMConfig(name: "busy", guestOS: .linux)) { bundle, _ in
            XCTAssertThrowsError(try VMBundle(url: bundle.url).trashAbandonedCreation())
            XCTAssertTrue(self.fm.fileExists(atPath: bundle.url.path))
        }
    }

    func testAFinishedVMIsNotTrashed() throws {
        let bundle = try VMBundle.create(at: VMLibrary.bundleURL(named: "done"), config: VMConfig(name: "done", guestOS: .linux)) { _, _ in }
        XCTAssertNil(try bundle.trashAbandonedCreation())
        XCTAssertTrue(fm.fileExists(atPath: bundle.url.path))
    }

    func testAFailedCreationLeavesNothing() throws {
        struct Boom: Error {}
        let url = VMLibrary.bundleURL(named: "fails")
        XCTAssertThrowsError(try VMBundle.create(at: url, config: VMConfig(name: "fails", guestOS: .linux)) { _, _ in throw Boom() })
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertFalse(VMBundle(url: url).holdsRunLock)
    }
}
