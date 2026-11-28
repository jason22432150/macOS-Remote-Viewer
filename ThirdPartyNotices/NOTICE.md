# Third-Party Notices

本 App 連結或參考下列第三方元件。散布前必須依各授權補齊完整 notices 與來源對應。

| 元件 | 用途 | 授權（待發布時再核對鎖定版本） |
|---|---|---|
| CocoaSpice | SPICE Cocoa bindings 與 Metal renderer | Apache-2.0 |
| spice-gtk / libspice-client-glib-2.0 | SPICE channel、proxy、TLS、agent | LGPL-2.1-or-later 等（見 spice-gtk 發行說明） |
| GLib / GObject / GIO | 事件迴圈與物件系統 | LGPL-2.1-or-later |
| GStreamer | CocoaSpice 連結依賴；第一版關閉音訊 | LGPL-2.1-or-later |

CocoaSpice 與底層 C 程式庫授權不同，不可只複製一份 NOTICE 就視為完成。

## 發布前必須核對

上游來源：
- CocoaSpice: https://github.com/utmapp/CocoaSpice
- spice-gtk: https://gitlab.freedesktop.org/spice/spice-gtk
- GLib: https://gitlab.gnome.org/GNOME/glib
- GStreamer: https://gitlab.freedesktop.org/gstreamer/gstreamer
- Homebrew formula: https://github.com/Homebrew/homebrew-core

打包還包含傳遞 dylib、plugins、scanner 及可能的 OpenSSL provider。須依實際二進位對應 formula / 版本逐一確認授權、保存完整授權文字及適用來源取得方式，並核對 CocoaSpice overlay 修改通知義務。專案自身授權由著作權人決定。CI 通過不代表完成散布義務。

## 缺少 keg 授權聲明時的補取

CI #45596255639（2026-11-25）34 個觀察到的 Homebrew keg，OSV 無命中，31 個已有候選聲明；缺 GLib 2.90.1、JSON-GLib 1.10.8、SQLite 3.54.1。GNOME 官方文件標示 GLib 與 JSON-GLib 為 LGPL-2.1-or-later；SQLite 核心為公有領域（https://www.sqlite.org/copyright.html），其原始碼開頭宣告可作候選資料，不應捏造傳統 LICENSE。新版工具僅對上述三個缺漏 keg 以相同穩定版本與 Homebrew revision 核對 formula、HTTPS 官方主機及 SHA-256 後讀取來源封存檔中的候選聲明／SQLite 原始碼前 4096 bytes，保存來源 metadata；不解壓至檔案系統、不安裝或更新套件。取得失敗仍明列 missing-review-required。此來源比對不等於證明瓶裝二進位的完整對應原始碼或補齊下游 patches、所有授權義務；尚須人員審查 LGPL/GPL 等散布條件、專案自身授權及完整 notices。


## Candidate 散布證據清單

CI 會從實際 Candidate SBOM、baseline audit/notices、修改版 source evidence、staging report 與建置紀錄產生 distribution-inventory.json。每個 signed Mach-O 檔案歸入唯一元件群組，並記錄 signed SHA-256、已收集授權候選文件與來源證據。CocoaSpice overlay、靜態連結與其他未觀察依賴明列待審。所有授權結論保持空值，release_ready 固定為 false；此清單不是完整授權清單或法律批准，不得用來宣稱可散布。


Installed Homebrew formula/receipt 與 FFmpeg dylib 自身回報的 configuration/license 將封存至 homebrew-recipe-evidence.zip；與 baseline SBOM 及 native manifest 綁定，Candidate 清單只採用仍實際散布的 keg。這些是建置與授權線索，並非 SPDX 結論，也不代表已取得完整上游原始碼、資源、下游 patch 或靜態依賴證據。


CocoaSpice 修改版來源證據將保存在 cocoaspice-source-evidence.zip：鎖定上游 Git archive、修改後完整 regular files、兩個上游 Symbolic Link 目標資料、overlay diff、建置配方及原始 LICENSE。保留授權文件並不等於完成 Apache-2.0 修改聲明、NOTICE（若適用）及所有靜態相依審查；發布閘門仍保持關閉。
