import AppKit
import Foundation
import os
import CocoaSpiceNoUsb

/// The GLib worker never waits synchronously for the main thread.
/// Each activation has a generation; queued writes from old tabs are discarded.
final class CocoaSpicePasteboard: NSObject, CSPasteboardDelegate, @unchecked Sendable {
    private struct Snapshot: Sendable {
        var enabled = false
        var generation: UInt64 = 0
        var changeCount = -1
        var items: [String: Data] = [:]
    }

    private let snapshot = OSAllocatedUnfairLock(initialState: Snapshot())
    @MainActor private var pollTask: Task<Void, Never>?
    private static let maxItemBytes = 16 * 1024 * 1024

    @MainActor func startPolling() {
        guard !snapshot.withLock({ $0.enabled }) else { return }
        snapshot.withLock {
            $0.enabled = true
            $0.generation &+= 1
            $0.changeCount = -1
        }
        refresh(announce: false)
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.refresh(announce: true)
            }
        }
    }

    @MainActor func stopPolling() {
        snapshot.withLock {
            $0.enabled = false
            $0.generation &+= 1
            $0.items.removeAll()
            $0.changeCount = -1
        }
        pollTask?.cancel()
        pollTask = nil
    }

    func canReadItem(for type: CSPasteboardType) -> Bool {
        guard let key = type.pasteboardType?.rawValue else { return false }
        return snapshot.withLock { $0.enabled && $0.items[key] != nil }
    }

    func data(for type: CSPasteboardType) -> Data? {
        guard let key = type.pasteboardType?.rawValue else { return nil }
        return snapshot.withLock { $0.enabled ? $0.items[key] : nil }
    }

    func string() -> String? {
        guard let data = data(for: .string) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setData(_ data: Data, for type: CSPasteboardType) {
        guard data.count <= Self.maxItemBytes else { return }
        if type == .string {
            guard let text = String(data: data, encoding: .utf8) else { return }
            setString(text)
            return
        }
        guard let key = type.pasteboardType?.rawValue else { return }
        enqueueWrite { pasteboard in
            pasteboard.clearContents()
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(key))
        }
    }

    func setString(_ string: String) {
        guard string.utf8.count <= Self.maxItemBytes else { return }
        enqueueWrite { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        }
    }

    func clearContents() {
        enqueueWrite { $0.clearContents() }
    }

    private func enqueueWrite(_ body: @escaping @MainActor @Sendable (NSPasteboard) -> Void) {
        guard let generation = snapshot.withLock({ $0.enabled ? $0.generation : nil }) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.snapshot.withLock({ $0.enabled && $0.generation == generation }) else { return }
            body(NSPasteboard.general)
            self.refresh(announce: false)
        }
    }

    @MainActor private func refresh(announce: Bool) {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard let generation = snapshot.withLock({ state -> UInt64? in
            guard state.enabled, state.changeCount != count else { return nil }
            return state.generation
        }) else { return }

        var items: [String: Data] = [:]
        if let string = pasteboard.string(forType: .string), string.utf8.count <= Self.maxItemBytes {
            items[NSPasteboard.PasteboardType.string.rawValue] = Data(string.utf8)
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("com.microsoft.bmp")]
        for type in imageTypes where pasteboard.types?.contains(type) == true {
            if let data = pasteboard.data(forType: type), data.count <= Self.maxItemBytes {
                items[type.rawValue] = data
            }
        }
        let immutableItems = items
        let changed = snapshot.withLock { state -> Bool in
            guard state.enabled, state.generation == generation else { return false }
            state.changeCount = count
            state.items = immutableItems
            return true
        }
        if announce && changed {
            NotificationCenter.default.post(name: .csPasteboardChanged, object: self)
        }
    }
}

private extension CSPasteboardType {
    var pasteboardType: NSPasteboard.PasteboardType? {
        switch self {
        case .string: return .string
        case .png: return .png
        case .tiff: return .tiff
        case .jpg: return NSPasteboard.PasteboardType("public.jpeg")
        case .bmp: return NSPasteboard.PasteboardType("com.microsoft.bmp")
        default: return nil
        }
    }
}
