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
    /// 目前按下的全部按鍵（SPICE／CSInput mask）。
    public var buttonMask: UInt32
    /// down／up 時剛變化的那一顆按鍵；move／scroll 為 0。
    public var button: UInt32
    public var scrollDelta: CGFloat

    public init(
        kind: Kind,
        point: CGPoint,
        buttonMask: UInt32 = 0,
        button: UInt32 = 0,
        scrollDelta: CGFloat = 0
    ) {
        self.kind = kind
        self.point = point
        self.buttonMask = buttonMask
        self.button = button
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
    func attachDisplayRenderer(_ renderer: AnyObject)
    /// 分頁切走時畫面會被卸載，必須先從 display 拿掉 renderer，避免指向已釋放的 Metal 視圖。
    func detachDisplayRenderer(_ renderer: AnyObject)
    func requestResolution(_ size: CGSize)
    /// 多 session 時只讓作用中連線同步剪貼簿。
    func setClipboardSharingEnabled(_ enabled: Bool)
}
