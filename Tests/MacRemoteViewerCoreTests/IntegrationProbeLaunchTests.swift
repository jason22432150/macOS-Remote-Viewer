import XCTest
@testable import MacRemoteViewerCore

final class IntegrationProbeLaunchTests: XCTestCase {
    private let enabled = [IntegrationProbeLaunch.optInKey: "1"]

    func testNormalLaunchDoesNotRequireOptIn() {
        for arguments in [["app"], ["app", "/tmp/example.vv"], ["app", "-psn_0_123"]] {
            XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: arguments, environment: [:]), .normal)
            XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: arguments, environment: enabled), .normal)
        }
    }

    func testEveryProbeRequiresExplicitOptInAndExactArguments() {
        let cases: [(String, [String])] = [
            ("--startup-smoke-test", []), ("--scanout-runtime-probe", []),
            ("--scanout-drawable-probe", []), ("--clipboard-security-probe", []),
            ("--loopback-tls-probe", ["a.vv"]), ("--loopback-spice-auth-probe", ["a.vv"]),
            ("--loopback-spice-display-probe", ["a.vv"]), ("--loopback-spice-partial-probe", ["a.vv"]),
            ("--loopback-spice-clipboard-probe", ["a.vv"]),
            ("--loopback-spice-clipboard-invalid-probe", ["a.vv"]),
            ("--loopback-spice-clipboard-bulk-probe", ["a.vv"]),
            ("--loopback-spice-agent-probe", ["a.vv", "full"]),
            ("--loopback-spice-agent-probe", ["a.vv", "monitor-stress-full"]),
            ("--loopback-spice-clipboard-isolation-probe", ["a.vv", "b.vv"]),
            ("--loopback-spice-clipboard-late-probe", ["a.vv", "b.vv", "request", "delivered"]),
            ("--loopback-spice-clipboard-reactivate-probe", ["a.vv", "b.vv", "request", "delivered"]),
            ("--loopback-spice-wrapper-probe", ["a.vv", "b.vv", "c.vv", "d.vv"]),
            ("--loopback-spice-multi-probe", ["a.vv", "b.vv", "c.vv", "d.vv"]),
            ("--loopback-spice-network-fault-probe", ["a.vv", "b.vv", "c.vv", "d.vv"]),
            ("--loopback-spice-relay-stall-probe", ["a.vv", "b.vv", "c.vv", "d.vv"]),
            ("--loopback-spice-handshake-stall-probe", ["a.vv", "b.vv"]),
            ("--loopback-spice-ticket-expiry-probe", ["a.vv", "b.vv"]),
            ("--loopback-spice-workspace-probe", ["a.vv", "b.vv", "c.vv", "d.vv"]),
        ]
        for (mode, operands) in cases {
            let args = ["app", mode] + operands
            XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: args, environment: [:]), .denied, mode)
            XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: args, environment: [IntegrationProbeLaunch.optInKey: "true"]), .denied, mode)
            XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: args, environment: enabled), .allowed, mode)
            XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: args + ["extra"], environment: enabled), .denied, mode)
            XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: ["app", "extra", mode] + operands, environment: enabled), .denied, mode)
            XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: args + ["--startup-smoke-test"], environment: enabled), .denied, mode)
            if !operands.isEmpty {
                XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: Array(args.dropLast()), environment: enabled), .denied, mode)
            }
        }
    }

    func testInvalidAgentModeAndFlagLikeOperandRejected() {
        XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: ["app", "--loopback-spice-agent-probe", "a.vv", "invalid"], environment: enabled), .denied)
        XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: ["app", "--loopback-tls-probe", "--unknown"], environment: enabled), .denied)
        XCTAssertEqual(IntegrationProbeLaunch.evaluate(arguments: ["app", "--loopback-tls-probe", ""], environment: enabled), .denied)
    }
}
