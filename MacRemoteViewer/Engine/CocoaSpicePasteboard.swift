import AppKit
import Foundation
import os
import CocoaSpiceNoUsb

/// The GLib worker never waits synchronously for the main thread.
/// Each activation has a generation; queued writes from old tabs are discarded.
final class CocoaSpicePasteboard: NSObject, CSPasteboardDelegate, @unchecked Sendable {
    // Immutable, privately owned bytes. The last strong reference erases
    // the entire allocation before releasing it. AppKit/CocoaSpice copies
    // are outside our control; never expose a no-copy Data or raw pointer.
    fileprivate final class OwnedBuffer: @unchecked Sendable {
        private let bytes: UnsafeMutableRawPointer
        let count: Int
        private let capacity: Int

        init(_ data: Data) {
            count = data.count
            capacity = max(1, data.count)
            let allocation = UnsafeMutableRawPointer.allocate(byteCount: max(1, data.count), alignment: 1)
            bytes = allocation
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                if let base = source.baseAddress, !source.isEmpty {
                    allocation.copyMemory(from: base, byteCount: source.count)
                } else {
                    allocation.storeBytes(of: UInt8(0), as: UInt8.self)
                }
            }
        }

        func dataValue() -> Data {
            withExtendedLifetime(self) { Data(bytes: bytes, count: count) }
        }

        func stringValue() -> String {
            withExtendedLifetime(self) {
                String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
            }
        }

