import CoreGraphics
import Foundation
import Observation

/// 每個工作階段的狀態、取消、channel 事件與清理順序。
@MainActor
@Observable
public final class SessionController: SpiceEngineDelegate, Identifiable {
    public let sessionID: String
    /// `sessionID` 建立後不變，可供 `ForEach` 在非 MainActor 讀取。
    nonisolated public var id: String { sessionID }
    public private(set) var state: SessionState = .idle
    public private(set) var profile: ConnectionProfile?
    public private(set) var agent: AgentCapabilities = AgentCapabilities()
    public private(set) var displaySize: RemoteFrame?
    public private(set) var relativeMouseRequested = false
    public var usesServerMouseMode: Bool { state == .connected && engine.usesServerMouseMode }
    public private(set) var hasRenderedFrame = false
    public private(set) var firstFrameMilliseconds: Int?
    public private(set) var firstFrameDelayed = false
    @ObservationIgnored private var firstFrameTask: Task<Void, Never>?
    private let firstFrameWarningDelay: Duration
    @ObservationIgnored private var frameWaitStarted: ContinuousClock.Instant?
    public private(set) var cleanupResult: SourceCleanupResult = .skipped

    public let diagnostics: DiagnosticsLog
    /// 設定頁會讀取；必須保持 observable。內部 viewport 同步欄位則忽略，避免 layout 期間 willSet。
    public private(set) var resolutionPreference: GuestResolutionPreference
    /// 已送出 monitors config，但 guest 桌面解析度沒有跟上（常見於 Kali／XFCE）。
    public private(set) var guestDidNotApplyResolution = false

    private let engine: SpiceEngineing
    private let files: FileAccessing
    private let cleanup: SourceFileCleanup
    private let connectionTimeout: Duration
    private let displayTimeout: Duration
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    private let resolutionDebounce: Duration
    private let resolutionRetryDelay: Duration
    private let resolutionRetryLimit: Int
    /// 內部同步狀態不可被 SwiftUI 追蹤；layout／`updateNSView` 期間 willSet 會讓 AppKit SIGTRAP。
    @ObservationIgnored private var didCleanupSource = false
    @ObservationIgnored private var pendingViewportSize: CGSize?
    @ObservationIgnored private var lastRequestedFrame: RemoteFrame?
    @ObservationIgnored private var resolutionTask: Task<Void, Never>?
    @ObservationIgnored private var resolutionRetryTask: Task<Void, Never>?
    @ObservationIgnored private var resolutionRetryCount = 0

    public init(
        engine: SpiceEngineing,
        files: FileAccessing = FoundationFileAccessor(),
        cleanup: SourceFileCleanup = SourceFileCleanup(),
        diagnostics: DiagnosticsLog = DiagnosticsLog(sessionID: UUID().uuidString),
        resolutionDebounce: Duration = .milliseconds(400),
        resolutionRetryDelay: Duration = .seconds(2),
        resolutionRetryLimit: Int = 3,
        resolutionPreference: GuestResolutionPreference = .matchWindow,
        sessionID: String = UUID().uuidString,
        connectionTimeout: Duration = .seconds(30),
        displayTimeout: Duration = .seconds(30),
        firstFrameWarningDelay: Duration = .seconds(15)
    ) {
        self.engine = engine
        self.files = files
        self.cleanup = cleanup
        self.diagnostics = diagnostics
        self.connectionTimeout = connectionTimeout
        self.displayTimeout = displayTimeout
        self.firstFrameWarningDelay = firstFrameWarningDelay
        self.resolutionDebounce = resolutionDebounce
        self.resolutionRetryDelay = resolutionRetryDelay
        self.resolutionRetryLimit = resolutionRetryLimit
        self.resolutionPreference = resolutionPreference
        self.sessionID = sessionID
        self.engine.delegate = self
    }

