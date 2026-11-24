import Observation
import XCTest
@testable import MacRemoteViewerCore

@MainActor
final class SessionControllerTests: XCTestCase {
    func testSuccessfulConnectDeletesMatchingSourceFile() throws {
        let files = MockFileAccessor()
        let url = URL(fileURLWithPath: "/tmp/example.vv")
        files.identities[url] = SourceFileIdentity(
            path: url.path,
            fileNumber: 42,
            volumeIdentifier: 1,
            size: 100,
            modificationTime: 10
        )
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            files: files,
            cleanup: SourceFileCleanup()
        )
        var profile = try VVParser().parse(data: Data(Self.minimalVV().utf8), sourceIdentity: files.identities[url])
        profile = ConnectionProfile(
            sessionID: profile.sessionID,
            title: profile.title,
            host: profile.host,
            tlsPort: profile.tlsPort,
            proxyURL: profile.proxyURL,
            caPEM: profile.caPEM,
            hostSubject: profile.hostSubject,
            ticket: profile.ticket,
            deleteSourceFile: true,
            toggleFullscreen: profile.toggleFullscreen,
            releaseCursor: profile.releaseCursor,
            secureAttention: profile.secureAttention,
            unknownFieldNames: profile.unknownFieldNames,
            sourceIdentity: files.identities[url]
        )
        controller.open(profile)
        engine.delegate?.engineDidConnect()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.cleanupResult, .deleted)
        XCTAssertTrue(files.removed.contains(url.path))
        XCTAssertEqual(files.accessCount, 1)
    }

    func testReplacedFileIsNotDeleted() throws {
        let files = MockFileAccessor()
        let original = SourceFileIdentity(path: "/tmp/example.vv", fileNumber: 1, volumeIdentifier: 1, size: 10, modificationTime: 1)
        files.identities[URL(fileURLWithPath: original.path)] = SourceFileIdentity(
            path: original.path,
            fileNumber: 99,
            volumeIdentifier: 1,
            size: 10,
            modificationTime: 2
        )
        let engine = MockEngine()
        let controller = SessionController(engine: engine, files: files)
        let profile = try VVParser().parse(data: Data(Self.minimalVV().utf8), sourceIdentity: original)
        controller.open(profile)
        engine.delegate?.engineDidConnect()
        XCTAssertEqual(controller.cleanupResult, .replacedFilePreserved)
        XCTAssertTrue(files.removed.isEmpty)
    }

    func testUserPreferenceKeepsSourceFileAfterConnect() throws {
        let files = MockFileAccessor()
        let url = URL(fileURLWithPath: "/tmp/example.vv")
        files.identities[url] = SourceFileIdentity(
            path: url.path,
            fileNumber: 42,
            volumeIdentifier: 1,
            size: 100,
            modificationTime: 10
        )
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            files: files,
            cleanup: SourceFileCleanup(deleteAfterSuccessfulConnect: false)
        )
        let profile = try VVParser().parse(
            data: Data(Self.minimalVV().utf8),
            sourceIdentity: files.identities[url]
        )
        controller.open(profile)
        engine.delegate?.engineDidConnect()
        XCTAssertEqual(controller.cleanupResult, .skipped)
        XCTAssertTrue(files.removed.isEmpty)
    }

    func testUserPreferenceDeletesFileEvenWithoutDeleteThisFileFlag() throws {
        let files = MockFileAccessor()
        let url = URL(fileURLWithPath: "/tmp/example.vv")
        files.identities[url] = SourceFileIdentity(
            path: url.path,
            fileNumber: 7,
            volumeIdentifier: 1,
            size: 80,
            modificationTime: 3
        )
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            files: files,
            cleanup: SourceFileCleanup(deleteAfterSuccessfulConnect: true)
        )
        let profile = try VVParser().parse(
            data: Data(Self.minimalVV(deleteThisFile: false).utf8),
            sourceIdentity: files.identities[url]
        )
        controller.open(profile)
        engine.delegate?.engineDidConnect()
        XCTAssertEqual(controller.cleanupResult, .deleted)
        XCTAssertEqual(files.removed, [url.path])
    }

    func testFailedConnectionKeepsSourceFile() throws {
        let files = MockFileAccessor()
        let engine = MockEngine()
        engine.connectError = .authenticationRejected
        let controller = SessionController(engine: engine, files: files)
        let profile = try VVParser().parse(data: Data(Self.minimalVV().utf8))
        controller.open(profile)
        XCTAssertEqual(controller.state, .failed(.authenticationRejected))
        XCTAssertTrue(files.removed.isEmpty)
    }

    func testCancelReleasesKeys() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        controller.cancel()
        XCTAssertTrue(engine.didReleaseKeys)
        XCTAssertEqual(controller.state, .disconnected)
    }

    func testAttachRendererForwardsToEngine() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine)
        let renderer = NSObject()
        controller.attachRenderer(renderer)
        XCTAssertTrue(engine.attachedRenderer === renderer)
    }

    func testDetachRendererForwardsToEngineAndClearsAttachment() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine)
        let renderer = NSObject()
        controller.attachRenderer(renderer)
        controller.detachRenderer(renderer)
        XCTAssertTrue(engine.detachedRenderer === renderer)
        XCTAssertNil(engine.attachedRenderer)
    }

    func testDetachRendererWritesDiagnostics() {
        let writer = MemoryFileLogWriter()
        let sink = FileLogSink(enabled: true, writer: writer)
        let controller = SessionController(
            engine: MockEngine(),
            diagnostics: DiagnosticsLog(sessionID: "session-demo", fileLog: sink)
        )
        let renderer = NSObject()
        controller.attachRenderer(renderer)
        controller.detachRenderer(renderer)
        XCTAssertTrue(writer.lines.contains { $0.contains("renderer-detach") })
        XCTAssertFalse(writer.lines.contains { $0.contains("renderer-attach") })
    }

    func testDisplayUpdateStoresFrameForViewport() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1920, height: 1080))
        XCTAssertEqual(controller.displaySize, RemoteFrame(width: 1920, height: 1080))
    }

    func testViewportResizeRequestsGuestResolutionWhenAgentAllows() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        try connect(controller, engine: engine, monitorsConfig: true)
        controller.updateViewportSize(CGSize(width: 1281, height: 801))
        XCTAssertEqual(engine.requestedResolutions, [CGSize(width: 1280, height: 800)])
    }

    func testViewportResizeIsIgnoredWithoutMonitorsConfig() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        try connect(controller, engine: engine, monitorsConfig: false)
        controller.updateViewportSize(CGSize(width: 1280, height: 800))
        XCTAssertTrue(engine.requestedResolutions.isEmpty)
    }

    func testPendingViewportResizeFlushesWhenAgentConnects() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        XCTAssertTrue(engine.requestedResolutions.isEmpty)

        engine.delegate?.engineDidUpdateAgent(AgentCapabilities(
            isConnected: true,
            supportsClipboard: true,
            supportsMonitorsConfig: true
        ))
        XCTAssertEqual(engine.requestedResolutions, [CGSize(width: 1600, height: 900)])
    }

    func testDuplicateViewportSizeDoesNotResend() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        try connect(controller, engine: engine, monitorsConfig: true)
        controller.updateViewportSize(CGSize(width: 1280, height: 800))
        controller.updateViewportSize(CGSize(width: 1280, height: 800))
        XCTAssertEqual(engine.requestedResolutions.count, 1)
    }

    func testMatchingGuestDisplayDoesNotResend() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        try connect(controller, engine: engine, monitorsConfig: true)
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1280, height: 800))
        controller.updateViewportSize(CGSize(width: 1280, height: 800))
        XCTAssertTrue(engine.requestedResolutions.isEmpty)
    }

    func testGuestInitiatedChangeReappliesWindowSizeIfNeverRequested() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        try connect(controller, engine: engine, monitorsConfig: true)
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1280, height: 800))
        controller.updateViewportSize(CGSize(width: 1280, height: 800))
        XCTAssertTrue(engine.requestedResolutions.isEmpty)

        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1024, height: 768))
        XCTAssertEqual(engine.requestedResolutions, [CGSize(width: 1280, height: 800)])
    }

    func testDoesNotRefightGuestWhileRequestedSizeIsPending() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        try connect(controller, engine: engine, monitorsConfig: true)
        controller.updateViewportSize(CGSize(width: 1280, height: 800))
        XCTAssertEqual(engine.requestedResolutions.count, 1)

        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1280, height: 802))
        XCTAssertEqual(engine.requestedResolutions.count, 1)
    }

    func testRetriesWhenGuestDoesNotApplyRequestedSize() async throws {
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            resolutionDebounce: .zero,
            resolutionRetryDelay: .milliseconds(30),
            resolutionRetryLimit: 2
        )
        try connect(controller, engine: engine, monitorsConfig: true)
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1024, height: 768))
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        XCTAssertEqual(engine.requestedResolutions.count, 1)
        XCTAssertFalse(controller.guestDidNotApplyResolution)

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.requestedResolutions.count, 2)
        XCTAssertEqual(
            engine.requestedResolutions.last,
            CGSize(width: 1600, height: 900)
        )
        XCTAssertFalse(controller.guestDidNotApplyResolution)
    }

    func testFlagsWhenGuestNeverAppliesRequestedSize() async throws {
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            resolutionDebounce: .zero,
            resolutionRetryDelay: .milliseconds(30),
            resolutionRetryLimit: 1
        )
        try connect(controller, engine: engine, monitorsConfig: true)
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1024, height: 768))
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        XCTAssertEqual(engine.requestedResolutions.count, 1)

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(engine.requestedResolutions.count, 2)
        XCTAssertTrue(controller.guestDidNotApplyResolution)
    }

    func testDoesNotRetryAfterGuestAppliesRequestedSize() async throws {
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            resolutionDebounce: .zero,
            resolutionRetryDelay: .milliseconds(30),
            resolutionRetryLimit: 2
        )
        try connect(controller, engine: engine, monitorsConfig: true)
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        XCTAssertEqual(engine.requestedResolutions.count, 1)

        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1600, height: 900))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(engine.requestedResolutions.count, 1)
        XCTAssertFalse(controller.guestDidNotApplyResolution)
    }

    func testDisconnectDuringRetryDoesNotResendOrFlag() async throws {
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            resolutionDebounce: .zero,
            resolutionRetryDelay: .milliseconds(30),
            resolutionRetryLimit: 2
        )
        try connect(controller, engine: engine, monitorsConfig: true)
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1024, height: 768))
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        XCTAssertEqual(engine.requestedResolutions.count, 1)

        controller.cancel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(engine.requestedResolutions.count, 1)
        XCTAssertFalse(controller.guestDidNotApplyResolution)
    }

    func testNewViewportSizeClearsUnappliedResolutionFlag() async throws {
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            resolutionDebounce: .zero,
            resolutionRetryDelay: .milliseconds(30),
            resolutionRetryLimit: 1
        )
        try connect(controller, engine: engine, monitorsConfig: true)
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1024, height: 768))
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(controller.guestDidNotApplyResolution)

        controller.updateViewportSize(CGSize(width: 1280, height: 800))
        XCTAssertFalse(controller.guestDidNotApplyResolution)
        XCTAssertEqual(engine.requestedResolutions.last, CGSize(width: 1280, height: 800))
    }

    func testDebouncedResizeSendsLatestSize() async throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .milliseconds(30))
        try connect(controller, engine: engine, monitorsConfig: true)
        controller.updateViewportSize(CGSize(width: 1000, height: 800))
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        XCTAssertTrue(engine.requestedResolutions.isEmpty)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(engine.requestedResolutions, [CGSize(width: 1600, height: 900)])
    }

    func testAgentReconnectResendsViewportSize() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        try connect(controller, engine: engine, monitorsConfig: true)
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        XCTAssertEqual(engine.requestedResolutions.count, 1)

        engine.delegate?.engineDidUpdateAgent(AgentCapabilities())
        engine.delegate?.engineDidUpdateAgent(AgentCapabilities(
            isConnected: true,
            supportsClipboard: true,
            supportsMonitorsConfig: true
        ))
        XCTAssertEqual(engine.requestedResolutions, [
            CGSize(width: 1600, height: 900),
            CGSize(width: 1600, height: 900)
        ])
    }

    func testPresetResolutionIgnoresViewportSize() throws {
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            resolutionDebounce: .zero,
            resolutionPreference: .preset(RemoteFrame(width: 1920, height: 1080))
        )
        try connect(controller, engine: engine, monitorsConfig: true)
        controller.updateViewportSize(CGSize(width: 1280, height: 800))
        XCTAssertEqual(engine.requestedResolutions, [CGSize(width: 1920, height: 1080)])
    }

    func testKeepGuestDoesNotRequestResolution() throws {
        let engine = MockEngine()
        let controller = SessionController(
            engine: engine,
            resolutionDebounce: .zero,
            resolutionPreference: .keepGuest
        )
        try connect(controller, engine: engine, monitorsConfig: true)
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        XCTAssertTrue(engine.requestedResolutions.isEmpty)
    }

    func testApplyResolutionPreferenceSendsPreset() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        try connect(controller, engine: engine, monitorsConfig: true)
        controller.updateViewportSize(CGSize(width: 1280, height: 800))
        XCTAssertEqual(engine.requestedResolutions, [CGSize(width: 1280, height: 800)])

        controller.applyResolutionPreference(.preset(RemoteFrame(width: 1920, height: 1080)))
        XCTAssertEqual(engine.requestedResolutions, [
            CGSize(width: 1280, height: 800),
            CGSize(width: 1920, height: 1080)
        ])
    }

    func testCancelDropsPendingResolutionRequest() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        controller.cancel()
        engine.delegate?.engineDidUpdateAgent(AgentCapabilities(
            isConnected: true,
            supportsClipboard: true,
            supportsMonitorsConfig: true
        ))
        XCTAssertTrue(engine.requestedResolutions.isEmpty)
    }

    /// SwiftUI 在 `updateNSView`／layout 期間會安裝 Observation tracking。
    /// 第一個呼叫會讀內部 viewport 狀態；若該欄位未被 `@ObservationIgnored`，
    /// 第二次寫入會觸發 onChange，AppKit display cycle 會 SIGTRAP。
    func testViewportSizeUpdateDoesNotNotifyObservationTracking() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero)
        try connect(controller, engine: engine, monitorsConfig: true)
        let changed = ObservationFlag()

        withObservationTracking {
            controller.updateViewportSize(CGSize(width: 1280, height: 800))
        } onChange: {
            changed.value = true
        }
        controller.updateViewportSize(CGSize(width: 1600, height: 900))

        XCTAssertEqual(
            engine.requestedResolutions,
            [CGSize(width: 1280, height: 800), CGSize(width: 1600, height: 900)]
        )
        XCTAssertFalse(
            changed.value,
            "updateViewportSize 不可讓 SwiftUI 追蹤內部 viewport 狀態"
        )
    }

    func testDisplaySizeUpdateStillNotifiesObservationTracking() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        let changed = ObservationFlag()

        withObservationTracking {
            _ = controller.displaySize
        } onChange: {
            changed.value = true
        }

        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1920, height: 1080))
        XCTAssertTrue(changed.value)
        XCTAssertEqual(controller.displaySize, RemoteFrame(width: 1920, height: 1080))
    }

    private func connect(
        _ controller: SessionController,
        engine: MockEngine,
        monitorsConfig: Bool
    ) throws {
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        engine.delegate?.engineDidUpdateAgent(AgentCapabilities(
            isConnected: true,
            supportsClipboard: true,
            supportsMonitorsConfig: monitorsConfig
        ))
    }

    private static func minimalVV(deleteThisFile: Bool = true) -> String {
        """
        [virt-viewer]
        type=spice
        host=pve.example.test
        proxy=http://pve.example.test:3128
        tls-port=61001
        password=example-ticket-not-secret
        ca=-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----
        host-subject=CN=pve.example.test
        delete-this-file=\(deleteThisFile ? "1" : "0")
        """
    }
}

