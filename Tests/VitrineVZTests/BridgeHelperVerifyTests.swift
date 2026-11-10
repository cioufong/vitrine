import XCTest
@testable import VitrineVZ

/// The install path minus the administrator prompt: the same compiled-in script text, quoting and
/// osascript call, with the unprivileged `verify` and `stage` steps root runs on its staged copy.
final class BridgeHelperVerifyTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bridged-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// An ad-hoc-signed copy of a system binary, standing in for vitrine-bridged, signed with the
    /// identifier build-app.sh gives it.
    func adhocBinary(_ name: String, from source: String, identifier: String = "vitrine-bridged") throws -> URL {
        let url = dir.appendingPathComponent(name)
        // One slice, like build-app.sh's vitrine-bridged (each slice of a universal binary has its own cdhash).
        XCTAssertEqual(try run("/usr/bin/lipo", [source, "-thin", "arm64e", "-output", url.path]).status, 0)
        XCTAssertEqual(try run("/usr/bin/codesign", ["-s", "-", "-f", "--identifier", identifier, url.path]).status, 0)
        return url
    }

    func run(_ tool: String, _ args: [String]) throws -> (status: Int32, err: String, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe(), out = Pipe()
        p.standardError = err
        p.standardOutput = out
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs the compiled-in script with `args` the way runAsAdmin does, minus `with administrator privileges`.
    func throughOsascript(_ args: [String]) throws -> (status: Int32, err: String, out: String) {
        try run("/usr/bin/osascript", ["-e", BridgeHelper.appleScript(BridgeHelper.adminCommand(script: BridgeHelper.script, args))])
    }

    func verifyThroughOsascript(_ file: URL, _ requirement: String) throws -> Int32 {
        try throughOsascript(["verify", file.path, requirement]).status
    }

    func staging() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".vitrine-bridged.") }) ?? []
    }

    func testTheExpectedBinaryPasses() throws {
        let bin = try adhocBinary("vitrine-bridged", from: "/usr/bin/true")
        let req = try BridgeHelper.codeRequirement(for: bin, teamID: nil)
        XCTAssertTrue(req.hasPrefix("identifier \"vitrine-bridged\" and cdhash H\""), req)
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
        XCTAssertTrue(req.hasPrefix("anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"vitrine-bridged\" and cdhash H\""), req)
        // An ad-hoc binary can't satisfy a Team ID anchor.
        XCTAssertNotEqual(try verifyThroughOsascript(bin, req), 0)
        XCTAssertThrowsError(try BridgeHelper.codeRequirement(for: bin, teamID: "X\" or true"))
    }

    func testUniversalBinariesAreRefused() {
        XCTAssertThrowsError(try BridgeHelper.codeRequirement(for: URL(fileURLWithPath: "/usr/bin/true"), teamID: nil))
    }

    func testABinaryWithAnotherIdentifierIsRefused() throws {
        // What a plain `swift build` leaves: the linker's vitrine-bridged-<hash>.
        let bin = try adhocBinary("vitrine-bridged", from: "/usr/bin/true", identifier: "vitrine-bridged-0123abcd")
        XCTAssertThrowsError(try BridgeHelper.codeRequirement(for: bin, teamID: nil))
    }

    func testTheIdentifierClauseIsEnforced() throws {
        // The right cdhash but the requirement's identifier differs: codesign must refuse.
        let bin = try adhocBinary("vitrine-bridged", from: "/usr/bin/true")
        let req = try BridgeHelper.codeRequirement(for: bin, teamID: nil)
        XCTAssertEqual(try verifyThroughOsascript(bin, req), 0)
        let other = req.replacingOccurrences(of: "identifier \"vitrine-bridged\"", with: "identifier \"vitrine-bridgee\"")
        XCTAssertNotEqual(other, req)
        XCTAssertNotEqual(try verifyThroughOsascript(bin, other), 0)
    }

    func testStagingKeepsTheCopyRootOnlyAndVerified() throws {
        let bin = try adhocBinary("vitrine-bridged", from: "/usr/bin/true")
        let req = try BridgeHelper.codeRequirement(for: bin, teamID: nil)
        let r = try throughOsascript(["stage", bin.path, dir.path, req])
        XCTAssertEqual(r.status, 0, r.err)
        let staged = URL(fileURLWithPath: r.out)
        XCTAssertEqual(staged.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path,
                       dir.resolvingSymlinksInPath().path)
        let fm = FileManager.default
        let fileAttrs = try fm.attributesOfItem(atPath: staged.path)
        XCTAssertEqual(fileAttrs[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((fileAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let dirAttrs = try fm.attributesOfItem(atPath: staged.deletingLastPathComponent().path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: bin))
    }

    func testStagingRefusesASymlinkedSource() throws {
        let bin = try adhocBinary("vitrine-bridged", from: "/usr/bin/true")
        let req = try BridgeHelper.codeRequirement(for: bin, teamID: nil)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bin)
        let r = try throughOsascript(["stage", link.path, dir.path, req])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.err.contains("not a regular file"), r.err)
        XCTAssertEqual(staging(), [])
    }

    func testStagingRefusesAFIFOWithoutReadingIt() throws {
        let fifo = dir.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let r = try throughOsascript(["stage", fifo.path, dir.path, "identifier \"vitrine-bridged\""])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(staging(), [])
    }

    func testAFailedVerificationLeavesNothingStaged() throws {
        let expected = try adhocBinary("vitrine-bridged", from: "/usr/bin/true")
        let req = try BridgeHelper.codeRequirement(for: expected, teamID: nil)
        let other = try adhocBinary("vitrine-bridged-swapped", from: "/usr/bin/false")
        let r = try throughOsascript(["stage", other.path, dir.path, req])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.err.contains("not installing"), r.err)
        XCTAssertEqual(staging(), [])
    }
}
