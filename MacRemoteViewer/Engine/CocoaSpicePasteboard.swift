import AppKit
import Foundation
import os
import CocoaSpiceNoUsb

/// CocoaSpice 的 `CSPasteboardDelegate`：直接對 `NSPasteboard.general` 做雙向同步。
///
/// GLib worker 可能呼叫這些方法，因此 pasteboard 存取一律轉到主執行緒。
final class CocoaSpicePasteboard: NSObject, CSPasteboardDelegate, @unchecked Sendable {
    private let pasteboard = NSPasteboard.general
    private let lastChangeCount = OSAllocatedUnfairLock(initialState: 0)
    private var pollTask: Task<Void, Never>?

    func startPolling() {
        lastChangeCount.withLock { $0 = readChangeCount() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.announceIfChanged()
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - CSPasteboardDelegate

    func canReadItem(for type: CSPasteboardType) -> Bool {
        guard let pasteboardType = type.pasteboardType else { return false }
        return onMain {
            (self.pasteboard.types ?? []).contains(pasteboardType)
        }
    }

    func data(for type: CSPasteboardType) -> Data? {
        onMain {
            if type == .string, let text = self.pasteboard.string(forType: .string) {
                return Data(text.utf8)
            }
            guard let pasteboardType = type.pasteboardType else { return nil }
            return self.pasteboard.data(forType: pasteboardType)
        }
    }

    func setData(_ data: Data, for type: CSPasteboardType) {
        onMainWrite {
            if type == .string, let text = String(data: data, encoding: .utf8) {
                self.writeString(text)
                return
            }
            guard let pasteboardType = type.pasteboardType else { return }
            self.pasteboard.clearContents()
            self.pasteboard.setData(data, forType: pasteboardType)
            self.rememberChangeCount()
        }
    }

    func string() -> String? {
        onMain { self.pasteboard.string(forType: .string) }
    }

    func setString(_ string: String) {
        onMainWrite { self.writeString(string) }
    }

    func clearContents() {
        onMainWrite {
            self.pasteboard.clearContents()
            self.rememberChangeCount()
        }
    }

    // MARK: - Private

    private func announceIfChanged() {
        let current = readChangeCount()
        let previous = lastChangeCount.withLock { stored -> Int in
            let old = stored
            stored = current
            return old
        }
        guard current != previous else { return }
        // CSSession 監聽此通知後對 guest 做 clipboard grab。
        NotificationCenter.default.post(name: .csPasteboardChanged, object: self)
    }

    private func writeString(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        rememberChangeCount()
    }

    private func rememberChangeCount() {
        lastChangeCount.withLock { $0 = pasteboard.changeCount }
    }

    private func readChangeCount() -> Int {
        onMain { self.pasteboard.changeCount }
    }

    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    /// 寫入走 async，避免 GLib worker 在 disconnect 期間 `main.sync` 與 `CSMain.syncWith` 互鎖。
    private func onMainWrite(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
            return
        }
        DispatchQueue.main.async(execute: body)
    }
}

private extension CSPasteboardType {
    var pasteboardType: NSPasteboard.PasteboardType? {
        switch self {
        case .string:
            return .string
        case .png:
            return .png
        case .tiff:
            return .tiff
        case .jpg:
            return NSPasteboard.PasteboardType("public.jpeg")
        case .bmp:
            return NSPasteboard.PasteboardType("com.microsoft.bmp")
        default:
            return nil
        }
    }
}
