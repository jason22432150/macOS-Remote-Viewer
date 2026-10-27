# Mac Remote Viewer

原生 macOS App：雙擊 PVE 下載的 `.vv` 開啟 SPICE 遠端畫面，並提供雙向純文字剪貼簿。

第一版範圍見 `macOS-PVE-Remote-Viewer-技術規劃.md`。目前完成階段 A／B 的專案骨架、Parser、session 狀態、剪貼簿政策與 CocoaSpice 連線適配；實機 PVE 連線與剪貼簿壓力測試仍待用新下載的 `.vv` 驗證。

## 需求

- Apple Silicon Mac、macOS 14 或更新版本（`@Observable` 需要 14；規劃原稿的 13 依此調整）
- Xcode 27（完整 IDE，不是只有 Command Line Tools）
- Homebrew 的 `spice-gtk`、`glib`、`gstreamer`（本機已可作為原型連結來源）
- 一份**新下載**的 PVE `.vv`（票證會過期；請勿把真實連線檔提交到 git）

## 建置

1. 確認命令列使用完整 Xcode：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

目的：讓 `xcodebuild` 使用 Xcode.app，而不是 Command Line Tools。  
影響：需要管理員密碼，會改變全系統開發者目錄。  
預期：輸出 `Xcode 27.x`。

2. 產生原型連結設定（Homebrew 路徑，僅供開發）：

```bash
./BuildSupport/generate-xcconfig.sh
```

目的：把 `pkg-config` 的 header／library 路徑寫入 `BuildSupport/Generated.xcconfig`。  
影響：只寫入該檔，不安裝套件。  
預期：終端顯示「已寫入 …Generated.xcconfig」。

3. 執行 Core 測試：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
```

4. 用 Xcode 開啟 `MacRemoteViewer.xcodeproj`，Run。第一次會下載鎖定的 CocoaSpice commit。

## 使用

- 雙擊、拖放或選單「開啟 .vv…」
- 快捷鍵依連線檔：全螢幕、釋放游標、`Ctrl+Alt+Ins` 傳送 `Ctrl+Alt+Del`（不是原組合）
- 剪貼簿預設手動；自動模式僅同步作用中視窗的純文字，上限 1 MiB

## 已知限制

- 目前 App 以 stub SPICE 引擎建置：Parser、檔案關聯、錯誤 UI 可用，但還不能顯示 PVE 畫面。Homebrew 的 `spice-gtk`／GStreamer **不能**直接滿足 CocoaSpice（缺少 `gst_plugin_*_register` 與 `spice_util_set_main_context`，那是 UTM 的靜態 GStreamer／spice-gtk fork）。
- 沒有 Apple Developer ID 時只能本機 ad-hoc 執行，無法公證發布。
- 尚未完成音效、多顯示器、圖片剪貼簿、USB、PVE API 自動換票。
