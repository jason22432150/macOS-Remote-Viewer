import Foundation

/// Mac virtual key 與 modifier 狀態轉成 PC XT set 1 scancode。
/// 延伸碼以 CocoaSpice 慣例將 0xE0 換成 0x100。
public enum KeyboardMapping {
    private static let leftControl = 0x1D
    private static let rightControl = 0x11D
    private static let leftShift = 0x2A
    private static let rightShift = 0x36
    private static let leftOption = 0x38
    private static let rightOption = 0x138
    private static let leftCommand = 0x15B
    private static let rightCommand = 0x15C
    private static let capsLock = 0x3A

    public static func xtScancode(forMacKeyCode keyCode: Int) -> Int? {
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
            121: 0x151, 65: 0x53, 67: 0x37, 69: 0x4E, 71: 0x45,
            75: 0x135, 76: 0x11C, 78: 0x4A, 81: 0x59,
            82: 0x52, 83: 0x4F, 84: 0x50, 85: 0x51, 86: 0x4B,
            87: 0x4C, 88: 0x4D, 89: 0x47, 91: 0x48, 92: 0x49
        ]
        return map[keyCode]
    }

    /// `flagsChanged`：依實際左右修飾鍵送 press／release。Caps Lock 送一次 click。
    public static func flagsChangedEvents(
        macKeyCode: Int,
        control: Bool,
        option: Bool,
        shift: Bool,
        command: Bool,
        pressedScancodes: inout Set<Int>,
        individualModifierDown: Bool? = nil
    ) -> [KeyEvent] {
        if macKeyCode == 57 {
            return [
                KeyEvent(pressed: true, scancode: capsLock),
                KeyEvent(pressed: false, scancode: capsLock)
            ]
        }
        guard let scancode = xtScancode(forMacKeyCode: macKeyCode) else { return [] }
        let isDown: Bool
        switch macKeyCode {
        case 59, 62: isDown = control
        case 56, 60: isDown = shift
        case 58, 61: isDown = option
        case 55, 54: isDown = command
        default: return []
        }
        return apply(scancode: scancode, isDown: individualModifierDown ?? isDown, pressedScancodes: &pressedScancodes)
    }

    /// 在一般 keyDown／keyUp 前補齊 modifier，避免 flagsChanged 被系統吃掉時 Ctrl+A 只送出 A。
    public static func syncModifiers(
        control: Bool,
        option: Bool,
        shift: Bool,
        command: Bool,
        pressedScancodes: inout Set<Int>
    ) -> [KeyEvent] {
        var events: [KeyEvent] = []
        events += syncGroup(isDown: control, scancodes: [leftControl, rightControl], pressedScancodes: &pressedScancodes)
        events += syncGroup(isDown: option, scancodes: [leftOption, rightOption], pressedScancodes: &pressedScancodes)
        events += syncGroup(isDown: shift, scancodes: [leftShift, rightShift], pressedScancodes: &pressedScancodes)
        events += syncGroup(isDown: command, scancodes: [leftCommand, rightCommand], pressedScancodes: &pressedScancodes)
        return events
    }

    private static func syncGroup(
        isDown: Bool,
        scancodes: [Int],
        pressedScancodes: inout Set<Int>
    ) -> [KeyEvent] {
        let active = scancodes.filter { pressedScancodes.contains($0) }
        if isDown {
            if !active.isEmpty { return [] }
            return apply(scancode: scancodes[0], isDown: true, pressedScancodes: &pressedScancodes)
        }
        return active.flatMap { apply(scancode: $0, isDown: false, pressedScancodes: &pressedScancodes) }
    }

    private static func apply(
        scancode: Int,
        isDown: Bool,
        pressedScancodes: inout Set<Int>
    ) -> [KeyEvent] {
        if isDown {
            guard !pressedScancodes.contains(scancode) else { return [] }
            pressedScancodes.insert(scancode)
            return [KeyEvent(pressed: true, scancode: scancode)]
        }
        guard pressedScancodes.contains(scancode) else { return [] }
        pressedScancodes.remove(scancode)
        return [KeyEvent(pressed: false, scancode: scancode)]
    }
}
