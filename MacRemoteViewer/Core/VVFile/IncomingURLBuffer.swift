import Foundation

/// 緩衝 Finder／Launch Services 在 UI 就緒前送來的檔案 URL。
/// 雙擊 `.vv` 啟動時，`application(_:open:)` 可能早於 SwiftUI `onAppear`。
@MainActor
public final class IncomingURLBuffer {
    private var pending: [URL] = []
    private var handler: (@MainActor ([URL]) -> Void)?

    public init() {}

    public func setHandler(_ handler: @escaping @MainActor ([URL]) -> Void) {
        self.handler = handler
        flush()
    }

    public func handle(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let handler {
            handler(urls)
        } else {
            pending.append(contentsOf: urls)
        }
    }

    private func flush() {
        guard let handler, !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        handler(urls)
    }
}
