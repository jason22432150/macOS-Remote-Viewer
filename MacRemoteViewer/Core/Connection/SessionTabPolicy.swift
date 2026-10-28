import Foundation

/// 多 session 分頁的純規則：UI 與 workspace 共用，避免各層自行判斷。
public enum SessionTabPolicy {
    /// 只有第二個連線出現後才顯示分頁列，單一連線維持原本全畫面。
    public static func shouldShowTabBar(sessionCount: Int) -> Bool {
        sessionCount > 1
    }

    /// 關閉分頁後選右側鄰居；關掉最後一個則改選新的最後一個。
    public static func selectedIndexAfterClosing(closedIndex: Int, remainingCount: Int) -> Int? {
        guard remainingCount > 0 else { return nil }
        if closedIndex < remainingCount {
            return closedIndex
        }
        return remainingCount - 1
    }

    /// `.vv` 的 title 為空白時用 fallback，避免分頁列出現空標籤。
    public static func tabTitle(profileTitle: String, fallback: String) -> String {
        let trimmed = profileTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
