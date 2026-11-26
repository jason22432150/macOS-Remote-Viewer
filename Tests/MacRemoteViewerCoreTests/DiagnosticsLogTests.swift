import XCTest
@testable import MacRemoteViewerCore

final class DiagnosticsLogTests: XCTestCase {
    func testExportDoesNotContainSampleSecrets() {
        let log = DiagnosticsLog(sessionID: "session-demo")
        let lines = log.exportSanitizedLines(sampleSecrets: ["example-ticket-not-secret", "pve.example.test"])
        let joined = lines.joined(separator: "\n")
        XCTAssertFalse(joined.contains("example-ticket-not-secret"))
        XCTAssertFalse(joined.contains("pve.example.test"))
        XCTAssertTrue(joined.contains("session=<redacted>"))
    }

    func testClosedGrammarRejectsArbitraryTextAndErrorPayloads() {
        let writer = MemoryFileLogWriter()
        let sink = FileLogSink(enabled: true, writer: writer)
        let id = "01234567-89AB-CDEF-0123-456789ABCDEF"
        let log = DiagnosticsLog(sessionID: id, fileLog: sink)
        for value in ["PASSWORD=synthetic-secret", "ticket: synthetic-secret",
                      "https://user:synthetic-secret@127.0.0.1",
                      "pvespiceproxy:synthetic-secret", "synthetic-secret",
                      "connected\nsynthetic-secret", "guest-resolution 1024x768\n",
                      "first-frame-rendered-ms 12 synthetic-secret",
                      String(repeating: "x", count: 4096)] {
            log.info(value)
            XCTAssertTrue(writer.lines.last?.contains("INFO <redacted>") == true)
        }
        for value in ["connected", "first-frame-rendered-ms 42",
                      "guest-resolution 1024x768", "guest-resolution-unapplied 800x600",
                      "window-present count=2 extras-closed=1 remembered=true"] {
            log.info(value)
            XCTAssertTrue(writer.lines.last?.contains("INFO \(value) session=\(id)") == true)
        }
        log.error(.missingField("synthetic-secret"))
        XCTAssertTrue(writer.lines.last?.contains("error=missing-field") == true)
        log.error(.duplicateField("synthetic-secret"))
        XCTAssertTrue(writer.lines.last?.contains("error=duplicate-field") == true)
        log.error(.unknown(code: "synthetic-secret"))
        XCTAssertTrue(writer.lines.last?.contains("error=unknown") == true)
        log.compatibilityHint(unknownFields: ["synthetic-secret"])
        XCTAssertTrue(writer.lines.last?.contains("unknown-fields=count:1") == true)
        sink.write(level: "synthetic-secret", message: "synthetic-secret", sessionID: "synthetic-secret")
        XCTAssertTrue(writer.lines.last?.contains("UNKNOWN <redacted> session=<redacted>") == true)
        XCTAssertFalse(writer.lines.joined().contains("synthetic-secret"))
        XCTAssertFalse(writer.lines.joined().contains("user:"))
    }

    func testFileLogRedactsSecretsAndHonorsGate() {
        let writer = MemoryFileLogWriter()
        let sink = FileLogSink(enabled: true, writer: writer)
        let log = DiagnosticsLog(sessionID: "session-demo", fileLog: sink)
        log.info("connecting password=example-ticket-not-secret")
        XCTAssertEqual(writer.lines.count, 1)
        XCTAssertTrue(writer.lines[0].contains("<redacted>"))
        XCTAssertFalse(writer.lines[0].contains("example-ticket-not-secret"))

        sink.isEnabled = false
        log.info("connected")
        XCTAssertEqual(writer.lines.count, 1)
    }
}
