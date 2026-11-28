import XCTest
@testable import MacRemoteViewerCore

final class L10nTests: XCTestCase {
    func testEveryKeyHasBothTranslations() {
        for key in L10nKey.allCases {
            XCTAssertTrue(L10n.hasTranslation(key, language: .zhHant), "缺少繁中翻譯：\(key.rawValue)")
            XCTAssertTrue(L10n.hasTranslation(key, language: .english), "缺少英文翻譯：\(key.rawValue)")
        }
    }

    func testLanguagesReturnDifferentCopyForUserFacingSettings() {
        XCTAssertNotEqual(
            L10n.string(.deleteVVAfterConnect, language: .zhHant),
            L10n.string(.deleteVVAfterConnect, language: .english)
        )
        XCTAssertNotEqual(
            L10n.string(.scrollReversed, language: .zhHant),
            L10n.string(.scrollReversed, language: .english)
        )
        XCTAssertNotEqual(
            L10n.string(.mouseWheelSensitivity, language: .zhHant),
            L10n.string(.mouseWheelSensitivity, language: .english)
        )
        XCTAssertNotEqual(
            L10n.string(.trackpadScrollSensitivity, language: .zhHant),
            L10n.string(.trackpadScrollSensitivity, language: .english)
        )
        XCTAssertNotEqual(
            L10n.string(.sideButton4, language: .zhHant),
            L10n.string(.sideButton4, language: .english)
        )
        XCTAssertEqual(L10n.string(.sideButtonPreviousPage, language: .zhHant), "上頁")
        XCTAssertEqual(L10n.string(.sideButtonNextPage, language: .zhHant), "下一頁")
        XCTAssertEqual(L10n.string(.guestDidNotApplyResolution, language: .zhHant), "遠端未套用解析度")
        XCTAssertNotEqual(
            L10n.string(.guestDidNotApplyResolution, language: .zhHant),
            L10n.string(.guestDidNotApplyResolution, language: .english)
        )
    }

    func testFormatInsertsSafeFieldName() {
        let chinese = L10n.string(.errorMissingField, language: .zhHant, "host")
        let english = L10n.string(.errorMissingField, language: .english, "host")
        XCTAssertTrue(chinese.contains("host"))
        XCTAssertTrue(english.contains("host"))
        XCTAssertNotEqual(chinese, english)
    }

    func testRemoteIPFormatIncludesHost() {
        // 只驗證 L10n 模板；host 為控制過的字面值。正式顯示請走 SessionStatusText.remoteIP。
        let host = "192.0.2.10"
        let chinese = L10n.string(.statusRemoteIP, language: .zhHant, host)
        let english = L10n.string(.statusRemoteIP, language: .english, host)
        XCTAssertEqual(chinese, "遠端 IP：192.0.2.10")
        XCTAssertEqual(english, "Remote IP: 192.0.2.10")
    }

    func testFreshConnectionIsOfferedOnlyForTerminalRecoveryStates() {
        for state: SessionState in [.disconnected, .failed(.authenticationRejected),
                                   .failed(.network), .failed(.tls), .failed(.displayTimeout)] {
            XCTAssertTrue(state.canOpenFreshConnectionFile)
        }
        for state: SessionState in [.idle, .parsing, .connecting, .connected, .disconnecting,
                                   .failed(.invalidCA), .failed(.cancelled), .failed(.engineUnavailable)] {
            XCTAssertFalse(state.canOpenFreshConnectionFile)
        }
        for language: AppLanguage in [.zhHant, .english] {
            XCTAssertTrue(L10n.string(.freshConnectionHint, language: language).contains(".vv"))
            XCTAssertTrue(L10n.string(.chooseRecoveryVVMessage, language: language).contains(".vv"))
        }
    }

    func testSessionErrorUsesSelectedLanguage() {
        XCTAssertEqual(
            SessionError.disconnected.userMessage(language: .zhHant),
            L10n.string(.errorDisconnected, language: .zhHant)
        )
        XCTAssertEqual(
            SessionError.disconnected.userMessage(language: .english),
            L10n.string(.errorDisconnected, language: .english)
        )
    }
}