private final class MockEngine: SpiceEngineing {
    weak var delegate: SpiceEngineDelegate?
    var connectError: SessionError?
    var didReleaseKeys = false
    var attachedRenderer: AnyObject?
    var detachedRenderer: AnyObject?
    var requestedResolutions: [CGSize] = []

    func startWorker() throws {}

    func connect(profile: ConnectionProfile) throws {
        if let connectError {
            throw connectError
        }
    }

    func disconnect() {}
    func sendMouse(_ event: MouseEvent) {}
    func sendKey(_ event: KeyEvent) {}
    func releaseKeys() { didReleaseKeys = true }
    func sendCtrlAltDelete() {}
    func attachDisplayRenderer(_ renderer: AnyObject) { attachedRenderer = renderer }
    func detachDisplayRenderer(_ renderer: AnyObject) {
        detachedRenderer = renderer
        if attachedRenderer === renderer {
            attachedRenderer = nil
        }
    }
    func requestResolution(_ size: CGSize) {
        requestedResolutions.append(size)
    }

    func setClipboardSharingEnabled(_ enabled: Bool) {}
}

/// `withObservationTracking` 的 onChange 是 `@Sendable`。測試本體在 `@MainActor` 上序列化存取，故無需鎖。
private final class ObservationFlag: @unchecked Sendable {
    var value = false
}

private final class MockFileAccessor: FileAccessing, @unchecked Sendable {
    var identities: [URL: SourceFileIdentity] = [:]
    var removed: [String] = []
    var accessCount = 0

    func read(from url: URL) throws -> Data { Data() }

    func identity(of url: URL) throws -> SourceFileIdentity {
        guard let identity = identities[url] else {
            throw SessionError.sourceFileUnavailable
        }
        return identity
    }

    func removeItem(at url: URL) throws {
        removed.append(url.path)
    }

    func startAccessing(_ url: URL) -> Bool {
        accessCount += 1
        return true
    }
    func stopAccessing(_ url: URL) {}
}
