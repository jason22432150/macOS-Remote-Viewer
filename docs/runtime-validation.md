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

## CI 掛載及啟動 Smoke Test

CI 以唯讀方式掛載最終 DMG，比對內嵌與獨立 SBOM、檢查 Applications 捷徑、版本、Mach-O SHA-256 與 App 簽章。另一個步驟從 DMG 複製 App 至暫存目錄，清除 DYLD/GST/OPENSSL 環境覆寫並以 `--startup-smoke-test` 啟動。測試須確認 Metal device／command queue、SPICE worker 啟動請求及可見主視窗後才回傳成功訊號；40 秒內未退出即失敗。這個模式不連線 PVE，不證明 GLib/GStreamer 初始化已完全完成、不驗證 GPU 實際呈現，也不是無 Homebrew 的乾淨 Mac 實測。CI Runner 的圖形與 Metal 裝置可用性可能影響結果。

## 本機 TLS／SPICE Link 整合測試

`BuildSupport/test-loopback-tls.py` 使用臨時 RSA CA／server certificate、只監聽 127.0.0.1 的 Python TLS 端點及實際簽署 App。受信任 CA + Subject 必須完成 TLS 並送出 SPICE `REDQ` link magic；錯誤 CA、錯誤 Subject 不得送出任何應用資料，且三種情況都不得降級成 plaintext。端點故意不提供 SPICE link reply／ticket auth／display channel，故 App 必須終止連線，不能回報 connected。這不是完整 SPICE server 或真實 PVE 連線測試。測試憑證與 key 只在暫存目錄生成，不上傳、不使用真實票證。

## 真實 SPICE Main Channel / Ticket Authentication

`BuildSupport/test-spice-auth.py` 在 macOS 透過 Homebrew test-only `spice-server` 編譯 C fixture，使用 GLib main loop 與 TLS-only 127.0.0.1 端點。使用合成 CA、票證與實際簽署 App：正確票證須在同一 engine/controller 內連線及取消三次，且伺服器須觀察三個 TLS main-channel initialized 事件；錯誤票證須收到 authenticationRejected，且不得初始化 main channel。fixture 不提供 guest OS、QXL、Display Channel 或 guest agent；不代表真實 PVE GUI、輸入或 framebuffer 測試。測試套件於打包及依賴審查之後安裝，非發行 App 的新增相依。若未安裝 server 依賴，本測試不可宣稱通過。

## 真實 Display Channel 與 GPU 首幀

SPICE fixture 另提供固定 640×480 CPU Primary Surface（QXL interface）；同一簽署 App、engine、controller 及 RemoteCanvasView 反覆連線兩次。每輪須收到實際 Display Channel 尺寸、成功 Metal command buffer completion、首幀時間，斷線後須清空畫面與首幀狀態。伺服器另核對 TLS Display Channel 事件。這是合成 CPU framebuffer，不驗證影像像素正確性、動畫、GL Scanout、真實螢幕呈現或 Guest OS。原本純認證測試保留。

Display fixture 每 250 ms 送出一個 QXL_DRAW_FILL，輪流填滿紅色與綠色；同時最多 16 個未釋放 command，且最多一個等待 worker 消費；收到 release 才能重用對應記憶體。Metal overlay 僅在明確設定 smokePixelHandler 時從已渲染的 BGRA8 drawable 中心以 GPU blit 讀回一個像素，完成後比對 RGB。每輪須同時觀察兩種預期顏色才算成功；一般 App 未設定 handler，不配置讀回 buffer。這仍是中心像素驗證，並非完整畫面像素比對、實體螢幕掃描輸出、GL Scanout 或真實 Guest 測試。

動態測試改採 QXL_DRAW_COPY + immutable red/green direct bitmap，避免以單色 brush fill 作為唯一更新路徑。fixture 會記錄提交、worker 消費、release 次數及退出狀態；App 記錄有限的實際 RGB 樣本、GPU 讀回不可用狀態與首幀診斷。正常 shader 的非 alpha surface 使用 normalized alpha 1.0。紅／綠都必須符合原本精確 RGB 條件；不允許以超時、黑畫面或僅 GPU completion 代替。

CI #45392068111 顯示已建立 Main/Display Channel、完成 GPU draw 與黑色像素讀回，但 QXL submitted=1、consumed=0。SPICE red worker 在 VM 尚未 running 時不消費 QXL 命令。fixture 在建立 QXL primary surface 後、啟動 GLib loop 前呼叫 `spice_server_vm_start`；結束時先銷毀 surface，再 `spice_server_vm_stop`。測試保留雙色 RGB 驗證，並要求伺服器 VM_STARTED marker 與實際消費計數，不將僅送出初始 surface 視為動態更新成功。
