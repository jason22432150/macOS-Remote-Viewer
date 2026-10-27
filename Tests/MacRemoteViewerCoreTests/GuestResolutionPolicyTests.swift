import XCTest
@testable import MacRemoteViewerCore

final class GuestResolutionPolicyTests: XCTestCase {
    func testRoundsToEvenIntegers() {
        XCTAssertEqual(
            GuestResolutionPolicy.frame(forViewSize: CGSize(width: 1281.4, height: 801.6)),
            RemoteFrame(width: 1280, height: 802)
        )
    }

    func testRejectsEmptyOrNonFiniteSize() {
        XCTAssertNil(GuestResolutionPolicy.frame(forViewSize: .zero))
        XCTAssertNil(GuestResolutionPolicy.frame(forViewSize: CGSize(width: -10, height: 800)))
        XCTAssertNil(GuestResolutionPolicy.frame(forViewSize: CGSize(width: CGFloat.nan, height: 800)))
        XCTAssertNil(GuestResolutionPolicy.frame(forViewSize: CGSize(width: CGFloat.infinity, height: 800)))
    }

    func testRejectsBelowMinimumAfterAlignment() {
        XCTAssertNil(GuestResolutionPolicy.frame(forViewSize: CGSize(width: 100, height: 100)))
        XCTAssertNil(GuestResolutionPolicy.frame(forViewSize: CGSize(width: 319, height: 200)))
    }

    func testAcceptsMinimumEvenSize() {
        XCTAssertEqual(
            GuestResolutionPolicy.frame(forViewSize: CGSize(width: 320, height: 200)),
            RemoteFrame(width: 320, height: 200)
        )
    }

    func testClampsToMaximumEvenSize() {
        XCTAssertEqual(
            GuestResolutionPolicy.frame(forViewSize: CGSize(width: 9000, height: 9001)),
            RemoteFrame(width: 8192, height: 8192)
        )
    }

    func testSkipsDuplicateOrAlreadyAppliedFrames() {
        let frame = RemoteFrame(width: 1280, height: 800)
        XCTAssertTrue(GuestResolutionPolicy.shouldRequest(frame, currentDisplay: nil, lastRequested: nil))
        XCTAssertFalse(GuestResolutionPolicy.shouldRequest(frame, currentDisplay: frame, lastRequested: nil))
        XCTAssertFalse(GuestResolutionPolicy.shouldRequest(frame, currentDisplay: nil, lastRequested: frame))
        XCTAssertTrue(
            GuestResolutionPolicy.shouldRequest(
                RemoteFrame(width: 1600, height: 900),
                currentDisplay: frame,
                lastRequested: frame
            )
        )
    }
}
