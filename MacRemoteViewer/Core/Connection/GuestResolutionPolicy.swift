import Foundation
import CoreGraphics

/// 使用者選擇的 guest 解析度策略。
public enum GuestResolutionPreference: Equatable, Sendable {
    /// 依目前應用程式視窗邏輯尺寸對齊。
    case matchWindow
    /// 使用固定解析度，忽略後續視窗縮放。
    case preset(RemoteFrame)
    /// 不送 monitors config，保留 guest 目前解析度。
    case keepGuest
}

/// 設定頁提供的常用解析度。數值皆為偶數，符合 QXL 限制。
public struct RemoteResolutionPreset: Equatable, Hashable, Sendable, Identifiable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var id: String { "\(width)x\(height)" }
    public var displayName: String { "\(width)×\(height)" }
    public var frame: RemoteFrame { RemoteFrame(width: width, height: height) }

    public static let common: [RemoteResolutionPreset] = [
        RemoteResolutionPreset(width: 1024, height: 768),
        RemoteResolutionPreset(width: 1280, height: 720),
        RemoteResolutionPreset(width: 1280, height: 800),
        RemoteResolutionPreset(width: 1366, height: 768),
        RemoteResolutionPreset(width: 1440, height: 900),
        RemoteResolutionPreset(width: 1600, height: 900),
        RemoteResolutionPreset(width: 1680, height: 1050),
        RemoteResolutionPreset(width: 1920, height: 1080),
        RemoteResolutionPreset(width: 1920, height: 1200),
        RemoteResolutionPreset(width: 2560, height: 1440),
        RemoteResolutionPreset(width: 3840, height: 2160)
    ]
}

/// 把本機視窗邏輯點數轉成 SPICE guest 可接受的解析度。
/// 使用 points 而非 Retina pixels，避免 guest 桌面被當成超高解析度而縮小 UI。
public enum GuestResolutionPolicy {
    public static let minimumWidth = 320
    public static let minimumHeight = 200
    public static let maximumDimension = 8192

    /// QXL／部分 guest 不接受奇數邊長；超出範圍則捨棄，避免送出無效 monitors config。
    public static func frame(forViewSize size: CGSize) -> RemoteFrame? {
        guard size.width.isFinite, size.height.isFinite else { return nil }
        let width = alignedDimension(size.width)
        let height = alignedDimension(size.height)
        guard width >= minimumWidth, height >= minimumHeight else { return nil }
        return RemoteFrame(width: width, height: height)
    }

    /// 依偏好決定要送給 guest 的目標尺寸；無法決定時回傳 nil。
    public static func targetFrame(
        preference: GuestResolutionPreference,
        windowSize: CGSize?
    ) -> RemoteFrame? {
        switch preference {
        case .matchWindow:
            guard let windowSize else { return nil }
            return frame(forViewSize: windowSize)
        case .preset(let preset):
            return frame(forViewSize: CGSize(width: preset.width, height: preset.height))
        case .keepGuest:
            return nil
        }
    }

    /// 已送出或 guest 已是目標尺寸時不再重複請求，避免拖曳縮放時灌爆 vdagent。
    public static func shouldRequest(
        _ frame: RemoteFrame,
        currentDisplay: RemoteFrame?,
        lastRequested: RemoteFrame?
    ) -> Bool {
        lastRequested != frame && currentDisplay != frame
    }

    private static func alignedDimension(_ value: CGFloat) -> Int {
        let clamped = min(max(value.rounded(), 0), CGFloat(maximumDimension))
        return Int(clamped) & ~1
    }
}
