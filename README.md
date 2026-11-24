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
- 依視窗調整 guest 解析度也走 vdagent。Windows 通常會立刻改；Linux（尤其 Kali 預設 XFCE）常只更新 xrandr 可用模式、桌面不套用。可在 guest 執行 `xrandr --output Virtual-1 --auto`，或在設定改選固定解析度

## 已知限制

- 可攜包內嵌 Homebrew dylib，不是 UTM 的靜態 GStreamer／spice-gtk fork。GLib worker 跑在 default main context。
- 沒有 Developer ID：可以打包，但不能公證。下載後會有隔離屬性警告。
- Homebrew bottle 若以 macOS 27 建置，打出來的 DMG 目前只保證在 Apple Silicon 的 macOS 27 執行。
- 尚未完成音效、多顯示器、圖片剪貼簿、USB、PVE API 自動換票。
- Kali／XFCE 等 Linux 桌面可能不套用 SPICE monitors config；App 會重試並在 status bar 提示，無法在 client 端強制改 guest 桌面解析度。

### 診斷日誌容量

日誌預設每檔最多 5 MiB，同一天保留目前檔及三個輪替檔（合計上限約 20 MiB／日）；超過 30 天的本程式日誌與輪替檔會清理。日誌寫入不跟隨 symlink。

### 連線檔安全清理

連線檔須為一般檔案，不接受 symlink 或 FIFO。成功連線且允許刪除時，程式會先在同目錄建立私有 `.macremoteviewer-cleanup-*` 暫存目錄，原子移動檔案並核對 inode / device / size / mtime 後才刪除。若原路徑被其他檔案占用而無法安全還原，暫存目錄會保留原檔，請手動檢查（Finder 可用 Command+Shift+. 顯示隱藏檔）。此機制不保證抵抗具有相同使用者權限的惡意程式。

### 建置相依版本驗證

`python3 BuildSupport/check-dependencies.py --strict`：核對實際 Homebrew 連結版本是否符合 lockfile，發現版本漂移即失敗，不自動降級或修改系統。開發者可不加 `--strict` 取得差異報告；更新鎖定版本前須重新驗證 CI。CocoaSpice bootstrap 直接使用 lockfile 的 Git revision。此檢查鎖定三個直接原生依賴，並記錄全部已安裝 formula，尚非完整可重現的傳遞依賴安裝器。

### 相對滑鼠擷取

連線後按工具列「相對滑鼠」，等待 SPICE server 接受模式，再點擊遠端畫面以擷取游標。釋放快捷鍵依 .vv 設定（預設 Ctrl+Alt+R）；切換分頁、視窗失焦、切換回絕對模式或斷線也會釋放。伺服器可能拒絕模式變更，此時不鎖定游標。此功能需實機測試。標準 SPICE Inputs Channel / CocoaSpice 未提供原生水平滾輪。設定 → 滑鼠 → 水平滾輪相容模式（預設關閉）可將主要水平方向手勢轉為 Shift＋垂直滾輪；只有支援此快捷操作的 guest 應用程式才會水平捲動。

### CI 預覽 DMG 與發布關卡

CI 重用該次 Release App 打包，驗證內嵌 dylib、ARM64、Mach-O 最低版本、ad-hoc 簽章與 DMG checksum。從 Actions 對應執行紀錄下載 `MacRemoteViewer-arm64-preview` artifact（保留 14 天）。這不是正式 GitHub Release，也未經 Apple 公證。依賴版本與 SDK 資訊記錄在 `native-build.json`。

Swift Core 的 macOS 14 設定不代表打包後 App 支援 macOS 14。打包工具會將 ARM64 Mach-O 宣告的最高最低版本寫回 Info.plist；仍須在乾淨的目標 macOS 實機驗證，才能正式宣告支援版本。

正式發布前須完成第三方授權審查及 PVE 實機測試，再由維護者於 main 手動執行 Draft Release workflow。此 workflow 只建立草稿，不公開發布。

### 發布前實機回歸驗證

請依 [實機驗證清單](docs/runtime-validation.md) 記錄結果。CI 成功僅代表自動測試及打包驗證，不代表已通過 PVE、輸入擷取或效能實測。
