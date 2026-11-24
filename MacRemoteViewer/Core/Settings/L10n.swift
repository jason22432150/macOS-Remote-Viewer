import Foundation

/// 介面字串鍵。兩種語言都必須提供翻譯，缺少時測試會失敗。
public enum L10nKey: String, CaseIterable, Sendable {
    case welcomeSubtitle
    case openVV
    case openVVEllipsis
    case welcomeLimitation
    case close
    case ctrlAltDel
    case fullscreen
    case connectingEllipsis
    case disconnected
    case back
    case openNewVV
    case statusIdle
    case statusParsing
    case statusConnecting
    case statusConnected
    case firstFrame
    case waitingFirstFrame
    case relativeMouseOn
    case relativeMouseOff
    case relativeMouseHelp
    case statusDisconnecting
    case statusDisconnected
    case statusFailed
    case statusRemoteIP
    case noGuestAgent
    case cannotAdjustResolution
    case guestDidNotApplyResolution
    case clipboardUnavailable
    case ignoredFields
    case menuSession
    case sendCtrlAltDel
    case releasePointer
    case chooseVVMessage
    case settingsMouse
    case settingsLanguage
    case settingsConnectionFile
    case settingsDisplay
    case settingsDiagnostics
    case scrollDirection
    case scrollNatural
    case horizontalScrollCompatibility
    case horizontalScrollCompatibilityHelp
    case scrollReversed
    case mouseWheelSensitivity
    case mouseWheelSensitivityHelp
    case trackpadScrollSensitivity
    case trackpadScrollSensitivityHelp
    case scrollSensitivitySlow
    case scrollSensitivityFast
    case sideButton4
    case sideButton5
    case sideButtonPreviousPage
    case sideButtonNextPage
    case sideButtonNone
    case sideButtonHelp
    case language
    case deleteVVAfterConnect
    case deleteVVAfterConnectHelp
    case matchResolutionToWindow
    case matchResolutionToWindowHelp
    case commonResolutions
    case nativeDisplayPixels
    case nativeDisplayPixelsHelp
    case resetResolution
    case resetResolutionHelp
    case recordLogs
    case recordLogsHelp
    case openLogFolder
    case clipboardAndResolutionHelp
    case keyboardHelp
    case errorFileTooLarge
    case errorInvalidEncoding
    case errorMissingSection
    case errorUnsupportedType
    case errorMissingField
    case errorDuplicateField
    case errorInvalidPort
    case errorPlaintextPort
    case errorInvalidProxy
    case errorInvalidBoolean
    case errorInvalidCA
    case errorInvalidHotKey
    case errorSourceFileUnavailable
    case errorEngineUnavailable
    case errorCancelled
    case errorNetwork
    case errorDisplayTimeout
    case errorTLS
    case errorAuthenticationRejected
    case errorGuestAgentUnavailable
    case errorDisconnected
    case errorUnknown
}

public enum L10n {
    public static func string(_ key: L10nKey, language: AppLanguage, _ args: CVarArg...) -> String {
        let template = lookup(key, language: language)
        guard !args.isEmpty else { return template }
        return String(format: template, locale: language.locale, arguments: args)
    }

    public static func hasTranslation(_ key: L10nKey, language: AppLanguage) -> Bool {
        tables[language]?[key] != nil
    }

    private static func lookup(_ key: L10nKey, language: AppLanguage) -> String {
        if let value = tables[language]?[key] {
            return value
        }
        return tables[.zhHant]?[key] ?? key.rawValue
    }

    private static let tables: [AppLanguage: [L10nKey: String]] = [
        .zhHant: zhHant,
        .english: english
    ]

