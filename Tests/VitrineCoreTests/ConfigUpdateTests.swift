import Foundation
import XCTest
@testable import VitrineCore

/// Concurrent "load, change one field, save" edits all survive.
final class ConfigUpdateTests: XCTestCase {
    func testConcurrentWritersOfDifferentFieldsBothPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-update-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try VMBundle.create(at: root.appendingPathComponent("vm.vitrinevm"),
                                         config: VMConfig(name: "vm", guestOS: .linux, cpuCount: 0, memoryMiB: 1024))
        let rounds = 50
        DispatchQueue.concurrentPerform(iterations: 2) { writer in
            for _ in 0..<rounds {
                // Separate VMBundle values, as two processes would have.
                let b = VMBundle(url: bundle.url)
                do {
                    try b.updateConfig { c in if writer == 0 { c.cpuCount += 1 } else { c.notes += "x" } }
                } catch { XCTFail("\(error)") }
            }
        }
        let saved = try bundle.loadConfig()
        XCTAssertEqual(saved.cpuCount, rounds)
        XCTAssertEqual(saved.notes.count, rounds)
    }

    func testUnchangedConfigIsNotRewritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-update-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try VMBundle.create(at: root.appendingPathComponent("vm.vitrinevm"), config: VMConfig(name: "vm"))
        let before = try FileManager.default.attributesOfItem(atPath: bundle.configURL.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.01)
        try bundle.updateConfig { _ in }
        let after = try FileManager.default.attributesOfItem(atPath: bundle.configURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }
}
