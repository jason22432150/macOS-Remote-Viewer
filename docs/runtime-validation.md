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

## 四個真實 Session 並行

CI 的 multi probe 在同一 App 程序內開四個 loopback TLS SPICE server，分別提供紅/綠、藍/黃、青/洋紅、白/灰動態 bitmap。使用同一 Metal device、四個 production RemoteCanvasView 及四個獨立 SessionController/Adapter；以可見 2×2 grid 測試四輪 active 切換。每輪要求每個 canvas 重新取得自身兩色、無其他非黑色、保持 connected 並確認 active/background preferredFramesPerSecond 為 60/15。關閉第二組後剩餘三組須重新取得自身雙色，關閉組須清除 display/frame state。這是 canvas/controller 層的真實網路並行測試，並非 SwiftUI 分頁整合測試；不測 clipboard/guest input，FPS 設定不等於實際量測 FPS，亦不驗證完全隱藏或遮蔽視窗的 GPU 行為。

CI #45396733101：Debug/Release 通過，單一 display 雙色通過；四組並行時出現重複 Main/Display 初始化、連線關閉及一組 fixture SIGSEGV。原始 CocoaSpice 的 connect/disconnect 直接在呼叫端操作 SpiceSession，overlay 改為 CSMain GLib context 同步序列化；callback 仍透過既有 MainActor hop。此變更針對已確認的執行緒歸屬風險，尚不能認定它就是重複連線的唯一原因。multi probe 增加各組失敗/斷線/最終狀態診斷；fixture 關閉前給予固定 500 ms 排空 peer disconnect，保留全部四組並行、雙色、channel 數量與退出狀態的嚴格驗證。

CI #45398346179 出現 GLib `g_main_context_push_thread_default: assertion 'acquired_context' failed`。CocoaSpice overlay 現在由 Worker 顯式取得 default GMainContext 所有權、push thread-default、完成 GStreamer 初始化後才釋放啟動 semaphore；若 context acquire 失敗則回傳 worker 啟動失敗。跨執行緒排程使用 GSource attach，避免 invoke_full 在呼叫執行緒自行取得 context 並 inline 執行；已在 context owner 上的工作維持 inline 語意。保留 connect/disconnect 的 GLib 序列化。這是針對已觀察到的 context 競態的修正，四 Session 仍需完整 CI 驗證；啟動等待仍為同步，尚未改成可取消的非同步初始化。Overlay 測試同步涵蓋真正的 connect/disconnect 與 Worker 所有權路徑。

CI #45399562937：Core/Overlay/Debug/Release/單連線全數通過，四連線 App 出現 GLib pop_thread_default stack assertion 與 coroutine abort（-6）。PVE 所用 CSConnection(host:port:) 現在在已啟動的 GLib Worker 建立 SpiceSession、初始化 CocoaSpice session 及設定 TLS 屬性，避免在其他 Session 的 coroutine 運行期間從 AppKit 直接建立 GObject。保留四組同時連線及精確雙色驗證。multi probe opt-in 記錄 GLib critical 的 thread id、是否 AppKit thread、default context ownership 及最多 32 個 stack frames，並記錄 packaged spice-gtk 的相關未定義符號（不能單獨證明 coroutine backend）；即使四組成功，若出現 GLib critical 仍判定失敗。尚未確認 coroutine 崩潰根因，不宣稱完成修復。

CI #45402772383：無新 GLib critical/abort，但多連線仍出現額外 main channel 與非預期斷線；封裝 dylib imports 顯示 native ucontext/setjmp 系列。新增獨立 C probe：從相同已簽署 App 的 Frameworks 直接連結 spice-client-glib/GLib/GIO/GObject，檢查 otool linkage，不使用 Swift/CocoaSpice/Metal；在單一 pthread 上建立四個 TLS-only Session，要求各 Main/Display channel 正常開啟一次並持續兩秒。兩組測試使用不同新建 fixture processes，任何一組失敗仍執行另一組，最終任一失敗即 CI 失敗。這是故障隔離測試，不宣稱 ucontext 已修復；若 C probe 同樣失敗，下一步比較 upstream 支援的 libucontext backend（UTM build_dependencies.sh 使用此選項）。不改變 production dependency、TLS policy 或原四組像素測試要求。

CI #45405805517 attempt 3：native C 四組通過，62 個 draw commands 全數消費/釋放；正式 App 在 GLib critical marker 後 SIGSEGV，未印出 backtrace。不能認定 backtrace 就是原始錯誤，故移除 alternate-stack unwinding，改先印原始 GLib critical message（僅合成 fixture opt-in），保留 critical failure gate。新增 production SessionController/SpiceEngineAdapter/CocoaSpice 無 remote Metal canvas 的四組 wrapper probe，要求每組連線與 640x480 display 同時穩定兩秒、正常關閉；native、wrapper、full pixel tests 各使用新 fixture，任一失敗仍執行其他組。Input mouse mode、Display enable/resolution 改在 GLib worker 內檢查 main channel，避免排程期間 channel 被移除後使用 NULL。未變更 backend 或降低既有驗證標準。

