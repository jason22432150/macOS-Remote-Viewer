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
    public func guestPoint(fromPixelPoint pixel: CGPoint) -> CGPoint? {
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
        local.x = min(max(local.x, 0), scaled.width)
        local.y = min(max(local.y, 0), scaled.height)
        return CGPoint(x: local.x / viewportScale, y: local.y / viewportScale)
    }

    /// `viewPoint` 與 `bounds` 使用 flipped NSView 座標（左上為原點）。
    public func guestPoint(fromViewPoint viewPoint: CGPoint, bounds: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let pixel = CGPoint(
            x: viewPoint.x * drawableSize.width / bounds.width,
            y: viewPoint.y * drawableSize.height / bounds.height
        )
        return guestPoint(fromPixelPoint: pixel)
    }
}
