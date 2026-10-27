import Foundation

/// 介面語言。名稱以該語言慣用寫法顯示，不隨目前 UI 語系翻譯。
public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case zhHant = "zh-Hant"
    case english = "en"

    public var id: String { rawValue }

    public var nativeName: String {
        switch self {
        case .zhHant: return "繁體中文"
        case .english: return "English"
        }
    }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }
}

/// 滑鼠滾輪要沿用 macOS 方向，或改為反向。
public enum ScrollWheelDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case natural
    case reversed

    public var id: String { rawValue }
}

/// 可持久化的使用者偏好。
public struct AppPreferences: Equatable, Sendable, Codable {
    public var scrollWheelDirection: ScrollWheelDirection
    public var language: AppLanguage
    /// 成功連線後是否刪除匯入的 `.vv`。
    public var deleteVVFileAfterConnect: Bool
    /// 是否依目前視窗邏輯尺寸調整 guest 解析度。
    public var matchGuestResolutionToWindow: Bool
    public var manualResolutionWidth: Int?
    public var manualResolutionHeight: Int?
    public var loggingEnabled: Bool

    public init(
        scrollWheelDirection: ScrollWheelDirection = .natural,
        language: AppLanguage = .zhHant,
        deleteVVFileAfterConnect: Bool = true,
        matchGuestResolutionToWindow: Bool = true,
        manualResolutionWidth: Int? = nil,
        manualResolutionHeight: Int? = nil,
        loggingEnabled: Bool = true
    ) {
        self.scrollWheelDirection = scrollWheelDirection
        self.language = language
        self.deleteVVFileAfterConnect = deleteVVFileAfterConnect
        self.matchGuestResolutionToWindow = matchGuestResolutionToWindow
        self.manualResolutionWidth = manualResolutionWidth
        self.manualResolutionHeight = manualResolutionHeight
        self.loggingEnabled = loggingEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppPreferences()
        scrollWheelDirection = try container.decodeIfPresent(
            ScrollWheelDirection.self,
            forKey: .scrollWheelDirection
        ) ?? fallback.scrollWheelDirection
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? fallback.language
        deleteVVFileAfterConnect = try container.decodeIfPresent(
            Bool.self,
            forKey: .deleteVVFileAfterConnect
        ) ?? fallback.deleteVVFileAfterConnect
        matchGuestResolutionToWindow = try container.decodeIfPresent(
            Bool.self,
            forKey: .matchGuestResolutionToWindow
        ) ?? fallback.matchGuestResolutionToWindow
        manualResolutionWidth = try container.decodeIfPresent(Int.self, forKey: .manualResolutionWidth)
        manualResolutionHeight = try container.decodeIfPresent(Int.self, forKey: .manualResolutionHeight)
        loggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .loggingEnabled) ?? fallback.loggingEnabled
    }

    public var invertScrollWheel: Bool {
        scrollWheelDirection == .reversed
    }

    public var manualFrame: RemoteFrame? {
        guard let manualResolutionWidth, let manualResolutionHeight else { return nil }
        return RemoteFrame(width: manualResolutionWidth, height: manualResolutionHeight)
    }

    public var resolutionPreference: GuestResolutionPreference {
        if matchGuestResolutionToWindow {
            return .matchWindow
        }
        if let manualFrame {
            return .preset(manualFrame)
        }
        return .keepGuest
    }

    public mutating func selectResolutionPreset(_ preset: RemoteResolutionPreset) {
        matchGuestResolutionToWindow = false
        manualResolutionWidth = preset.width
        manualResolutionHeight = preset.height
    }

    public mutating func resetResolutionToMatchWindow() {
        matchGuestResolutionToWindow = true
        manualResolutionWidth = nil
        manualResolutionHeight = nil
    }

    public func isSelectedPreset(_ preset: RemoteResolutionPreset) -> Bool {
        !matchGuestResolutionToWindow
            && manualResolutionWidth == preset.width
            && manualResolutionHeight == preset.height
    }
}

public protocol PreferencesStoring: Sendable {
    func load() -> AppPreferences
    func save(_ preferences: AppPreferences) throws
}

/// 以 UserDefaults 儲存整包偏好，避免多個 key 寫入不一致。
/// `UserDefaults` 本身執行緒安全；實際讀寫由 `@MainActor` 的 `AppSettings` 呼叫。
public struct UserDefaultsPreferencesStore: PreferencesStoring, @unchecked Sendable {
    public static let defaultKey = "MacRemoteViewer.preferences.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsPreferencesStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppPreferences {
        guard let data = defaults.data(forKey: key) else {
            return AppPreferences()
        }
        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data)
        } catch {
            return AppPreferences()
        }
    }

    public func save(_ preferences: AppPreferences) throws {
        let data = try JSONEncoder().encode(preferences)
        defaults.set(data, forKey: key)
    }
}