    private static let zhHant: [L10nKey: String] = [
        .welcomeSubtitle: "雙擊或拖入 PVE 下載的 .vv 連線檔，即可開啟 SPICE 遠端畫面。",
        .openVV: "開啟 .vv",
        .openVVEllipsis: "開啟 .vv…",
        .welcomeLimitation: "第一版僅支援 SPICE + TLS。票證過期時請重新從 PVE 下載，不會自動更新。",
        .close: "關閉",
        .ctrlAltDel: "Ctrl+Alt+Del",
        .fullscreen: "全螢幕",
        .connectingEllipsis: "連線中…",
        .disconnected: "已斷線",
        .back: "返回",
        .openNewVV: "開啟新的 .vv",
        .statusIdle: "待命",
        .statusParsing: "解析連線檔",
        .statusConnecting: "連線中",
        .statusConnected: "已連線",
        .firstFrame: "首幀",
        .waitingFirstFrame: "等待首幀",
        .relativeMouseOn: "相對滑鼠",
        .relativeMouseOff: "絕對滑鼠",
        .relativeMouseHelp: "要求 SPICE Server Mouse Mode；伺服器接受後，點擊遠端畫面擷取游標。使用連線檔的釋放快捷鍵或切換視窗即可釋放。",
        .statusDisconnecting: "中斷中",
        .statusDisconnected: "已斷線",
        .statusFailed: "失敗",
        .statusRemoteIP: "遠端 IP：%@",
        .noGuestAgent: "無 guest agent",
        .cannotAdjustResolution: "無法自動調整解析度",
        .guestDidNotApplyResolution: "遠端未套用解析度",
        .clipboardUnavailable: "剪貼簿不可用",
        .ignoredFields: "忽略未支援欄位：%@",
        .menuSession: "工作階段",
        .sendCtrlAltDel: "傳送 Ctrl+Alt+Del",
        .releasePointer: "釋放滑鼠／鍵盤",
        .chooseVVMessage: "選擇 PVE 下載的 .vv 連線檔",
        .settingsMouse: "滑鼠",
        .settingsLanguage: "語言",
        .settingsConnectionFile: "連線檔",
        .settingsDisplay: "畫面",
        .settingsDiagnostics: "診斷",
        .scrollDirection: "滾輪方向",
        .scrollNatural: "與系統相同",
        .horizontalScrollCompatibility: "水平滾輪相容模式",
        .horizontalScrollCompatibilityHelp: "以 Shift＋垂直滾輪模擬主要為水平方向的手勢；預設關閉。遠端應用程式必須支援此快捷操作，並非原生水平滾輪。",
        .scrollReversed: "反向",
        .mouseWheelSensitivity: "滑鼠滾輪靈敏度",
        .mouseWheelSensitivityHelp: "調整傳統滑鼠滾輪（一格一線）送到遠端的幅度。1× 為目前預設。",
        .trackpadScrollSensitivity: "觸控板雙指靈敏度",
        .trackpadScrollSensitivityHelp: "調整觸控板雙指捲動送到遠端的幅度。Magic Mouse 的精準滾動也使用此設定。1× 為目前預設。",
        .scrollSensitivitySlow: "慢",
        .scrollSensitivityFast: "快",
        .sideButton4: "側鍵 4（後方）",
        .sideButton5: "側鍵 5（前方）",
        .sideButtonPreviousPage: "上頁",
        .sideButtonNextPage: "下一頁",
        .sideButtonNone: "無動作",
        .sideButtonHelp: "上頁／下一頁會送到遠端 Alt+←／Alt+→（瀏覽器與檔案總管的上一頁／下一頁）。可對調或停用。",
        .language: "語言",
        .deleteVVAfterConnect: "成功連線後刪除 .vv 檔案",
        .deleteVVAfterConnectHelp: "只在連線成功且 .vv 明確要求 delete-this-file 時刪除。關閉可保留所有連線檔。",
        .matchResolutionToWindow: "依目前視窗大小調整遠端解析度",
        .matchResolutionToWindowHelp: "需要 guest 的 spice-vdagent。Windows 的 QXL 驅動通常會立刻改解析度。Linux（尤其 Kali 預設 XFCE）往往只更新可用模式、桌面不套用；App 會自動重試數次，仍未套用時 status bar 會提示，畫面改為本機縮放。可在 guest 執行 xrandr --output Virtual-1 --auto，或改選常用解析度。",
        .commonResolutions: "常用解析度",
        .nativeDisplayPixels: "使用 Retina 原生像素",
        .nativeDisplayPixelsHelp: "只在視窗大小同步模式生效。Retina 2× 可能增加約四倍畫面像素，耗用更多頻寬與 GPU 資源。",
        .resetResolution: "重設解析度",
        .resetResolutionHelp: "恢復為依目前應用程式視窗大小自動調整。",
        .recordLogs: "紀錄 log",
        .recordLogsHelp: "寫入已遮蔽機密的診斷檔。不會記錄票證、原始 .vv 或剪貼簿內容。",
        .openLogFolder: "打開 log 資料夾",
        .clipboardAndResolutionHelp: "連線後由 SPICE vdagent 自動同步剪貼簿。Guest 需安裝 spice-vdagent。",
        .keyboardHelp: "部分鍵盤的 F11 需要搭配 Fn。釋放游標預設為 Ctrl+Alt+R。",
        .errorFileTooLarge: "連線檔太大，已拒絕解析。",
        .errorInvalidEncoding: "連線檔不是有效的 UTF-8 文字。",
        .errorMissingSection: "連線檔缺少 [virt-viewer] 區段。",
        .errorUnsupportedType: "第一版只支援 type=spice 的連線檔。",
        .errorMissingField: "連線檔缺少必要欄位：%@。",
        .errorDuplicateField: "連線檔含有重複的必要欄位：%@。",
        .errorInvalidPort: "tls-port 必須是 1 到 65535 的整數。",
        .errorPlaintextPort: "此連線檔沒有 tls-port。第一版不會改走明文 port。",
        .errorInvalidProxy: "proxy 必須是 http 或 https 的 CONNECT 位址。",
        .errorInvalidBoolean: "布林欄位只接受 0 或 1。",
        .errorInvalidCA: "ca 憑證資料格式無效。",
        .errorInvalidHotKey: "快捷鍵格式無法辨識。",
        .errorSourceFileUnavailable: "無法讀取連線檔。",
        .errorEngineUnavailable: "SPICE 引擎尚未連結。Parser 與 UI 可用，但還不能連到 PVE；需要 UTM 相容的 spice-gtk／GStreamer 靜態依賴。",
        .errorCancelled: "連線已取消。",
        .errorNetwork: "無法經由 proxy 或網路連到遠端。",
        .errorDisplayTimeout: "已建立連線，但遠端畫面通道未在期限內提供有效畫面尺寸。請重新下載連線檔再試。",
        .errorTLS: "TLS 驗證失敗。請確認憑證與 host-subject 來自新下載的連線檔。",
        .errorAuthenticationRejected: "票證已失效或被拒絕。請重新從 PVE 下載連線檔；本 App 不會自動更新票證。",
        .errorGuestAgentUnavailable: "Guest agent 不可用，畫面與輸入仍可使用，但剪貼簿已停用。",
        .errorDisconnected: "遠端連線已中斷。",
        .errorUnknown: "連線失敗。"
    ]

