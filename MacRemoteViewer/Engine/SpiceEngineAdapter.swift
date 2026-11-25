import Foundation
import AppKit
import MetalKit
@preconcurrency import CocoaSpiceNoUsb
import CocoaSpiceRenderer

/// 封裝 CocoaSpice／C API，集中 callback 與執行緒轉接。UI 不持有 C 指標。
@MainActor
final class SpiceEngineAdapter: NSObject, SpiceEngineing, CSConnectionDelegate {
    weak var delegate: SpiceEngineDelegate?

    private var connection: CSConnection?
    // No native object or credential is retained for this integration assertion.
    private(set) var lastNativeCredentialCleanupSucceeded: Bool?
    private var input: CSInput?
    private var display: CSDisplay?
    private let spicePasteboard: CocoaSpicePasteboard

    override init() {
        spicePasteboard = CocoaSpicePasteboard()
        super.init()
    }

    init(pasteboardName: NSPasteboard.Name) {
        spicePasteboard = CocoaSpicePasteboard(pasteboardName: pasteboardName)
        super.init()
    }
    // The view owns its renderer; preserve its registration across reconnects.
    private weak var pendingRenderer: CSRenderer?
    private var attachedRenderer: CSRenderer?
    private var frameGeneration = UUID()
    private var pendingResolution: CGSize?
    private static var workerStarted = false
    private var pressedMouseMask: UInt32 = 0
    private var relativeMouseRequested = false
    var usesServerMouseMode: Bool { input?.serverModeCursor == true }

    func requestRelativeMouseMode(_ enabled: Bool) {
        relativeMouseRequested = enabled
        input?.requestMouseMode(enabled)
    }
    /// 預設開啟；workspace 會在多 session 時只留給作用中分頁。
    private var clipboardSharingEnabled = false

    func startWorker() throws {
        if Self.workerStarted { return }
        CSMain.shared.spiceSetDebug(false)
        guard CSMain.shared.spiceStart() else {
            throw SessionError.engineUnavailable
        }
        Self.workerStarted = true
    }

    func connect(profile: ConnectionProfile) throws {
        try VVParser.validateTransport(host: profile.host, tlsPort: profile.tlsPort,
                                       proxyURL: profile.proxyURL, hostSubject: profile.hostSubject,
                                       ticket: profile.ticket.value)
        guard let pem = String(data: profile.caPEM, encoding: .utf8) else { throw SessionError.invalidCA }
        let validatedCA = try VVParser.validatedCA(pem)
        disconnect()
        lastNativeCredentialCleanupSucceeded = nil
        let connection = CSConnection(host: profile.host, port: String(profile.tlsPort))
        connection.audioEnabled = false
        connection.delegate = self

        let proxy = profile.proxyURL?.absoluteString
        do {
            try connection.pve_applyHost(
                profile.host,
                tlsPort: String(profile.tlsPort),
                proxy: proxy,
                ca: validatedCA,
                certSubject: profile.hostSubject,
                password: profile.ticket.value
            )
        } catch {
            connection.delegate = nil
            lastNativeCredentialCleanupSucceeded = connection.disconnectPVEAndClearCredentials()
            throw SessionError.engineUnavailable
        }

        self.connection = connection
        applyClipboardSharing(to: connection)
        attachPendingRenderer()
        guard connection.connect() else {
            disconnect()
            throw SessionError.network
        }
    }

    func disconnect() {
        releaseKeys()
        spicePasteboard.stopPolling()
        connection?.session.pve_setClipboardDelegate(nil, enabled: false)
        clearFrameObserver()
        if let attachedRenderer { display?.removeRenderer(attachedRenderer) }
        if let connection {
            connection.delegate = nil
            let cleared = connection.disconnectPVEAndClearCredentials()
            lastNativeCredentialCleanupSucceeded = cleared
            if !cleared {
                NSLog("Native SPICE terminal credential cleanup verification failed")
            }
        }
        connection = nil
        input = nil
        relativeMouseRequested = false
        display = nil
        attachedRenderer = nil
        pendingResolution = nil
    }

