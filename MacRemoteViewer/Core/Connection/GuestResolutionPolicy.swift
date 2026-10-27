import Foundation
import CoreGraphics

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
