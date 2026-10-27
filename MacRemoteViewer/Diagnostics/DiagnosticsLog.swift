import Foundation
import OSLog

/// 去機密的診斷紀錄。禁止寫入票證、原始 `.vv`、剪貼簿或未遮蔽位址。
public struct DiagnosticsLog: Sendable {
    public let sessionID: String
    private let logger: Logger
    private let fileLog: FileLogSink?

    public init(
        sessionID: String,
        subsystem: String = "local.MacRemoteViewer",
        fileLog: FileLogSink? = nil
    ) {
        self.sessionID = sessionID
        self.logger = Logger(subsystem: subsystem, category: "session")
        self.fileLog = fileLog
    }

    public func info(_ message: String) {
        let redacted = redact(message)
        logger.info("\(redacted, privacy: .public) session=\(self.sessionID, privacy: .public)")
        fileLog?.write(level: "INFO", message: redacted, sessionID: sessionID)
    }

    public func error(_ error: SessionError) {
        let description = String(describing: error)
        logger.error("error=\(description, privacy: .public) session=\(self.sessionID, privacy: .public)")
        fileLog?.write(level: "ERROR", message: "error=\(description)", sessionID: sessionID)
    }

    public func compatibilityHint(unknownFields: [String]) {
        guard !unknownFields.isEmpty else { return }
        let names = unknownFields.joined(separator: ",")
        logger.notice("unknown-fields=\(names, privacy: .public) session=\(self.sessionID, privacy: .public)")
        fileLog?.write(level: "NOTICE", message: "unknown-fields=\(names)", sessionID: sessionID)
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

    private func redact(_ message: String) -> String {
        var result = message
        for regex in Self.redactRegexes {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<redacted>")
        }
        return result
    }

    /// 固定 pattern，編譯失敗應在測試／啟動時立刻暴露，不可默默略過遮蔽。
    private static let redactRegexes: [NSRegularExpression] = {
        let patterns = [
            #"password=[^\s]+"#,
            #"ticket=[^\s]+"#,
            #"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----"#
        ]
        return patterns.map { pattern in
            do {
                return try NSRegularExpression(pattern: pattern)
            } catch {
                preconditionFailure("invalid diagnostics redact pattern: \(pattern)")
            }
        }
    }()
}
