import Foundation
import OSLog

/// 去機密的診斷紀錄。禁止寫入票證、原始 `.vv`、剪貼簿或未遮蔽位址。
public struct DiagnosticsLog: Sendable {
    public let sessionID: String
    private let logger: Logger

    public init(sessionID: String, subsystem: String = "local.MacRemoteViewer") {
        self.sessionID = sessionID
        self.logger = Logger(subsystem: subsystem, category: "session")
    }

    public func info(_ message: String) {
        logger.info("\(self.redact(message), privacy: .public) session=\(self.sessionID, privacy: .public)")
    }

    public func error(_ error: SessionError) {
        logger.error("error=\(String(describing: error), privacy: .public) session=\(self.sessionID, privacy: .public)")
    }

    public func compatibilityHint(unknownFields: [String]) {
        guard !unknownFields.isEmpty else { return }
        let names = unknownFields.joined(separator: ",")
        logger.notice("unknown-fields=\(names, privacy: .public) session=\(self.sessionID, privacy: .public)")
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
        let patterns = [
            #"password=[^\s]+"#,
            #"ticket=[^\s]+"#,
            #"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<redacted>")
            }
        }
        return result
    }
}
