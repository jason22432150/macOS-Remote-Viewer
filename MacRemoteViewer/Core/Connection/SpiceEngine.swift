import Foundation
import CoreGraphics

public struct RemoteFrame: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct MouseEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case move
        case down
        case up
        case scroll
    }

    public var kind: Kind
    public var point: CGPoint
    public var buttonMask: UInt32
    public var scrollDelta: CGFloat

    public init(kind: Kind, point: CGPoint, buttonMask: UInt32 = 0, scrollDelta: CGFloat = 0) {
        self.kind = kind
        self.point = point
        self.buttonMask = buttonMask
        self.scrollDelta = scrollDelta
    }
}

public struct KeyEvent: Sendable, Equatable {
    public var pressed: Bool
    public var scancode: Int
    public var isPause: Bool

    public init(pressed: Bool, scancode: Int, isPause: Bool = false) {
        self.pressed = pressed
        self.scancode = scancode
        self.isPause = isPause
    }
}

@MainActor
public protocol SpiceEngineDelegate: AnyObject {
    func engineDidConnect()
    func engineDidDisconnect()
    func engineDidFail(_ error: SessionError)
    func engineDidUpdateDisplay(_ frame: RemoteFrame)
    func engineDidUpdateAgent(_ capabilities: AgentCapabilities)
    func engineDidReceiveClipboard(_ data: Data, generation: UInt64)
}

/// UI 與 C 指標之間的邊界。UI 不持有 SpiceSession／channel。
@MainActor
public protocol SpiceEngineing: AnyObject {
    var delegate: SpiceEngineDelegate? { get set }
    func startWorker() throws
    func connect(profile: ConnectionProfile) throws
    func disconnect()
    func sendMouse(_ event: MouseEvent)
    func sendKey(_ event: KeyEvent)
    func releaseKeys()
    func sendCtrlAltDelete()
    func sendClipboard(_ data: Data, generation: UInt64) async throws
    func requestClipboard(generation: UInt64) async throws -> Data
    func attachDisplayRenderer(_ renderer: AnyObject)
    func requestResolution(_ size: CGSize)
}
