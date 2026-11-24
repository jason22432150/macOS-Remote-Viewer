import XCTest
@testable import MacRemoteViewerCore

final class KeyboardMappingTests: XCTestCase {
    func testControlFlagsChangedSendsLeftCtrlScancode() {
        var pressed = Set<Int>()
        let down = KeyboardMapping.flagsChangedEvents(
            macKeyCode: 59,
            control: true,
            option: false,
            shift: false,
            command: false,
            pressedScancodes: &pressed
        )
        XCTAssertEqual(down, [KeyEvent(pressed: true, scancode: 0x1D)])
        XCTAssertTrue(pressed.contains(0x1D))

        let up = KeyboardMapping.flagsChangedEvents(
            macKeyCode: 59,
            control: false,
            option: false,
            shift: false,
            command: false,
            pressedScancodes: &pressed
        )
        XCTAssertEqual(up, [KeyEvent(pressed: false, scancode: 0x1D)])
        XCTAssertFalse(pressed.contains(0x1D))
    }

    func testDuplicateModifierDownIsIgnored() {
        var pressed: Set<Int> = [0x1D]
        let events = KeyboardMapping.flagsChangedEvents(
            macKeyCode: 59,
            control: true,
            option: false,
            shift: false,
            command: false,
            pressedScancodes: &pressed
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testCapsLockSendsPressAndRelease() {
        var pressed = Set<Int>()
        let events = KeyboardMapping.flagsChangedEvents(
            macKeyCode: 57,
            control: false,
            option: false,
            shift: false,
            command: false,
            pressedScancodes: &pressed
        )
        XCTAssertEqual(events, [
            KeyEvent(pressed: true, scancode: 0x3A),
            KeyEvent(pressed: false, scancode: 0x3A)
        ])
        XCTAssertTrue(pressed.isEmpty)
    }

    func testSyncInsertsLeftCtrlWhenFlagsHaveControl() {
        var pressed = Set<Int>()
        let events = KeyboardMapping.syncModifiers(
            control: true,
            option: false,
            shift: false,
            command: false,
            pressedScancodes: &pressed
        )
        XCTAssertEqual(events, [KeyEvent(pressed: true, scancode: 0x1D)])
    }

    func testReleasingLeftShiftWhileRightShiftRemainsDown() {
        var pressed: Set<Int> = [0x2A, 0x36]
        let events = KeyboardMapping.flagsChangedEvents(macKeyCode: 56, control: false,
            option: false, shift: true, command: false, pressedScancodes: &pressed,
            individualModifierDown: false)
        XCTAssertEqual(events, [KeyEvent(pressed: false, scancode: 0x2A)])
        XCTAssertEqual(pressed, [0x36])
    }

    func testKeypadMappings() {
        XCTAssertEqual(KeyboardMapping.xtScancode(forMacKeyCode: 82), 0x52)
        XCTAssertEqual(KeyboardMapping.xtScancode(forMacKeyCode: 76), 0x11C)
    }

    func testLetterAUsesXTScancode() {
        XCTAssertEqual(KeyboardMapping.xtScancode(forMacKeyCode: 0), 0x1E)
    }
}
