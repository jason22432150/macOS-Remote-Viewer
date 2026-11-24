import AppKit
import Foundation
import os
import CocoaSpiceNoUsb

/// The GLib worker never waits synchronously for the main thread.
/// Each activation has a generation; queued writes from old tabs are discarded.
final class CocoaSpicePasteboard: NSObject, CSPasteboardDelegate, @unchecked Sendable {
    private struct PendingWrite: Sendable {
        let generation: UInt64
        let body: @MainActor @Sendable (NSPasteboard) -> Void
    }

    private struct Snapshot: Sendable {
        var enabled = false
        var generation: UInt64 = 0
        var changeCount = -1
        var items: [String: Data] = [:]
        var pendingWrite: PendingWrite?
        var drainScheduled = false
    }

    private let snapshot = OSAllocatedUnfairLock(initialState: Snapshot())
    @MainActor private var pollTask: Task<Void, Never>?
    private static let maxItemBytes = 16 * 1024 * 1024
    private static let maxSnapshotBytes = 32 * 1024 * 1024

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
            $0.pendingWrite = nil
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
        // Each write replaces the entire pasteboard. Coalesce pending writes
        // to the newest value and keep at most one queued main-actor drain.
        let schedule = snapshot.withLock { state -> Bool in
            guard state.enabled else { return false }
            state.pendingWrite = PendingWrite(generation: state.generation, body: body)
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let write = self.snapshot.withLock { state -> PendingWrite? in
                defer {
                    state.pendingWrite = nil
                    state.drainScheduled = false
                }
                guard state.enabled, let write = state.pendingWrite,
                      write.generation == state.generation else { return nil }
                return write
            }
            guard let write else { return }
            write.body(NSPasteboard.general)
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
        var totalBytes = 0
        if let string = pasteboard.string(forType: .string), string.utf8.count <= Self.maxItemBytes {
            let data = Data(string.utf8)
            items[NSPasteboard.PasteboardType.string.rawValue] = data
            totalBytes += data.count
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("com.microsoft.bmp")]
        for type in imageTypes where pasteboard.types?.contains(type) == true {
            if let data = pasteboard.data(forType: type), data.count <= Self.maxItemBytes,
               data.count <= Self.maxSnapshotBytes - totalBytes {
                items[type.rawValue] = data
                totalBytes += data.count
            }
        }
        // Do not publish a mixed snapshot if another process changed the board.
        guard pasteboard.changeCount == count else { return }
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
