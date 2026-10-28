import XCTest
@testable import MacRemoteViewerCore

final class WindowPresentationPolicyTests: XCTestCase {
    func testReturnsNoneWhenThereAreNoPresentableWindows() {
        XCTAssertEqual(WindowPresentationPolicy.action(for: []), .none)
        XCTAssertEqual(
            WindowPresentationPolicy.action(for: [
                .panel(isVisible: true),
                .unpresentable,
            ]),
            .none
        )
    }

    func testPrefersVisibleMainWindowOverPanelAndHiddenWindows() {
        let windows = [
            WindowPresentationCandidate.panel(isVisible: true),
            WindowPresentationCandidate(canBecomeMain: true, isVisible: false, isMiniaturized: false, isPanel: false),
            WindowPresentationCandidate(canBecomeMain: true, isVisible: true, isMiniaturized: false, isPanel: false),
        ]

        XCTAssertEqual(WindowPresentationPolicy.action(for: windows), .orderFront(index: 2))
    }

    func testDeminiaturizesCollapsedMainWindow() {
        let windows = [
            WindowPresentationCandidate.panel(isVisible: true),
            WindowPresentationCandidate(canBecomeMain: true, isVisible: false, isMiniaturized: true, isPanel: false),
        ]

        XCTAssertEqual(
            WindowPresentationPolicy.action(for: windows),
            .deminiaturizeAndOrderFront(index: 1)
        )
    }

    func testOrdersFrontHiddenMainWindowWhenNothingIsVisible() {
        let windows = [
            WindowPresentationCandidate(canBecomeMain: true, isVisible: false, isMiniaturized: false, isPanel: false),
        ]

        XCTAssertEqual(WindowPresentationPolicy.action(for: windows), .orderFront(index: 0))
    }

    func testPrefersFirstVisibleMainWindowWhenSeveralExist() {
        let windows = [
            WindowPresentationCandidate(canBecomeMain: true, isVisible: true, isMiniaturized: false, isPanel: false),
            WindowPresentationCandidate(canBecomeMain: true, isVisible: true, isMiniaturized: false, isPanel: false),
        ]

        XCTAssertEqual(WindowPresentationPolicy.action(for: windows), .orderFront(index: 0))
    }

    func testRetriesAfterSceneReadyOnlyWhenNoWindowExistsYet() {
        XCTAssertTrue(WindowPresentationPolicy.shouldRetryAfterSceneReady(.none))
        XCTAssertFalse(WindowPresentationPolicy.shouldRetryAfterSceneReady(.orderFront(index: 0)))
        XCTAssertFalse(
            WindowPresentationPolicy.shouldRetryAfterSceneReady(.deminiaturizeAndOrderFront(index: 0))
        )
    }
}

private extension WindowPresentationCandidate {
    static var unpresentable: WindowPresentationCandidate {
        WindowPresentationCandidate(canBecomeMain: false, isVisible: true, isMiniaturized: false, isPanel: false)
    }

    static func panel(isVisible: Bool) -> WindowPresentationCandidate {
        WindowPresentationCandidate(canBecomeMain: true, isVisible: isVisible, isMiniaturized: false, isPanel: true)
    }
}
