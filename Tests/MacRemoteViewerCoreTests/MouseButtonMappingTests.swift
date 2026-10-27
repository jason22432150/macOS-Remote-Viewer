import XCTest
@testable import MacRemoteViewerCore

final class MouseButtonMappingTests: XCTestCase {
    func testPressedMouseButtonsMapsLeftMiddleRight() {
        XCTAssertEqual(MouseButtonMapping.spiceMask(pressedMouseButtons: 1 << 0), MouseButtonMapping.left)
        XCTAssertEqual(MouseButtonMapping.spiceMask(pressedMouseButtons: 1 << 1), MouseButtonMapping.right)
        XCTAssertEqual(MouseButtonMapping.spiceMask(pressedMouseButtons: 1 << 2), MouseButtonMapping.middle)
    }

    func testDefaultPageActionsDoNotSendSpiceMouseSideBits() {
        // 上頁／下一頁改送 Alt+方向鍵；X1／X2 在多數 Guest 不會有反應。
        XCTAssertEqual(MouseButtonMapping.spiceMask(pressedMouseButtons: 1 << 3), 0)
        XCTAssertEqual(MouseButtonMapping.spiceMask(pressedMouseButtons: 1 << 4), 0)
        XCTAssertEqual(
            MouseButtonMapping.spiceMask(pressedMouseButtons: (1 << 0) | (1 << 3) | (1 << 4)),
            MouseButtonMapping.left
        )
    }

    func testButtonNumberMapsToSingleSpiceButton() {
        XCTAssertEqual(MouseButtonMapping.spiceButton(buttonNumber: 0), MouseButtonMapping.left)
        XCTAssertEqual(MouseButtonMapping.spiceButton(buttonNumber: 1), MouseButtonMapping.right)
        XCTAssertEqual(MouseButtonMapping.spiceButton(buttonNumber: 2), MouseButtonMapping.middle)
        XCTAssertEqual(MouseButtonMapping.spiceButton(buttonNumber: 3), 0)
        XCTAssertEqual(MouseButtonMapping.spiceButton(buttonNumber: 4), 0)
        XCTAssertEqual(MouseButtonMapping.spiceButton(buttonNumber: 5), 0)
    }

    func testPressWhileHoldingLeftIgnoresRemappedSideButton() {
        let bits = MouseButtonMapping.spiceButtons(
            pressedMouseButtons: (1 << 0) | (1 << 3),
            changedButtonNumber: 3,
            isRelease: false
        )
        XCTAssertEqual(bits.button, 0)
        XCTAssertEqual(bits.mask, MouseButtonMapping.left)
    }

    func testPhysicalButtonNumbersSelectConfiguredActions() {
        XCTAssertEqual(MouseButtonMapping.action(buttonNumber: 3), .previousPage)
        XCTAssertEqual(MouseButtonMapping.action(buttonNumber: 4), .nextPage)
        XCTAssertEqual(MouseButtonMapping.action(buttonNumber: 8), .previousPage)
        XCTAssertEqual(MouseButtonMapping.action(buttonNumber: 9), .nextPage)
        XCTAssertEqual(
            MouseButtonMapping.action(buttonNumber: 3, button4: .nextPage, button5: .previousPage),
            .nextPage
        )
        XCTAssertEqual(MouseButtonMapping.action(buttonNumber: 0), .none)
    }

    func testPreviousPageSendsAltLeftClick() {
        XCTAssertEqual(
            MouseSideButtonAction.previousPage.pageNavigationClickEvents(),
            [
                KeyEvent(pressed: true, scancode: MouseSideButtonAction.leftAltScancode),
                KeyEvent(pressed: true, scancode: MouseSideButtonAction.leftArrowScancode),
                KeyEvent(pressed: false, scancode: MouseSideButtonAction.leftArrowScancode),
                KeyEvent(pressed: false, scancode: MouseSideButtonAction.leftAltScancode)
            ]
        )
    }

    func testNextPageSendsAltRightClick() {
        XCTAssertEqual(
            MouseSideButtonAction.nextPage.pageNavigationClickEvents(),
            [
                KeyEvent(pressed: true, scancode: MouseSideButtonAction.leftAltScancode),
                KeyEvent(pressed: true, scancode: MouseSideButtonAction.rightArrowScancode),
                KeyEvent(pressed: false, scancode: MouseSideButtonAction.rightArrowScancode),
                KeyEvent(pressed: false, scancode: MouseSideButtonAction.leftAltScancode)
            ]
        )
    }

    func testPageNavigationSkipsAltWhenAlreadyDown() {
        XCTAssertEqual(
            MouseSideButtonAction.previousPage.pageNavigationClickEvents(altAlreadyDown: true),
            [
                KeyEvent(pressed: true, scancode: MouseSideButtonAction.leftArrowScancode),
                KeyEvent(pressed: false, scancode: MouseSideButtonAction.leftArrowScancode)
            ]
        )
    }

    func testDisabledSideButtonSendsNoKeysOrMouseBits() {
        XCTAssertTrue(MouseSideButtonAction.none.pageNavigationClickEvents().isEmpty)
        let down = MouseButtonMapping.spiceButtons(
            pressedMouseButtons: 1 << 3,
            changedButtonNumber: 3,
            isRelease: false,
            button4: .none
        )
        XCTAssertEqual(down.button, 0)
        XCTAssertEqual(down.mask, 0)
    }
}