    func sendMouse(_ event: MouseEvent) {
        guard let input else { return }
        switch event.kind {
        case .move:
            let mask = CSInputButton(rawValue: UInt(pressedMouseMask))
            if input.serverModeCursor {
                let delta = event.relativeDelta ?? .zero
                guard delta.x.isFinite, delta.y.isFinite else { return }
                input.sendMouseMotion(mask, relativePoint: delta)
            } else {
                input.sendMousePosition(mask, absolutePoint: event.point)
                // client 模式必須自己移動 overlay，否則遠端游標會停在舊位置。
                display?.cursor?.move(to: event.point)
            }
        case .down, .up:
            // 只能送剛變化的那一顆 bit；複合 mask 當 button id 時 SPICE 會解成無效值。
            let button = CSInputButton(rawValue: UInt(event.button))
            guard !button.isEmpty else { return }
            if event.kind == .down {
                guard pressedMouseMask & event.button == 0 else { return }
                pressedMouseMask |= event.button
            } else {
                guard pressedMouseMask & event.button != 0 else { return }
                pressedMouseMask &= ~event.button
            }
            let mask = CSInputButton(rawValue: UInt(pressedMouseMask))
            // In client mode, ensure the server receives the actual click
            // location even when AppKit did not send a preceding move event.
            if !input.serverModeCursor {
                let previousMask = event.kind == .down ? pressedMouseMask & ~event.button : pressedMouseMask | event.button
                input.sendMousePosition(CSInputButton(rawValue: UInt(previousMask)), absolutePoint: event.point)
                display?.cursor?.move(to: event.point)
            }
            input.sendMouseButton(button, mask: mask, pressed: event.kind == .down)
        case .scroll:
            guard event.scrollDelta.isFinite else { return }
            let mask = CSInputButton(rawValue: UInt(pressedMouseMask))
            let delta = min(max(event.scrollDelta, -64), 64)
            if event.scrollIsHorizontal {
                input.sendHorizontalScrollCompatibility(mask, dx: delta)
            } else {
                input.sendMouseScroll(.smooth, buttonMask: mask, dy: delta)
            }
        }
    }

    func sendKey(_ event: KeyEvent) {
        guard let input else { return }
        let kind: CSInputKey = event.pressed ? .press : .release
        if event.isPause {
            input.sendPause(kind)
        } else {
            input.send(kind, code: Int32(event.scancode))
        }
    }

    func releaseKeys() {
        input?.releaseKeys()
        for bit in [MouseButtonMapping.left, MouseButtonMapping.middle, MouseButtonMapping.right,
                    MouseButtonMapping.side, MouseButtonMapping.extra] where pressedMouseMask & bit != 0 {
            pressedMouseMask &= ~bit
            input?.sendMouseButton(CSInputButton(rawValue: UInt(bit)),
                                   mask: CSInputButton(rawValue: UInt(pressedMouseMask)), pressed: false)
        }
        pressedMouseMask = 0
    }

    func sendCtrlAltDelete() {
        input?.sendSecureAttention()
    }

    func setClipboardSharingEnabled(_ enabled: Bool) {
        clipboardSharingEnabled = enabled
        if let connection {
            applyClipboardSharing(to: connection)
        } else if !enabled {
            spicePasteboard.stopPolling()
        }
    }

    func attachDisplayRenderer(_ renderer: AnyObject) {
        guard let renderer = renderer as? CSRenderer else { return }
        if pendingRenderer !== renderer {
            clearFrameObserver()
            if let attachedRenderer { display?.removeRenderer(attachedRenderer) }
            attachedRenderer = nil
            pendingRenderer = renderer
        }
        attachPendingRenderer()
    }

    func detachDisplayRenderer(_ renderer: AnyObject) {
        guard let renderer = renderer as? CSRenderer else { return }
        if pendingRenderer === renderer {
            clearFrameObserver()
            pendingRenderer = nil
        }
        if attachedRenderer === renderer {
            attachedRenderer = nil
            display?.removeRenderer(renderer)
        }
    }

