import Foundation
import CoreGraphics

/// 每個工作階段的狀態、取消、channel 事件與清理順序。不直接操作 pasteboard。
@MainActor
@Observable
public final class SessionController: SpiceEngineDelegate {
    public private(set) var state: SessionState = .idle
    public private(set) var profile: ConnectionProfile?
    public private(set) var agent: AgentCapabilities = AgentCapabilities()
    public private(set) var displaySize: RemoteFrame?
    public private(set) var cleanupResult: SourceCleanupResult = .skipped
    public private(set) var unknownFieldHint: String?

    public let clipboard: ClipboardCoordinator
    public let diagnostics: DiagnosticsLog

    private let engine: SpiceEngineing
    private let files: FileAccessing
    private let cleanup: SourceFileCleanup
    private var didCleanupSource = false

    public init(
        engine: SpiceEngineing,
        clipboard: ClipboardCoordinator,
        files: FileAccessing = FoundationFileAccessor(),
        cleanup: SourceFileCleanup = SourceFileCleanup(),
        diagnostics: DiagnosticsLog = DiagnosticsLog(sessionID: UUID().uuidString)
    ) {
        self.engine = engine
        self.clipboard = clipboard
        self.files = files
        self.cleanup = cleanup
        self.diagnostics = diagnostics
        self.engine.delegate = self
    }

    public func open(_ profile: ConnectionProfile) {
        cancel()
        self.profile = profile
        didCleanupSource = false
        clipboard.invalidateGeneration()
        clipboard.isWindowActive = true
        unknownFieldHint = profile.unknownFieldNames.isEmpty
            ? nil
            : "忽略未支援欄位：\(profile.unknownFieldNames.joined(separator: ", "))"
        diagnostics.compatibilityHint(unknownFields: profile.unknownFieldNames)
        state = .connecting
        do {
            try engine.startWorker()
            try engine.connect(profile: profile)
            diagnostics.info("connecting")
        } catch let error as SessionError {
            fail(error)
        } catch {
            fail(.engineUnavailable)
        }
    }

    public func cancel() {
        switch state {
        case .idle, .disconnected, .failed:
            break
        default:
            state = .disconnecting
        }
        clipboard.isWindowActive = false
        clipboard.invalidateGeneration()
        engine.disconnect()
        engine.releaseKeys()
        if state == .disconnecting {
            state = .disconnected
        }
    }

    public func sendMouse(_ event: MouseEvent) {
        guard state == .connected else { return }
        engine.sendMouse(event)
    }

    public func sendKey(_ event: KeyEvent) {
        guard state == .connected else { return }
        engine.sendKey(event)
    }

    public func releaseKeys() {
        engine.releaseKeys()
    }

    public func sendSecureAttention() {
        engine.sendCtrlAltDelete()
    }

    public func attachRenderer(_ renderer: AnyObject) {
        engine.attachDisplayRenderer(renderer)
    }

    public func requestResolution(_ size: CGSize) {
        guard agent.supportsMonitorsConfig else { return }
        engine.requestResolution(size)
    }

    public func engineDidConnect() {
        state = .connected
        diagnostics.info("connected")
        deleteSourceFileIfNeeded()
    }

    public func engineDidDisconnect() {
        clipboard.invalidateGeneration()
        if state != .failed(.disconnected) {
            state = .disconnected
        }
        diagnostics.info("disconnected")
    }

    public func engineDidFail(_ error: SessionError) {
        fail(error)
    }

    public func engineDidUpdateDisplay(_ frame: RemoteFrame) {
        displaySize = frame
    }

    public func engineDidUpdateAgent(_ capabilities: AgentCapabilities) {
        agent = capabilities
        clipboard.updateAgent(capabilities)
        if !capabilities.isConnected || !capabilities.supportsClipboard {
            diagnostics.info("guest-agent-limited")
        }
    }

    public func engineDidReceiveClipboard(_ data: Data, generation: UInt64) {
        clipboard.handleRemoteText(data, generation: generation)
    }

    private func fail(_ error: SessionError) {
        clipboard.invalidateGeneration()
        clipboard.isWindowActive = false
        state = .failed(error)
        diagnostics.error(error)
        engine.disconnect()
    }

    private func deleteSourceFileIfNeeded() {
        guard !didCleanupSource, let profile else { return }
        didCleanupSource = true
        cleanupResult = cleanup.deleteIfNeeded(profile: profile, files: files)
        switch cleanupResult {
        case .permissionDenied:
            diagnostics.info("source-file-retained-permission")
        case .replacedFilePreserved:
            diagnostics.info("source-file-replaced-not-deleted")
        case .deleted:
            diagnostics.info("source-file-deleted")
        case .skipped:
            break
        }
    }
}
