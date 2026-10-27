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
        let clipboard = ClipboardCoordinator(pasteboard: MockPasteboard(), transport: MockClipboardTransport())
        let controller = SessionController(
            engine: engine,
            clipboard: clipboard,
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
        let clipboard = ClipboardCoordinator(pasteboard: MockPasteboard(), transport: MockClipboardTransport())
        let controller = SessionController(engine: engine, clipboard: clipboard, files: files)
        let profile = try VVParser().parse(data: Data(Self.minimalVV().utf8), sourceIdentity: original)
        controller.open(profile)
        engine.delegate?.engineDidConnect()
        XCTAssertEqual(controller.cleanupResult, .replacedFilePreserved)
        XCTAssertTrue(files.removed.isEmpty)
    }

    func testFailedConnectionKeepsSourceFile() throws {
        let files = MockFileAccessor()
        let engine = MockEngine()
        engine.connectError = .authenticationRejected
        let clipboard = ClipboardCoordinator(pasteboard: MockPasteboard(), transport: MockClipboardTransport())
        let controller = SessionController(engine: engine, clipboard: clipboard, files: files)
        let profile = try VVParser().parse(data: Data(Self.minimalVV().utf8))
        controller.open(profile)
        XCTAssertEqual(controller.state, .failed(.authenticationRejected))
        XCTAssertTrue(files.removed.isEmpty)
    }

    func testCancelReleasesKeysAndInvalidatesClipboardGeneration() throws {
        let engine = MockEngine()
        let clipboard = ClipboardCoordinator(pasteboard: MockPasteboard(), transport: MockClipboardTransport())
        let controller = SessionController(engine: engine, clipboard: clipboard)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        controller.cancel()
        XCTAssertTrue(engine.didReleaseKeys)
        XCTAssertEqual(controller.state, .disconnected)
    }

    func testAttachRendererForwardsToEngine() throws {
        let engine = MockEngine()
        let clipboard = ClipboardCoordinator(pasteboard: MockPasteboard(), transport: MockClipboardTransport())
        let controller = SessionController(engine: engine, clipboard: clipboard)
        let renderer = NSObject()
        controller.attachRenderer(renderer)
        XCTAssertTrue(engine.attachedRenderer === renderer)
    }

    func testDisplayUpdateStoresFrameForViewport() throws {
        let engine = MockEngine()
        let clipboard = ClipboardCoordinator(pasteboard: MockPasteboard(), transport: MockClipboardTransport())
        let controller = SessionController(engine: engine, clipboard: clipboard)
        controller.open(try VVParser().parse(data: Data(Self.minimalVV().utf8)))
        engine.delegate?.engineDidConnect()
        engine.delegate?.engineDidUpdateDisplay(RemoteFrame(width: 1920, height: 1080))
        XCTAssertEqual(controller.displaySize, RemoteFrame(width: 1920, height: 1080))
    }

    private static func minimalVV() -> String {
        """
        [virt-viewer]
        type=spice
        host=pve.example.test
        proxy=http://pve.example.test:3128
        tls-port=61001
        password=example-ticket-not-secret
        ca=-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----
        host-subject=CN=pve.example.test
        delete-this-file=1
        """
    }
}

private final class MockEngine: SpiceEngineing {
    weak var delegate: SpiceEngineDelegate?
    var connectError: SessionError?
    var didReleaseKeys = false
    var attachedRenderer: AnyObject?

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
    func sendClipboard(_ data: Data, generation: UInt64) async throws {}
    func requestClipboard(generation: UInt64) async throws -> Data { Data() }
    func attachDisplayRenderer(_ renderer: AnyObject) { attachedRenderer = renderer }
    func requestResolution(_ size: CGSize) {}
}

private final class MockFileAccessor: FileAccessing, @unchecked Sendable {
    var identities: [URL: SourceFileIdentity] = [:]
    var removed: [String] = []

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

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

private final class MockPasteboard: PasteboardAccessing {
    var changeCount: Int = 0
    func readPlainText() -> String? { nil }
    func writePlainText(_ text: String) {}
    func containsNonTextPayload() -> Bool { false }
}

private final class MockClipboardTransport: SpiceClipboardTransporting {
    var hasAgent = true
    var supportsClipboard = true
    func sendPlainText(_ utf8: Data, generation: UInt64) async throws {}
    func requestPlainText(generation: UInt64) async throws -> Data { Data() }
}