    private func attachPendingRenderer() {
        guard let display, let pendingRenderer, attachedRenderer !== pendingRenderer else { return }
        attachedRenderer = pendingRenderer
        if let renderer = pendingRenderer as? CSMetalRenderer {
            let generation = UUID()
            frameGeneration = generation
            renderer.frameRenderedHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.frameGeneration == generation else { return }
                    self.clearFrameObserver()
                    self.delegate?.engineDidRenderFrame()
                }
            }
        }
        display.addRenderer(pendingRenderer)
    }

    private func clearFrameObserver() {
        frameGeneration = UUID()
        (pendingRenderer as? CSMetalRenderer)?.frameRenderedHandler = nil
    }

    private func applyClipboardSharing(to connection: CSConnection) {
        if clipboardSharingEnabled {
            spicePasteboard.startPolling()
            connection.session.pve_setClipboardDelegate(spicePasteboard, enabled: true)
        } else {
            spicePasteboard.stopPolling()
            connection.session.pve_setClipboardDelegate(nil, enabled: false)
        }
    }

    func clearPendingResolution() { pendingResolution = nil }

    func requestResolution(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        pendingResolution = size
        applyPendingResolution()
    }

    /// Display channel 可能比 agent 晚就緒；先記住目標尺寸，避免請求被丟掉。
    private func applyPendingResolution() {
        guard let display, let pendingResolution else { return }
        display.requestResolution(CGRect(origin: .zero, size: pendingResolution))
    }

    // MARK: - CSConnectionDelegate

    /// CocoaSpice 從 GLib worker 呼叫；不可直接進入 MainActor 隔離方法。
    nonisolated func spiceConnected(_ connection: CSConnection) {
        hopToMain(from: connection) { adapter in
            adapter.delegate?.engineDidConnect()
        }
    }

    nonisolated func spiceDisconnected(_ connection: CSConnection) {
        hopToMain(from: connection) { adapter in
            adapter.delegate?.engineDidDisconnect()
        }
    }

    nonisolated func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        hopToMain(from: connection) { adapter in
            adapter.input = input
            // spice-gtk already defaults to client mouse mode. Do not
            // inject a redundant main-channel message during channel setup.
            if adapter.relativeMouseRequested {
                input.requestMouseMode(true)
            }
        }
    }

    nonisolated func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        hopToMain(from: connection) { adapter in
            if adapter.input === input {
                adapter.pressedMouseMask = 0
                adapter.input = nil
            }
        }
    }

    nonisolated func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        let error = Self.mapError(code: code, message: message)
        hopToMain(from: connection) { adapter in
            adapter.delegate?.engineDidFail(error)
        }
    }

    nonisolated func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        let frame = Self.validatedFrame(display.displaySize)
        let isPrimary = display.isPrimaryDisplay
        hopToMain(from: connection) { adapter in
            if adapter.display == nil || isPrimary {
                if adapter.display !== display {
                    adapter.clearFrameObserver()
                    if let attached = adapter.attachedRenderer { adapter.display?.removeRenderer(attached) }
                    if adapter.display != nil { adapter.delegate?.engineDidLoseDisplay() }
                    adapter.attachedRenderer = nil
                }
                adapter.display = display
                adapter.attachPendingRenderer()
                adapter.applyPendingResolution()
                if let frame { adapter.delegate?.engineDidUpdateDisplay(frame) }
            }
        }
    }

    nonisolated func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        let frame = Self.validatedFrame(display.displaySize)
        hopToMain(from: connection) { adapter in
            guard display === adapter.display else { return }
            if let frame { adapter.delegate?.engineDidUpdateDisplay(frame) }
        }
    }

    nonisolated func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        hopToMain(from: connection) { adapter in
            if adapter.display === display {
                adapter.clearFrameObserver()
                adapter.attachedRenderer = nil
                adapter.display = nil
                adapter.delegate?.engineDidLoseDisplay()
            }
        }
    }

    nonisolated func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        let supportsClipboard = connection.pve_hasClipboardCapability()
        hopToMain(from: connection) { adapter in
            adapter.delegate?.engineDidUpdateAgent(AgentCapabilities(
                isConnected: true,
                supportsClipboard: supportsClipboard,
                supportsMonitorsConfig: features.contains(.monitorsConfig)
            ))
        }
    }

    nonisolated func spiceAgentDisconnected(_ connection: CSConnection) {
        hopToMain(from: connection) { adapter in
            adapter.delegate?.engineDidUpdateAgent(AgentCapabilities())
        }
    }

    nonisolated func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    nonisolated func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}

    /// 把 GLib 執行緒上的事件轉回 MainActor；連線已更換則丟棄過期 callback。
    nonisolated private func hopToMain(
        from connection: CSConnection,
        _ body: @escaping @MainActor (SpiceEngineAdapter) -> Void
    ) {
        // A queued callback must not extend the lifetime of a closed
        // adapter. Still retain the originating connection for identity fencing.
        Task { @MainActor [weak self] in
            guard let self, self.connection === connection else { return }
            body(self)
        }
    }

    nonisolated private static func validatedFrame(_ size: CGSize) -> RemoteFrame? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= CGFloat(Int32.max), size.height <= CGFloat(Int32.max) else { return nil }
        return RemoteFrame(width: Int(size.width), height: Int(size.height))
    }

    nonisolated private static func mapError(code: CSConnectionError, message: String?) -> SessionError {
        let lowered = (message ?? "").lowercased()
        if lowered.contains("tls") || lowered.contains("certificate") || lowered.contains("ssl") {
            return .tls
        }
        switch code {
        case .authentication:
            return .authenticationRejected
        case .connect:
            return .network
        default:
            return .unknown(code: "spice")
        }
    }
}