        deinit {
            ConnectionProfile.Ticket.clearOwnedBytes(
                UnsafeMutableRawBufferPointer(start: bytes, count: capacity))
            bytes.deallocate()
        }
    }

    // Weak handles expose no payload and do not extend its lifetime.
    final class BufferLifetime: @unchecked Sendable {
        private weak var buffer: OwnedBuffer?
        fileprivate init(_ buffer: OwnedBuffer) { self.buffer = buffer }
        var isAlive: Bool { buffer != nil }
    }

    private enum WritePayload: Sendable {
        case text(OwnedBuffer)
        case binary(String, OwnedBuffer)
        case clear

        var buffer: OwnedBuffer? {
            switch self {
            case .text(let value), .binary(_, let value): return value
            case .clear: return nil
            }
        }

        @MainActor func apply(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            switch self {
            case .text(let value):
                pasteboard.setString(value.stringValue(), forType: .string)
            case .binary(let key, let value):
                pasteboard.setData(value.dataValue(), forType: NSPasteboard.PasteboardType(key))
            case .clear: break
            }
        }
    }

    private struct PendingWrite: Sendable {
        let generation: UInt64
        let payload: WritePayload
    }

    private struct Snapshot: Sendable {
        var enabled = false
        var generation: UInt64 = 0
        var changeCount = -1
        var items: [String: OwnedBuffer] = [:]
        var pendingWrite: PendingWrite?
        var drainScheduled = false
    }

    private let snapshot = OSAllocatedUnfairLock(initialState: Snapshot())
    // nil is the production system pasteboard. A probe may inject an
    // isolated named pasteboard, never redirect production clipboard traffic.
    private let pasteboardName: NSPasteboard.Name?

    @MainActor init(pasteboardName: NSPasteboard.Name? = nil) {
        self.pasteboardName = pasteboardName
        super.init()
    }

    @MainActor private var pasteboard: NSPasteboard {
        if let pasteboardName { return NSPasteboard(name: pasteboardName) }
        return NSPasteboard.general
    }
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
        let retired = snapshot.withLock { state -> ([String: OwnedBuffer], PendingWrite?) in
            let old = (state.items, state.pendingWrite)
            state.enabled = false
            state.generation &+= 1
            state.items = [:]
            state.pendingWrite = nil
            state.changeCount = -1
            return old
        }
        pollTask?.cancel()
        pollTask = nil
        // Do not wipe multi-MiB buffers while holding the worker lock.
        withExtendedLifetime(retired) {}
    }

    func canReadItem(for type: CSPasteboardType) -> Bool {
        guard let key = type.pasteboardType?.rawValue else { return false }
        return snapshot.withLock { $0.enabled && $0.items[key] != nil }
    }

    func data(for type: CSPasteboardType) -> Data? {
        guard let key = type.pasteboardType?.rawValue else { return nil }
        let buffer = snapshot.withLock { $0.enabled ? $0.items[key] : nil }
        return buffer?.dataValue()
    }

    func string() -> String? {
        let key = NSPasteboard.PasteboardType.string.rawValue
        let buffer = snapshot.withLock { $0.enabled ? $0.items[key] : nil }
        return buffer?.stringValue()
    }

    @MainActor func bufferLifetimesForProbe() -> [BufferLifetime] {
        guard pasteboardName != nil,
              ProcessInfo.processInfo.environment["MRV_ENABLE_INTEGRATION_PROBES"] == "1" else { return [] }
        return snapshot.withLock { state in
            var handles = state.items.values.map { BufferLifetime($0) }
            if let buffer = state.pendingWrite?.payload.buffer {
                handles.append(BufferLifetime(buffer))
            }
            return handles
        }
    }

    @MainActor func refreshForProbe() {
        guard pasteboardName != nil,
              ProcessInfo.processInfo.environment["MRV_ENABLE_INTEGRATION_PROBES"] == "1" else { return }
        refresh(announce: false)
    }

    private func activeGeneration() -> UInt64? {
        snapshot.withLock { $0.enabled ? $0.generation : nil }
    }

    func setData(_ data: Data, for type: CSPasteboardType) {
        guard data.count <= Self.maxItemBytes, let generation = activeGeneration() else { return }
        if type == .string {
            guard String(data: data, encoding: .utf8) != nil else { return }
            enqueueWrite(.text(OwnedBuffer(data)), generation: generation)
            return
        }
        guard let key = type.pasteboardType?.rawValue else { return }
        enqueueWrite(.binary(key, OwnedBuffer(data)), generation: generation)
    }

    func setString(_ string: String) {
        guard string.utf8.count <= Self.maxItemBytes, let generation = activeGeneration() else { return }
        enqueueWrite(.text(OwnedBuffer(Data(string.utf8))), generation: generation)
    }

    func clearContents() {
        guard let generation = activeGeneration() else { return }
        enqueueWrite(.clear, generation: generation)
    }

    private func enqueueWrite(_ payload: WritePayload, generation: UInt64) {
        // A generation captured before copying prevents an old activation's
        // large buffer from being queued after a stop/start on the main actor.
        let (schedule, retired) = snapshot.withLock { state -> (Bool, PendingWrite?) in
            guard state.enabled, state.generation == generation else { return (false, nil) }
            let old = state.pendingWrite
            state.pendingWrite = PendingWrite(generation: generation, payload: payload)
            guard !state.drainScheduled else { return (false, old) }
            state.drainScheduled = true
            return (true, old)
        }
        withExtendedLifetime(retired) {}
        guard schedule else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (valid, write) = self.snapshot.withLock { state -> (Bool, PendingWrite?) in
                let write = state.pendingWrite
                state.pendingWrite = nil
                state.drainScheduled = false
                return (state.enabled && write?.generation == state.generation, write)
            }
            guard valid, let write else { return }
            write.payload.apply(to: self.pasteboard)
            self.refresh(announce: false)
        }
    }

    @MainActor private func refresh(announce: Bool) {
        let pasteboard = self.pasteboard
        let count = pasteboard.changeCount
        guard let generation = snapshot.withLock({ state -> UInt64? in
            guard state.enabled, state.changeCount != count else { return nil }
            return state.generation
        }) else { return }

        var items: [String: OwnedBuffer] = [:]
        var totalBytes = 0
        if let string = pasteboard.string(forType: .string), string.utf8.count <= Self.maxItemBytes {
            let data = Data(string.utf8)
            items[NSPasteboard.PasteboardType.string.rawValue] = OwnedBuffer(data)
            totalBytes += data.count
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("com.microsoft.bmp")]
        for type in imageTypes where pasteboard.types?.contains(type) == true {
            if let data = pasteboard.data(forType: type), data.count <= Self.maxItemBytes,
               data.count <= Self.maxSnapshotBytes - totalBytes {
                items[type.rawValue] = OwnedBuffer(data)
                totalBytes += data.count
            }
        }
        // Do not publish a mixed snapshot if another process changed the board.
        guard pasteboard.changeCount == count else { return }
        let immutableItems = items
        let retired = snapshot.withLock { state -> [String: OwnedBuffer]? in
            guard state.enabled, state.generation == generation else { return nil }
            let old = state.items
            state.changeCount = count
            state.items = immutableItems
            return old
        }
        withExtendedLifetime(retired) {}
        if announce && retired != nil {
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
