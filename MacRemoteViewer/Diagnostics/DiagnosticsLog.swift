import Foundation
import OSLog

/// Closed diagnostic grammar: never echo arbitrary user/peer text.
enum DiagnosticLogPolicy {
    private static let fixedEvents: Set<String> = [
        "connecting", "connected", "disconnected", "renderer-detach",
        "first-frame-delayed", "guest-agent-limited", "source-file-retained-permission",
        "source-file-replaced-not-deleted", "source-file-deleted",
        "error=file-too-large", "error=invalid-encoding", "error=missing-section",
        "error=unsupported-type", "error=missing-field", "error=duplicate-field",
        "error=invalid-port", "error=plaintext-port-not-allowed", "error=invalid-proxy",
        "error=invalid-host", "error=invalid-connection-field", "error=invalid-boolean",
        "error=invalid-ca", "error=invalid-hot-key", "error=source-file-unavailable",
        "error=engine-unavailable", "error=cancelled", "error=network",
        "error=display-timeout", "error=tls", "error=authentication-rejected",
        "error=guest-agent-unavailable", "error=disconnected", "error=unknown",
        "<redacted>"
    ]
    private static let numericEvents: [NSRegularExpression] = [
        #"\Afirst-frame-rendered-ms [0-9]{1,9}\z"#,
        #"\Aguest-resolution(?:-unapplied)? [0-9]{1,5}x[0-9]{1,5}\z"#,
        #"\Aunknown-fields=count:[0-9]{1,9}\z"#,
        #"\Awindow-present count=[0-9]{1,5} extras-closed=[0-9]{1,5} remembered=(?:true|false)\z"#
    ].map { try! NSRegularExpression(pattern: $0) }

    static func message(_ value: String) -> String {
        // Bound work before running regexes. Anchors require the whole
        // string, including rejecting trailing newlines or extra fields.
        guard value.utf8.count <= 128 else { return "<redacted>" }
        if fixedEvents.contains(value) { return value }
        let range = NSRange(value.startIndex..., in: value)
        return numericEvents.contains { $0.firstMatch(in: value, range: range) != nil }
            ? value : "<redacted>"
    }

    static func level(_ value: String) -> String {
        ["INFO", "NOTICE", "ERROR", "WARNING"].contains(value) ? value : "UNKNOWN"
    }

    static func session(_ value: String) -> String {
        if value == "window" { return value }
        guard value.utf8.count == 36, let id = UUID(uuidString: value) else { return "<redacted>" }
        return id.uuidString
    }

    static func errorCode(_ error: SessionError) -> String {
        switch error {
        case .fileTooLarge: return "file-too-large"
        case .invalidEncoding: return "invalid-encoding"
        case .missingSection: return "missing-section"
        case .unsupportedType: return "unsupported-type"
        case .missingField: return "missing-field"
        case .duplicateField: return "duplicate-field"
        case .invalidPort: return "invalid-port"
        case .plaintextPortNotAllowed: return "plaintext-port-not-allowed"
        case .invalidProxy: return "invalid-proxy"
        case .invalidHost: return "invalid-host"
        case .invalidConnectionField: return "invalid-connection-field"
        case .invalidBoolean: return "invalid-boolean"
        case .invalidCA: return "invalid-ca"
        case .invalidHotKey: return "invalid-hot-key"
        case .sourceFileUnavailable: return "source-file-unavailable"
        case .engineUnavailable: return "engine-unavailable"
        case .cancelled: return "cancelled"
        case .network: return "network"
        case .displayTimeout: return "display-timeout"
        case .tls: return "tls"
        case .authenticationRejected: return "authentication-rejected"
        case .guestAgentUnavailable: return "guest-agent-unavailable"
        case .disconnected: return "disconnected"
        case .unknown: return "unknown"
        }
    }
}

/// Declassified diagnostics. Only fixed events and bounded numeric metrics
/// are accepted; never use UI descriptions as log messages.
public struct DiagnosticsLog: Sendable {
    public let sessionID: String
    private let logger: Logger
    private let fileLog: FileLogSink?

    public init(
        sessionID: String,
        subsystem: String = "local.MacRemoteViewer",
        fileLog: FileLogSink? = nil
    ) {
        self.sessionID = DiagnosticLogPolicy.session(sessionID)
        // Keep source compatibility, but do not accept a caller-supplied
        // subsystem as another arbitrary public metadata field.
        _ = subsystem
        self.logger = Logger(subsystem: "local.MacRemoteViewer", category: "session")
        self.fileLog = fileLog
    }

    public func info(_ message: String) {
        let safe = DiagnosticLogPolicy.message(message)
        logger.info("\(safe, privacy: .public) session=\(self.sessionID, privacy: .public)")
        fileLog?.write(level: "INFO", message: safe, sessionID: sessionID)
    }

    public func error(_ error: SessionError) {
        let safe = "error=\(DiagnosticLogPolicy.errorCode(error))"
        logger.error("\(safe, privacy: .public) session=\(self.sessionID, privacy: .public)")
        fileLog?.write(level: "ERROR", message: safe, sessionID: sessionID)
    }

    public func compatibilityHint(unknownFields: [String]) {
        guard !unknownFields.isEmpty else { return }
        let safe = DiagnosticLogPolicy.message("unknown-fields=count:\(unknownFields.count)")
        logger.notice("\(safe, privacy: .public) session=\(self.sessionID, privacy: .public)")
        fileLog?.write(level: "NOTICE", message: safe, sessionID: sessionID)
    }

    public func exportSanitizedLines(sampleSecrets: [String] = []) -> [String] {
        let lines = [
            "app=MacRemoteViewer",
            "session=\(sessionID)",
            "state-log=sanitized"
        ]
        return lines.map { line in
            sampleSecrets.reduce(line) { partial, secret in
                guard !secret.isEmpty else { return partial }
                return partial.replacingOccurrences(of: secret, with: "<redacted>")
            }
        }
    }
}
