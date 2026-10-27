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

    func testLineScrollingUsesMouseWheelSensitivity() {
        XCTAssertEqual(
            ScrollWheelMapping.guestDelta(
                4,
                inverted: false,
                hasPreciseScrollingDeltas: false,
                mouseWheelSensitivity: 2,
                trackpadScrollSensitivity: 0.5
            ),
            8
        )
    }

    func testPreciseScrollingUsesTrackpadSensitivityAndBaseScale() {
        XCTAssertEqual(
            ScrollWheelMapping.guestDelta(
                4,
                inverted: false,
                hasPreciseScrollingDeltas: true,
                mouseWheelSensitivity: 2,
                trackpadScrollSensitivity: 0.5
            ),
            4 * 0.5 * ScrollWheelMapping.preciseScrollBaseScale
        )
    }

    func testSensitivityAppliesAfterDirectionInvert() {
        XCTAssertEqual(
            ScrollWheelMapping.guestDelta(
                3,
                inverted: true,
                hasPreciseScrollingDeltas: false,
                mouseWheelSensitivity: 2,
                trackpadScrollSensitivity: 1
            ),
            -6
        )
    }

    func testOutOfRangeSensitivityIsClampedBeforeScaling() {
        XCTAssertEqual(
            ScrollWheelMapping.guestDelta(
                2,
                inverted: false,
                hasPreciseScrollingDeltas: false,
                mouseWheelSensitivity: 100,
                trackpadScrollSensitivity: 1
            ),
            8
        )
        XCTAssertEqual(
            ScrollWheelMapping.guestDelta(
                8,
                inverted: false,
                hasPreciseScrollingDeltas: true,
                mouseWheelSensitivity: 1,
                trackpadScrollSensitivity: 0
            ),
            8 * ScrollWheelMapping.minimumSensitivity * ScrollWheelMapping.preciseScrollBaseScale
        )
    }

    func testMinimumSensitivityIsSlowerThanPreviousQuarterScale() {
        XCTAssertEqual(ScrollWheelMapping.minimumSensitivity, 0.05)
        XCTAssertLessThan(ScrollWheelMapping.minimumSensitivity, 0.25)
    }

    func testClampSensitivityRejectsNonFiniteAndOutOfRangeValues() {
        XCTAssertEqual(ScrollWheelMapping.clampSensitivity(1), 1)
        XCTAssertEqual(ScrollWheelMapping.clampSensitivity(0.05), 0.05)
        XCTAssertEqual(ScrollWheelMapping.clampSensitivity(0.25), 0.25)
        XCTAssertEqual(ScrollWheelMapping.clampSensitivity(4), 4)
        XCTAssertEqual(ScrollWheelMapping.clampSensitivity(0), ScrollWheelMapping.minimumSensitivity)
        XCTAssertEqual(ScrollWheelMapping.clampSensitivity(100), ScrollWheelMapping.maximumSensitivity)
        XCTAssertEqual(ScrollWheelMapping.clampSensitivity(.nan), ScrollWheelMapping.defaultSensitivity)
        XCTAssertEqual(ScrollWheelMapping.clampSensitivity(.infinity), ScrollWheelMapping.maximumSensitivity)
        XCTAssertEqual(ScrollWheelMapping.clampSensitivity(-.infinity), ScrollWheelMapping.minimumSensitivity)
    }

    func testPreferenceSensitivityRangeMatchesMapping() {
        XCTAssertEqual(ScrollSensitivity.default, ScrollWheelMapping.defaultSensitivity)
        XCTAssertEqual(ScrollSensitivity.minimum, ScrollWheelMapping.minimumSensitivity)
        XCTAssertEqual(ScrollSensitivity.maximum, ScrollWheelMapping.maximumSensitivity)
        XCTAssertEqual(ScrollSensitivity.step, 0.05)
        XCTAssertEqual(ScrollSensitivity.clamp(100), ScrollWheelMapping.clampSensitivity(100))
        XCTAssertEqual(ScrollSensitivity.clamp(0), ScrollWheelMapping.clampSensitivity(0))
    }
}
