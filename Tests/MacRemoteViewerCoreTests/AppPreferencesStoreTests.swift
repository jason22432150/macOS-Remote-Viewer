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

    func testLoadReturnsDefaultsWhenEmpty() {
        let preferences = store.load()
        XCTAssertEqual(preferences.scrollWheelDirection, .natural)
        XCTAssertEqual(preferences.language, .zhHant)
        XCTAssertTrue(preferences.deleteVVFileAfterConnect)
        XCTAssertTrue(preferences.matchGuestResolutionToWindow)
        XCTAssertNil(preferences.manualFrame)
        XCTAssertTrue(preferences.loggingEnabled)
        XCTAssertEqual(preferences.resolutionPreference, .matchWindow)
    }

    func testSaveAndLoadRoundTrip() throws {
        var preferences = AppPreferences()
        preferences.scrollWheelDirection = .reversed
        preferences.language = .english
        preferences.deleteVVFileAfterConnect = false
        preferences.loggingEnabled = false
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
        XCTAssertTrue(loaded.deleteVVFileAfterConnect)
        XCTAssertTrue(loaded.matchGuestResolutionToWindow)
        XCTAssertTrue(loaded.loggingEnabled)
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
