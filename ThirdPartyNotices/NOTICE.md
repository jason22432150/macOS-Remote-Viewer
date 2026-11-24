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
