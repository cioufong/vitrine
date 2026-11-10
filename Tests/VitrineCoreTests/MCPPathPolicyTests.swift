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

extension MCPPathPolicyTests {
    func testAncestorsOfProtectedRootsAreProtected() {
        // push_file "~" would scp -r the whole home; pull_file into it would merge into ~/.ssh and co.
        for p in [home.path, home.appendingPathComponent("Library").path,
                  home.appendingPathComponent("Library/Application Support").path,
                  tmp.path, "/"] {
            XCTAssertNotNil(policy.protectedRoot(for: p), p)
            XCTAssertNotNil(policy.protectedRoot(forDestination: p), p)
        }
        XCTAssertNil(policy.protectedRoot(forDestination: home.appendingPathComponent("Projects").path))
    }

    func testAllowListOpensAnAncestor() throws {
        try policy.setAllowed(home.path, true)
        XCTAssertNil(policy.protectedRoot(for: home.path))
        XCTAssertNil(policy.protectedRoot(for: home.appendingPathComponent(".ssh/id_ed25519").path))
        // Allowing one protected root doesn't open its parent, which still holds the others.
        try policy.setAllowed(home.path, false)
        try policy.setAllowed(home.appendingPathComponent(".ssh").path, true)
        XCTAssertNotNil(policy.protectedRoot(for: home.path))
    }

    // MARK: pull_file staging

    func staged(_ files: [String: String]) throws -> URL {
        let s = tmp.appendingPathComponent("staging-\(UUID().uuidString)")
        for (path, body) in files {
            let url = s.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        return s
    }

    func testPullIntoAFolderPlacesEntriesInside() throws {
        let s = try staged(["dir/a.txt": "a", "dir/sub/b.txt": "b"])
        let dest = home.appendingPathComponent("Projects")
        let plan = try policy.planDownload(staging: s, to: dest)
        XCTAssertTrue(plan.allSatisfy { $0.protectedRoot == nil })
        try policy.place(plan)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("dir/sub/b.txt"), encoding: .utf8), "b")
    }

    func testPullToANewPathRenamesTheSingleEntry() throws {
        let s = try staged(["x.txt": "x"])
        let dest = home.appendingPathComponent("Projects/renamed.txt")
        try policy.place(try policy.planDownload(staging: s, to: dest))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "x")
    }

    func testPullIntoHomeFlagsEveryProtectedDestination() throws {
        // A guest folder holding .ssh, .zshrc and Library/LaunchAgents, pulled with its contents into ~.
        let s = try staged([".ssh/authorized_keys": "evil", ".zshrc": "evil", "Library/LaunchAgents/x.plist": "evil",
                            "notes.txt": "fine"])
        let plan = try policy.planDownload(staging: s, to: home)
        let flagged = Set(plan.filter { $0.protectedRoot != nil }.map { $0.destination.path })
        for p in [".ssh", ".ssh/authorized_keys", ".zshrc", "Library", "Library/LaunchAgents", "Library/LaunchAgents/x.plist"] {
            XCTAssertTrue(flagged.contains(home.appendingPathComponent(p).path), p)
        }
        XCTAssertFalse(flagged.contains(home.appendingPathComponent("notes.txt").path))
    }

    func testApprovingADestinationCoversOnlyItsOwnProtectedRoot() throws {
        // The user approved writing to ~/.ssh: a file under it is covered, nothing else is.
        let ssh = MCPPathPolicy.resolve(home.appendingPathComponent(".ssh").path)
        let s = try staged([".ssh/authorized_keys": "k", ".zshrc": "evil", "notes.txt": "fine"])
        let plan = try policy.planDownload(staging: s, to: home)
        let left = Set(MCPPathPolicy.needingApproval(plan, approved: ssh).map { $0.destination.lastPathComponent })
        XCTAssertEqual(left, [".zshrc"])
        // Approving an ancestor (were it possible) would not cover the protected roots inside it.
        let all = Set(MCPPathPolicy.needingApproval(plan, approved: MCPPathPolicy.resolve(home.path)).map { $0.destination.lastPathComponent })
        XCTAssertEqual(all, [".ssh", "authorized_keys", ".zshrc"])
        XCTAssertEqual(MCPPathPolicy.needingApproval(plan, approved: nil).count, 3)
    }

    func testPullOfAReadOnlyFolderWorks() throws {
        let s = try staged(["ro/a.txt": "a"])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: s.appendingPathComponent("ro").path)
        let dest = home.appendingPathComponent("Projects")
        try policy.place(try policy.planDownload(staging: s, to: dest))
        let ro = dest.appendingPathComponent("ro")
        XCTAssertEqual(try String(contentsOf: ro.appendingPathComponent("a.txt"), encoding: .utf8), "a")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: ro.path)[.posixPermissions] as? NSNumber)?.intValue, 0o555)
        for d in [ro, s.appendingPathComponent("ro")] {  // so tearDown can delete them
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path)
        }
    }

    func testPullThroughAnExistingSymlinkIsFlagged() throws {
        // ~/Projects/innocent -> ~/.ssh: merging a folder named "innocent" writes into ~/.ssh.
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Projects/innocent"),
                                                   withDestinationURL: home.appendingPathComponent(".ssh"))
        let s = try staged(["innocent/authorized_keys": "evil"])
        let plan = try policy.planDownload(staging: s, to: home.appendingPathComponent("Projects"))
        XCTAssertTrue(plan.contains { $0.protectedRoot != nil && $0.destination.lastPathComponent == "authorized_keys" })
    }

    func testPullRefusesSymlinksPointingOutOfTheDownload() throws {
        for target in ["../../home/.ssh", "/etc/passwd", home.appendingPathComponent(".ssh").path] {
            let s = try staged(["dir/ok.txt": "ok"])
            try FileManager.default.createSymbolicLink(atPath: s.appendingPathComponent("dir/link").path,
                                                       withDestinationPath: target)
            XCTAssertThrowsError(try policy.planDownload(staging: s, to: home.appendingPathComponent("Projects")), target)
        }
        // A link that stays inside what was downloaded is fine.
        let s = try staged(["dir/ok.txt": "ok"])
        try FileManager.default.createSymbolicLink(atPath: s.appendingPathComponent("dir/link").path, withDestinationPath: "ok.txt")
        XCTAssertNoThrow(try policy.planDownload(staging: s, to: home.appendingPathComponent("Projects")))
    }
}

final class LibraryNameTests: XCTestCase {
    func testOnlyBareNamesInTheLibraryResolve() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lib-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = tmp.appendingPathComponent("VMs"), outside = tmp.appendingPathComponent("Downloads")
        for d in [lib.appendingPathComponent("good.vitrinevm"), outside.appendingPathComponent("evil.vitrinevm")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("linked.vitrinevm"),
                                                   withDestinationURL: outside.appendingPathComponent("evil.vitrinevm"))
        XCTAssertEqual(try VMLibrary.findByName("good", in: lib).name, "good")
        for name in [outside.appendingPathComponent("evil.vitrinevm").path, "../Downloads/evil", "good.vitrinevm",
                     "~/good", "linked", "missing", ""] {
            XCTAssertThrowsError(try VMLibrary.findByName(name, in: lib), name)
        }
        // The CLI keeps taking paths.
        XCTAssertNoThrow(try VMLibrary.find(outside.appendingPathComponent("evil.vitrinevm").path))
    }
}