    private static let english: [L10nKey: String] = [
        .welcomeSubtitle: "Double-click or drop a .vv file downloaded from PVE to open the SPICE session.",
        .openVV: "Open .vv",
        .openVVEllipsis: "Open .vv…",
        .welcomeLimitation: "The first release only supports SPICE over TLS. Download a new file from PVE when the ticket expires; this app will not refresh tickets.",
        .close: "Close",
        .ctrlAltDel: "Ctrl+Alt+Del",
        .fullscreen: "Full Screen",
        .connectingEllipsis: "Connecting…",
        .disconnected: "Disconnected",
        .back: "Back",
        .openNewVV: "Open a new .vv",
        .statusIdle: "Idle",
        .statusParsing: "Parsing connection file",
        .statusConnecting: "Connecting",
        .statusConnected: "Connected",
        .firstFrame: "First frame",
        .waitingFirstFrame: "Waiting for first frame",
        .relativeMouseOn: "Relative mouse",
        .relativeMouseOff: "Absolute mouse",
        .relativeMouseHelp: "Request SPICE server mouse mode; click the remote display after the server accepts it to capture. Use the connection file release shortcut or switch windows to release.",
        .statusDisconnecting: "Disconnecting",
        .statusDisconnected: "Disconnected",
        .statusFailed: "Failed",
        .statusRemoteIP: "Remote IP: %@",
        .noGuestAgent: "No guest agent",
        .cannotAdjustResolution: "Cannot resize guest display",
        .guestDidNotApplyResolution: "Guest did not apply resolution",
        .clipboardUnavailable: "Clipboard unavailable",
        .ignoredFields: "Ignoring unsupported fields: %@",
        .menuSession: "Session",
        .sendCtrlAltDel: "Send Ctrl+Alt+Del",
        .releasePointer: "Release mouse and keyboard",
        .chooseVVMessage: "Choose a .vv connection file downloaded from PVE",
        .settingsMouse: "Mouse",
        .settingsLanguage: "Language",
        .settingsConnectionFile: "Connection file",
        .settingsDisplay: "Display",
        .settingsDiagnostics: "Diagnostics",
        .scrollDirection: "Scroll wheel direction",
        .scrollNatural: "Match system",
        .horizontalScrollCompatibility: "Horizontal scroll compatibility",
        .horizontalScrollCompatibilityHelp: "Emulate mainly horizontal gestures with Shift+vertical wheel; off by default. Requires guest app support and is not native horizontal scrolling.",
        .scrollReversed: "Reversed",
        .mouseWheelSensitivity: "Mouse wheel sensitivity",
        .mouseWheelSensitivityHelp: "Scales traditional mouse-wheel notches sent to the guest. 1× is the current default.",
        .trackpadScrollSensitivity: "Trackpad two-finger sensitivity",
        .trackpadScrollSensitivityHelp: "Scales two-finger trackpad scrolling sent to the guest. Precise Magic Mouse scrolling uses this setting too. 1× is the current default.",
        .scrollSensitivitySlow: "Slow",
        .scrollSensitivityFast: "Fast",
        .sideButton4: "Side button 4 (back)",
        .sideButton5: "Side button 5 (forward)",
        .sideButtonPreviousPage: "Previous page",
        .sideButtonNextPage: "Next page",
        .sideButtonNone: "Do nothing",
        .sideButtonHelp: "Previous/next page send Alt+Left/Alt+Right to the guest (browser and file-explorer navigation). You can swap or disable them.",
        .language: "Language",
        .deleteVVAfterConnect: "Delete the .vv file after a successful connection",
        .deleteVVAfterConnectHelp: "Deletes the file only after a successful connection and when .vv explicitly requests delete-this-file. Turn off to keep all files.",
        .matchResolutionToWindow: "Match guest resolution to the current window size",
        .matchResolutionToWindowHelp: "Requires spice-vdagent. Windows QXL usually applies the new size immediately. Linux desktops (especially Kali’s default XFCE) often ignore it; the app retries a few times, then shows a status-bar hint and scales locally. In the guest, run xrandr --output Virtual-1 --auto, or pick a preset resolution.",
        .commonResolutions: "Common resolutions",
        .nativeDisplayPixels: "Use native Retina pixels",
        .nativeDisplayPixelsHelp: "Applies only when matching the window size. Retina 2× may quadruple framebuffer pixels and increase bandwidth and GPU use.",
        .resetResolution: "Reset resolution",
        .resetResolutionHelp: "Restore automatic matching to the current app window size.",
        .recordLogs: "Record logs",
        .recordLogsHelp: "Writes sanitized diagnostics to files. Tickets, raw .vv contents, and clipboard data are never recorded.",
        .openLogFolder: "Open log folder",
        .clipboardAndResolutionHelp: "Clipboard is synced automatically by SPICE vdagent after connecting. The guest needs spice-vdagent.",
        .keyboardHelp: "Some keyboards need Fn for F11. The default cursor-release shortcut is Ctrl+Alt+R.",
        .errorFileTooLarge: "The connection file is too large and was not parsed.",
        .errorInvalidEncoding: "The connection file is not valid UTF-8 text.",
        .errorMissingSection: "The connection file is missing the [virt-viewer] section.",
        .errorUnsupportedType: "The first release only supports connection files with type=spice.",
        .errorMissingField: "The connection file is missing a required field: %@.",
        .errorDuplicateField: "The connection file has a duplicated required field: %@.",
        .errorInvalidPort: "tls-port must be an integer from 1 to 65535.",
        .errorPlaintextPort: "This connection file has no tls-port. The first release will not fall back to a plaintext port.",
        .errorInvalidProxy: "proxy must be an http or https CONNECT address.",
        .errorInvalidBoolean: "Boolean fields only accept 0 or 1.",
        .errorInvalidCA: "The ca certificate data is invalid.",
        .errorInvalidHotKey: "The hotkey format is not recognized.",
        .errorSourceFileUnavailable: "The connection file could not be read.",
        .errorEngineUnavailable: "The SPICE engine is not linked. Parsing and the UI work, but PVE connections need UTM-compatible spice-gtk/GStreamer static dependencies.",
        .errorCancelled: "The connection was cancelled.",
        .errorNetwork: "Could not reach the remote session through the proxy or network.",
        .errorDisplayTimeout: "Connected, but the remote display channel did not provide valid dimensions in time. Download a new connection file and retry.",
        .errorTLS: "TLS verification failed. Confirm the certificate and host-subject come from a newly downloaded connection file.",
        .errorAuthenticationRejected: "The ticket was rejected or has expired. Download a new connection file from PVE; this app will not refresh tickets.",
        .errorGuestAgentUnavailable: "The guest agent is unavailable. Display and input still work, but the clipboard is disabled.",
        .errorDisconnected: "The remote connection was lost.",
        .errorUnknown: "The connection failed."
    ]
}
