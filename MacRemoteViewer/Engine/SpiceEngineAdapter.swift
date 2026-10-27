import Foundation
import AppKit
import MetalKit
@preconcurrency import CocoaSpiceNoUsb
import CocoaSpiceRenderer

/// 封裝 CocoaSpice／C API，集中 callback 與執行緒轉接。UI 不持有 C 指標。
@MainActor
final class SpiceEngineAdapter: NSObject, SpiceEngineing, @preconcurrency CSConnectionDelegate {
    weak var delegate: SpiceEngineDelegate?

    private var connection: CSConnection?
    private var input: CSInput?
    private var display: CSDisplay?
    private var clipboardBridge: PVESpiceClipboard?
    private var pendingRenderer: CSRenderer?
    private var workerStarted = false
    private var currentGeneration: UInt64 = 1

    func startWorker() throws {
        if workerStarted { return }
        CSMain.shared.spiceSetDebug(false)
        guard CSMain.shared.spiceStart() else {
            throw SessionError.engineUnavailable
        }
        workerStarted = true
    }

    func connect(profile: ConnectionProfile) throws {
        disconnect()
        currentGeneration += 1
        let connection = CSConnection(host: profile.host, port: String(profile.tlsPort))
        connection.audioEnabled = false
        connection.delegate = self
        connection.session.shareClipboard = false

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
        clipboardBridge = PVESpiceClipboard(connection: connection)
        attachPendingRenderer()
        guard connection.connect() else {
            throw SessionError.network
        }
    }

    func disconnect() {
        input?.releaseKeys()
        connection?.disconnect()
        connection?.delegate = nil
        connection = nil
        input = nil
        display = nil
        clipboardBridge = nil
        pendingRenderer = nil
    }

    func sendMouse(_ event: MouseEvent) {
        guard let input else { return }
        let buttons = CSInputButton(rawValue: UInt(event.buttonMask))
        switch event.kind {
        case .move:
            if input.serverModeCursor {
                input.sendMouseMotion(buttons, relativePoint: event.point)
            } else {
                input.sendMousePosition(buttons, absolutePoint: event.point)
            }
        case .down, .up:
            input.sendMouseButton(buttons, mask: buttons, pressed: event.kind == .down)
        case .scroll:
            input.sendMouseScroll(.smooth, buttonMask: buttons, dy: event.scrollDelta)
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

    func sendClipboard(_ data: Data, generation: UInt64) async throws {
        guard generation == currentGeneration else { throw SessionError.cancelled }
        guard let clipboardBridge else { throw SessionError.clipboardUnsupported }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            clipboardBridge.sendUTF8(data) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func requestClipboard(generation: UInt64) async throws -> Data {
        guard generation == currentGeneration else { throw SessionError.cancelled }
        guard let clipboardBridge else { throw SessionError.clipboardUnsupported }
        return try await withCheckedThrowingContinuation { continuation in
            clipboardBridge.requestUTF8 { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    func attachDisplayRenderer(_ renderer: AnyObject) {
        guard let renderer = renderer as? CSRenderer else { return }
        pendingRenderer = renderer
        attachPendingRenderer()
    }

    private func attachPendingRenderer() {
        guard let display, let pendingRenderer else { return }
        display.addRenderer(pendingRenderer)
    }

    func requestResolution(_ size: CGSize) {
        display?.requestResolution(CGRect(origin: .zero, size: size))
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
        input.requestMouseMode(false)
        hopToMain(from: connection) { adapter in
            adapter.input = input
        }
    }

    nonisolated func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        hopToMain(from: connection) { adapter in
            if adapter.input === input {
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
        hopToMain(from: connection) { adapter in
            let clipboardOK = adapter.clipboardBridge?.hasClipboardCapability() ?? false
            adapter.delegate?.engineDidUpdateAgent(AgentCapabilities(
                isConnected: true,
                supportsClipboard: clipboardOK,
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

