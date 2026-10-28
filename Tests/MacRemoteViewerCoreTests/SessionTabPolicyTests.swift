import XCTest
@testable import MacRemoteViewerCore

final class SessionTabPolicyTests: XCTestCase {
    func testTabBarAppearsOnlyWhenMoreThanOneSessionExists() {
        XCTAssertFalse(SessionTabPolicy.shouldShowTabBar(sessionCount: 0))
        XCTAssertFalse(SessionTabPolicy.shouldShowTabBar(sessionCount: 1))
        XCTAssertTrue(SessionTabPolicy.shouldShowTabBar(sessionCount: 2))
        XCTAssertTrue(SessionTabPolicy.shouldShowTabBar(sessionCount: 5))
    }

    func testClosingATabSelectsTheNeighborOnTheRight() {
        XCTAssertEqual(
            SessionTabPolicy.selectedIndexAfterClosing(closedIndex: 0, remainingCount: 2),
            0
        )
        XCTAssertEqual(
            SessionTabPolicy.selectedIndexAfterClosing(closedIndex: 1, remainingCount: 2),
            1
        )
    }

    func testClosingTheLastTabSelectsTheNewLastTab() {
        XCTAssertEqual(
            SessionTabPolicy.selectedIndexAfterClosing(closedIndex: 2, remainingCount: 2),
            1
        )
    }

    func testClosingTheOnlyTabClearsSelection() {
        XCTAssertNil(SessionTabPolicy.selectedIndexAfterClosing(closedIndex: 0, remainingCount: 0))
    }

    func testTabTitleUsesProfileTitleWhenPresent() {
        XCTAssertEqual(SessionTabPolicy.tabTitle(profileTitle: "win11-dev", fallback: "SPICE"), "win11-dev")
    }

    func testTabTitleFallsBackWhenProfileTitleIsBlank() {
        XCTAssertEqual(SessionTabPolicy.tabTitle(profileTitle: "   ", fallback: "SPICE Session"), "SPICE Session")
        XCTAssertEqual(SessionTabPolicy.tabTitle(profileTitle: "", fallback: "SPICE Session"), "SPICE Session")
    }
}
