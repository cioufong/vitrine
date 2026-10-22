import XCTest
import Virtualization
@testable import VitrineVZ
@testable import VitrineCore

final class DiskCachingTests: XCTestCase {
    /// Linux guests must not get the framework's automatic caching: it hands them zeroed pages.
    func testLinuxAutomaticUsesHostCacheWithFullSync() {
        let (caching, sync) = ConfigurationBuilder.diskModes(.automatic, guestOS: .linux)
        XCTAssertEqual(caching, .cached)
        XCTAssertEqual(sync, .full)
    }

    func testMacAutomaticKeepsFrameworkDefault() {
        let (caching, sync) = ConfigurationBuilder.diskModes(.automatic, guestOS: .macOS)
        XCTAssertEqual(caching, .automatic)
        XCTAssertEqual(sync, .full)
    }

    func testExplicitModesAreUnchanged() {
        for os in [VMConfig.GuestOS.linux, .macOS] {
            XCTAssertTrue(ConfigurationBuilder.diskModes(.fast, guestOS: os) == (.cached, .fsync))
            XCTAssertTrue(ConfigurationBuilder.diskModes(.uncached, guestOS: os) == (.uncached, .full))
        }
    }
}
