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
    }

    func testFormatInsertsSafeFieldName() {
        let chinese = L10n.string(.errorMissingField, language: .zhHant, "host")
        let english = L10n.string(.errorMissingField, language: .english, "host")
        XCTAssertTrue(chinese.contains("host"))
        XCTAssertTrue(english.contains("host"))
        XCTAssertNotEqual(chinese, english)
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
