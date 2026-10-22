import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

/// Defaults that differ by architecture because the two paths have different bottlenecks.
final class WindowsCreatorDefaultsTests: XCTestCase {
    /// Arm64 guests run natively, so half the cores is plenty and leaves the host responsive.
    func testArm64DefaultIsHalfTheCores() {
        XCTAssertEqual(WindowsCreator.Options.defaultCPUCount(for: .aarch64, processors: 10), 5)
        // Floor of 4 even on a small machine.
        XCTAssertEqual(WindowsCreator.Options.defaultCPUCount(for: .aarch64, processors: 4), 4)
    }

    /// An emulated x64 guest is throughput-bound: 7-Zip went 4 426 → 8 330 MIPS from 4 → 8 vCPUs, so the
    /// default claims every core but two (an emulating vCPU thread never yields).
    func testX64DefaultLeavesTwoCoresForTheHost() {
        XCTAssertEqual(WindowsCreator.Options.defaultCPUCount(for: .x86_64, processors: 10), 8)
        XCTAssertEqual(WindowsCreator.Options.defaultCPUCount(for: .x86_64, processors: 16), 8) // capped
        XCTAssertEqual(WindowsCreator.Options.defaultCPUCount(for: .x86_64, processors: 8), 6)
        XCTAssertEqual(WindowsCreator.Options.defaultCPUCount(for: .x86_64, processors: 4), 4) // floor
    }

    /// The stored default cannot depend on `architecture`, so `create` re-derives it when the caller
    /// left the value alone. A caller who chose a count explicitly keeps it.
    func testStoredDefaultMatchesAarch64SoCreateCanDetectIt() {
        let untouched = WindowsCreator.Options(name: "w", installISO: URL(fileURLWithPath: "/i.iso"))
        XCTAssertEqual(untouched.cpuCount, WindowsCreator.Options.defaultCPUCount(for: .aarch64),
                       "the stored default must match the aarch64 figure for the comparison in create() to work")

        var explicit = WindowsCreator.Options(name: "w", installISO: URL(fileURLWithPath: "/i.iso"))
        explicit.cpuCount = 3
        XCTAssertNotEqual(explicit.cpuCount, WindowsCreator.Options.defaultCPUCount(for: .aarch64))
    }
}
