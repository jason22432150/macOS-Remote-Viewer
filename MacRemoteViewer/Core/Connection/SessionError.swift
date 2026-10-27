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
    case clipboardUnsupported
    case clipboardTooLarge(maxBytes: Int)
    case clipboardTimeout
    case disconnected
    case unknown(code: String)

    /// 給使用者看的說明；刻意不帶入主機、票證或檔案內容。
    public var userMessage: String {
        switch self {
        case .fileTooLarge:
            return "連線檔太大，已拒絕解析。"
        case .invalidEncoding:
            return "連線檔不是有效的 UTF-8 文字。"
        case .missingSection:
            return "連線檔缺少 [virt-viewer] 區段。"
        case .unsupportedType:
            return "第一版只支援 type=spice 的連線檔。"
        case .missingField(let name):
            return "連線檔缺少必要欄位：\(Self.safeFieldName(name))。"
        case .duplicateField(let name):
            return "連線檔含有重複的必要欄位：\(Self.safeFieldName(name))。"
        case .invalidPort:
            return "tls-port 必須是 1 到 65535 的整數。"
        case .plaintextPortNotAllowed:
            return "此連線檔沒有 tls-port。第一版不會改走明文 port。"
        case .invalidProxy:
            return "proxy 必須是 http 或 https 的 CONNECT 位址。"
        case .invalidBoolean:
            return "布林欄位只接受 0 或 1。"
        case .invalidCA:
            return "ca 憑證資料格式無效。"
        case .invalidHotKey:
            return "快捷鍵格式無法辨識。"
        case .sourceFileUnavailable:
            return "無法讀取連線檔。"
        case .engineUnavailable:
            return "SPICE 引擎尚未連結。Parser 與 UI 可用，但還不能連到 PVE；需要 UTM 相容的 spice-gtk／GStreamer 靜態依賴。"
        case .cancelled:
            return "連線已取消。"
        case .network:
            return "無法經由 proxy 或網路連到遠端。"
        case .tls:
            return "TLS 驗證失敗。請確認憑證與 host-subject 來自新下載的連線檔。"
        case .authenticationRejected:
            return "票證已失效或被拒絕。請重新從 PVE 下載連線檔；本 App 不會自動更新票證。"
        case .guestAgentUnavailable:
            return "Guest agent 不可用，畫面與輸入仍可使用，但剪貼簿已停用。"
        case .clipboardUnsupported:
            return "遠端不支援文字剪貼簿。"
        case .clipboardTooLarge:
            return "文字超過 1 MiB 上限，已拒絕傳送且不會截斷。"
        case .clipboardTimeout:
            return "剪貼簿請求逾時。"
        case .disconnected:
            return "遠端連線已中斷。"
        case .unknown:
            return "連線失敗。"
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
