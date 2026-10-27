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
}
