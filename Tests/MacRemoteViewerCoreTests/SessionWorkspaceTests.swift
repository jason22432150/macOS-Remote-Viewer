import XCTest
@testable import MacRemoteViewerCore

@MainActor
final class SessionWorkspaceTests: XCTestCase {
    func testOpeningFirstProfileSelectsThatSession() throws {
        let harness = WorkspaceHarness()
        let profile = try Self.profile(title: "first", sessionID: "s1")

        harness.workspace.open(profile)

        XCTAssertEqual(harness.workspace.sessions.map(\.sessionID), ["s1"])
        XCTAssertEqual(harness.workspace.selectedSessionID, "s1")
        XCTAssertEqual(harness.workspace.selectedSession?.profile?.title, "first")
        XCTAssertFalse(harness.workspace.showsTabBar)
    }

    func testOpeningAnotherProfileKeepsTheExistingSessionAndSelectsTheNewTab() throws {
        let harness = WorkspaceHarness()
        let first = try Self.profile(title: "alpha", sessionID: "s1")
        let second = try Self.profile(title: "beta", sessionID: "s2")

        harness.workspace.open(first)
        harness.engines[0].delegate?.engineDidConnect()
        let firstDisconnectsAfterConnect = harness.engines[0].disconnectCount

        harness.workspace.open(second)
        harness.engines[1].delegate?.engineDidConnect()

        XCTAssertEqual(harness.workspace.sessions.map(\.sessionID), ["s1", "s2"])
        XCTAssertEqual(harness.workspace.selectedSessionID, "s2")
        XCTAssertEqual(harness.workspace.sessions[0].state, .connected)
        XCTAssertEqual(harness.workspace.sessions[1].state, .connected)
        XCTAssertEqual(
            harness.engines[0].disconnectCount,
            firstDisconnectsAfterConnect,
            "既有連線的 engine 不可因再開一個 .vv 被 disconnect"
        )
        XCTAssertTrue(harness.workspace.showsTabBar)
    }

    func testOpeningSeveralProfilesAtOnceKeepsAllSessionsAndSelectsTheLast() throws {
        let harness = WorkspaceHarness()
        let profiles = try [
            Self.profile(title: "one", sessionID: "s1"),
            Self.profile(title: "two", sessionID: "s2"),
            Self.profile(title: "three", sessionID: "s3"),
        ]

        harness.workspace.open(profiles)

        XCTAssertEqual(harness.workspace.sessions.map(\.sessionID), ["s1", "s2", "s3"])
        XCTAssertEqual(harness.workspace.selectedSessionID, "s3")
        XCTAssertTrue(harness.workspace.showsTabBar)
    }

    func testClosingSelectedTabSelectsTheRightNeighbor() throws {
        let harness = WorkspaceHarness()
        harness.workspace.open(try [
            Self.profile(title: "a", sessionID: "s1"),
            Self.profile(title: "b", sessionID: "s2"),
            Self.profile(title: "c", sessionID: "s3"),
        ])
        harness.workspace.select("s1")

        harness.workspace.close("s1")

        XCTAssertEqual(harness.workspace.sessions.map(\.sessionID), ["s2", "s3"])
        XCTAssertEqual(harness.workspace.selectedSessionID, "s2")
        XCTAssertEqual(harness.engines[0].disconnectCount, 2)
    }

    func testClosingLastTabSelectsTheNewLastTab() throws {
        let harness = WorkspaceHarness()
        harness.workspace.open(try [
            Self.profile(title: "a", sessionID: "s1"),
            Self.profile(title: "b", sessionID: "s2"),
        ])

        harness.workspace.close("s2")

        XCTAssertEqual(harness.workspace.sessions.map(\.sessionID), ["s1"])
        XCTAssertEqual(harness.workspace.selectedSessionID, "s1")
        XCTAssertFalse(harness.workspace.showsTabBar)
    }

    func testClosingTheOnlySessionReturnsToEmptyWorkspace() throws {
        let harness = WorkspaceHarness()
        harness.workspace.open(try Self.profile(title: "only", sessionID: "s1"))

        harness.workspace.close("s1")

        XCTAssertTrue(harness.workspace.sessions.isEmpty)
        XCTAssertNil(harness.workspace.selectedSessionID)
        XCTAssertNil(harness.workspace.selectedSession)
        XCTAssertFalse(harness.workspace.showsTabBar)
    }

    func testClosingABackgroundTabKeepsTheCurrentSelection() throws {
        let harness = WorkspaceHarness()
        harness.workspace.open(try [
            Self.profile(title: "a", sessionID: "s1"),
            Self.profile(title: "b", sessionID: "s2"),
            Self.profile(title: "c", sessionID: "s3"),
        ])

        harness.workspace.close("s1")

        XCTAssertEqual(harness.workspace.sessions.map(\.sessionID), ["s2", "s3"])
        XCTAssertEqual(harness.workspace.selectedSessionID, "s3")
    }

