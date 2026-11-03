import Foundation
import XCTest
@testable import VitrineCore

/// An unknown network mode used to load as NAT: a guest meant to be offline or host-only got the
/// internet, and the next save wrote NAT over the original value.
final class NetworkModeDecodingTests: XCTestCase {
    private func config(network: String) -> Data {
        Data(#"{"version":1,"id":"\#(UUID())","name":"n","guestOS":"linux","cpuCount":2,"memoryMiB":4096,"disks":[],"shares":[],"network":\#(network),"display":{"widthPixels":1,"heightPixels":1,"pixelsPerInch":1,"autoResize":true},"features":{},"notes":""}"#.utf8)
    }

    func testUnknownModeIsRefused() {
        XCTAssertThrowsError(try JSONDecoder().decode(VMConfig.self, from: config(network: #"{"mode":"isolated"}"#))) { error in
            XCTAssertTrue("\(error)".contains("unknown network mode \"isolated\""), "\(error)")
        }
    }

    func testMissingModeIsNAT() throws {
        XCTAssertEqual(try JSONDecoder().decode(VMConfig.self, from: config(network: "{}")).network.mode, .nat)
    }

    func testKnownModesRoundTrip() throws {
        for mode in VMConfig.NetworkConfig.Mode.allCases {
            var c = VMConfig(name: "n", guestOS: .linux, cpuCount: 2, memoryMiB: 4096)
            c.network.mode = mode
            let back = try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(c))
            XCTAssertEqual(back.network.mode, mode)
        }
    }

    /// `vitrinectl list` (and the app) still show a VM whose config can't be read.
    func testLoadConfigNamesTheBadMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-mode-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try VMBundle.create(at: root.appendingPathComponent("x.vitrinevm"),
                                    config: VMConfig(name: "x", guestOS: .linux, cpuCount: 2, memoryMiB: 4096))
        try config(network: #"{"mode":"isolated"}"#).write(to: b.configURL)
        XCTAssertThrowsError(try b.loadConfig()) { error in
            XCTAssertTrue(error.localizedDescription.contains("isolated"), error.localizedDescription)
        }
    }
}
