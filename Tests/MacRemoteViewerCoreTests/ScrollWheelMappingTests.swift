import XCTest
@testable import MacRemoteViewerCore

final class ScrollWheelMappingTests: XCTestCase {
    func testNaturalDirectionKeepsSign() {
        XCTAssertEqual(ScrollWheelMapping.guestDelta(3.5, inverted: false), 3.5)
        XCTAssertEqual(ScrollWheelMapping.guestDelta(-2, inverted: false), -2)
    }

    func testReversedDirectionNegatesDelta() {
        XCTAssertEqual(ScrollWheelMapping.guestDelta(3.5, inverted: true), -3.5)
        XCTAssertEqual(ScrollWheelMapping.guestDelta(-2, inverted: true), 2)
    }
}
