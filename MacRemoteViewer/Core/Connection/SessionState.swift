import Foundation

/// 工作階段生命週期。connecting 的細部進度只依底層可觀察事件更新。
public enum SessionState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case idle
    case parsing
    case connecting
    case connected
    case disconnecting
    case disconnected
    case failed(SessionError)

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .parsing: return "parsing"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .failed(let error): return "failed(\(error.description))"
        }
    }

    public var debugDescription: String { description }

    /// Offer a fresh, explicit import only after terminal transport errors.
    /// This is a new connection, not a retry using retained credentials.
    public var canOpenFreshConnectionFile: Bool {
        switch self {
        case .disconnected:
            return true
        case .failed(let error):
            return error.isRetryableWithNewFile
        default:
            return false
        }
    }
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
