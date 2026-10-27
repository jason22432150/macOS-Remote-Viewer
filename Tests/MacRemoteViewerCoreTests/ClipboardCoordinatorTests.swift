import XCTest
@testable import MacRemoteViewerCore

@MainActor
final class ClipboardCoordinatorTests: XCTestCase {
    func testManualSendRespectsSizeLimit() async {
        let pasteboard = MockPasteboard()
        pasteboard.text = String(repeating: "a", count: ClipboardCoordinator.maxUTF8Bytes + 1)
        let transport = MockClipboardTransport()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard, transport: transport)
        await coordinator.sendLocalTextManually()
        XCTAssertEqual(coordinator.lastError, .clipboardTooLarge(maxBytes: ClipboardCoordinator.maxUTF8Bytes))
        XCTAssertEqual(transport.sent.count, 0)
    }

    func testManualSendEmptyAndUnicode() async {
        let pasteboard = MockPasteboard()
        let transport = MockClipboardTransport()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard, transport: transport)
        pasteboard.text = ""
        await coordinator.sendLocalTextManually()
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(transport.sent.last, Data())

        pasteboard.text = "中文 emoji 😀\nline2"
        await coordinator.sendLocalTextManually()
        XCTAssertEqual(String(data: transport.sent.last ?? Data(), encoding: .utf8), "中文 emoji 😀\nline2")
    }

    func testRejectsNonTextPayload() async {
        let pasteboard = MockPasteboard()
        pasteboard.text = "hello"
        pasteboard.hasNonText = true
        let transport = MockClipboardTransport()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard, transport: transport)
        await coordinator.sendLocalTextManually()
        XCTAssertEqual(coordinator.lastError, .unknown(code: "clipboard-non-text"))
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testStaleGenerationDoesNotOverwritePasteboard() {
        let pasteboard = MockPasteboard()
        let transport = MockClipboardTransport()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard, transport: transport)
        coordinator.invalidateGeneration()
        coordinator.handleRemoteText(Data("old".utf8), generation: 1)
        XCTAssertNil(pasteboard.text)
    }

    func testAutomaticLoopIsDedupedByFingerprint() async {
        let pasteboard = MockPasteboard()
        pasteboard.text = "same"
        let transport = MockClipboardTransport()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard, transport: transport, mode: .automatic)
        coordinator.isWindowActive = true
        await coordinator.sendLocalTextManually()
        coordinator.handleRemoteText(Data("same".utf8), generation: 1)
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testInactiveWindowSkipsAutomaticSync() async {
        let pasteboard = MockPasteboard()
        pasteboard.text = "secret-to-other-window"
        pasteboard.changeCountValue = 9
        let transport = MockClipboardTransport()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard, transport: transport, mode: .automatic)
        coordinator.isWindowActive = false
        await coordinator.handleLocalPasteboardChangeIfNeeded()
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testTimeoutMapsToClipboardTimeout() async {
        let pasteboard = MockPasteboard()
        pasteboard.text = "hello"
        let transport = MockClipboardTransport()
        transport.delay = .milliseconds(80)
        let coordinator = ClipboardCoordinator(
            pasteboard: pasteboard,
            transport: transport,
            requestTimeout: .milliseconds(20)
        )
        await coordinator.sendLocalTextManually()
        XCTAssertEqual(coordinator.lastError, .clipboardTimeout)
    }

    func testMissingAgentSurfacesCapabilityError() async {
        let pasteboard = MockPasteboard()
        pasteboard.text = "hello"
        let transport = MockClipboardTransport()
        transport.hasAgent = false
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard, transport: transport)
        await coordinator.sendLocalTextManually()
        XCTAssertEqual(coordinator.lastError, .guestAgentUnavailable)
    }
}

private final class MockPasteboard: PasteboardAccessing {
    var changeCountValue = 0
    var text: String?
    var hasNonText = false
    var writeCount = 0

    var changeCount: Int { changeCountValue }

    func readPlainText() -> String? { text }

    func writePlainText(_ text: String) {
        writeCount += 1
        self.text = text
        changeCountValue += 1
    }

    func containsNonTextPayload() -> Bool { hasNonText }
}

private final class MockClipboardTransport: SpiceClipboardTransporting {
    var hasAgent = true
    var supportsClipboard = true
    var sent: [Data] = []
    var delay: Duration?
    var remoteData = Data()

    func sendPlainText(_ utf8: Data, generation: UInt64) async throws {
        if let delay {
            try await Task.sleep(for: delay)
        }
        sent.append(utf8)
    }

    func requestPlainText(generation: UInt64) async throws -> Data {
        if let delay {
            try await Task.sleep(for: delay)
        }
        return remoteData
    }
}
