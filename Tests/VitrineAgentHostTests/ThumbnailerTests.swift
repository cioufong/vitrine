import CoreImage
import XCTest
@testable import VitrineAgentHost

final class ThumbnailerTests: XCTestCase {
    /// 200×100 frame, white in its top half as the guest sees it (Core Image's origin is bottom left).
    private let frame = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 50, width: 200, height: 50))
        .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)))

    func testMeanColorUsesTopLeftOrigin() throws {
        let top = try XCTUnwrap(Thumbnailer.meanColor(of: frame, in: CGRect(x: 10, y: 10, width: 40, height: 30)))
        let bottom = try XCTUnwrap(Thumbnailer.meanColor(of: frame, in: CGRect(x: 10, y: 60, width: 40, height: 30)))
        XCTAssertEqual(top, [255, 255, 255])
        XCTAssertEqual(bottom, [0, 0, 0])
        // Straddling the edge: half white, half black.
        let mixed = try XCTUnwrap(Thumbnailer.meanColor(of: frame, in: CGRect(x: 0, y: 25, width: 200, height: 50)))
        XCTAssertEqual(mixed[0], 188, accuracy: 3) // 50% linear light is sRGB ~188
    }

    func testMeanColorClipsToTheFrame() {
        XCTAssertNotNil(Thumbnailer.meanColor(of: frame, in: CGRect(x: 190, y: 90, width: 40, height: 40)))
        XCTAssertNil(Thumbnailer.meanColor(of: frame, in: CGRect(x: 300, y: 10, width: 10, height: 10)))
    }
}
