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

/// 設定頁與持久化用的滾動靈敏度倍率。
/// 數值必須與 `ScrollWheelMapping` 的常數相同；兩邊不能互相 import，否則 Xcode batch compile 會 cycle。
public enum ScrollSensitivity: Sendable {
    public static let `default`: Double = 1
    public static let minimum: Double = 0.05
    public static let maximum: Double = 4
    public static let step: Double = 0.05

    public static func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return `default` }
        return min(max(value, minimum), maximum)
    }
}

/// 可持久化的使用者偏好。
public struct AppPreferences: Equatable, Sendable, Codable {
    public var scrollWheelDirection: ScrollWheelDirection
    /// 傳統滑鼠滾輪（line-based）倍率，1 為目前預設。
    public var mouseWheelSensitivity: Double {
        didSet { mouseWheelSensitivity = ScrollSensitivity.clamp(mouseWheelSensitivity) }
    }
    /// 觸控板雙指（pixel-based）倍率，1 為目前預設。
    public var trackpadScrollSensitivity: Double {
        didSet { trackpadScrollSensitivity = ScrollSensitivity.clamp(trackpadScrollSensitivity) }
    }
    public var language: AppLanguage
    /// 成功連線後是否刪除匯入的 `.vv`。
    public var deleteVVFileAfterConnect: Bool
    /// 是否依目前視窗邏輯尺寸調整 guest 解析度。
    public var matchGuestResolutionToWindow: Bool
    public var useNativeDisplayPixels: Bool
    public var manualResolutionWidth: Int?
    public var manualResolutionHeight: Int?
    public var loggingEnabled: Bool
    /// 滑鼠側鍵 4（通常是後方鍵）送到 guest 的動作。
    public var sideButton4: MouseSideButtonAction
    /// 滑鼠側鍵 5（通常是前方鍵）送到 guest 的動作。
    public var sideButton5: MouseSideButtonAction

    public init(
        scrollWheelDirection: ScrollWheelDirection = .natural,
        mouseWheelSensitivity: Double = ScrollSensitivity.default,
        trackpadScrollSensitivity: Double = ScrollSensitivity.default,
        language: AppLanguage = .zhHant,
        deleteVVFileAfterConnect: Bool = true,
        matchGuestResolutionToWindow: Bool = true,
        useNativeDisplayPixels: Bool = false,
        manualResolutionWidth: Int? = nil,
        manualResolutionHeight: Int? = nil,
        loggingEnabled: Bool = true,
        sideButton4: MouseSideButtonAction = .previousPage,
        sideButton5: MouseSideButtonAction = .nextPage
    ) {
        self.scrollWheelDirection = scrollWheelDirection
        self.mouseWheelSensitivity = ScrollSensitivity.clamp(mouseWheelSensitivity)
        self.trackpadScrollSensitivity = ScrollSensitivity.clamp(trackpadScrollSensitivity)
        self.language = language
        self.deleteVVFileAfterConnect = deleteVVFileAfterConnect
        self.matchGuestResolutionToWindow = matchGuestResolutionToWindow
        self.useNativeDisplayPixels = useNativeDisplayPixels
        self.manualResolutionWidth = manualResolutionWidth
        self.manualResolutionHeight = manualResolutionHeight
        self.loggingEnabled = loggingEnabled
        self.sideButton4 = sideButton4
        self.sideButton5 = sideButton5
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppPreferences()
        scrollWheelDirection = try container.decodeIfPresent(
            ScrollWheelDirection.self,
            forKey: .scrollWheelDirection
        ) ?? fallback.scrollWheelDirection
        mouseWheelSensitivity = ScrollSensitivity.clamp(
            try container.decodeIfPresent(Double.self, forKey: .mouseWheelSensitivity)
                ?? fallback.mouseWheelSensitivity
        )
        trackpadScrollSensitivity = ScrollSensitivity.clamp(
            try container.decodeIfPresent(Double.self, forKey: .trackpadScrollSensitivity)
                ?? fallback.trackpadScrollSensitivity
        )
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? fallback.language
        deleteVVFileAfterConnect = try container.decodeIfPresent(
            Bool.self,
            forKey: .deleteVVFileAfterConnect
        ) ?? fallback.deleteVVFileAfterConnect
        matchGuestResolutionToWindow = try container.decodeIfPresent(
            Bool.self,
            forKey: .matchGuestResolutionToWindow
        ) ?? fallback.matchGuestResolutionToWindow
        useNativeDisplayPixels = try container.decodeIfPresent(Bool.self, forKey: .useNativeDisplayPixels) ?? fallback.useNativeDisplayPixels
        manualResolutionWidth = try container.decodeIfPresent(Int.self, forKey: .manualResolutionWidth)
        manualResolutionHeight = try container.decodeIfPresent(Int.self, forKey: .manualResolutionHeight)
        loggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .loggingEnabled) ?? fallback.loggingEnabled
        sideButton4 = try container.decodeIfPresent(
            MouseSideButtonAction.self,
            forKey: .sideButton4
        ) ?? fallback.sideButton4
        sideButton5 = try container.decodeIfPresent(
            MouseSideButtonAction.self,
            forKey: .sideButton5
        ) ?? fallback.sideButton5
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
