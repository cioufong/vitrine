import Foundation
import XCTest
import VitrineNet

/// vitrine-bridged's /var/run/vitrine check, run unprivileged against a directory this user owns.
final class SocketDirectoryTests: XCTestCase {
    var base: URL!
    var path: String { base.appendingPathComponent("vitrine").path }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sockdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func mode(_ p: String) -> mode_t { var st = stat(); XCTAssertEqual(lstat(p, &st), 0); return st.st_mode }

    func testCreatesAMissingDirectory() throws {
        try SocketDirectory.prepare(path, owner: getuid())
        XCTAssertEqual(mode(path) & S_IFMT, S_IFDIR)
        XCTAssertEqual(mode(path) & 0o7777, 0o755)
    }

    func testTakesAwayGroupAndWorldWrite() throws {
        XCTAssertEqual(mkdir(path, 0o700), 0)
        XCTAssertEqual(chmod(path, 0o777), 0)
        try SocketDirectory.prepare(path, owner: getuid())
        XCTAssertEqual(mode(path) & 0o7777, 0o755)
    }

    func testReplacesASymlinkWithoutTouchingItsTarget() throws {
        let target = base.appendingPathComponent("elsewhere").path
        XCTAssertEqual(mkdir(target, 0o777), 0)
        XCTAssertEqual(chmod(target, 0o777), 0)
        XCTAssertEqual(symlink(target, path), 0)
        try SocketDirectory.prepare(path, owner: getuid())
        XCTAssertEqual(mode(path) & S_IFMT, S_IFDIR)
        XCTAssertEqual(mode(target) & 0o7777, 0o777)
    }

    func testReplacesAFile() throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
        try SocketDirectory.prepare(path, owner: getuid())
        XCTAssertEqual(mode(path) & S_IFMT, S_IFDIR)
    }

    func testRefusesADirectoryOwnedBySomeoneElse() throws {
        XCTAssertEqual(mkdir(path, 0o755), 0)
        // This user's directory, checked as if root had to own it.
        XCTAssertThrowsError(try SocketDirectory.prepare(path, owner: getuid() == 0 ? 501 : 0)) {
            XCTAssertTrue("\($0)".contains("owned by uid"), "\($0)")
        }
    }
}
