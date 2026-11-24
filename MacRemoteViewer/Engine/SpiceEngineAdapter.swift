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
    private var input: CSInput?
    private var display: CSDisplay?
    private let spicePasteboard = CocoaSpicePasteboard()
    private var pendingRenderer: CSRenderer?
    private var pendingResolution: CGSize?
    private var lastGuestPoint: CGPoint?
    private static var workerStarted = false
    private var pressedMouseMask: UInt32 = 0
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
        disconnect()
        let connection = CSConnection(host: profile.host, port: String(profile.tlsPort))
        connection.audioEnabled = false
        connection.delegate = self
        applyClipboardSharing(to: connection)

        let proxy = profile.proxyURL?.absoluteString
        do {
            try connection.pve_applyHost(
                profile.host,
                tlsPort: String(profile.tlsPort),
                proxy: proxy,
                ca: profile.caPEM,
                certSubject: profile.hostSubject,
                password: profile.ticket.value
            )
        } catch {
            throw SessionError.engineUnavailable
        }

        self.connection = connection
        attachPendingRenderer()
        guard connection.connect() else {
            throw SessionError.network
        }
    }

    func disconnect() {
        releaseKeys()
        spicePasteboard.stopPolling()
        connection?.session.shareClipboard = false
        connection?.session.pasteboardDelegate = nil
        connection?.disconnect()
        connection?.delegate = nil
        connection = nil
        input = nil
        display = nil
        pendingRenderer = nil
        pendingResolution = nil
        lastGuestPoint = nil
    }

    func sendMouse(_ event: MouseEvent) {
        guard let input else { return }
        switch event.kind {
        case .move:
            let mask = CSInputButton(rawValue: UInt(pressedMouseMask))
            if input.serverModeCursor {
                let previous = lastGuestPoint ?? event.point
                let delta = CGPoint(x: event.point.x - previous.x, y: event.point.y - previous.y)
                input.sendMouseMotion(mask, relativePoint: delta)
            } else {
                input.sendMousePosition(mask, absolutePoint: event.point)
                // client 模式必須自己移動 overlay，否則遠端游標會停在舊位置。
                display?.cursor?.move(to: event.point)
            }
            lastGuestPoint = event.point
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
            input.sendMouseButton(button, mask: mask, pressed: event.kind == .down)
            if !input.serverModeCursor {
                display?.cursor?.move(to: event.point)
            }
        case .scroll:
            input.sendMouseScroll(.smooth, buttonMask: CSInputButton(rawValue: UInt(pressedMouseMask)), dy: event.scrollDelta)
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
        lastGuestPoint = nil
    }

    func sendCtrlAltDelete() {
        guard let input else { return }
        let ctrl = 0x1D
        let alt = 0x38
        let delete = 0x153
        input.send(.press, code: Int32(ctrl))
        input.send(.press, code: Int32(alt))
        input.send(.press, code: Int32(delete))
        input.send(.release, code: Int32(delete))
        input.send(.release, code: Int32(alt))
        input.send(.release, code: Int32(ctrl))
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
        pendingRenderer = renderer
        attachPendingRenderer()
    }

    func detachDisplayRenderer(_ renderer: AnyObject) {
        guard let renderer = renderer as? CSRenderer else { return }
        if pendingRenderer === renderer {
            pendingRenderer = nil
        }
        display?.removeRenderer(renderer)
    }

    private func attachPendingRenderer() {
        guard let display, let pendingRenderer else { return }
        // CocoaSpice 以 containsObject 去重，可重複呼叫。
        // 不在成功後清掉 pending：display channel 重建時還要用同一顆 renderer。
        display.addRenderer(pendingRenderer)
    }

    private func applyClipboardSharing(to connection: CSConnection) {
        if clipboardSharingEnabled {
            spicePasteboard.startPolling()
            connection.session.pasteboardDelegate = spicePasteboard
            connection.session.shareClipboard = true
        } else {
            spicePasteboard.stopPolling()
            connection.session.shareClipboard = false
            connection.session.pasteboardDelegate = nil
        }
    }

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
            input.requestMouseMode(false)
        }
    }

    nonisolated func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        hopToMain(from: connection) { adapter in
            if adapter.input === input {
                adapter.pressedMouseMask = 0
                adapter.lastGuestPoint = nil
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
        let width = Int(display.displaySize.width)
        let height = Int(display.displaySize.height)
        let isPrimary = display.isPrimaryDisplay
        hopToMain(from: connection) { adapter in
            if adapter.display == nil || isPrimary {
                adapter.display = display
                adapter.attachPendingRenderer()
                adapter.applyPendingResolution()
                adapter.delegate?.engineDidUpdateDisplay(RemoteFrame(width: width, height: height))
            }
        }
    }

    nonisolated func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        let width = Int(display.displaySize.width)
        let height = Int(display.displaySize.height)
        hopToMain(from: connection) { adapter in
            guard display === adapter.display else { return }
            adapter.delegate?.engineDidUpdateDisplay(RemoteFrame(width: width, height: height))
        }
    }

    nonisolated func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        hopToMain(from: connection) { adapter in
            if adapter.display === display {
                adapter.display = nil
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
        Task { @MainActor in
            guard self.connection === connection else { return }
            body(self)
        }
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

