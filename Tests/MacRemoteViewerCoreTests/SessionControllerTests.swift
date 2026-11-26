import Observation
import XCTest
@testable import MacRemoteViewerCore

@MainActor
final class SessionControllerTests: XCTestCase {
    func testEngineFailureDiscardsArbitraryAssociatedPayload() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidFail(.unknown(code: "synthetic-private-engine-error"))
        XCTAssertEqual(controller.state, .failed(.unknown(code: "<redacted>")))
        controller.cancel()
    }

    func testControllerKeepsPresentationNotTransportCredentials() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine)
        let base = try VVParser().parse(data: Data(Self.minimalVV().utf8))
        let profile = ConnectionProfile(
            sessionID: base.sessionID, title: "VM test",
            host: "pvespiceproxy:synthetic-private-destination",
            tlsPort: base.tlsPort, proxyURL: URL(string: "http://demo:synthetic-private-proxy@192.0.2.10:3128"),
            caPEM: base.caPEM, hostSubject: base.hostSubject,
            ticket: .init("synthetic-private-ticket"), deleteSourceFile: false,
            toggleFullscreen: base.toggleFullscreen, releaseCursor: base.releaseCursor,
            secureAttention: base.secureAttention, unknownFieldNames: base.unknownFieldNames,
            sourceIdentity: nil
        )
        controller.open(profile)
        XCTAssertTrue(engine.receivedExpectedCredentials)
        let presentation = try XCTUnwrap(controller.profile)
        XCTAssertEqual(presentation.title, "VM test")
        XCTAssertEqual(presentation.remoteAddress, "192.0.2.10")
        XCTAssertEqual(presentation.toggleFullscreen, profile.toggleFullscreen)
        XCTAssertEqual(presentation.releaseCursor, profile.releaseCursor)
        XCTAssertEqual(presentation.secureAttention, profile.secureAttention)
        XCTAssertEqual(presentation.unknownFieldNames, profile.unknownFieldNames)
        let labels = Set(Mirror(reflecting: presentation).children.compactMap(\.label))
        XCTAssertEqual(labels, Set(["title", "remoteAddress", "toggleFullscreen",
                                    "releaseCursor", "secureAttention", "unknownFieldNames"]))
        XCTAssertFalse(String(reflecting: presentation).contains("synthetic-private"))
        engine.delegate?.engineDidConnect()
        XCTAssertEqual(controller.profile, presentation)
        controller.cancel()
        XCTAssertEqual(controller.profile, presentation)
    }

    func testFailedOrCancelledConnectionDoesNotDeletePendingSource() throws {
        let files = MockFileAccessor()
        let url = URL(fileURLWithPath: "/tmp/secret.vv")
        let identity = SourceFileIdentity(path: url.path, fileNumber: 42, volumeIdentifier: 1,
                                          size: 100, modificationTime: 10)
        files.identities[url] = identity
        let profile = try VVParser().parse(data: Data(Self.minimalVV().utf8), sourceIdentity: identity)
        for action in 0..<3 {
            let engine = MockEngine()
            let controller = SessionController(engine: engine, files: files)
            controller.open(profile)
            switch action {
            case 0: controller.cancel()
            case 1: engine.delegate?.engineDidFail(.authenticationRejected)
            default: engine.delegate?.engineDidDisconnect()
            }
            engine.delegate?.engineDidConnect()
            XCTAssertTrue(files.removed.isEmpty)
            XCTAssertEqual(controller.cleanupResult, .skipped)
            // A fresh import without an identity cannot inherit a previous one.
            controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
            engine.delegate?.engineDidConnect()
            XCTAssertTrue(files.removed.isEmpty)
            controller.cancel()
        }
    }

    func testRelativeMouseModeRequiresConnectionAndServerAcceptance() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine)
        controller.setRelativeMouseMode(true)
        XCTAssertFalse(controller.relativeMouseRequested)
        XCTAssertTrue(engine.requestedMouseModes.isEmpty)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        controller.setRelativeMouseMode(true)
        XCTAssertTrue(controller.relativeMouseRequested)
        XCTAssertFalse(controller.usesServerMouseMode)
        XCTAssertEqual(engine.requestedMouseModes, [true])
        engine.usesServerMouseMode = true
        XCTAssertTrue(controller.usesServerMouseMode)
        controller.setRelativeMouseMode(true)
        XCTAssertEqual(engine.requestedMouseModes, [true])
        controller.setRelativeMouseMode(false)
        XCTAssertFalse(controller.relativeMouseRequested)
        XCTAssertEqual(engine.requestedMouseModes, [true, false])
        XCTAssertTrue(engine.didReleaseKeys)
        controller.setRelativeMouseMode(true)
        controller.cancel()
        XCTAssertFalse(controller.relativeMouseRequested)
        XCTAssertFalse(controller.usesServerMouseMode)
    }

    func testFirstFrameDelayWarnsWithoutDisconnectingAndClearsOnRender() async throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, firstFrameWarningDelay: .milliseconds(20))
        try connect(controller, engine: engine, monitorsConfig: false)
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 800, height: 600))
        let deadline = ContinuousClock.now + .seconds(2)
        while !controller.firstFrameDelayed && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.firstFrameDelayed)
        XCTAssertEqual(controller.state, .connected)
        engine.delegate?.engineDidRenderFrame()
        XCTAssertFalse(controller.firstFrameDelayed)
        XCTAssertTrue(controller.hasRenderedFrame)
        engine.delegate?.engineDidLoseDisplay()
        XCTAssertFalse(controller.firstFrameDelayed)
        controller.cancel()
    }

    func testReturningToCurrentResolutionCancelsObsoleteRetry() async throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, resolutionDebounce: .zero,
            resolutionRetryDelay: .milliseconds(30))
        try connect(controller, engine: engine, monitorsConfig: true)
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1024, height: 768))
        controller.updateViewportSize(CGSize(width: 1600, height: 900))
        controller.updateViewportSize(CGSize(width: 1024, height: 768))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(engine.requestedResolutions, [CGSize(width: 1600, height: 900)])
        XCTAssertGreaterThan(engine.clearPendingResolutionCount, 0)
        XCTAssertFalse(controller.guestDidNotApplyResolution)
    }

    func testFirstFrameObservationResetsWhenDisplayIsLost() throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 800, height: 600))
        XCTAssertFalse(controller.hasRenderedFrame)
        engine.delegate?.engineDidRenderFrame()
        XCTAssertTrue(controller.hasRenderedFrame)
        XCTAssertNotNil(controller.firstFrameMilliseconds)
        let initial = controller.firstFrameMilliseconds
        engine.delegate?.engineDidRenderFrame()
        XCTAssertEqual(controller.firstFrameMilliseconds, initial)
        engine.delegate?.engineDidLoseDisplay()
        XCTAssertFalse(controller.hasRenderedFrame)
        XCTAssertNil(controller.firstFrameMilliseconds)
        controller.cancel()
        engine.delegate?.engineDidRenderFrame()
        XCTAssertFalse(controller.hasRenderedFrame)
    }

    func testDisplayTimeoutAfterConnectionWithoutValidDimensions() async throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, displayTimeout: .milliseconds(20))
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 0, height: 0))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while controller.state == .connected && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state, .failed(.displayTimeout))
        XCTAssertTrue(engine.didReleaseKeys)
    }

    func testDisplayArrivalAndRecoveryCancelTimeout() async throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, displayTimeout: .milliseconds(20))
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 800, height: 600))
        engine.delegate?.engineDidLoseDisplay()
        XCTAssertNil(controller.displaySize)
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1024, height: 768))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.displaySize, RemoteFrame(width: 1024, height: 768))
    }

    func testConnectionTimeoutRejectsLateSuccess() async throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine, connectionTimeout: .milliseconds(20))
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while controller.state == .connecting && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state, .failed(.network))
        engine.delegate?.engineDidConnect()
        engine.delegate?.engineDidDisconnect()
        XCTAssertEqual(controller.state, .failed(.network))
    }

    func testInvalidSourceIdentityIsPreserved() throws {
        let files = MockFileAccessor()
        let url = URL(fileURLWithPath: "/tmp/example.vv")
        let identity = SourceFileIdentity(path: url.path, fileNumber: 0, volumeIdentifier: 0,
                                          size: 100, modificationTime: 10)
        files.identities[url] = identity
        let profile = try VVParser().parse(data: Data(Self.minimalVV().utf8), sourceIdentity: identity)
        XCTAssertEqual(SourceFileCleanup().deleteIfNeeded(profile: profile, files: files), .skipped)
        XCTAssertTrue(files.removed.isEmpty)
    }

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

    func testUserPreferenceRespectsExplicitKeepFileFlag() throws {
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
        XCTAssertEqual(controller.cleanupResult, .skipped)
        XCTAssertTrue(files.removed.isEmpty)
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

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        // Observe the terminal condition instead of assuming that the test task
        // resumes between the first and second retries on a loaded runner.
        while !controller.guestDidNotApplyResolution && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.guestDidNotApplyResolution)
        XCTAssertEqual(engine.requestedResolutions, Array(repeating: CGSize(width: 1600, height: 900), count: 3))
        // Exhaustion must not schedule another retry.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.requestedResolutions.count, 3)
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

        // CI scheduling may delay either retry timer; wait for the condition,
        // not an assumption about exact scheduler timing.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !controller.guestDidNotApplyResolution && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !controller.guestDidNotApplyResolution && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while engine.requestedResolutions.isEmpty && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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

    func testRepeatedCancellationAndReopenFencesScheduledWork() async throws {
        let engine = MockEngine()
        let controller = SessionController(engine: engine,
            resolutionDebounce: .milliseconds(15), resolutionRetryDelay: .milliseconds(15),
            connectionTimeout: .milliseconds(15), displayTimeout: .milliseconds(15),
            firstFrameWarningDelay: .milliseconds(15))
        let profile = try VVParser().parse(data: Data(Self.minimalVV(deleteThisFile: false).utf8))
        for _ in 0..<100 {
            controller.open(profile)
            engine.delegate?.engineDidConnect()
            engine.delegate?.engineDidUpdateAgent(AgentCapabilities(isConnected: true,
                supportsClipboard: true, supportsMonitorsConfig: true))
            controller.updateViewportSize(CGSize(width: 1600, height: 900))
            controller.cancel()
            // Late delegate notifications must not revive a cancelled controller.
            engine.delegate?.engineDidConnect()
            engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1024, height: 768))
            engine.delegate?.engineDidRenderFrame()
            XCTAssertEqual(controller.state, .disconnected)
            XCTAssertNil(controller.displaySize)
            XCTAssertFalse(controller.hasRenderedFrame)
        }
        controller.open(profile)
        engine.delegate?.engineDidConnect()
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1024, height: 768))
        engine.delegate?.engineDidRenderFrame()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.state, .connected)
        XCTAssertTrue(controller.hasRenderedFrame)
        XCTAssertFalse(controller.firstFrameDelayed)
        XCTAssertTrue(engine.requestedResolutions.isEmpty)
        controller.cancel()
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
        ca=-----BEGIN CERTIFICATE-----\\nMIIBizCCATGgAwIBAgIUL0QU9hTtHKAkePzKdhK6O29VxIEwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQcHZlLmV4YW1wbGUudGVzdDAeFw0yNjExMjQwNTQwMjBaFw0zNjExMjEwNTQwMjBaMBsxGTAXBgNVBAMMEHB2ZS5leGFtcGxlLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS58TUSpXMsnqt28K3DxsPeuGopROR9GqJdlU7E02qTpiHxgxhBKcJ/ITF5LrbhpgnAG6T80/49tExftl21vZ5so1MwUTAdBgNVHQ4EFgQU4v3tpNGL8ZZZOBfHCAVMDehGdGAwHwYDVR0jBBgwFoAU4v3tpNGL8ZZZOBfHCAVMDehGdGAwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiA0Gk8MiagBJ2gxgCszKUZrsRaPyYGQCNZGamYd5SAXhgIhAL5w+WStJ0cw88VFewjwIYczmaMsSUiwrq65kjqatWEZ\\n-----END CERTIFICATE-----
        host-subject=CN=pve.example.test
        delete-this-file=\(deleteThisFile ? "1" : "0")
        """
    }
}

private final class MockEngine: SpiceEngineing {
    weak var delegate: SpiceEngineDelegate?
    var connectError: SessionError?
    var receivedExpectedCredentials = false
    var didReleaseKeys = false
    var attachedRenderer: AnyObject?
    var detachedRenderer: AnyObject?
    var requestedResolutions: [CGSize] = []
    var clearPendingResolutionCount = 0
    func clearPendingResolution() { clearPendingResolutionCount += 1 }
    var usesServerMouseMode = false
    var requestedMouseModes: [Bool] = []
    func requestRelativeMouseMode(_ enabled: Bool) { requestedMouseModes.append(enabled) }

    func startWorker() throws {}

    func connect(profile: ConnectionProfile) throws {
        receivedExpectedCredentials = profile.ticket.value == "synthetic-private-ticket" &&
            profile.host == "pvespiceproxy:synthetic-private-destination" &&
            profile.proxyURL?.password == "synthetic-private-proxy"
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
