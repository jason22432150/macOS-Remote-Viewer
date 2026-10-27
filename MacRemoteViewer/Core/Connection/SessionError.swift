import Foundation

/// 可顯示的錯誤分類。訊息不得包含票證、原始 `.vv` 或剪貼簿內容。
public enum SessionError: Error, Equatable, Sendable {
    case fileTooLarge(maxBytes: Int)
    case invalidEncoding
    case missingSection
    case unsupportedType(String)
    case missingField(String)
    case duplicateField(String)
    case invalidPort(String)
    case plaintextPortNotAllowed
    case invalidProxy
    case invalidBoolean(String)
    case invalidCA
    case invalidHotKey(String)
    case sourceFileUnavailable
    case engineUnavailable
    case cancelled
    case network
    case tls
    case authenticationRejected
    case guestAgentUnavailable
    case disconnected
    case unknown(code: String)

    /// 給使用者看的說明；刻意不帶入主機、票證或檔案內容。
    public var userMessage: String {
        userMessage(language: .zhHant)
    }

    public func userMessage(language: AppLanguage) -> String {
        switch self {
        case .fileTooLarge:
            return L10n.string(.errorFileTooLarge, language: language)
        case .invalidEncoding:
            return L10n.string(.errorInvalidEncoding, language: language)
        case .missingSection:
            return L10n.string(.errorMissingSection, language: language)
        case .unsupportedType:
            return L10n.string(.errorUnsupportedType, language: language)
        case .missingField(let name):
            return L10n.string(.errorMissingField, language: language, Self.safeFieldName(name))
        case .duplicateField(let name):
            return L10n.string(.errorDuplicateField, language: language, Self.safeFieldName(name))
        case .invalidPort:
            return L10n.string(.errorInvalidPort, language: language)
        case .plaintextPortNotAllowed:
            return L10n.string(.errorPlaintextPort, language: language)
        case .invalidProxy:
            return L10n.string(.errorInvalidProxy, language: language)
        case .invalidBoolean:
            return L10n.string(.errorInvalidBoolean, language: language)
        case .invalidCA:
            return L10n.string(.errorInvalidCA, language: language)
        case .invalidHotKey:
            return L10n.string(.errorInvalidHotKey, language: language)
        case .sourceFileUnavailable:
            return L10n.string(.errorSourceFileUnavailable, language: language)
        case .engineUnavailable:
            return L10n.string(.errorEngineUnavailable, language: language)
        case .cancelled:
            return L10n.string(.errorCancelled, language: language)
        case .network:
            return L10n.string(.errorNetwork, language: language)
        case .tls:
            return L10n.string(.errorTLS, language: language)
        case .authenticationRejected:
            return L10n.string(.errorAuthenticationRejected, language: language)
        case .guestAgentUnavailable:
            return L10n.string(.errorGuestAgentUnavailable, language: language)
        case .disconnected:
            return L10n.string(.errorDisconnected, language: language)
        case .unknown:
            return L10n.string(.errorUnknown, language: language)
        }
    }

    public var isRetryableWithNewFile: Bool {
        switch self {
        case .authenticationRejected, .tls, .network:
            return true
        default:
            return false
        }
    }

    /// 只允許已知欄位名稱進入 UI，避免把任意檔案內容當欄位名顯示。
    private static func safeFieldName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(filtered)
        return result.isEmpty ? "unknown" : String(result.prefix(64))
    }
}