CI #45420674581 attempt 2：Native 四組成功（54 draws），無 Metal wrapper 與完整 App 均失敗；完整 App 出現 GObject invalid object 與 GSpice unknown major 0。spice_channel_send_link 讀取 channel->session 的 protocol 失敗與此現象一致，但尚不能確定失效原因。CocoaSpice 原先僅以 mutableChannels wrapper array 為空即回報 disconnected，而該 array 不含 main channel；SessionController 收到事件會主動 disconnect，可能在 main channel 仍存在時誤關其他待建立的 channel。現要求 main 已移除且實際 SpiceSession channel list 為空，或底層 disconnected signal，並去重。新增 opt-in session/channel identity、new/destroy/event/connect/disconnect diagnostics；不記錄票證或 CA。spice-gtk 預設 client mouse mode，因此僅在明確要求 relative 模式時於 inputs available 送出 request，避免初始化期間不必要的 main message。保留原 TLS/像素/三層並行測試；尚未證明此為全部故障根因。

CI #45426107420 的關鍵線索：四 controller 的 wrapper/full probe 實際記錄多於四個不同 `MRV_CONN_CONNECT`，full probe 可見六個不同 Session 主動 connect；非預期 main CLOSED 早於後續 App cleanup。AppDelegate 正常 Finder openFile/open URLs 流程可能也收到 positional `.vv` 參數，導致 AppModel 額外匯入並連至同一 fixture，server 替換舊 client。修正所有明確 integration probe flags，在 applicationWillFinishLaunching 就不安裝正常匯入 handler，兩種 AppKit 開檔回呼均直接忽略且記錄無路徑 marker；不執行 probe 的 LSRegisterURL 與正常視窗重整（startup smoke 仍驗證主窗）。保留 positional `.vv` 作回歸觸發條件。wrapper/full probe 必須驗證正常 workspace 為空，Python 必須看到精確四次不同 session connect；仍要求每個 fixture 只有一次 Main/Display 初始化。Native C 不受此限制改動。此為已觀察額外連線的高可信解釋，仍待 CI 確認，尚不能證明正式使用情境無其他 race。

## 多 Session 持續渲染及程序資源量測

CI #45427763320 attempt 2 已通過 Native、Wrapper、完整 App 四 Session 並行；四組首幀分別 316/324/277/299 ms。後續 multi probe 在每個 active phase 及關閉第二組後，先等待四（或三）組雙色正確，再清除觀測、進行至少 3 秒持續測量，每組必須再次讀回雙色且有完成樣本；仍禁止非預期非黑色、斷線及 FPS 設定錯誤。`MRV_MULTI_RESOURCES` 記錄該區間 process CPU time delta、wall time、macOS getrusage 累計 peak RSS bytes；`MRV_MULTI_SAMPLES` 記錄成功 GPU pixel readback callback 數，Python 核對五個 phase 共 19 組資料並計算完成率與 CPU%。CPU% 以單核心 100% 為基準，可能超過 100%；RSS 是程序歷史峰值，不是當前記憶體、GPU 記憶體或洩漏證據；讀回完成率不是螢幕呈現 FPS，合成來源每 250 ms 才嘗試更新，且讀回會增加測試負擔。CI 不設定不可靠的硬體效能閾值，保留既有正確性 gate。GPU command buffer 執行時間、無讀回真實 FPS 與長時間 RSS 趨勢仍待後續驗證。

## GPU command buffer 時間量測

CI #45431514695 已通過 19 組持續量測，完整 App 224 個 QXL draw commands 全數消費/釋放。後續 opt-in pixel probe 在 GPU 成功完成且有 readback buffer 時讀取 GPUStartTime/GPUEndTime，與像素一同回傳。每 phase/session 記錄有效/不可用數、總時間及最大時間（ns）；Python 核對 19 組計數與 readback 數一致。零、反向、非有限或超過 60 秒的異常時間戳標記 unavailable；不設 CI 速度閾值。正式 handler nil 不讀 timestamps。此量測包含 pixel blit，不是端到端延遲、螢幕 FPS 或 GPU 使用率；不同 queue 的時間不可直接加總推算 GPU busy。待 CI 確認實際時間戳可用性。

## 局部 framebuffer 更新

CI #45437464697 全部通過；19 組 GPU timestamps 無 unavailable，phase 平均 1.210–3.405 ms，最大 14.613 ms；完整 App 233 draws 全消費/釋放。新增獨立 partial fixture：第一個 full draw 為藍色，後續 QXL_DRAW_COPY 僅傳入 160×120 bitmap 至中央 (240,180)，交替紅綠；原 full draw modes 保留。新增 opt-in region callback 在同一 GPU command buffer 中取中心及四個 1/4、3/4 位置，只有此模式分配 1280 bytes，既有 center readback 仍 256 bytes。兩輪 TLS reconnect 均須取得紅/綠中心及四藍色外圍，拒絕非預期樣本並檢查正常 workspace 為空，Python 確認至少四次 partial commands。僅為五點取樣，不能證明每一像素正確、完全無撕裂或所有 dirty-rect/GL scanout 情況。正式使用兩 handler 均 nil，不增加 readback；待 CI 確認。
