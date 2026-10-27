import XCTest
@testable import MacRemoteViewerCore

final class HotKeyParserTests: XCTestCase {
    func testParsesSampleHotkeys() throws {
        let fullscreen = try HotKeyParser.parse("Shift+F11")
        XCTAssertEqual(fullscreen, HotKeyChord(shift: true, symbol: .function(11)))

        let release = try HotKeyParser.parse("Ctrl+Alt+R")
        XCTAssertEqual(release.control, true)
        XCTAssertEqual(release.option, true)
        XCTAssertEqual(release.symbol, .character("R"))

        let attention = try HotKeyParser.parse("Ctrl+Alt+Ins")
        XCTAssertEqual(attention.symbol, .insert)
    }

    func testSecureAttentionIsNotTheOriginalChord() throws {
        let attention = try HotKeyParser.parse("Ctrl+Alt+Ins")
        XCTAssertNotEqual(attention.symbol, .delete)
    }
}
