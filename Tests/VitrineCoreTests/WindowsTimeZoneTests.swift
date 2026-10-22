import XCTest
@testable import VitrineCore

final class WindowsTimeZoneTests: XCTestCase {
    func testICUMapping() {
        XCTAssertEqual(WindowsTimeZone.id(forIANA: "Asia/Taipei"), "Taipei Standard Time")
        XCTAssertEqual(WindowsTimeZone.id(forIANA: "Asia/Shanghai"), "China Standard Time")
        XCTAssertEqual(WindowsTimeZone.id(forIANA: "America/New_York"), "Eastern Standard Time")
        XCTAssertNil(WindowsTimeZone.id(forIANA: "Not/AZone"))
        XCTAssertFalse(WindowsTimeZone.current.isEmpty)
    }
}
