import AppKit

/// NSPasteboard 操作集中在 MainActor。
@MainActor
final class PasteboardService: PasteboardAccessing {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int {
        pasteboard.changeCount
    }

    func readPlainText() -> String? {
        pasteboard.string(forType: .string)
    }

    func writePlainText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func containsNonTextPayload() -> Bool {
        let types = pasteboard.types ?? []
        let blocked: Set<NSPasteboard.PasteboardType> = [
            .fileURL, .png, .tiff, .pdf, .rtf, .rtfd, .html, .color, .URL
        ]
        let hasBlocked = types.contains { blocked.contains($0) }
        let hasString = types.contains(.string)
        return hasBlocked && !hasString
    }
}
