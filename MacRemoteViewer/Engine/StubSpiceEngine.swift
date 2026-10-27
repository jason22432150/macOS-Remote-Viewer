import Foundation
import CoreGraphics

/// 測試與無原生依賴時的替身。App 正式路徑使用 SpiceEngineAdapter。
@MainActor
final class StubSpiceEngine: SpiceEngineing {
    weak var delegate: SpiceEngineDelegate?

    func startWorker() throws {}

    func connect(profile: ConnectionProfile) throws {
        throw SessionError.engineUnavailable
    }

    func disconnect() {}
    func sendMouse(_ event: MouseEvent) {}
    func sendKey(_ event: KeyEvent) {}
    func releaseKeys() {}
    func sendCtrlAltDelete() {}
    func sendClipboard(_ data: Data, generation: UInt64) async throws {
        throw SessionError.clipboardUnsupported
    }
    func requestClipboard(generation: UInt64) async throws -> Data {
        throw SessionError.clipboardUnsupported
    }
    func attachDisplayRenderer(_ renderer: AnyObject) {}
    func requestResolution(_ size: CGSize) {}
}

@MainActor
final class EngineClipboardTransport: SpiceClipboardTransporting {
    weak var engine: SpiceEngineing?
    var hasAgent = false
    var supportsClipboard = false

    func sendPlainText(_ utf8: Data, generation: UInt64) async throws {
        guard let engine else { throw SessionError.engineUnavailable }
        try await engine.sendClipboard(utf8, generation: generation)
    }

    func requestPlainText(generation: UInt64) async throws -> Data {
        guard let engine else { throw SessionError.engineUnavailable }
        return try await engine.requestClipboard(generation: generation)
    }
}
