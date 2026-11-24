import XCTest
@testable import MacRemoteViewerCore

final class SessionStatusTextTests: XCTestCase {
    func testPVETicketHostUsesProxyIP() throws {
        let profile = try makeProfile(
            host: "pvespiceproxy:6ae0ab99:180:pve::046e9bdd5db59a2b411524fb18927ff9554e8e67",
            proxy: "http://192.0.2.10:3128"
        )
        XCTAssertEqual(SessionStatusText.displayAddress(from: profile), "192.0.2.10")
        XCTAssertEqual(
            SessionStatusText.remoteIP(from: profile, language: .zhHant),
            "遠端 IP：192.0.2.10"
        )
        XCTAssertFalse(
            SessionStatusText.remoteIP(from: profile, language: .zhHant)?.contains("pvespiceproxy") == true
        )
    }

    func testSpiceProxyURIHostUsesProxyIP() throws {
        let profile = try makeProfile(
            host: "spiceproxy://6ae0ab99:180:pve:61002::046e9bdd5db59a2b411524fb18927ff9554e8e67",
            proxy: "http://192.0.2.80:3128"
        )
        XCTAssertEqual(SessionStatusText.displayAddress(from: profile), "192.0.2.80")
    }

    func testTicketHostWithoutProxyIsOmitted() throws {
        let profile = try makeProfile(
            host: "pvespiceproxy:6ae0ab99:180:pve::046e9bdd5db59a2b411524fb18927ff9554e8e67",
            proxy: nil
        )
        XCTAssertNil(SessionStatusText.displayAddress(from: profile))
        XCTAssertNil(SessionStatusText.remoteIP(from: profile, language: .english))
    }

    func testPlainIPHostIsShownWhenNoTicket() throws {
        let profile = try makeProfile(host: "203.0.113.5", proxy: nil)
        XCTAssertEqual(SessionStatusText.displayAddress(from: profile), "203.0.113.5")
        XCTAssertEqual(
            SessionStatusText.remoteIP(from: profile, language: .english),
            "Remote IP: 203.0.113.5"
        )
    }

    func testPlainHostPrefersSpiceHostOverProxy() throws {
        let profile = try makeProfile(host: "spice.example.test", proxy: "http://192.0.2.1:3128")
        XCTAssertEqual(SessionStatusText.displayAddress(from: profile), "spice.example.test")
    }

    func testProxyHostnameUsedWhenHostIsTicket() throws {
        let profile = try makeProfile(
            host: "pvespiceproxy:aaaaaaaa:100:node1::aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            proxy: "https://pve.example.test:3128"
        )
        XCTAssertEqual(SessionStatusText.displayAddress(from: profile), "pve.example.test")
    }

    func testIPv6ProxyHost() throws {
        let profile = try makeProfile(
            host: "pvespiceproxy:bbbbbbbb:101:node2::bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            proxy: "http://[2001:db8::10]:3128"
        )
        XCTAssertEqual(SessionStatusText.displayAddress(from: profile), "2001:db8::10")
    }

    func testNilProfileOmitsAddress() {
        XCTAssertNil(SessionStatusText.displayAddress(from: nil))
        XCTAssertNil(SessionStatusText.remoteIP(from: nil, language: .zhHant))
    }

    func testFormatSpecifiersInHostAreLiteral() throws {
        let profile = try makeProfile(host: "%@%n%d.example.test", proxy: nil)
        XCTAssertEqual(
            SessionStatusText.remoteIP(from: profile, language: .zhHant),
            "遠端 IP：%@%n%d.example.test"
        )
    }

    private func makeProfile(host: String, proxy: String?) throws -> ConnectionProfile {
        var lines = [
            "[virt-viewer]",
            "type=spice",
            "host=\(host)",
            "tls-port=61001",
            "password=example-ticket-not-secret",
            "ca=-----BEGIN CERTIFICATE-----\\nMIIBizCCATGgAwIBAgIUL0QU9hTtHKAkePzKdhK6O29VxIEwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQcHZlLmV4YW1wbGUudGVzdDAeFw0yNjExMjQwNTQwMjBaFw0zNjExMjEwNTQwMjBaMBsxGTAXBgNVBAMMEHB2ZS5leGFtcGxlLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS58TUSpXMsnqt28K3DxsPeuGopROR9GqJdlU7E02qTpiHxgxhBKcJ/ITF5LrbhpgnAG6T80/49tExftl21vZ5so1MwUTAdBgNVHQ4EFgQU4v3tpNGL8ZZZOBfHCAVMDehGdGAwHwYDVR0jBBgwFoAU4v3tpNGL8ZZZOBfHCAVMDehGdGAwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiA0Gk8MiagBJ2gxgCszKUZrsRaPyYGQCNZGamYd5SAXhgIhAL5w+WStJ0cw88VFewjwIYczmaMsSUiwrq65kjqatWEZ\\n-----END CERTIFICATE-----",
            "host-subject=CN=example"
        ]
        if let proxy {
            lines.insert("proxy=\(proxy)", at: 3)
        }
        return try VVParser().parse(data: Data(lines.joined(separator: "\n").utf8))
    }
}
