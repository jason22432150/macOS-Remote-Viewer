# PVE / macOS 實機回歸驗證

CI 無法證明互動式視窗、遠端 SPICE 連線、GPU 呈現或輸入擷取均正常。以下所有項目預設為未驗證，須由測試者填寫實際結果，不可將 CI 通過當成實測。

## 測試環境

- Commit / CI run / DMG SHA-256：
- Mac 型號 / macOS / 顯示器與縮放：
- PVE 版本 / QEMU 顯示設定（SPICE）：
- Guest OS / QXL 或 virtio-gpu / spice-vdagent 版本：
- 網路（LAN / VPN）：
- 測試日期：

使用測試 VM 與新下載的 .vv，避免真實憑證、票證或剪貼簿內容進入紀錄。DMG 從對應成功 CI Artifact 取得；先以 shasum -a 256 -c <檔名>.sha256 核對內容，再於乾淨的 Apple Silicon Mac 安裝。未公證預覽包須依 macOS 安全設定處理，不應關閉全系統 Gatekeeper。

## 連線與安全

- [ ] Windows QXL + guest tools：成功連線、首幀、Ctrl+Alt+Del、正常關閉。
- [ ] Linux + spice-vdagent：連線、解析度調整、剪貼簿及重新連線。
- [ ] 無 guest agent：顯示可用，剪貼簿及自動解析度不可用時有合理提示。
- [ ] 過期票證、不匹配的 host-subject、無效 CA：拒絕連線，不降級為 plaintext。
- [ ] 中途關閉 VM、網路中斷、Display 未就緒：逾時或斷線，輸入及游標釋放。
- [ ] .vv 刪除偏好及 delete-this-file 四種組合；匯入後替換原檔時保留替代檔。
- [ ] 以兩個 Session 驗證只有作用中分頁可同步剪貼簿，且無跨分頁按鍵。

## 滑鼠與鍵盤

- [ ] Absolute Mode：黑邊、各螢幕縮放比例、游標位置、點擊與拖曳一致。
- [ ] Relative Mode：要求模式後點擊擷取，移動超過本機螢幕邊界仍能轉送相對位移。
- [ ] 測試 release hotkey（預設 Ctrl+Alt+R）、Cmd+Tab、切換分頁、關閉視窗、斷線、全螢幕切換與伺服器拒絕模式；本機游標恢復且 guest 無卡鍵。
- [ ] 在同一 Session 內反覆切換 Absolute/Relative，及在兩個 Session 之間切換。
- [ ] 左右 Shift / Ctrl / Alt / Command、Caps Lock、Pause、數字鍵盤與側鍵。
- [ ] 水平相容模式關閉時，原本垂直滾輪完全保留。啟用後在支援 Shift+wheel 的應用程式測試左右方向、斜向手勢、靈敏度及反向設定。
- [ ] 實際按住左／右 Shift 再捲動，確認原本 Shift 不被提前放開；Ctrl/Alt/Command 組合不新增 Shift 模擬。

## 顯示及效能

以相同 Guest 解析度、相同工作負載及網路，分別比較一個／兩個／四個連線。先暖機 60 秒，再至少觀察 5 分鐘；長時間測試至少 30 分鐘。下列為建議的觀測欄位而非已測量數據。

| 場景 | 首幀 ms | CPU % | GPU %/時間 | RAM MiB | FPS/延遲 | 異常 |
|---|---|---|---|---|---|---|
| 單 Session | | | | | | |
| 兩 Session | | | | | | |
| 四 Session | | | | | | |
| 前景／背景反覆切換 | | | | | | |
| Retina 啟用 | | | | | | |
| 30 分鐘長時間 | | | | | | |

- [ ] 前景畫面持續更新，背景切回沒有卡死；背景 15 FPS 為目標值，不是已測量實際 FPS。
- [ ] 用 Activity Monitor 或 Instruments 記錄 CPU、記憶體及 GPU，檢查記憶體是否持續增長。
- [ ] 關閉所有分頁後檢查游標、CPU、GPU、Session、worker 清理。
- [ ] 確認日誌沒有票證、憑證全文、剪貼簿內容等敏感資訊，並確認容量輪替。

## 發布關卡

- [ ] CI Core、Overlay、Package、Debug/Release、DMG、SHA-256 全部成功。
- [ ] 乾淨 Mac 無 Homebrew 安裝時可啟動預覽包；最低宣告版本與實測 macOS 版本分開記錄。
- [ ] 完成所有第三方授權和來源義務審查。
- [ ] 確認 Developer ID、Hardened Runtime 及公證需求後再正式發布。
- [ ] 記錄尚未通過的項目、重現步驟和修正 Commit；未測試不得標示通過。
