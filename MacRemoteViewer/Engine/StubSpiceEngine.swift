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
    func attachDisplayRenderer(_ renderer: AnyObject) {}
    func requestResolution(_ size: CGSize) {}
}