    public func open(_ profile: ConnectionProfile) {
        cancel()
        self.profile = profile
        didCleanupSource = false
        cleanupResult = .skipped
        agent = AgentCapabilities()
        displaySize = nil
        relativeMouseRequested = false
        resetFrameObservation()
        diagnostics.compatibilityHint(unknownFields: profile.unknownFieldNames)
        state = .connecting
        frameWaitStarted = ContinuousClock.now
        if connectionTimeout > .zero {
            let delay = connectionTimeout
            connectionTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, let self, self.state == .connecting else { return }
                self.fail(.network)
            }
        }
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
        engine.releaseKeys()
        engine.disconnect()
        agent = AgentCapabilities()
        displaySize = nil
        relativeMouseRequested = false
        resetFrameObservation()
        if state == .disconnecting {
            state = .disconnected
        }
    }

    public func setRelativeMouseMode(_ enabled: Bool) {
        guard state == .connected, relativeMouseRequested != enabled else { return }
        engine.releaseKeys()
        relativeMouseRequested = enabled
        engine.requestRelativeMouseMode(enabled)
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
        guard state == .connected else { return }
        engine.sendCtrlAltDelete()
    }

    public func attachRenderer(_ renderer: AnyObject) {
        engine.attachDisplayRenderer(renderer)
    }

    public func detachRenderer(_ renderer: AnyObject) {
        // 雙擊第二個 `.vv` 若拆掉第一個連線的 Metal 畫面，這裡會留下紀錄。
        diagnostics.info("renderer-detach")
        engine.detachDisplayRenderer(renderer)
    }

    /// 以畫面視圖的邏輯尺寸（points）對齊 guest 解析度；無 vdagent 時略過。
    public func updateViewportSize(_ size: CGSize) {
        guard pendingViewportSize != size else { return }
        pendingViewportSize = size
        scheduleResolutionSync()
    }

    /// 設定頁變更解析度策略時立刻套用；重設 lastRequested 以免被去重擋下。
    public func applyResolutionPreference(_ preference: GuestResolutionPreference) {
        guard resolutionPreference != preference else { return }
        resolutionPreference = preference
        engine.clearPendingResolution()
        lastRequestedFrame = nil
        resolutionRetryCount = 0
        guestDidNotApplyResolution = false
        resolutionRetryTask?.cancel()
        resolutionRetryTask = nil
        flushResolutionIfNeeded()
    }

    public func setClipboardSharingEnabled(_ enabled: Bool) {
        engine.setClipboardSharingEnabled(enabled)
    }

    public func engineDidConnect() {
        guard state == .connecting else { return }
        connectionTask?.cancel()
        connectionTask = nil
        state = .connected
        diagnostics.info("connected")
        scheduleDisplayTimeoutIfNeeded()
        scheduleFirstFrameWarningIfNeeded()
        deleteSourceFileIfNeeded()
        flushResolutionIfNeeded()
    }

    public func engineDidDisconnect() {
        guard state == .connecting || state == .connected else { return }
        resolutionTask?.cancel()
        resolutionTask = nil
        resolutionRetryTask?.cancel()
        resolutionRetryTask = nil
        lastRequestedFrame = nil
        resolutionRetryCount = 0
        guestDidNotApplyResolution = false
        connectionTask?.cancel()
        connectionTask = nil
        displayTask?.cancel()
        displayTask = nil
        agent = AgentCapabilities()
        displaySize = nil
        relativeMouseRequested = false
        resetFrameObservation()
        if case .failed = state { return }
        state = .disconnected
        engine.disconnect()
        diagnostics.info("disconnected")
    }

    public func engineDidFail(_ error: SessionError) {
        guard state == .connecting || state == .connected else { return }
        fail(error)
    }

    public func engineDidUpdateDisplay(_ frame: RemoteFrame) {
        guard state == .connecting || state == .connected else { return }
        guard frame.width > 0, frame.height > 0 else { return }
        displayTask?.cancel()
        displayTask = nil
        displaySize = frame
        scheduleFirstFrameWarningIfNeeded()
        if frame == lastRequestedFrame {
            engine.clearPendingResolution()
            lastRequestedFrame = nil
            resolutionRetryTask?.cancel()
            resolutionRetryTask = nil
            resolutionRetryCount = 0
            guestDidNotApplyResolution = false
            return
        }
        // 尚未送出過目標尺寸時，guest 自行改解析度仍要以視窗為準再對齊。
        // 已送出則交給 lastRequested 去重，避免與 guest 套用中的中間尺寸互打。
        if lastRequestedFrame == nil {
            flushResolutionIfNeeded()
        }
    }

    public func engineDidLoseDisplay() {
        guard state == .connecting || state == .connected else { return }
        displaySize = nil
        resetFrameObservation()
        engine.clearPendingResolution()
        lastRequestedFrame = nil
        resolutionRetryTask?.cancel()
        resolutionRetryTask = nil
        resolutionRetryCount = 0
        guestDidNotApplyResolution = false
        frameWaitStarted = ContinuousClock.now
        engine.releaseKeys()
        scheduleDisplayTimeoutIfNeeded()
    }

    public func engineDidRenderFrame() {
        guard (state == .connecting || state == .connected), !hasRenderedFrame else { return }
        firstFrameTask?.cancel()
        firstFrameTask = nil
        firstFrameDelayed = false
        hasRenderedFrame = true
        if let start = frameWaitStarted {
            let elapsed = start.duration(to: ContinuousClock.now).components
            let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            firstFrameMilliseconds = milliseconds
            diagnostics.info("first-frame-rendered-ms \(milliseconds)")
        }
    }

    private func resetFrameObservation() {
        firstFrameTask?.cancel()
        firstFrameTask = nil
        firstFrameDelayed = false
        hasRenderedFrame = false
        firstFrameMilliseconds = nil
        frameWaitStarted = nil
    }

    // A hidden or minimized MTKView may have no drawable, so warn instead of disconnecting.
    private func scheduleFirstFrameWarningIfNeeded() {
        guard state == .connected, displaySize != nil, !hasRenderedFrame,
              !firstFrameDelayed, firstFrameTask == nil, firstFrameWarningDelay > .zero else { return }
        let delay = firstFrameWarningDelay
        firstFrameTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, self.state == .connected,
                  self.displaySize != nil, !self.hasRenderedFrame else { return }
            self.firstFrameTask = nil
            self.firstFrameDelayed = true
            self.diagnostics.info("first-frame-delayed")
        }
    }

    private func scheduleDisplayTimeoutIfNeeded() {
        guard state == .connected, displaySize == nil, displayTask == nil,
              displayTimeout > .zero else { return }
        let delay = displayTimeout
        displayTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, self.state == .connected,
                  self.displaySize == nil else { return }
            self.fail(.displayTimeout)
        }
    }

    public func engineDidUpdateAgent(_ capabilities: AgentCapabilities) {
        guard state == .connecting || state == .connected else { return }
        if !capabilities.isConnected || !capabilities.supportsMonitorsConfig {
            engine.clearPendingResolution()
            resolutionRetryTask?.cancel()
            resolutionRetryTask = nil
            lastRequestedFrame = nil
            resolutionRetryCount = 0
            guestDidNotApplyResolution = false
        }
        let gainedMonitorsConfig = !agent.supportsMonitorsConfig && capabilities.supportsMonitorsConfig
        agent = capabilities
        if !capabilities.isConnected || !capabilities.supportsClipboard {
            diagnostics.info("guest-agent-limited")
        }
        if gainedMonitorsConfig {
            resolutionRetryTask?.cancel()
            resolutionRetryTask = nil
            resolutionRetryCount = 0
            guestDidNotApplyResolution = false
            lastRequestedFrame = nil
        }
        flushResolutionIfNeeded()
    }

    private func fail(_ error: SessionError) {
        resetResolutionSync()
        state = .failed(error)
        agent = AgentCapabilities()
        displaySize = nil
        relativeMouseRequested = false
        resetFrameObservation()
        diagnostics.error(error)
        engine.releaseKeys()
        engine.disconnect()
    }

    /// 拖曳縮放會連續觸發；等尺寸穩定後才送 monitors config。
    private func scheduleResolutionSync() {
        resolutionTask?.cancel()
        if resolutionDebounce == .zero {
            flushResolutionIfNeeded()
            return
        }
        let delay = resolutionDebounce
        resolutionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushResolutionIfNeeded()
        }
    }

    private func flushResolutionIfNeeded() {
        guard state == .connected else { return }
        guard agent.isConnected, agent.supportsMonitorsConfig else { return }
        guard let frame = GuestResolutionPolicy.targetFrame(
            preference: resolutionPreference,
            windowSize: pendingViewportSize
        ) else { return }
        // Cancel an obsolete target even when the new target already matches the guest.
        if let previous = lastRequestedFrame, previous != frame {
            engine.clearPendingResolution()
            resolutionRetryTask?.cancel()
            resolutionRetryTask = nil
            lastRequestedFrame = nil
            resolutionRetryCount = 0
            guestDidNotApplyResolution = false
        }
        guard GuestResolutionPolicy.shouldRequest(
            frame,
            currentDisplay: displaySize,
            lastRequested: lastRequestedFrame
        ) else {
            return
        }
        resolutionRetryCount = 0
        guestDidNotApplyResolution = false
        lastRequestedFrame = frame
        diagnostics.info("guest-resolution \(frame.width)x\(frame.height)")
        engine.requestResolution(CGSize(width: frame.width, height: frame.height))
        scheduleResolutionRetry()
    }

    /// Linux session agent 常比 capability 晚就緒；逾時仍未套用就再送一次。
    private func scheduleResolutionRetry() {
        resolutionRetryTask?.cancel()
        guard resolutionRetryDelay > .zero else { return }
        let requested = lastRequestedFrame
        let delay = resolutionRetryDelay
        resolutionRetryTask = Task { @MainActor [weak self] in
            guard let requested else { return }
            // Keep a single task for this target instead of cancelling and spawning
            // a replacement from inside the retry callback.
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, let self, self.state == .connected, self.agent.isConnected,
                      self.agent.supportsMonitorsConfig,
                      self.lastRequestedFrame == requested else { return }
                if self.displaySize == requested {
                    self.resolutionRetryTask = nil
                    return
                }
                guard self.resolutionRetryCount < self.resolutionRetryLimit else {
                    self.guestDidNotApplyResolution = true
                    self.diagnostics.info("guest-resolution-unapplied \(requested.width)x\(requested.height)")
                    self.resolutionRetryTask = nil
                    return
                }
                self.resolutionRetryCount += 1
                self.engine.requestResolution(CGSize(width: requested.width, height: requested.height))
            }
        }
    }

    private func resetResolutionSync() {
        displayTask?.cancel()
        displayTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        resolutionRetryTask?.cancel()
        resolutionRetryTask = nil
        pendingViewportSize = nil
        lastRequestedFrame = nil
        resolutionRetryCount = 0
        guestDidNotApplyResolution = false
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
