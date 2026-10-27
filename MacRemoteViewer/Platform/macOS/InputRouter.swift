import AppKit

/// 鍵盤滑鼠映射、特殊按鍵、失焦釋放。快捷鍵由 App 層先攔截。
@MainActor
final class InputRouter {
    var captured = true
    private var pressedScancodes: Set<Int> = []

    func mouseEvent(from event: NSEvent, in view: NSView, mapping: GuestPointerMapping) -> MouseEvent? {
        let location = view.convert(event.locationInWindow, from: nil)
        guard let point = mapping.guestPoint(fromViewPoint: location, bounds: view.bounds) else {
            return nil
        }
        let mask = Self.buttonMask(from: event)

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return MouseEvent(kind: .down, point: point, buttonMask: mask)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return MouseEvent(kind: .up, point: point, buttonMask: mask)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return MouseEvent(kind: .move, point: point, buttonMask: mask)
        case .scrollWheel:
            return MouseEvent(kind: .scroll, point: point, buttonMask: mask, scrollDelta: event.scrollingDeltaY)
        default:
            return nil
        }
    }

    func keyEvent(from event: NSEvent) -> KeyEvent? {
        if event.keyCode == 113 { // Pause 在部分鍵盤上的對應
            return KeyEvent(pressed: event.type == .keyDown, scancode: 0, isPause: true)
        }
        guard let scancode = Self.xtScancode(forMacKeyCode: Int(event.keyCode)) else {
            return nil
        }
        let pressed = event.type == .keyDown && !event.isARepeat
        let released = event.type == .keyUp
        guard pressed || released else { return nil }
        if pressed {
            pressedScancodes.insert(scancode)
        } else {
            pressedScancodes.remove(scancode)
        }
        return KeyEvent(pressed: pressed, scancode: scancode)
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

    private static func buttonMask(from event: NSEvent) -> UInt32 {
        var mask: UInt32 = 0
        let buttons = NSEvent.pressedMouseButtons
        if buttons & 1 != 0 { mask |= 1 }
        if buttons & 4 != 0 { mask |= 2 }
        if buttons & 2 != 0 { mask |= 4 }
        return mask
    }

    private static func functionKeyCode(_ number: Int) -> Int? {
        let map: [Int: Int] = [
            1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98,
            8: 100, 9: 101, 10: 109, 11: 103, 12: 111
        ]
        return map[number]
    }

    /// Mac virtual key → PC XT set 1。延伸碼以 CocoaSpice 慣例將 0xE0 換成 0x100。
    static func xtScancode(forMacKeyCode keyCode: Int) -> Int? {
        let map: [Int: Int] = [
            0: 0x1E, 1: 0x1F, 2: 0x20, 3: 0x21, 4: 0x23, 5: 0x22, 6: 0x2C, 7: 0x2D,
            8: 0x2E, 9: 0x2F, 11: 0x30, 12: 0x10, 13: 0x11, 14: 0x12, 15: 0x13,
            16: 0x15, 17: 0x14, 18: 0x02, 19: 0x03, 20: 0x04, 21: 0x05, 22: 0x07,
            23: 0x06, 24: 0x0D, 25: 0x0A, 26: 0x08, 27: 0x0C, 28: 0x09, 29: 0x0B,
            30: 0x1B, 31: 0x18, 32: 0x16, 33: 0x1A, 34: 0x17, 35: 0x19, 36: 0x1C,
            37: 0x26, 38: 0x24, 39: 0x28, 40: 0x25, 41: 0x27, 42: 0x2B, 43: 0x33,
            44: 0x35, 45: 0x31, 46: 0x32, 47: 0x34, 48: 0x0F, 49: 0x39, 50: 0x29,
            51: 0x0E, 53: 0x01, 54: 0x15C, 55: 0x15B, 56: 0x2A, 57: 0x3A, 58: 0x38,
            59: 0x1D, 60: 0x36, 61: 0x138, 62: 0x11D, 96: 0x3F, 97: 0x40, 98: 0x41,
            99: 0x3D, 100: 0x42, 101: 0x43, 103: 0x57, 109: 0x44, 111: 0x58,
            118: 0x3E, 120: 0x3C, 122: 0x3B, 123: 0x14B, 124: 0x14D, 125: 0x150,
            126: 0x148, 114: 0x152, 115: 0x147, 116: 0x149, 117: 0x153, 119: 0x14F,
            121: 0x151
        ]
        return map[keyCode]
    }
}
