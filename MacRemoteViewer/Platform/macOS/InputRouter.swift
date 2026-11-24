import AppKit

/// 鍵盤滑鼠映射、特殊按鍵、失焦釋放。快捷鍵由 App 層先攔截。
@MainActor
final class InputRouter {
    var captured = true
    /// 與系統滾輪相反時為 true，來自可持久化的使用者偏好。
    var invertScrollWheel = false
    var horizontalScrollCompatibility = false
    /// 傳統滑鼠滾輪倍率，1 為預設。
    var mouseWheelSensitivity: Double = 1
    /// 觸控板雙指／精準滾動倍率，1 為預設。
    var trackpadScrollSensitivity: Double = 1
    /// 側鍵 4 送到 guest 的動作，來自可持久化的使用者偏好。
    var sideButton4: MouseSideButtonAction = .previousPage
    /// 側鍵 5 送到 guest 的動作，來自可持久化的使用者偏好。
    var sideButton5: MouseSideButtonAction = .nextPage
    private var pressedScancodes: Set<Int> = []

    func mouseEvent(from event: NSEvent, in view: NSView, mapping: GuestPointerMapping, relativeCaptured: Bool = false) -> MouseEvent? {
        let location = view.convert(event.locationInWindow, from: nil)
        // 黑邊不轉給 guest；button-up 例外，夾到畫面邊緣以免 guest 按鍵卡住。
        let clampToDisplay = relativeCaptured || Self.isButtonUp(event)
        guard let point = mapping.guestPoint(
            fromViewPoint: location,
            bounds: view.bounds,
            clampToDisplay: clampToDisplay
        ) else {
            return nil
        }
        let pressed = NSEvent.pressedMouseButtons
        let mask = MouseButtonMapping.spiceMask(
            pressedMouseButtons: pressed,
            button4: sideButton4,
            button5: sideButton5
        )

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let bits = MouseButtonMapping.spiceButtons(
                pressedMouseButtons: pressed,
                changedButtonNumber: event.buttonNumber,
                isRelease: false,
                button4: sideButton4,
                button5: sideButton5
            )
            // 停用的側鍵或無法對應的按鍵不送 down，但仍轉發後續 move。
            guard bits.button != 0 else { return nil }
            return MouseEvent(kind: .down, point: point, buttonMask: bits.mask, button: bits.button)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let bits = MouseButtonMapping.spiceButtons(
                pressedMouseButtons: pressed,
                changedButtonNumber: event.buttonNumber,
                isRelease: true,
                button4: sideButton4,
                button5: sideButton5
            )
            guard bits.button != 0 else { return nil }
            return MouseEvent(kind: .up, point: point, buttonMask: bits.mask, button: bits.button)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return MouseEvent(kind: .move, point: point, buttonMask: mask,
                              relativeDelta: CGPoint(x: event.deltaX, y: event.deltaY))
        case .scrollWheel:
            let flags = event.modifierFlags
            let allowHorizontal = horizontalScrollCompatibility &&
                flags.intersection([.control, .option, .command]).isEmpty
            let axis = ScrollWheelMapping.selectedAxis(horizontal: event.scrollingDeltaX,
                vertical: event.scrollingDeltaY, horizontalEnabled: allowHorizontal)
            let delta = ScrollWheelMapping.guestDelta(
                axis.delta,
                inverted: invertScrollWheel,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                mouseWheelSensitivity: mouseWheelSensitivity,
                trackpadScrollSensitivity: trackpadScrollSensitivity
            )
            guard delta.isFinite, delta != 0 else { return nil }
            return MouseEvent(kind: .scroll, point: point, buttonMask: mask, scrollDelta: delta,
                              scrollIsHorizontal: axis.isHorizontal)
        default:
            return nil
        }
    }

    /// 側鍵上頁／下一頁在 mouseDown 送出 Alt+方向鍵 click。
    func sideButtonKeyEvents(from event: NSEvent) -> [KeyEvent] {
        guard captured else { return [] }
        guard event.type == .otherMouseDown else { return [] }
        let action = MouseButtonMapping.action(
            buttonNumber: event.buttonNumber,
            button4: sideButton4,
            button5: sideButton5
        )
        let altAlreadyDown = pressedScancodes.contains(MouseSideButtonAction.leftAltScancode)
            || pressedScancodes.contains(MouseSideButtonAction.rightAltScancode)
        return action.pageNavigationClickEvents(altAlreadyDown: altAlreadyDown)
    }

    func keyEvents(from event: NSEvent) -> [KeyEvent] {
        let flags = event.modifierFlags
        if event.type == .flagsChanged {
            return KeyboardMapping.flagsChangedEvents(
                macKeyCode: Int(event.keyCode),
                control: flags.contains(.control),
                option: flags.contains(.option),
                shift: flags.contains(.shift),
                command: flags.contains(.command),
                pressedScancodes: &pressedScancodes,
                individualModifierDown: Self.individualModifierDown(event)
            )
        }

        var events = KeyboardMapping.syncModifiers(
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            command: flags.contains(.command),
            pressedScancodes: &pressedScancodes
        )

        if event.keyCode == 113 {
            events.append(KeyEvent(pressed: event.type == .keyDown, scancode: 0, isPause: true))
            return events
        }
        guard let scancode = KeyboardMapping.xtScancode(forMacKeyCode: Int(event.keyCode)) else {
            return events
        }
        let pressed = event.type == .keyDown && !event.isARepeat
        let released = event.type == .keyUp
        guard pressed || released else { return events }
        if pressed {
            if !pressedScancodes.contains(scancode) {
                pressedScancodes.insert(scancode)
                events.append(KeyEvent(pressed: true, scancode: scancode))
            }
        } else if pressedScancodes.contains(scancode) {
            pressedScancodes.remove(scancode)
            events.append(KeyEvent(pressed: false, scancode: scancode))
        }
        return events
    }

    func releaseAll() -> [KeyEvent] {
        let events = pressedScancodes.map { KeyEvent(pressed: false, scancode: $0) }
        pressedScancodes.removeAll()
        return events
    }

    func matches(_ chord: HotKeyChord, event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        guard control == chord.control,
              option == chord.option,
              shift == chord.shift,
              command == chord.command
        else { return false }

        switch chord.symbol {
        case .function(let number):
            return Self.functionKeyCode(number) == Int(event.keyCode)
        case .character(let character):
            return event.charactersIgnoringModifiers?.uppercased() == String(character)
        case .insert:
            return event.keyCode == 114
        case .delete:
            return event.keyCode == 117
        case .unnamed:
            return false
        }
    }

    // NX device-dependent modifier bits distinguish the physical left/right keys.
    private static func individualModifierDown(_ event: NSEvent) -> Bool? {
        let pairs: [UInt16: (UInt, UInt)] = [
            59: (0x0001, 0x2000), 62: (0x2000, 0x0001),
            56: (0x0002, 0x0004), 60: (0x0004, 0x0002),
            55: (0x0008, 0x0010), 54: (0x0010, 0x0008),
            58: (0x0020, 0x0040), 61: (0x0040, 0x0020)
        ]
        guard let (own, other) = pairs[event.keyCode] else { return nil }
        let raw = event.modifierFlags.rawValue
        guard raw & (own | other) != 0 else { return nil }
        return raw & own != 0
    }

    private static func isButtonUp(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    private static func functionKeyCode(_ number: Int) -> Int? {
        let map: [Int: Int] = [
            1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98,
            8: 100, 9: 101, 10: 109, 11: 103, 12: 111
        ]
        return map[number]
    }

}
