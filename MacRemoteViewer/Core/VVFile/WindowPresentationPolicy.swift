import Foundation

/// 可供前景決策使用的視窗摘要。App 層負責從 `NSWindow` 轉成此值。
public struct WindowPresentationCandidate: Equatable, Sendable {
    public var canBecomeMain: Bool
    public var isVisible: Bool
    public var isMiniaturized: Bool
    public var isPanel: Bool

    public init(canBecomeMain: Bool, isVisible: Bool, isMiniaturized: Bool, isPanel: Bool) {
        self.canBecomeMain = canBecomeMain
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.isPanel = isPanel
    }
}

/// 雙擊 `.vv` 或點 Dock 時，對現有視窗要做的前景動作。
public enum WindowPresentationAction: Equatable, Sendable {
    case none
    case orderFront(index: Int)
    case deminiaturizeAndOrderFront(index: Int)
}

/// 從現有視窗選出應叫到前景的主視窗，避開 Settings／panel。
public enum WindowPresentationPolicy {
    public static func action(for windows: [WindowPresentationCandidate]) -> WindowPresentationAction {
        let candidates = windows.enumerated().filter { _, window in
            window.canBecomeMain && !window.isPanel
        }
        guard !candidates.isEmpty else { return .none }

        if let visible = candidates.first(where: { _, window in
            window.isVisible && !window.isMiniaturized
        }) {
            return .orderFront(index: visible.offset)
        }
        if let miniaturized = candidates.first(where: { _, window in
            window.isMiniaturized
        }) {
            return .deminiaturizeAndOrderFront(index: miniaturized.offset)
        }
        return .orderFront(index: candidates[0].offset)
    }

    /// 開檔事件可能早於 SwiftUI 建立 `WindowGroup`，此時下一輪 run loop 再試一次。
    public static func shouldRetryAfterSceneReady(_ action: WindowPresentationAction) -> Bool {
        action == .none
    }
}
