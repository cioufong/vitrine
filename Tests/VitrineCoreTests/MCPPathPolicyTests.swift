import XCTest
@testable import VitrineCore

final class MCPPathPolicyTests: XCTestCase {
    var tmp: URL!, home: URL!, library: URL!, policy: MCPPathPolicy!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-policy-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = tmp.appendingPathComponent("home"); library = tmp.appendingPathComponent("lib")
        for d in [home!, library!, home.appendingPathComponent(".ssh"), home.appendingPathComponent("Projects"),
                  home.appendingPathComponent("Library/Application Support/Vitrine")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try Data("key".utf8).write(to: home.appendingPathComponent(".ssh/id_ed25519"))
        try Data("pw".utf8).write(to: library.appendingPathComponent("guest-account.secret"))
        policy = MCPPathPolicy(home: home, libraryRoot: library,
                               allowListURL: home.appendingPathComponent("Library/Application Support/Vitrine/mcp-allowed-paths"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testOrdinaryPathsAreAllowed() {
        XCTAssertNil(policy.protectedRoot(for: home.appendingPathComponent("Projects").path))
        XCTAssertNil(policy.protectedRoot(for: home.appendingPathComponent("Projects/new/out.txt").path)) // not there yet
        XCTAssertNil(policy.protectedRoot(for: "/tmp"))
    }

    func testSecretsAndAutorunLocationsAreProtected() {
        for p in [".ssh/id_ed25519", ".zshrc", "Library/LaunchAgents/x.plist", ".claude/settings.json",
                  "Library/Application Support/Vitrine/mcp-allowed-paths"] {
            XCTAssertNotNil(policy.protectedRoot(for: home.appendingPathComponent(p).path), p)
        }
        XCTAssertNotNil(policy.protectedRoot(for: library.appendingPathComponent("guest-account.secret").path))
        XCTAssertNotNil(policy.protectedRoot(for: "/Library/LaunchDaemons/evil.plist"))
    }

    func testCaseAndDotSegmentsDoNotBypass() {
        XCTAssertNotNil(policy.protectedRoot(for: home.appendingPathComponent(".SSH/id_ed25519").path))
        XCTAssertNotNil(policy.protectedRoot(for: home.appendingPathComponent("Projects/../.ssh/id_ed25519").path))
    }

    func testSymlinksAreFollowed() throws {
        let link = home.appendingPathComponent("Projects/innocent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent(".ssh"))
        XCTAssertNotNil(policy.protectedRoot(for: link.appendingPathComponent("id_ed25519").path))
        // A folder whose contents link into a protected place (scp -r copies the target).
        XCTAssertNotNil(policy.protectedRoot(for: home.appendingPathComponent("Projects").path))
    }

    func testAllowListOpensAProtectedPath() throws {
        let key = home.appendingPathComponent(".ssh/id_ed25519").path
        try policy.setAllowed(home.appendingPathComponent(".ssh").path, true)
        XCTAssertNil(policy.protectedRoot(for: key))
        try policy.setAllowed(home.appendingPathComponent(".ssh").path, false)
        XCTAssertNotNil(policy.protectedRoot(for: key))
    }
}
