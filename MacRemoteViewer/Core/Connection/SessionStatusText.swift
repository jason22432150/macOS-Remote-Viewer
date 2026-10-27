import Foundation

/// Status bar 顯示用字串。View 只負責排版，不自行判斷要顯示哪一個位址。
public enum SessionStatusText {
    /// 有可顯示位址時回傳「遠端 IP：…」；票證或尚未載入則不顯示。
    public static func remoteIP(from profile: ConnectionProfile?, language: AppLanguage) -> String? {
        guard let address = displayAddress(from: profile) else { return nil }
        return interpolate(L10n.string(.statusRemoteIP, language: language), value: address)
    }

    /// 抽出可顯示的 IP／主機名。UI 請用 `remoteIP(from:language:)`，以免漏掉語系與票證過濾。
    /// PVE 的 `host` 常是 spice 票證（`pvespiceproxy:…`），真正連到的是 `proxy` 的 IP／主機名。
    public static func displayAddress(from profile: ConnectionProfile?) -> String? {
        guard let profile else { return nil }
        if let host = displayableHost(profile.host) {
            return host
        }
        return displayableHost(profile.proxyURL?.host)
    }

    /// 只接受一般 hostname／IP；拒絕 spice 票證與帶 scheme 的 URI，避免把簽名畫到 UI。
    private static func displayableHost(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if looksLikeSpiceTicket(trimmed) { return nil }
        if trimmed.contains("://") { return nil }
        return trimmed
    }

    private static func looksLikeSpiceTicket(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower.hasPrefix("pvespiceproxy:") || lower.hasPrefix("spiceproxy:")
    }

    /// host 來自 .vv，不可當 `String(format:)` 參數，以免 `%` 被當成 format specifier。
    private static func interpolate(_ template: String, value: String) -> String {
        guard let placeholder = template.range(of: "%@") else {
            assertionFailure("L10n 模板缺少 %@：\(template)")
            return template
        }
        return template.replacingCharacters(in: placeholder, with: value)
    }
}
