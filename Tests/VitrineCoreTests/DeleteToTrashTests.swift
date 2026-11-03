import Foundation
import XCTest
@testable import VitrineCore

/// Deleting a VM from the app moves it to the Trash so it can be put back. It used to be renamed to
/// a hidden `.vitrine-delete-…` first, which Finder doesn't show in the Trash.
final class DeleteToTrashTests: XCTestCase {
    func testTrashedVMKeepsItsName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-trash-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "Trash Me \(UUID().uuidString.prefix(8))"
        let source = try VMBundle.create(at: root.appendingPathComponent("\(name).vitrinevm"),
                                         config: VMConfig(name: name, guestOS: .linux))

        guard let trashed = try source.deleteSafely(trash: true) else { return XCTFail("no Trash location") }
        defer { try? FileManager.default.removeItem(at: trashed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("config.json").path))
        XCTAssertTrue(trashed.lastPathComponent.hasPrefix(name), trashed.lastPathComponent)
        XCTAssertFalse(trashed.lastPathComponent.hasPrefix("."))
    }

    func testDeleteRemovesTheVM() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-delete-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try VMBundle.create(at: root.appendingPathComponent("Gone.vitrinevm"),
                                         config: VMConfig(name: "Gone", guestOS: .linux))
        XCTAssertNil(try source.deleteSafely())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
