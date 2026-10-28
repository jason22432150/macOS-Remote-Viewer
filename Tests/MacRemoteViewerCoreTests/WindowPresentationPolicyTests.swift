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

    func testClosesExtraMainWindowsCreatedByFinderDoubleClick() {
        let windows = [
            WindowPresentationCandidate(canBecomeMain: true, isVisible: true, isMiniaturized: false, isPanel: false),
            WindowPresentationCandidate.panel(isVisible: true),
            WindowPresentationCandidate(canBecomeMain: true, isVisible: true, isMiniaturized: false, isPanel: false),
        ]

        XCTAssertEqual(
            WindowPresentationPolicy.extraMainWindowIndices(in: windows, keptIndex: 0),
            [2]
        )
    }

    func testDoesNotCloseTheKeptMainWindowOrSettingsPanel() {
        let windows = [
            WindowPresentationCandidate.panel(isVisible: true),
            WindowPresentationCandidate(canBecomeMain: true, isVisible: true, isMiniaturized: false, isPanel: false),
        ]

        XCTAssertEqual(
            WindowPresentationPolicy.extraMainWindowIndices(in: windows, keptIndex: 1),
            []
        )
    }

    func testKeptIndexFollowsThePresentationAction() {
        XCTAssertNil(WindowPresentationPolicy.keptIndex(for: .none))
        XCTAssertEqual(WindowPresentationPolicy.keptIndex(for: .orderFront(index: 2)), 2)
        XCTAssertEqual(
            WindowPresentationPolicy.keptIndex(for: .deminiaturizeAndOrderFront(index: 1)),
            1
        )
    }

    func testClosesFrontmostExtraWindowWhenRememberedMainWindowIsBehindIt() {
        let windows = [
            WindowPresentationCandidate(canBecomeMain: true, isVisible: true, isMiniaturized: false, isPanel: false),
            WindowPresentationCandidate(canBecomeMain: true, isVisible: true, isMiniaturized: false, isPanel: false),
        ]

        XCTAssertEqual(
            WindowPresentationPolicy.keptIndexForClosingExtras(
                rememberedIndex: 1,
                action: .orderFront(index: 0)
            ),
            1
        )
        XCTAssertEqual(
            WindowPresentationPolicy.extraMainWindowIndices(in: windows, keptIndex: 1),
            [0]
        )
    }

    func testFallsBackToPresentationActionWhenNoMainWindowIsRemembered() {
        XCTAssertEqual(
            WindowPresentationPolicy.keptIndexForClosingExtras(
                rememberedIndex: nil,
                action: .orderFront(index: 0)
            ),
            0
        )
        XCTAssertNil(
            WindowPresentationPolicy.keptIndexForClosingExtras(
                rememberedIndex: nil,
                action: .none
            )
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
