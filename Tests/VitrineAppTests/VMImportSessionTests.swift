import Foundation
import XCTest
@testable import VitrineApp
import VitrineCore
import VitrineVZ

/// The import sheet's non-UI logic: name checks, which plan warnings stay visible, guesses for disk
/// images and the engine's progress lines.
final class VMImportSessionTests: XCTestCase {
    func testNameProblemsFollowTheEngineRule() {
        let none: (String) -> Bool = { _ in false }
        XCTAssertEqual(VMImportSession.nameProblem("", exists: none), .empty)
        XCTAssertNil(VMImportSession.nameProblem("debian-12.12_arm", exists: none))
        for bad in ["My VM", ".hidden", "-x", "a/b", "../x", "名前", String(repeating: "a", count: 65)] {
            XCTAssertEqual(VMImportSession.nameProblem(bad, exists: none), .invalid, bad)
            XCTAssertFalse(VMCreationJob.isValidVMName(bad), bad)
        }
        XCTAssertEqual(VMImportSession.nameProblem("Taken", exists: { $0 == "Taken" }), .taken)
    }

    func testNameWarningsAreWorkedOutLive() {
        var plan = ImportPlan(format: .parallels, source: URL(fileURLWithPath: "/x.pvm"), sourceRoot: URL(fileURLWithPath: "/"),
                              name: "My-VM", cpuCount: 2, memoryMiB: 4096)
        plan.warn(.nameChanged, "named the VM My-VM")
        plan.warn(.nameTaken, "a VM named My-VM already exists")
        plan.warn(.emulated, "x86_64 guests are emulated")
        XCTAssertEqual(VMImportSession.visibleWarnings(plan, name: "My-VM").map(\.code), [.nameChanged, .emulated])
        XCTAssertEqual(VMImportSession.visibleWarnings(plan, name: "Other").map(\.code), [.emulated])
    }

    func testDiskImageGuesses() {
        XCTAssertTrue(VMImportSession.guessGuest(fromFileName: "debian-12-generic-arm64.qcow2") == (.linux, .aarch64))
        XCTAssertTrue(VMImportSession.guessGuest(fromFileName: "jammy-server-cloudimg-amd64.img") == (.linux, .x86_64))
        XCTAssertTrue(VMImportSession.guessGuest(fromFileName: "Win11_24H2_x64.vhdx") == (.windows, .x86_64))
        XCTAssertTrue(VMImportSession.guessGuest(fromFileName: "Windows11_InsiderPreview_Client_ARM64.vhdx") == (.windows, .aarch64))
        XCTAssertTrue(VMImportSession.guessGuest(fromFileName: "disk.vmdk") == (.linux, .aarch64))
        // "windowmaker" and "x64ish" words don't count as Windows or x86_64.
        XCTAssertTrue(VMImportSession.guessGuest(fromFileName: "darwin-box.qcow2") == (.linux, .aarch64))
    }

    func testProgressLines() {
        XCTAssertEqual(VMImportSession.localizedStatus("converting disk 2 of 3 (sata0:0, vmdk, 64.0 GiB)", kind: .wholeVM(.vmware)),
                       "Converting disk 2 of 3…")
        XCTAssertEqual(VMImportSession.localizedStatus("something new", kind: .wholeVM(.ova)), "something new")
        XCTAssertEqual(VMImportSession.localizedStatus("", kind: .diskImage), "Converting the disk…")
        XCTAssertEqual(VMImportSession.localizedStatus("", kind: .utm), "Copying the virtual machine…")
    }

    @MainActor func testUnimportableSourcesAreRefusedWithAReason() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-session-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appendingPathComponent("installer.iso")
        try Data("x".utf8).write(to: iso)
        let session = VMImportSession()
        var problem: String?
        XCTAssertFalse(session.begin(iso, problem: &problem))
        XCTAssertNotNil(problem)
        XCTAssertFalse(session.isActive)
    }
}
