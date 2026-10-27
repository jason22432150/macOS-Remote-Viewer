import CoreGraphics

/// 把本機滾輪位移轉成要送給 guest 的方向。
public enum ScrollWheelMapping {
    /// `inverted` 為 true 時正負相反，用來對應「反向滾輪」。
    public static func guestDelta(_ scrollingDeltaY: CGFloat, inverted: Bool) -> CGFloat {
        inverted ? -scrollingDeltaY : scrollingDeltaY
    }
}
