import Foundation
import Observation
import OSLog

/// 設定頁與連線流程共用的偏好狀態，變更會立刻寫入 UserDefaults。
@MainActor
@Observable
public final class AppSettings {
    public var preferences: AppPreferences {
        didSet {
            let resolutionChanged = oldValue.resolutionPreference != preferences.resolutionPreference
            persist()
            if resolutionChanged {
                onChange?()
            }
        }
    }

    public let fileLog: FileLogSink
    private let store: any PreferencesStoring
    private let logger = Logger(subsystem: "local.MacRemoteViewer", category: "settings")
    public var onChange: (@MainActor () -> Void)?

    public init(
        store: any PreferencesStoring = UserDefaultsPreferencesStore(),
        fileLog: FileLogSink? = nil
    ) {
        let loaded = store.load()
        self.store = store
        self.preferences = loaded
        self.fileLog = fileLog ?? FileLogSink(
            enabled: loaded.loggingEnabled,
            writer: AsyncFileLogWriter()
        )
        // 注入的 sink 也要跟已持久化的偏好對齊。
        self.fileLog.isEnabled = loaded.loggingEnabled
    }

    public var language: AppLanguage { preferences.language }

    public func selectResolutionPreset(_ preset: RemoteResolutionPreset) {
        preferences.selectResolutionPreset(preset)
    }

    public func resetResolutionToMatchWindow() {
        preferences.resetResolutionToMatchWindow()
    }

    public func isSelectedPreset(_ preset: RemoteResolutionPreset) -> Bool {
        preferences.isSelectedPreset(preset)
    }

    private func persist() {
        fileLog.isEnabled = preferences.loggingEnabled
        do {
            try store.save(preferences)
        } catch {
            logger.error("preferences-save-failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
