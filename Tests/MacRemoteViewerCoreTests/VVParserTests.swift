import XCTest
@testable import MacRemoteViewerCore

final class VVParserTests: XCTestCase {
    private let parser = VVParser()

    func testParsesSyntheticFixture() throws {
        let url = Bundle.module.url(forResource: "valid-spice", withExtension: "vv", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "valid-spice", withExtension: "vv")
        let fixtureURL = try XCTUnwrap(url)
        let profile = try parser.parse(data: try Data(contentsOf: fixtureURL))
        XCTAssertEqual(profile.host, "pve.example.test")
        XCTAssertEqual(profile.tlsPort, 61001)
        XCTAssertEqual(profile.proxyURL?.host, "pve.example.test")
        XCTAssertEqual(profile.proxyURL?.port, 3128)
        XCTAssertEqual(profile.deleteSourceFile, true)
        XCTAssertEqual(profile.toggleFullscreen.symbol, .function(11))
        XCTAssertEqual(profile.releaseCursor.control, true)
        XCTAssertEqual(profile.secureAttention.symbol, .insert)
        XCTAssertTrue(profile.unknownFieldNames.contains("x-unknown-demo"))
        XCTAssertTrue(String(data: profile.caPEM, encoding: .utf8)?.contains("BEGIN CERTIFICATE") == true)
        XCTAssertFalse(String(describing: profile).contains("example-ticket-not-secret"))
        XCTAssertEqual(profile.ticket.description, "<redacted>")
    }

    func testUnescapesCANewlines() throws {
        let profile = try parser.parse(data: Data(minimalVV().utf8))
        let pem = try XCTUnwrap(String(data: profile.caPEM, encoding: .utf8))
        XCTAssertTrue(pem.contains("\n"))
        XCTAssertFalse(pem.contains("\\n"))
    }

    func testRejectsMissingSection() {
        XCTAssertThrowsError(try parser.parse(data: Data("type=spice\n".utf8))) { error in
            XCTAssertEqual(error as? SessionError, .missingSection)
        }
    }

    func testRejectsUnsupportedType() {
        XCTAssertThrowsError(try parser.parse(data: Data(minimalVV(type: "vnc").utf8))) { error in
            XCTAssertEqual(error as? SessionError, .unsupportedType("vnc"))
        }
    }

    func testRejectsDuplicateHost() {
        let text = minimalVV() + "host=another.example.test\n"
        XCTAssertThrowsError(try parser.parse(data: Data(text.utf8))) { error in
            XCTAssertEqual(error as? SessionError, .duplicateField("host"))
        }
    }

    func testRejectsIllegalPort() {
        XCTAssertThrowsError(try parser.parse(data: Data(minimalVV(tlsPort: "70000").utf8))) { error in
            XCTAssertEqual(error as? SessionError, .invalidPort("tls-port"))
        }
    }

    func testDoesNotInventPlaintextPort() {
        XCTAssertThrowsError(try parser.parse(data: Data(minimalVV(tlsPort: nil, extra: "port=5900\n").utf8))) { error in
            XCTAssertEqual(error as? SessionError, .plaintextPortNotAllowed)
        }
    }

    func testRejectsNonHTTPProxy() {
        XCTAssertThrowsError(try parser.parse(data: Data(minimalVV(proxy: "file:///tmp/x").utf8))) { error in
            XCTAssertEqual(error as? SessionError, .invalidProxy)
        }
    }

    func testImporterRejectsOversizedRegularFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 65, count: VVParser.maxFileBytes + 1).write(to: url)
        XCTAssertThrowsError(try VVFileImporter().importFile(at: url)) { error in
            XCTAssertEqual(error as? SessionError, .fileTooLarge(maxBytes: VVParser.maxFileBytes))
        }
    }

    func testRejectsOversizedFile() {
        let payload = Data(repeating: 0x41, count: VVParser.maxFileBytes + 1)
        XCTAssertThrowsError(try parser.parse(data: payload)) { error in
            XCTAssertEqual(error as? SessionError, .fileTooLarge(maxBytes: VVParser.maxFileBytes))
        }
    }

    func testUnknownFieldsAreNotExecuted() throws {
        let profile = try parser.parse(data: Data(minimalVV(extra: "command=rm -rf /\nurl=https://evil.example\n").utf8))
        XCTAssertTrue(profile.unknownFieldNames.contains("command"))
        XCTAssertTrue(profile.unknownFieldNames.contains("url"))
    }

    private func minimalVV(
        type: String = "spice",
        tlsPort: String? = "61001",
        proxy: String = "http://pve.example.test:3128",
        extra: String = ""
    ) -> String {
        var lines = [
            "[virt-viewer]",
            "type=\(type)",
            "host=pve.example.test",
            "proxy=\(proxy)"
        ]
        if let tlsPort {
            lines.append("tls-port=\(tlsPort)")
        }
        lines.append(contentsOf: [
            "password=example-ticket-not-secret",
            "ca=-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----",
            "host-subject=CN=pve.example.test",
            extra
        ])
        return lines.joined(separator: "\n") + "\n"
    }
}
