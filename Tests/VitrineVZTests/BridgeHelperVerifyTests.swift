import XCTest
@testable import VitrineVZ

/// The install path minus the administrator prompt: the same script text, quoting and osascript
/// call, with the unprivileged `verify` step root runs on its staged copy.
final class BridgeHelperVerifyTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bridged-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// An ad-hoc-signed copy of a system binary, standing in for vitrine-bridged.
    func adhocBinary(_ name: String, from source: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        // One slice, like build-app.sh's vitrine-bridged (each slice of a universal binary has its own cdhash).
        XCTAssertEqual(try run("/usr/bin/lipo", [source, "-thin", "arm64e", "-output", url.path]).status, 0)
        XCTAssertEqual(try run("/usr/bin/codesign", ["-s", "-", "-f", url.path]).status, 0)
        return url
    }

    func run(_ tool: String, _ args: [String]) throws -> (status: Int32, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func verifyThroughOsascript(_ file: URL, _ requirement: String) throws -> Int32 {
        let script = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Resources/bridge-helper.sh").standardizedFileURL, encoding: .utf8)
        let command = BridgeHelper.adminCommand(script: script, ["verify", file.path, requirement])
        return try run("/usr/bin/osascript", ["-e", "do shell script \"\(BridgeHelper.appleScriptEscape(command))\""]).status
    }

    func testTheExpectedBinaryPasses() throws {
        let bin = try adhocBinary("vitrine-bridged", from: "/usr/bin/true")
        let req = try BridgeHelper.codeRequirement(for: bin, teamID: nil)
        XCTAssertTrue(req.hasPrefix("cdhash H\""))
        XCTAssertEqual(try verifyThroughOsascript(bin, req), 0)
    }

    func testAModifiedBinaryFails() throws {
        let bin = try adhocBinary("vitrine-bridged", from: "/usr/bin/true")
        let req = try BridgeHelper.codeRequirement(for: bin, teamID: nil)
        let h = try FileHandle(forUpdating: bin)
        try h.seek(toOffset: 0x4000)
        let b = try XCTUnwrap(h.readData(ofLength: 1).first)
        try h.seek(toOffset: 0x4000)
        h.write(Data([b ^ 0xFF]))
        try h.close()
        XCTAssertNotEqual(try verifyThroughOsascript(bin, req), 0)
    }

    func testAnotherSignedBinaryFails() throws {
        let expected = try adhocBinary("vitrine-bridged", from: "/usr/bin/true")
        let req = try BridgeHelper.codeRequirement(for: expected, teamID: nil)
        // Re-signed by "anyone running as the user": a valid signature, the wrong code.
        let other = try adhocBinary("vitrine-bridged-swapped", from: "/usr/bin/false")
        XCTAssertNotEqual(try verifyThroughOsascript(other, req), 0)
    }

    func testTeamSignedRequirementAnchorsToTheTeam() throws {
        let bin = try adhocBinary("vitrine-bridged", from: "/usr/bin/true")
        let req = try BridgeHelper.codeRequirement(for: bin, teamID: "ABCDE12345")
        XCTAssertTrue(req.hasPrefix("anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and cdhash H\""))
        // An ad-hoc binary can't satisfy a Team ID anchor.
        XCTAssertNotEqual(try verifyThroughOsascript(bin, req), 0)
        XCTAssertThrowsError(try BridgeHelper.codeRequirement(for: bin, teamID: "X\" or true"))
    }

    func testUniversalBinariesAreRefused() {
        XCTAssertThrowsError(try BridgeHelper.codeRequirement(for: URL(fileURLWithPath: "/usr/bin/true"), teamID: nil))
    }
}
