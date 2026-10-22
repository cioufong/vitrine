import XCTest
@testable import VitrineVZ

final class PastedTextTests: XCTestCase {
    func testNewlinesAndTabsBecomeKeysBetweenRuns() {
        XCTAssertEqual(PastedText.pieces("printf '字' > f; exit\n"), [.text("printf '字' > f; exit"), .key("ret")])
        XCTAssertEqual(PastedText.pieces("a\tb\r\n\nc"), [.text("a"), .key("tab"), .text("b"), .key("ret"), .key("ret"), .text("c")])
        XCTAssertEqual(PastedText.pieces("\n"), [.key("ret")])
        XCTAssertEqual(PastedText.pieces(""), [])
        XCTAssertEqual(PastedText.pieces("😀👍🏽"), [.text("😀👍🏽")])
    }
}