    func testSelectingASessionEnablesClipboardOnlyOnTheActiveTab() throws {
        let harness = WorkspaceHarness()
        harness.workspace.open(try [
            Self.profile(title: "a", sessionID: "s1"),
            Self.profile(title: "b", sessionID: "s2"),
        ])

        XCTAssertFalse(harness.engines[0].clipboardSharingEnabled)
        XCTAssertTrue(harness.engines[1].clipboardSharingEnabled)

        harness.workspace.select("s1")

        XCTAssertTrue(harness.engines[0].clipboardSharingEnabled)
        XCTAssertFalse(harness.engines[1].clipboardSharingEnabled)
        XCTAssertTrue(harness.engines[1].didReleaseKeys)
    }

    func testApplyResolutionPreferenceUpdatesEverySession() throws {
        let harness = WorkspaceHarness()
        harness.workspace.open(try [
            Self.profile(title: "a", sessionID: "s1"),
            Self.profile(title: "b", sessionID: "s2"),
        ])
        for (controller, engine) in zip(harness.workspace.sessions, harness.engines.all) {
            engine.delegate?.engineDidConnect()
            engine.delegate?.engineDidUpdateAgent(AgentCapabilities(
                isConnected: true,
                supportsClipboard: true,
                supportsMonitorsConfig: true
            ))
            controller.updateViewportSize(CGSize(width: 1280, height: 800))
        }

        harness.workspace.applyResolutionPreference(.preset(RemoteFrame(width: 1920, height: 1080)))

        XCTAssertEqual(
            harness.engines.all.map(\.requestedResolutions),
            [
                [CGSize(width: 1280, height: 800), CGSize(width: 1920, height: 1080)],
                [CGSize(width: 1280, height: 800), CGSize(width: 1920, height: 1080)],
            ]
        )
    }

    private static func profile(title: String, sessionID: String) throws -> ConnectionProfile {
        let parsed = try VVParser().parse(data: Data(minimalVV(title: title).utf8))
        return ConnectionProfile(
            sessionID: sessionID,
            title: parsed.title,
            host: parsed.host,
            tlsPort: parsed.tlsPort,
            proxyURL: parsed.proxyURL,
            caPEM: parsed.caPEM,
            hostSubject: parsed.hostSubject,
            ticket: parsed.ticket,
            deleteSourceFile: parsed.deleteSourceFile,
            toggleFullscreen: parsed.toggleFullscreen,
            releaseCursor: parsed.releaseCursor,
            secureAttention: parsed.secureAttention,
            unknownFieldNames: parsed.unknownFieldNames,
            sourceIdentity: parsed.sourceIdentity
        )
    }

    private static func minimalVV(title: String) -> String {
        """
        [virt-viewer]
        type=spice
        title=\(title)
        host=pve.example.test
        proxy=http://pve.example.test:3128
        tls-port=61001
        password=example-ticket-not-secret
        ca=-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----
        host-subject=CN=pve.example.test
        """
    }
}

@MainActor
private final class WorkspaceHarness {
    let engines: EngineBox
    let workspace: SessionWorkspace

    init() {
        let engines = EngineBox()
        self.engines = engines
        self.workspace = SessionWorkspace { profile in
            let engine = engines.make()
            return SessionController(
                engine: engine,
                resolutionDebounce: .zero,
                sessionID: profile.sessionID
            )
        }
    }
}

/// 讓 factory closure 與測試本體共用同一批 engine。
@MainActor
private final class EngineBox {
    private(set) var all: [WorkspaceMockEngine] = []

    subscript(index: Int) -> WorkspaceMockEngine { all[index] }

    func make() -> WorkspaceMockEngine {
        let engine = WorkspaceMockEngine()
        all.append(engine)
        return engine
    }
}

@MainActor
private final class WorkspaceMockEngine: SpiceEngineing {
    weak var delegate: SpiceEngineDelegate?
    var disconnectCount = 0
    var didReleaseKeys = false
    var clipboardSharingEnabled = true
    var requestedResolutions: [CGSize] = []

    func startWorker() throws {}

    func connect(profile: ConnectionProfile) throws {}

    func disconnect() {
        disconnectCount += 1
    }

    func sendMouse(_ event: MouseEvent) {}
    func sendKey(_ event: KeyEvent) {}
    func releaseKeys() { didReleaseKeys = true }
    func sendCtrlAltDelete() {}
    func attachDisplayRenderer(_ renderer: AnyObject) {}
    func detachDisplayRenderer(_ renderer: AnyObject) {}
    func requestResolution(_ size: CGSize) {
        requestedResolutions.append(size)
    }

    func setClipboardSharingEnabled(_ enabled: Bool) {
        clipboardSharingEnabled = enabled
    }
}
