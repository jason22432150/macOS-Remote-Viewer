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

    func testCommonPresetsAreEvenAndInRange() {
        XCTAssertTrue(RemoteResolutionPreset.common.contains(RemoteResolutionPreset(width: 1920, height: 1080)))
        for preset in RemoteResolutionPreset.common {
            let frame = GuestResolutionPolicy.targetFrame(
                preference: .preset(preset.frame),
                windowSize: nil
            )
            XCTAssertEqual(frame, preset.frame)
            XCTAssertEqual(preset.width % 2, 0)
            XCTAssertEqual(preset.height % 2, 0)
        }
    }

    func testTargetFrameUsesWindowOnlyWhenMatching() {
        XCTAssertEqual(
            GuestResolutionPolicy.targetFrame(
                preference: .matchWindow,
                windowSize: CGSize(width: 1600, height: 900)
            ),
            RemoteFrame(width: 1600, height: 900)
        )
        XCTAssertNil(GuestResolutionPolicy.targetFrame(preference: .matchWindow, windowSize: nil))
        XCTAssertNil(GuestResolutionPolicy.targetFrame(preference: .keepGuest, windowSize: CGSize(width: 1600, height: 900)))
        XCTAssertEqual(
            GuestResolutionPolicy.targetFrame(
                preference: .preset(RemoteFrame(width: 1920, height: 1080)),
                windowSize: CGSize(width: 800, height: 600)
            ),
            RemoteFrame(width: 1920, height: 1080)
        )
    }
}
