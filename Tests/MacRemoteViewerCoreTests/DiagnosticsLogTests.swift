import XCTest
@testable import MacRemoteViewerCore

final class DiagnosticsLogTests: XCTestCase {
    func testExportDoesNotContainSampleSecrets() {
        let log = DiagnosticsLog(sessionID: "session-demo")
        let lines = log.exportSanitizedLines(sampleSecrets: ["example-ticket-not-secret", "pve.example.test"])
        let joined = lines.joined(separator: "\n")
        XCTAssertFalse(joined.contains("example-ticket-not-secret"))
        XCTAssertFalse(joined.contains("pve.example.test"))
        XCTAssertTrue(joined.contains("session=session-demo"))
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
