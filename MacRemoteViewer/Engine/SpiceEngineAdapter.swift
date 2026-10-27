import Foundation
import AppKit
import MetalKit
import CocoaSpiceNoUsb
import CocoaSpiceRenderer

/// 封裝 CocoaSpice／C API，集中 callback 與執行緒轉接。UI 不持有 C 指標。
@MainActor
final class SpiceEngineAdapter: NSObject, SpiceEngineing, @preconcurrency CSConnectionDelegate {
    weak var delegate: SpiceEngineDelegate?

    private var connection: CSConnection?
    private var input: CSInput?
    private var display: CSDisplay?
    private var clipboardBridge: PVESpiceClipboard?
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
        guard let display, let renderer = renderer as? CSRenderer else { return }
        display.addRenderer(renderer)
    }

    func requestResolution(_ size: CGSize) {
        display?.requestResolution(CGRect(origin: .zero, size: size))
    }

    // MARK: - CSConnectionDelegate

    func spiceConnected(_ connection: CSConnection) {
        delegate?.engineDidConnect()
    }

    func spiceDisconnected(_ connection: CSConnection) {
        delegate?.engineDidDisconnect()
    }

    func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        self.input = input
        input.requestMouseMode(false)
    }

    func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        if self.input === input {
            self.input = nil
        }
    }

    func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        delegate?.engineDidFail(Self.mapError(code: code, message: message))
    }

    func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        if self.display == nil || display.isPrimaryDisplay {
            self.display = display
            delegate?.engineDidUpdateDisplay(RemoteFrame(
                width: Int(display.displaySize.width),
                height: Int(display.displaySize.height)
            ))
        }
    }

    func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        guard display === self.display else { return }
        delegate?.engineDidUpdateDisplay(RemoteFrame(
            width: Int(display.displaySize.width),
            height: Int(display.displaySize.height)
        ))
    }

    func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        if self.display === display {
            self.display = nil
        }
    }

    func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        let clipboardOK = clipboardBridge?.hasClipboardCapability() ?? false
        delegate?.engineDidUpdateAgent(AgentCapabilities(
            isConnected: true,
            supportsClipboard: clipboardOK,
            supportsMonitorsConfig: features.contains(.monitorsConfig)
        ))
    }

    func spiceAgentDisconnected(_ connection: CSConnection) {
        delegate?.engineDidUpdateAgent(AgentCapabilities())
    }

    func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}

    private static func mapError(code: CSConnectionError, message: String?) -> SessionError {
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

