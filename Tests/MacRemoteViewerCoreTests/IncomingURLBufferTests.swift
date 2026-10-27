import XCTest
@testable import MacRemoteViewerCore

@MainActor
final class IncomingURLBufferTests: XCTestCase {
    func testBuffersURLsUntilHandlerIsReady() {
        let buffer = IncomingURLBuffer()
        let first = URL(fileURLWithPath: "/tmp/one.vv")
        let second = URL(fileURLWithPath: "/tmp/two.vv")
        var received: [[URL]] = []

        buffer.handle([first])
        buffer.setHandler { urls in
            received.append(urls)
        }
        buffer.handle([second])

        XCTAssertEqual(received, [[first], [second]])
    }

    func testConcatenatesPendingURLsBeforeHandlerIsReady() {
        let buffer = IncomingURLBuffer()
        let first = URL(fileURLWithPath: "/tmp/one.vv")
        let second = URL(fileURLWithPath: "/tmp/two.vv")
        var received: [URL] = []

        buffer.handle([first])
        buffer.handle([second])
        buffer.setHandler { urls in
            received.append(contentsOf: urls)
        }

        XCTAssertEqual(received, [first, second])
    }

    func testIgnoresEmptyURLList() {
        let buffer = IncomingURLBuffer()
        var received: [[URL]] = []
        buffer.setHandler { urls in
            received.append(urls)
        }

        buffer.handle([])

        XCTAssertTrue(received.isEmpty)
    }
}
