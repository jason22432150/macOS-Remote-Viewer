import Foundation

/// 滑鼠側鍵 4／5 送到 guest 的動作。預設上頁／下一頁以 Alt+方向鍵送出，因為多數 Guest 不會處理滑鼠 X1／X2。
public enum MouseSideButtonAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case previousPage
    case nextPage
    case none

    public var id: String { rawValue }

    public static let leftAltScancode = 0x38
    public static let rightAltScancode = 0x138
    public static let leftArrowScancode = 0x14B
    public static let rightArrowScancode = 0x14D

    /// 上頁／下一頁改送鍵盤，不佔 SPICE 滑鼠 Side／Extra bit。
    public var spiceBit: UInt32 { 0 }

    /// 一次完整 click，避免 mouseUp 遺失時 Alt 卡在 guest。
    public func pageNavigationClickEvents(altAlreadyDown: Bool = false) -> [KeyEvent] {
        let arrow: Int
        switch self {
        case .previousPage:
            arrow = Self.leftArrowScancode
        case .nextPage:
            arrow = Self.rightArrowScancode
        case .none:
            return []
        }
        var events: [KeyEvent] = []
        if !altAlreadyDown {
            events.append(KeyEvent(pressed: true, scancode: Self.leftAltScancode))
        }
        events.append(KeyEvent(pressed: true, scancode: arrow))
        events.append(KeyEvent(pressed: false, scancode: arrow))
        if !altAlreadyDown {
            events.append(KeyEvent(pressed: false, scancode: Self.leftAltScancode))
        }
        return events
    }
}

/// 把 macOS `NSEvent` 的滑鼠按鍵編號／pressed bits 轉成 SPICE／CSInput mask。
///
/// `NSEvent.pressedMouseButtons`：bit0 左鍵、bit1 右鍵、bit2 中鍵、bit3 側鍵 4、bit4 側鍵 5。
/// CocoaSpice `CSInputButton` 與 SPICE 相同：bit0 Left、bit1 Middle、bit2 Right、bit5 Side、bit6 Extra。
public enum MouseButtonMapping {
    public static let left: UInt32 = 1 << 0
    public static let middle: UInt32 = 1 << 1
    public static let right: UInt32 = 1 << 2
    public static let side: UInt32 = 1 << 5
    public static let extra: UInt32 = 1 << 6

    /// 目前按下的所有按鍵，轉成 SPICE mask。側鍵依使用者設定重映射。
    public static func spiceMask(
        pressedMouseButtons: Int,
        button4: MouseSideButtonAction = .previousPage,
        button5: MouseSideButtonAction = .nextPage
    ) -> UInt32 {
        var mask: UInt32 = 0
        if pressedMouseButtons & (1 << 0) != 0 { mask |= left }
        if pressedMouseButtons & (1 << 1) != 0 { mask |= right }
        if pressedMouseButtons & (1 << 2) != 0 { mask |= middle }
        if pressedMouseButtons & (1 << 3) != 0 { mask |= button4.spiceBit }
        if pressedMouseButtons & (1 << 4) != 0 { mask |= button5.spiceBit }
        return mask
    }

    /// `NSEvent.buttonNumber` 對應的側鍵設定；3／8 為側鍵 4，4／9 為側鍵 5。
    public static func action(
        buttonNumber: Int,
        button4: MouseSideButtonAction = .previousPage,
        button5: MouseSideButtonAction = .nextPage
    ) -> MouseSideButtonAction {
        switch buttonNumber {
        case 3, 8: return button4
        case 4, 9: return button5
        default: return .none
        }
    }

    /// 單一 `NSEvent.buttonNumber` 對應的 SPICE button bit；無法對應或停用則為 0。
    public static func spiceButton(
        buttonNumber: Int,
        button4: MouseSideButtonAction = .previousPage,
        button5: MouseSideButtonAction = .nextPage
    ) -> UInt32 {
        switch buttonNumber {
        case 0: return left
        case 1: return right
        case 2: return middle
        case 3, 8: return button4.spiceBit
        case 4, 9: return button5.spiceBit
        default: return 0
        }
    }

    /// 組出 down／up 要送給 guest 的 mask 與「剛變化的那一顆按鍵」。
    ///
    /// mouseUp 時 `pressedMouseButtons` 可能仍含剛放開的 bit，必須用 `isRelease` 清掉，
    /// 否則 `sendMouseButton` 會把整份 mask 當成 button id。
    public static func spiceButtons(
        pressedMouseButtons: Int,
        changedButtonNumber: Int,
        isRelease: Bool,
        button4: MouseSideButtonAction = .previousPage,
        button5: MouseSideButtonAction = .nextPage
    ) -> (mask: UInt32, button: UInt32) {
        let button = spiceButton(
            buttonNumber: changedButtonNumber,
            button4: button4,
            button5: button5
        )
        var mask = spiceMask(
            pressedMouseButtons: pressedMouseButtons,
            button4: button4,
            button5: button5
        )
        if isRelease {
            mask &= ~button
        } else {
            mask |= button
        }
        return (mask, button)
    }
}
