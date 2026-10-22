import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

final class WindowsDriversTests: XCTestCase {
    /// Uses the cached virtio-win ISO when present (downloaded by WindowsCreator.fetchVirtioWin).
    func testExtractsArm64Win11Drivers() throws {
        let iso = VMLibrary.cacheDirectory.appendingPathComponent("windows/virtio-win.iso")
        guard FileManager.default.fileExists(atPath: iso.path) else { throw XCTSkip("virtio-win.iso not cached") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("drv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        try WindowsCreator.extractDrivers(iso: iso, arch: .aarch64, to: dest)
        let netkvm = try FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent("NetKVM").path)
        XCTAssertTrue(netkvm.contains { $0.lowercased().hasSuffix(".inf") }, "NetKVM ARM64 driver missing: \(netkvm)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("vioserial").path))
    }
}
