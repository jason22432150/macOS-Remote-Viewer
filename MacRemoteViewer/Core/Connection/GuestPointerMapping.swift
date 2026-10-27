import Foundation
import CoreGraphics

/// 把 Metal drawable 像素對應到 SPICE guest 座標。
/// CocoaSpice 以 drawable 中心為原點、client 模式 Y 軸向下（與 flipped NSView 相同）。
public struct GuestPointerMapping: Equatable, Sendable {
    public var displaySize: CGSize
    public var drawableSize: CGSize
    public var viewportOrigin: CGPoint
    public var viewportScale: CGFloat

    public init(
        displaySize: CGSize,
        drawableSize: CGSize,
        viewportOrigin: CGPoint,
        viewportScale: CGFloat
    ) {
        self.displaySize = displaySize
        self.drawableSize = drawableSize
        self.viewportOrigin = viewportOrigin
        self.viewportScale = viewportScale
    }

    /// 等比縮放並置中；`viewportOrigin` 為 0 表示不額外平移。
    public static func aspectFit(displaySize: CGSize, drawableSize: CGSize) -> GuestPointerMapping {
        let scale: CGFloat
        if displaySize.width <= 0 || displaySize.height <= 0 {
            scale = 1
        } else {
            scale = min(
                drawableSize.width / displaySize.width,
                drawableSize.height / displaySize.height
            )
        }
        return GuestPointerMapping(
            displaySize: displaySize,
            drawableSize: drawableSize,
            viewportOrigin: .zero,
            viewportScale: scale
        )
    }

    /// `pixel` 的原點在 drawable 左上、Y 向下。
    /// 黑邊（letterbox / pillarbox）預設不對應 guest，避免游標被夾到畫面邊緣。
    /// `clampToDisplay` 為 true 時，超出範圍的點會對應到畫面邊緣（給 mouse-up 釋放按鍵用）。
    public func guestPoint(fromPixelPoint pixel: CGPoint, clampToDisplay: Bool = false) -> CGPoint? {
        guard displaySize.width > 0, displaySize.height > 0, viewportScale > 0 else {
            return nil
        }
        let scaled = CGSize(
            width: displaySize.width * viewportScale,
            height: displaySize.height * viewportScale
        )
        let drawOrigin = CGPoint(
            x: viewportOrigin.x + drawableSize.width / 2 - scaled.width / 2,
            y: viewportOrigin.y + drawableSize.height / 2 - scaled.height / 2
        )
        var local = CGPoint(x: pixel.x - drawOrigin.x, y: pixel.y - drawOrigin.y)
        let isInside = local.x >= 0 && local.x <= scaled.width
            && local.y >= 0 && local.y <= scaled.height
        if !isInside {
            guard clampToDisplay else { return nil }
            local.x = min(max(local.x, 0), scaled.width)
            local.y = min(max(local.y, 0), scaled.height)
        }
        return CGPoint(x: local.x / viewportScale, y: local.y / viewportScale)
    }

    /// `viewPoint` 與 `bounds` 使用 flipped NSView 座標（左上為原點）。
    public func guestPoint(
        fromViewPoint viewPoint: CGPoint,
        bounds: CGRect,
        clampToDisplay: Bool = false
    ) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let pixel = CGPoint(
            x: viewPoint.x * drawableSize.width / bounds.width,
            y: viewPoint.y * drawableSize.height / bounds.height
        )
        return guestPoint(fromPixelPoint: pixel, clampToDisplay: clampToDisplay)
    }

    /// drawable 像素是否落在等比縮放後的遠端畫面內（不含黑邊）。
    public func contains(pixelPoint: CGPoint) -> Bool {
        guestPoint(fromPixelPoint: pixelPoint) != nil
    }

    /// NSView 座標是否落在等比縮放後的遠端畫面內（不含黑邊）。
    public func contains(viewPoint: CGPoint, bounds: CGRect) -> Bool {
        guestPoint(fromViewPoint: viewPoint, bounds: bounds) != nil
    }
}

/// 把本機滾輪位移轉成要送給 guest 的方向與幅度。
/// 與 `GuestPointerMapping` 同檔，讓 `InputRouter` 在 Xcode batch compile 下仍看得到此型別。
public enum ScrollWheelMapping {
    public static let defaultSensitivity: Double = 1
    public static let minimumSensitivity: Double = 0.05
    public static let maximumSensitivity: Double = 4
    /// 觸控板／Magic Mouse 的像素位移比滾輪一格大很多，先縮再套用使用者倍率。
    public static let preciseScrollBaseScale: Double = 0.25

    /// `inverted` 為 true 時正負相反，用來對應「反向滾輪」。
    /// 傳統滑鼠滾輪是 line-based（`hasPreciseScrollingDeltas == false`）；
    /// 觸控板雙指與 Magic Mouse 是 pixel-based，共用觸控板靈敏度。
    public static func guestDelta(
        _ scrollingDeltaY: CGFloat,
        inverted: Bool,
        hasPreciseScrollingDeltas: Bool = false,
        mouseWheelSensitivity: Double = defaultSensitivity,
        trackpadScrollSensitivity: Double = defaultSensitivity
    ) -> CGFloat {
        let directed = inverted ? -scrollingDeltaY : scrollingDeltaY
        let userScale = hasPreciseScrollingDeltas ? trackpadScrollSensitivity : mouseWheelSensitivity
        let baseScale = hasPreciseScrollingDeltas ? preciseScrollBaseScale : 1
        return directed * CGFloat(clampSensitivity(userScale) * baseScale)
    }

    /// 非法或超出範圍的靈敏度回到可操作區間，避免 0 或極大值讓滾動失效。
    public static func clampSensitivity(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultSensitivity }
        return min(max(value, minimumSensitivity), maximumSensitivity)
    }
}
