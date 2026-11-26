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

    func testRejectsMalformedX509PEM() {
        let malformed = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
        XCTAssertThrowsError(try VVParser.validatedCA(malformed)) { error in
            XCTAssertEqual(error as? SessionError, .invalidCA)
        }
    }

    func testRejectsExtraTextAfterCertificate() throws {
        let profile = try parser.parse(data: Data(minimalVV().utf8))
        let pem = try XCTUnwrap(String(data: profile.caPEM, encoding: .utf8))
        XCTAssertThrowsError(try VVParser.validatedCA(pem + "unexpected payload"))
        XCTAssertNoThrow(try VVParser.validatedCA(pem + pem))
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

    func testRejectsUnsafeHostAfterINIUnescaping() {
        for host in ["pve.example.test\\r\\nX-Test: value", "pve.example.test\\tother",
                     "pve.example.test\\sother", "https://pve.example.test",
                     "pve.example.test/path", "user@pve.example.test", "pve.example.test?query"] {
            let text = minimalVV().replacingOccurrences(of: "host=pve.example.test", with: "host=\(host)")
            XCTAssertThrowsError(try parser.parse(data: Data(text.utf8))) {
                XCTAssertEqual($0 as? SessionError, .invalidHost)
            }
        }
    }

    func testPreservesOpaqueSPICEProxyDestinationsWithoutNormalization() throws {
        let suffix = "1234abcd:180:pve:61002::0123456789abcdef"
        for host in ["pvespiceproxy:" + suffix, "spiceproxy://" + suffix, "SPICEPROXY://" + suffix] {
            let text = minimalVV().replacingOccurrences(of: "host=pve.example.test", with: "host=\(host)")
            let profile = try parser.parse(data: Data(text.utf8))
            XCTAssertEqual(profile.host, host)
            XCTAssertNoThrow(try VVParser.validateTransport(host: profile.host, tlsPort: profile.tlsPort,
                proxyURL: profile.proxyURL, hostSubject: profile.hostSubject, ticket: profile.ticket.value))
        }
    }

    func testRejectsUnsafeSPICEProxyDestinations() {
        let badHosts = ["spiceproxy://", "spiceproxy://node/path", "spiceproxy://node?query",
                        "spiceproxy://user@node", "spiceproxy://node\\r\\nextra",
                        "pvespiceproxy:node\\sother", "%@%n%d.example.test"]
        for host in badHosts {
            let text = minimalVV().replacingOccurrences(of: "host=pve.example.test", with: "host=\(host)")
            XCTAssertThrowsError(try parser.parse(data: Data(text.utf8))) {
                XCTAssertEqual($0 as? SessionError, .invalidHost)
            }
        }
        let noProxy = minimalVV(proxy: "").replacingOccurrences(of: "host=pve.example.test",
            with: "host=spiceproxy://1234abcd:180:pve:61002::0123456789abcdef")
        XCTAssertThrowsError(try parser.parse(data: Data(noProxy.utf8))) {
            XCTAssertEqual($0 as? SessionError, .invalidHost)
        }
    }

    func testPreservesNormalHostnameIPv4IPv6AndTLSSubject() throws {
        for host in ["pve.local", "192.0.2.10", "2001:db8::1", "[2001:db8::1]", "pve.example.test."] {
            let text = minimalVV().replacingOccurrences(of: "host=pve.example.test", with: "host=\(host)")
            XCTAssertEqual(try parser.parse(data: Data(text.utf8)).host, host)
        }
        let text = minimalVV().replacingOccurrences(of: "CN=pve.example.test",
            with: "CN=PVE Server,O=Example Org")
        XCTAssertEqual(try parser.parse(data: Data(text.utf8)).hostSubject, "CN=PVE Server,O=Example Org")
    }

    func testRejectsAmbiguousProxyEndpointsAndDecodedControls() {
        for proxy in ["http://proxy.example.test:0", "http://proxy.example.test:65536",
                      "http://proxy.example.test/path", "http://proxy.example.test?query=1",
                      "http://proxy.example.test#fragment", "http://proxy.example.test\\nother",
                      "http://user%0A:pass@proxy.example.test:3128",
                      "http://proxy.example.test%0D:3128"] {
            XCTAssertThrowsError(try parser.parse(data: Data(minimalVV(proxy: proxy).utf8)), proxy) {
                XCTAssertEqual($0 as? SessionError, .invalidProxy)
            }
        }
    }

    func testPreservesHTTPHTTPSAndProxyCredentials() throws {
        for proxy in ["http://proxy.example.test:3128", "https://proxy.example.test",
                      "http://proxy.example.test:3128/", "http://[2001:db8::1]:3128",
                      "http://user:pass%20word@proxy.example.test:3128"] {
            let profile = try parser.parse(data: Data(minimalVV(proxy: proxy).utf8))
            XCTAssertNotNil(profile.proxyURL)
        }
        XCTAssertNil(try parser.parse(data: Data(minimalVV(proxy: "").utf8)).proxyURL)
    }

    func testRejectsControlsInNativeTicketAndCertificateSubject() {
        for (field, value) in [("password", "example-ticket-not-secret"),
                               ("host-subject", "CN=pve.example.test")] {
            let text = minimalVV().replacingOccurrences(of: "\(field)=\(value)",
                with: "\(field)=\(value)\\r\\nextra")
            XCTAssertThrowsError(try parser.parse(data: Data(text.utf8))) {
                XCTAssertEqual($0 as? SessionError, .invalidConnectionField)
            }
        }
        XCTAssertThrowsError(try VVParser.validateTransport(host: "pve.example.test", tlsPort: 61001,
            proxyURL: nil, hostSubject: "CN=PVE", ticket: "secret\u{0000}suffix")) {
            XCTAssertEqual($0 as? SessionError, .invalidConnectionField)
        }
        XCTAssertThrowsError(try VVParser.validateTransport(host: "pve.example.test", tlsPort: 0,
            proxyURL: nil, hostSubject: "CN=PVE", ticket: "secret")) {
            XCTAssertEqual($0 as? SessionError, .invalidPort("tls-port"))
        }
    }

    func testImporterDoesNotRetainUntrustedErrorPayloads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vv")
        defer { try? FileManager.default.removeItem(at: url) }
        let secret = "synthetic-private-value"
        for (input, expected) in [
            (minimalVV(type: secret), SessionError.unsupportedType("<redacted>")),
            (minimalVV(extra: "delete-this-file=\(secret)"), .invalidBoolean("<redacted>")),
            (minimalVV(extra: "toggle-fullscreen=Ctrl+Shift"), .invalidHotKey("<redacted>"))
        ] {
            try Data(input.utf8).write(to: url)
            XCTAssertThrowsError(try VVFileImporter().importFile(at: url)) {
                XCTAssertEqual($0 as? SessionError, expected)
                XCTAssertFalse(String(reflecting: $0).contains(secret))
            }
        }
        XCTAssertEqual(SessionError.missingField(secret).sanitizedForRetention, .missingField("unknown"))
        XCTAssertEqual(SessionError.unknown(code: secret).sanitizedForRetention, .unknown(code: "<redacted>"))
        XCTAssertFalse(SessionError.duplicateField(secret).userMessage.contains(secret))
        try Data(minimalVV().utf8).write(to: url)
        XCTAssertEqual(try VVFileImporter().importFile(at: url).ticket.value, "example-ticket-not-secret")
    }

    func testDescriptorReadExactSizesAndIdentity() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vv")
        defer { try? FileManager.default.removeItem(at: url) }
        let files = FoundationFileAccessor()
        for count in [0, 1, 65537, VVParser.maxFileBytes] {
            let payload = Data(repeating: 0x41, count: count)
            try payload.write(to: url)
            let (data, identity) = try files.readIdentified(from: url)
            XCTAssertEqual(data, payload)
            XCTAssertEqual(identity?.size, UInt64(count))
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

    func testImporterRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.vv")
        try Data(minimalVV().utf8).write(to: target)
        let link = root.appendingPathComponent("link.vv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try VVFileImporter().importFile(at: link)) { error in
            XCTAssertEqual(error as? SessionError, .sourceFileUnavailable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testDescriptorIdentityCleanupPreservesReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("connection.vv")
        let files = FoundationFileAccessor()
        try Data(minimalVV().utf8).write(to: url)
        let original = try XCTUnwrap(files.readIdentified(from: url).1)
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("old.vv"))
        try Data("replacement".utf8).write(to: url)
        XCTAssertEqual(files.removeMatchingItem(at: url, identity: original), .replacedFilePreserved)
        XCTAssertEqual(try Data(contentsOf: url), Data("replacement".utf8))
        let replacement = try files.identity(of: url)
        XCTAssertEqual(files.removeMatchingItem(at: url, identity: replacement), .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRejectsOversizedFile() {
        let payload = Data(repeating: 0x41, count: VVParser.maxFileBytes + 1)
        XCTAssertThrowsError(try parser.parse(data: payload)) { error in
            XCTAssertEqual(error as? SessionError, .fileTooLarge(maxBytes: VVParser.maxFileBytes))
        }
    }

    func testRejectsEmbeddedNULBeforeParsing() {
        let content = minimalVV().replacingOccurrences(of: "host=pve.example.test",
            with: "host=pve.example.test\u{0000}suffix")
        XCTAssertThrowsError(try parser.parse(data: Data(content.utf8))) { error in
            XCTAssertEqual(error as? SessionError, .invalidEncoding)
        }
    }

    func testManyUnknownFieldsAndDuplicateCriticalField() throws {
        let extras = (0..<4000).map { "unknown-\($0)=value" }.joined(separator: "\n")
        let profile = try parser.parse(data: Data(minimalVV(extra: extras).utf8))
        XCTAssertEqual(profile.unknownFieldNames.count, 4000)
        XCTAssertThrowsError(try parser.parse(data: Data(minimalVV(extra: extras + "\nhost=other.example").utf8))) {
            XCTAssertEqual($0 as? SessionError, .duplicateField("host"))
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
            "ca=-----BEGIN CERTIFICATE-----\\nMIIBizCCATGgAwIBAgIUL0QU9hTtHKAkePzKdhK6O29VxIEwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQcHZlLmV4YW1wbGUudGVzdDAeFw0yNjExMjQwNTQwMjBaFw0zNjExMjEwNTQwMjBaMBsxGTAXBgNVBAMMEHB2ZS5leGFtcGxlLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS58TUSpXMsnqt28K3DxsPeuGopROR9GqJdlU7E02qTpiHxgxhBKcJ/ITF5LrbhpgnAG6T80/49tExftl21vZ5so1MwUTAdBgNVHQ4EFgQU4v3tpNGL8ZZZOBfHCAVMDehGdGAwHwYDVR0jBBgwFoAU4v3tpNGL8ZZZOBfHCAVMDehGdGAwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiA0Gk8MiagBJ2gxgCszKUZrsRaPyYGQCNZGamYd5SAXhgIhAL5w+WStJ0cw88VFewjwIYczmaMsSUiwrq65kjqatWEZ\\n-----END CERTIFICATE-----",
            "host-subject=CN=pve.example.test",
            extra
        ])
        return lines.joined(separator: "\n") + "\n"
    }
}
