import Foundation
import CoreGraphics

/// 每個工作階段的狀態、取消、channel 事件與清理順序。
@MainActor
@Observable
public final class SessionController: SpiceEngineDelegate {
    public private(set) var state: SessionState = .idle
    public private(set) var profile: ConnectionProfile?
    public private(set) var agent: AgentCapabilities = AgentCapabilities()
    public private(set) var displaySize: RemoteFrame?
    public private(set) var cleanupResult: SourceCleanupResult = .skipped
    public private(set) var unknownFieldHint: String?

    public let diagnostics: DiagnosticsLog

    private let engine: SpiceEngineing
    private let files: FileAccessing
    private let cleanup: SourceFileCleanup
    private let resolutionDebounce: Duration
    private var didCleanupSource = false
    private var pendingViewportSize: CGSize?
    private var lastRequestedFrame: RemoteFrame?
    private var resolutionTask: Task<Void, Never>?

    public init(
        engine: SpiceEngineing,
        files: FileAccessing = FoundationFileAccessor(),
        cleanup: SourceFileCleanup = SourceFileCleanup(),
        diagnostics: DiagnosticsLog = DiagnosticsLog(sessionID: UUID().uuidString),
        resolutionDebounce: Duration = .milliseconds(400)
    ) {
        self.engine = engine
        self.files = files
        self.cleanup = cleanup
        self.diagnostics = diagnostics
        self.resolutionDebounce = resolutionDebounce
        self.engine.delegate = self
    }

    public func open(_ profile: ConnectionProfile) {
        cancel()
        self.profile = profile
        didCleanupSource = false
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
        resetResolutionSync()
        switch state {
        case .idle, .disconnected, .failed:
            break
        default:
            state = .disconnecting
        }
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

    /// 以畫面視圖的邏輯尺寸（points）對齊 guest 解析度；無 vdagent 時略過。
    public func updateViewportSize(_ size: CGSize) {
        guard pendingViewportSize != size else { return }
        pendingViewportSize = size
        scheduleResolutionSync()
    }

    public func requestResolution(_ size: CGSize) {
        updateViewportSize(size)
    }

    public func engineDidConnect() {
        state = .connected
        diagnostics.info("connected")
        deleteSourceFileIfNeeded()
        flushResolutionIfNeeded()
    }

    public func engineDidDisconnect() {
        resolutionTask?.cancel()
        resolutionTask = nil
        lastRequestedFrame = nil
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
        // 尚未送出過目標尺寸時，guest 自行改解析度仍要以視窗為準再對齊。
        // 已送出則交給 lastRequested 去重，避免與 guest 套用中的中間尺寸互打。
        if lastRequestedFrame == nil {
            flushResolutionIfNeeded()
        }
    }

    public func engineDidUpdateAgent(_ capabilities: AgentCapabilities) {
        let gainedMonitorsConfig = !agent.supportsMonitorsConfig && capabilities.supportsMonitorsConfig
        agent = capabilities
        if !capabilities.isConnected || !capabilities.supportsClipboard {
            diagnostics.info("guest-agent-limited")
        }
        if gainedMonitorsConfig {
            lastRequestedFrame = nil
        }
        flushResolutionIfNeeded()
    }

    private func fail(_ error: SessionError) {
        resetResolutionSync()
        state = .failed(error)
        diagnostics.error(error)
        engine.disconnect()
    }

    /// 拖曳縮放會連續觸發；等尺寸穩定後才送 monitors config。
    private func scheduleResolutionSync() {
        resolutionTask?.cancel()
        if resolutionDebounce == .zero {
            flushResolutionIfNeeded()
            return
        }
        resolutionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: resolutionDebounce)
            } catch {
                return
            }
            flushResolutionIfNeeded()
        }
    }

    private func flushResolutionIfNeeded() {
        guard state == .connected else { return }
        guard agent.supportsMonitorsConfig else { return }
        guard let pendingViewportSize else { return }
        guard let frame = GuestResolutionPolicy.frame(forViewSize: pendingViewportSize) else { return }
        guard GuestResolutionPolicy.shouldRequest(
            frame,
            currentDisplay: displaySize,
            lastRequested: lastRequestedFrame
        ) else {
            return
        }
        lastRequestedFrame = frame
        diagnostics.info("guest-resolution \(frame.width)x\(frame.height)")
        engine.requestResolution(CGSize(width: frame.width, height: frame.height))
    }

    private func resetResolutionSync() {
        resolutionTask?.cancel()
        resolutionTask = nil
        pendingViewportSize = nil
        lastRequestedFrame = nil
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
