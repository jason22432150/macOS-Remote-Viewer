# Mac Remote Viewer

原生 macOS App：雙擊 PVE 下載的 `.vv` 開啟 SPICE 遠端畫面，並提供雙向純文字剪貼簿。

第一版範圍見 `macOS-PVE-Remote-Viewer-技術規劃.md`。目前完成階段 A／B 的專案骨架、Parser、session 狀態與 CocoaSpice 連線適配；剪貼簿走 SPICE vdagent。實機 PVE 連線仍待用新下載的 `.vv` 驗證。

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

4. 取得鎖定的 CocoaSpice 並套用 Homebrew overlay：

```bash
./BuildSupport/bootstrap-cocoaspice.sh
```

目的：clone 鎖定 commit 到 `ThirdParty/CocoaSpice`（不進 git），把靜態 GStreamer／`spice_util_set_main_context` 換成 Homebrew 可連結的版本。  
影響：只寫入該目錄。  
預期：終端顯示「CocoaSpice 已就緒」。

5. 用 Xcode 開啟 `MacRemoteViewer.xcodeproj`，Run。

## 打包給別人（不上架、不公證）

沒有 Developer ID 也可以產出 DMG。對方從 GitHub 下載會被標隔離屬性，第一次要「仍要打開」。

```bash
./BuildSupport/package-portable.sh
```

目的：建置 Release，把 spice-gtk／GLib／GStreamer 等 dylib 打進 App，ad-hoc 簽署後做成 DMG。  
影響：寫入 `dist/` 與 `build/package/`，不修改 Homebrew 套件。  
預期：出現 `dist/MacRemoteViewer-*-arm64.dmg`、`.sha256`；映像內有 App、「應用程式」捷徑與 `如何開啟.txt`。

把 DMG 上傳到 GitHub Release 即可，不要把 `dist/` 提交進 git。

對方打開 DMG 後：

1. 把 `Mac Remote Viewer` 拖到同一個視窗裡的 Applications
2. 退出磁碟映像
3. macOS 27 沒有 Launchpad。從 Finder「應用程式」打開一次，或 Spotlight 搜尋英文名稱 **Mac Remote Viewer**（排在 Lunport 與 Maccy 之間）。若 Apps 網格還沒出現，關掉 Spotlight 再開一次；必要時登出再登入
4. 第一次：Control-點 App → 打開；或「系統設定 → 隱私權與安全性 → 仍要打開」
5. 進階：`xattr -cr "/Applications/Mac Remote Viewer.app"`

目前 bottle 是本機 Homebrew 建置，**只保證 Apple Silicon、與打包機相同的 macOS 大版本**。換成別的 macOS／Intel 會打不開。

## 使用

- 第一次請先從「應用程式」打開 App 一次，讓 Launch Services 註冊 `.vv`
- 之後即可雙擊 PVE 下載的 `.vv`；若仍開錯 App，在 Finder 資訊視窗「打開方式」指定 **Mac Remote Viewer** 並「全部更改」
- 也可拖放到視窗或 Dock 圖示，或用選單「開啟 .vv…」
- 快捷鍵依連線檔：全螢幕、釋放游標、`Ctrl+Alt+Ins` 傳送 `Ctrl+Alt+Del`（不是原組合）
- 剪貼簿由 CocoaSpice／spice-vdagent 自動雙向同步；Guest 需安裝 spice-vdagent

## 已知限制

- 可攜包內嵌 Homebrew dylib，不是 UTM 的靜態 GStreamer／spice-gtk fork。GLib worker 跑在 default main context。
- 沒有 Developer ID：可以打包，但不能公證。下載後會有隔離屬性警告。
- Homebrew bottle 若以 macOS 27 建置，打出來的 DMG 目前只保證在 Apple Silicon 的 macOS 27 執行。
- 尚未完成音效、多顯示器、圖片剪貼簿、USB、PVE API 自動換票。
