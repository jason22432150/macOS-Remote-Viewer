import XCTest
@testable import MacRemoteViewerCore

final class AppPreferencesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: UserDefaultsPreferencesStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MacRemoteViewer.preferences.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        store = UserDefaultsPreferencesStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testHorizontalScrollCompatibilityPersistsAndDefaultsOff() throws {
        XCTAssertFalse(store.load().horizontalScrollCompatibility)
        var preferences = AppPreferences()
        preferences.horizontalScrollCompatibility = true
        try store.save(preferences)
        XCTAssertTrue(store.load().horizontalScrollCompatibility)
        let legacy = try JSONSerialization.data(withJSONObject: ["language": "en"])
        defaults.set(legacy, forKey: UserDefaultsPreferencesStore.defaultKey)
        XCTAssertFalse(store.load().horizontalScrollCompatibility)
    }

    func testLoadReturnsDefaultsWhenEmpty() {
        let preferences = store.load()
        XCTAssertEqual(preferences.scrollWheelDirection, .natural)
        XCTAssertEqual(preferences.mouseWheelSensitivity, ScrollSensitivity.default)
        XCTAssertEqual(preferences.trackpadScrollSensitivity, ScrollSensitivity.default)
        XCTAssertEqual(preferences.language, .zhHant)
        XCTAssertTrue(preferences.deleteVVFileAfterConnect)
        XCTAssertTrue(preferences.matchGuestResolutionToWindow)
        XCTAssertFalse(preferences.useNativeDisplayPixels)
        XCTAssertNil(preferences.manualFrame)
        XCTAssertTrue(preferences.loggingEnabled)
        XCTAssertEqual(preferences.resolutionPreference, .matchWindow)
        XCTAssertEqual(preferences.sideButton4, .previousPage)
        XCTAssertEqual(preferences.sideButton5, .nextPage)
    }

    func testSaveAndLoadRoundTrip() throws {
        var preferences = AppPreferences()
        preferences.scrollWheelDirection = .reversed
        preferences.mouseWheelSensitivity = 2
        preferences.trackpadScrollSensitivity = 0.5
        preferences.language = .english
        preferences.deleteVVFileAfterConnect = false
        preferences.loggingEnabled = false
        preferences.useNativeDisplayPixels = true
        preferences.sideButton4 = .nextPage
        preferences.sideButton5 = .none
        preferences.selectResolutionPreset(RemoteResolutionPreset(width: 1920, height: 1080))
        try store.save(preferences)

        let loaded = store.load()
        XCTAssertEqual(loaded, preferences)
        XCTAssertEqual(
            loaded.resolutionPreference,
            .preset(RemoteFrame(width: 1920, height: 1080))
        )
        XCTAssertTrue(loaded.isSelectedPreset(RemoteResolutionPreset(width: 1920, height: 1080)))
        XCTAssertTrue(loaded.invertScrollWheel)
    }

    func testResetResolutionRestoresWindowMatching() {
        var preferences = AppPreferences()
        preferences.selectResolutionPreset(RemoteResolutionPreset(width: 1280, height: 720))
        preferences.resetResolutionToMatchWindow()
        XCTAssertTrue(preferences.matchGuestResolutionToWindow)
        XCTAssertNil(preferences.manualFrame)
        XCTAssertEqual(preferences.resolutionPreference, .matchWindow)
    }

    func testPartialJSONUsesDefaultsForMissingKeys() throws {
        let data = try JSONSerialization.data(withJSONObject: ["language": "en"])
        defaults.set(data, forKey: UserDefaultsPreferencesStore.defaultKey)
        let loaded = store.load()
        XCTAssertEqual(loaded.language, .english)
        XCTAssertEqual(loaded.scrollWheelDirection, .natural)
        XCTAssertEqual(loaded.mouseWheelSensitivity, ScrollSensitivity.default)
        XCTAssertEqual(loaded.trackpadScrollSensitivity, ScrollSensitivity.default)
        XCTAssertTrue(loaded.deleteVVFileAfterConnect)
        XCTAssertTrue(loaded.matchGuestResolutionToWindow)
        XCTAssertFalse(loaded.useNativeDisplayPixels)
        XCTAssertTrue(loaded.loggingEnabled)
        XCTAssertEqual(loaded.sideButton4, .previousPage)
        XCTAssertEqual(loaded.sideButton5, .nextPage)
    }

    func testAssigningOutOfRangeScrollSensitivityClampsInPlace() {
        var preferences = AppPreferences()
        preferences.mouseWheelSensitivity = 100
        preferences.trackpadScrollSensitivity = -1
        XCTAssertEqual(preferences.mouseWheelSensitivity, ScrollSensitivity.maximum)
        XCTAssertEqual(preferences.trackpadScrollSensitivity, ScrollSensitivity.minimum)
    }

    func testOutOfRangeScrollSensitivityIsClampedOnLoad() throws {
        let payload: [String: Any] = [
            "mouseWheelSensitivity": 100,
            "trackpadScrollSensitivity": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        defaults.set(data, forKey: UserDefaultsPreferencesStore.defaultKey)
        let loaded = store.load()
        XCTAssertEqual(loaded.mouseWheelSensitivity, ScrollSensitivity.maximum)
        XCTAssertEqual(loaded.trackpadScrollSensitivity, ScrollSensitivity.minimum)
    }

    func testCorruptJSONFallsBackToDefaults() {
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsPreferencesStore.defaultKey)
        let loaded = store.load()
        XCTAssertEqual(loaded, AppPreferences())
    }

    @MainActor
    func testAppSettingsPersistsMutations() throws {
        let settings = AppSettings(store: store, fileLog: FileLogSink(enabled: true, writer: MemoryFileLogWriter()))
        settings.preferences.language = .english
        XCTAssertEqual(store.load().language, .english)
        settings.preferences.mouseWheelSensitivity = 1.5
        settings.preferences.trackpadScrollSensitivity = 0.75
        settings.preferences.sideButton4 = .none
        settings.preferences.sideButton5 = .previousPage
        XCTAssertEqual(store.load().mouseWheelSensitivity, 1.5)
        XCTAssertEqual(store.load().trackpadScrollSensitivity, 0.75)
        XCTAssertEqual(store.load().sideButton4, .none)
        XCTAssertEqual(store.load().sideButton5, .previousPage)
        settings.selectResolutionPreset(RemoteResolutionPreset(width: 1600, height: 900))
        XCTAssertFalse(store.load().matchGuestResolutionToWindow)
        XCTAssertEqual(store.load().manualResolutionWidth, 1600)
        settings.resetResolutionToMatchWindow()
        XCTAssertTrue(store.load().matchGuestResolutionToWindow)
        XCTAssertNil(store.load().manualFrame)
    }

    @MainActor
    func testLoggingToggleUpdatesFileLogSink() {
        let sink = FileLogSink(enabled: true, writer: MemoryFileLogWriter())
        let settings = AppSettings(store: store, fileLog: sink)
        settings.preferences.loggingEnabled = false
        XCTAssertFalse(sink.isEnabled)
        settings.preferences.loggingEnabled = true
        XCTAssertTrue(sink.isEnabled)
    }
}
