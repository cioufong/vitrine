import XCTest
import VitrineCore
@testable import vitrinectl

/// The MCP tools take a VM by its library name only: a bundle path (say one pulled into
/// ~/Downloads, whose config shares the Mac's home) must not be opened or started.
final class MCPVMNameTests: XCTestCase {
    func testMCPToolsRefuseBundlePaths() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-name-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appendingPathComponent("crafted.vitrinevm")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for name in [bundle.path, dir.path + "/crafted", "../crafted.vitrinevm"] {
            XCTAssertThrowsError(try MCPServer.Arguments(values: ["name": name]).vm(), name)
        }
    }
}
