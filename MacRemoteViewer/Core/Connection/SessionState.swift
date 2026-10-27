import Foundation

/// 工作階段生命週期。connecting 的細部進度只依底層可觀察事件更新。
public enum SessionState: Equatable, Sendable {
    case idle
    case parsing
    case connecting
    case connected
    case disconnecting
    case disconnected
    case failed(SessionError)
}

/// 遠端 guest agent 能力。缺少剪貼簿時畫面與輸入仍可用。
public struct AgentCapabilities: Equatable, Sendable {
    public var isConnected: Bool
    public var supportsClipboard: Bool
    public var supportsMonitorsConfig: Bool

    public init(
        isConnected: Bool = false,
        supportsClipboard: Bool = false,
        supportsMonitorsConfig: Bool = false
    ) {
        self.isConnected = isConnected
        self.supportsClipboard = supportsClipboard
        self.supportsMonitorsConfig = supportsMonitorsConfig
    }
}
