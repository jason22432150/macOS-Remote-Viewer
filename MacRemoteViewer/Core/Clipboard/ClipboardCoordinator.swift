import Foundation

public enum ClipboardMode: String, Sendable, CaseIterable {
    case off
    case manual
    case automatic
}

@MainActor
public protocol PasteboardAccessing: AnyObject {
    var changeCount: Int { get }
    func readPlainText() -> String?
    func writePlainText(_ text: String)
    func containsNonTextPayload() -> Bool
}

@MainActor
public protocol SpiceClipboardTransporting: AnyObject {
    var hasAgent: Bool { get }
    var supportsClipboard: Bool { get }
    func sendPlainText(_ utf8: Data, generation: UInt64) async throws
    func requestPlainText(generation: UInt64) async throws -> Data
}

/// 剪貼簿政策的單一來源。自動模式通過驗收前，產品預設為手動。
@MainActor
public final class ClipboardCoordinator {
    public static let maxUTF8Bytes = 1 * 1024 * 1024
    public static let defaultRequestTimeout: Duration = .seconds(5)

    public private(set) var mode: ClipboardMode
    public private(set) var lastError: SessionError?
    public var isWindowActive = false

    private let pasteboard: PasteboardAccessing
    private let transport: SpiceClipboardTransporting
    private let requestTimeout: Duration
    private var agentCapabilities = AgentCapabilities()
    private var generation: UInt64 = 1
    private var lastLocalFingerprint: String?
    private var lastRemoteFingerprint: String?
    private var lastObservedChangeCount: Int = -1

    public init(
        pasteboard: PasteboardAccessing,
        transport: SpiceClipboardTransporting,
        mode: ClipboardMode = .manual,
        requestTimeout: Duration = ClipboardCoordinator.defaultRequestTimeout
    ) {
        self.pasteboard = pasteboard
        self.transport = transport
        self.mode = mode
        self.requestTimeout = requestTimeout
    }

    public func setMode(_ mode: ClipboardMode) {
        self.mode = mode
        lastError = nil
    }

    public func updateAgent(_ capabilities: AgentCapabilities) {
        agentCapabilities = capabilities
        if !capabilities.isConnected || !capabilities.supportsClipboard {
            lastError = capabilities.isConnected ? .clipboardUnsupported : .guestAgentUnavailable
        } else if lastError == .guestAgentUnavailable || lastError == .clipboardUnsupported {
            lastError = nil
        }
    }

    public func invalidateGeneration() {
        generation += 1
        lastLocalFingerprint = nil
        lastRemoteFingerprint = nil
    }

    public func sendLocalTextManually() async {
        await transferLocalToRemote()
    }

    public func fetchRemoteTextManually() async {
        await transferRemoteToLocal()
    }

    /// 由 App 在 pasteboard changeCount 變化且視窗作用中時呼叫。
    public func handleLocalPasteboardChangeIfNeeded() async {
        guard mode == .automatic, isWindowActive else { return }
        let current = pasteboard.changeCount
        guard current != lastObservedChangeCount else { return }
        lastObservedChangeCount = current
        await transferLocalToRemote()
    }

    public func handleRemoteText(_ utf8: Data, generation: UInt64) {
        guard generation == self.generation else { return }
        guard mode != .off else { return }
        do {
            let text = try decodeText(utf8)
            let fingerprint = Self.fingerprint(text)
            if fingerprint == lastLocalFingerprint {
                return
            }
            lastRemoteFingerprint = fingerprint
            pasteboard.writePlainText(text)
            lastObservedChangeCount = pasteboard.changeCount
        } catch let error as SessionError {
            lastError = error
        } catch {
            lastError = .unknown(code: "clipboard-decode")
        }
    }

    private func transferLocalToRemote() async {
        lastError = nil
        guard agentCapabilities.isConnected || transport.hasAgent else {
            lastError = .guestAgentUnavailable
            return
        }
        guard agentCapabilities.supportsClipboard || transport.supportsClipboard else {
            lastError = .clipboardUnsupported
            return
        }
        if pasteboard.containsNonTextPayload() {
            lastError = .unknown(code: "clipboard-non-text")
            return
        }
        guard let text = pasteboard.readPlainText() else {
            return
        }
        do {
            let data = try encodeText(text)
            let capturedGeneration = generation
            lastLocalFingerprint = Self.fingerprint(text)
            let payload = data
            try await withTimeout {
                try await self.transport.sendPlainText(payload, generation: capturedGeneration)
            }
        } catch let error as SessionError {
            lastError = error
        } catch {
            lastError = .unknown(code: "clipboard-send")
        }
    }

    private func transferRemoteToLocal() async {
        lastError = nil
        guard agentCapabilities.isConnected || transport.hasAgent else {
            lastError = .guestAgentUnavailable
            return
        }
        guard agentCapabilities.supportsClipboard || transport.supportsClipboard else {
            lastError = .clipboardUnsupported
            return
        }
        let capturedGeneration = generation
        do {
            let data = try await withTimeout {
                try await self.transport.requestPlainText(generation: capturedGeneration)
            }
            handleRemoteText(data, generation: capturedGeneration)
        } catch let error as SessionError {
            lastError = error
        } catch {
            lastError = .clipboardTimeout
        }
    }

    private func encodeText(_ text: String) throws -> Data {
        guard let data = text.data(using: .utf8) else {
            throw SessionError.unknown(code: "clipboard-encode")
        }
        guard data.count <= Self.maxUTF8Bytes else {
            throw SessionError.clipboardTooLarge(maxBytes: Self.maxUTF8Bytes)
        }
        return data
    }

    private func decodeText(_ data: Data) throws -> String {
        guard data.count <= Self.maxUTF8Bytes else {
            throw SessionError.clipboardTooLarge(maxBytes: Self.maxUTF8Bytes)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionError.unknown(code: "clipboard-decode")
        }
        return text
    }

    private func withTimeout<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let timeout = requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)
            Task { @MainActor in
                do {
                    let value = try await work()
                    box.resume(returning: value)
                } catch {
                    box.resume(throwing: error)
                }
            }
            Task {
                do {
                    try await Task.sleep(for: timeout)
                    box.resume(throwing: SessionError.clipboardTimeout)
                } catch {
                    // 工作已完成並取消 timeout task
                }
            }
        }
    }

    /// 指紋只留在記憶體，不寫入日誌。
    public static func fingerprint(_ text: String) -> String {
        var hasher = Hasher()
        hasher.combine(text.utf8.count)
        hasher.combine(text)
        return String(hasher.finalize())
    }
}

/// 確保 continuation 只 resume 一次，避免 timeout 與完成同時到達。
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
