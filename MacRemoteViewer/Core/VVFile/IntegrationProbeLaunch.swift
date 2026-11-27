import Foundation

/// Explicit opt-in for the packaged-app integration harness. Not an OS
/// authorization boundary: a local process can supply its own environment.
public enum IntegrationProbeLaunch: Equatable, Sendable {
    case normal
    case allowed
    case denied

    public static let optInKey = "MRV_ENABLE_INTEGRATION_PROBES"

    // Number of arguments following the single mode flag.
    private static let modes: [String: Int] = [
        "--startup-smoke-test": 0,
        "--loopback-tls-probe": 1,
        "--loopback-spice-auth-probe": 1,
        "--loopback-spice-display-probe": 1,
        "--loopback-spice-wrapper-probe": 4,
        "--loopback-spice-multi-probe": 4,
        "--loopback-spice-network-fault-probe": 4,
        "--loopback-spice-partial-probe": 1,
        "--loopback-spice-workspace-probe": 4,
        "--loopback-spice-agent-probe": 2,
        "--loopback-spice-clipboard-probe": 1,
        "--clipboard-security-probe": 0,
        "--loopback-spice-clipboard-isolation-probe": 2,
        "--loopback-spice-clipboard-invalid-probe": 1,
        "--loopback-spice-clipboard-late-probe": 4,
        "--loopback-spice-clipboard-reactivate-probe": 4,
        "--loopback-spice-clipboard-bulk-probe": 1,
        "--scanout-runtime-probe": 0,
        "--scanout-drawable-probe": 0,
    ]

    public static func evaluate(arguments: [String], environment: [String: String]) -> Self {
        let args = Array(arguments.dropFirst())
        let flags = args.filter { modes[$0] != nil }
        guard !flags.isEmpty else { return .normal }
        guard environment[optInKey] == "1", flags.count == 1,
              let mode = args.first, let count = modes[mode],
              args.count == count + 1,
              args.dropFirst().allSatisfy({ !$0.isEmpty && !$0.hasPrefix("--") }) else {
            return .denied
        }
        if mode == "--loopback-spice-agent-probe",
           !["full", "limited", "monitor-full", "monitor-limited", "monitor-resize-full", "monitor-stress-full"].contains(args[2]) {
            return .denied
        }
        return .allowed
    }
}
