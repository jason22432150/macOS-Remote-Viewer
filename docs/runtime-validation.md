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

## 真實 SwiftUI workspace 分頁整合

CI #45441275158 attempt 3：partial 兩輪五點正確、5 個局部命令，6/6 draw consumed/released；full multi 227/227。新增獨立 `--loopback-spice-workspace-probe`，用隔離 AppModel 及 NSHostingView 承載 production ContentView（SessionTabBar/ZStack/RemoteSessionView/RemoteDisplayView），正常 app workspace 保持空白，四個合成 loopback TLS profiles 明確檢查，避免 AppKit 重複匯入。從 NSView hierarchy 發現真實 representable 的 RemoteCanvasView，記錄 identity；不由 probe 手動 setActive/attach renderer。以正式 tab 按鈕相同 Model API 切換 8 次，每次要求所有 live session 連線及原 canvas identity、active state/60:15 設定，選中 canvas 再次取得該 session 雙色；關背景 tab 保持選擇、關選中末 tab 選鄰近前 tab，最後全部關閉並檢查 canvas 移除及 controller 清理。Python 驗證全部 marker、恰好四個 connect、各 server 一次 TLS Main/Display 及資源計數。獨立新 fixture，保留舊三層及局部測試。此非實體滑鼠點擊/螢幕 compositor 呈現測試，背景 canvas 不要求每次真的 draw（被遮擋可能無 drawable），亦不宣稱 memory leak 已排除。待 CI 驗證。

CI #45444452551 attempt 4：八次 workspace selection、background/active close 均輸出成功；四 fixture 各一次 TLS main/display，95/95 draws 消費及釋放。client 回傳 0 但在最後兩個 session disconnect 後缺少 final marker，Python gate 正確失敗。原 cleanup 在等待 SwiftUI reconciliation 前 orderOut，且 AppDelegate 即使 probe 也允許最後視窗關閉後自動終止；本輪保留 host 視窗至全部 cleanup 斷言完成、測試模式不允許 last-window automatic termination（一般 App 不變），逐一關閉 snapshot IDs，新增 begin/state marker 並要求 0 sessions / 0 canvases / 4 disconnected / normal workspace 0 / selected nil / cleared display and frame state / no foreign pixels，再明確退出。原終止原因仍待 CI 確認，未移除任何 gate。

## Drawable demand 最佳化

CI #45521534489：真實 SwiftUI workspace 24/24 selection、前/背景 close、最終 0 sessions/0 views/4 disconnected/normal 0；215/215 QXL draws 釋放，其他整合測試全過。本輪調整 production CocoaSpice renderer：先檢查 retained source visibility/dirty flag，再要求 MetalKit currentRenderPassDescriptor/currentDrawable；idle、無 drawable、無 command buffer 仍 drain pending invalidate completions，後兩者不消耗 dirty state。視窗 drawable resize、sampler 變更及回到 active tab 主動標記 retained frame dirty，以避免靜態 guest 畫面切回時不重畫。保留 60/15 FPS tick 及既有獨立 GPU blit completion、scanout ownership，不 pause background、不更換 renderer；structural gate 驗證順序與 completion。尚未量測節省的 CPU/GPU 數量，待 CI 重新驗證既有 pixel、partial、24 次 workspace switch 和 cleanup。

## 60 秒 workspace soak 與 current RSS

CI #45523232164 已通過 drawable demand 最佳化及既有測試；workspace 24/24 switch、224/224 fixture draws，full multi 236/236。本輪保留原 24 次切換及關閉驗證，再加入至少 60 秒同一四組連線的 soak；6 個每十秒 checkpoint 依序切換、前景雙色重驗，區間每 100ms 檢查四組 connected、解析度、selection 及 foreign pixel。以 MACH_TASK_BASIC_INFO resident_size 取 current RSS，getrusage 取 peak RSS/累計 CPU，記錄 phase 0–6 與全部關閉後 phase 7。Python 驗證 8 組順序、時間、CPU/peak 單調性、4→0 live count，輸出 current RSS 差、sampled peak、after-close RSS、CPU%。保留原 workspace canvas identity/cleanup gate 及所有其他 tests；workspace subprocess timeout 延至 420s，以容納保守 phase deadline。這是短期 60 秒 synthetic source soak，不是數小時壓測或洩漏證明；final RSS 包含 probe 持有的 controller references、AppKit/GPU cache，不等於未釋放 allocation。無人為 RSS/CPU 性能閾值；待 CI 驗證。

## 同一程序反覆建立／銷毀 Workspace

CI #45524693883：60.866 秒 soak 通過，CPU 3.00%（單核心），RSS 414.67→166.03 MiB，關閉後 163.88 MiB，944/944 QXL draws。RSS 變化不證明不存在洩漏。本輪保留原 24 次切換、60 秒 soak 與兩種關閉斷言；同一 AppModel/NSHostingView/程序額外再開關三批四組 TLS session，每批重新解析合成 VV 取得新 UUID，要求共 16 個 distinct profile IDs、每批前景四色組重新驗證、所有 controller 清理、空 view hierarchy，使用 generation fence 忽略舊 GPU probe callback。每輪放掉 probe 的 strong controller references，等待 1 秒後採樣 current RSS/peak/CPU 與 NSHashTable weak survivors；weak count 作診斷，不把暫時 retained UI/cache 直接當洩漏或自訂效能門檻。Python 要求四批各四個 unique concurrent GObject connects（跨批允許 allocator 重用地址）、每 fixture 四次 TLS Main/Display、原 8 soak samples 及新 4 churn samples/weak samples；workspace 專用合成 ticket TTL 600s、timeout 540s，不改真實連線票證或其他 fixture TTL。尚待 CI 驗證，若 survivor 有成長再深入追查。

CI #45526125753：四批 16 個 TLS sessions 與原 soak 均通過，1085/1085 QXL draws；每批關閉後 current RSS 160.34/171.91/172.88/173.31 MiB，NSHashTable 弱引用 controller 2/4/4/4、canvas 均 0，未證明洩漏也未證明釋放完成。Core 既有 mock 400 lifecycle 測試要求 controller 即時釋放。改用逐 session Swift weak slot（不建立 NSHashTable allObjects 強引用 snapshot），保留批次標記，輸出每次採樣各歷史批次殘留；最後測試才移除 NSHostingView（不改正式 workspace），最多 5 秒觀察 weak refs，區分 UI graph/cache 與 persistent retention。Python 驗證所有 10 個 batch 樣本與總數一致、final unhost marker 唯一，不假定零為必然或放寬既有 gates。另 production adapter hopToMain 改 weak self，保持 connection identity fence，避免已關閉 adapter 被排隊 callback 延長生命；此項並非已證實 controller 殘留根因。待 CI 實際驗證。

## Guest Agent capability 整合測試

CI #45529336809 已通過全部既有 gate；四批 weak slots 顯示歷史批次均在下一批歸零，最後移除 NSHostingView 後 controller 4→0、canvas 0；1111/1111 draws，churn RSS 173.48→176.61 MiB。支持 SwiftUI 暫時保留解釋，不宣稱所有 native allocations 已排除洩漏。本輪新增獨立 `agent-full`/`agent-limited` loopback fixtures：使用公開 libspice-server SpiceCharDeviceInterface、spice-protocol VDIChunkHeader/VDAgentMessage，synthetic vdagent 收到 client capability announce 後回覆（完整：monitors config / clipboard by demand；受限：reply），三秒後實際 remove interface。App 使用正式 SpiceEngineAdapter/SessionController，禁用 clipboard sharing、proxy、source deletion，無 display 的 probe 專用 timeout zero；要求正確 capability 狀態穩定至少 500ms、agent hot removal 後 main 仍 connected、所有 flags 清除、正常 workspace 空。Python 驗證 server/client markers 和單次 TLS main；保留舊 auth/display/partial/multi/soak gates。此為 capability exchange/agent removal，不包含真實 OS guest agent、剪貼簿內容、monitor config 套用或重連。Char-device fixture 只辨識完整小型 capability chunk，不是通用 agent 實作；待 CI 確認 Homebrew header/API 與時序。
參考：https://spice.pages.freedesktop.org/spice-space/agent-protocol.html 與 https://sources.debian.org/src/spice/0.15.2-1/server/spice-char.h

## Guest Monitor Config wire 與未套用處理

CI #45543938489 通過原 full/limited agent capability 與 hot removal（兩者 server exit 0、各一次 TLS main），其餘整合 gate 全過；16 lifecycle 最終 weak controller/canvas 均 0。本輪新增獨立 agent-monitor-full/limited，保留原兩種 capability-only fixtures。結合 640×480 QXL surface 與 synthetic char device，解析 bounded VDAgentMonitorsConfig/VDAgentMonConfig little-endian fields；正式 SessionController 在 capability 與 display ready 後設定 viewport 1024×768，經實際 adapter/CSDisplay 發送。Full fixture 故意不套用尺寸，使用 probe 專用 1 秒重試/1 次 retry limit，要求 guestDidNotApplyResolution 成立並收到至少一個真實 single-monitor 1024×768 config；limited 不得收到該目標或顯示未套用警示；agent 6 秒後 hot removal，兩者皆維持 main 與原 640×480 並清除警示。Python 核對兩端 markers、實際 target count、TLS Main/Display、draw lifecycle。此為 wire/negative/unapplied 測試，不宣稱真實 OS 解析度已改變或已完成 clipboard。未實作通用 fragmented agent message assembler；固定小型 test config。待 CI 驗證。參考 https://spice.pages.freedesktop.org/spice-space/agent-protocol.html 及 https://www.spice-space.org/multiple-monitors.html。

## Guest 實際 primary surface resize

CI #45547397542 通過 monitor-full 2 次真實目標 config（初始+重試）、monitor-limited 0 次、警示及 hot removal，既有整合 gate 全過。本輪另增 agent-monitor-resize-full：保留原不套用測試，收到 1024×768 request 後在 GLib main loop 等待 pending draw 消費、同步 destroy/create QXL primary，固定 bounded 1024×768 backing 與不可變新 bitmap（cyan/magenta），原 modes 保留紅綠/原尺寸。App probe 使用實際 RemoteCanvasView/Metal readback，800×450 寬視窗，要求舊 640×480 雙色與 cached mapping，再將正式 resolution preference 從 keepGuest 改 preset 1024×768，要求 display callback 新尺寸、新雙色、frame flag、無 unapplied warning、實際 cached mapping 中心及黑邊拒絕；agent removal 後保持新尺寸、連線，既有 cleanup。Python 驗證 client/server marker、TLS channels 及 draw counts。不是實際 OS agent 套用、完整畫面像素或滑鼠封包端到端測試。resize mode 延長 synthetic agent removal 至 10s、retry delay 3s；待 CI 確認 surface recreation 及 timing。

CI #45550136550 attempt 1：core success，App 在 compile_fixture 失敗（spice-auth-fixture.c:468:46，no member named framebuffer）。`#define pixels framebuffer.pixels` 使 `sizeof(framebuffer.pixels)` 二次拼接成 `sizeof(framebuffer.framebuffer.pixels)`；改為 `sizeof(pixels)`，保留整個 1024×768 backing 的清零、原 resize/agent/其他 assertions。App 執行階段 resize 未測得，待新 CI 驗證。

## 真實 Guest Agent UTF-8 clipboard exchange

CI #45550980560 通過 primary resize 640×480→1024×768、cyan/magenta pixels、cached mapping、1 matching wire request、34/34 QXL draws、原 multi/workspace gate（1139/1139 workspace draws）。本輪另加 agent-clipboard-full fixture，使用既有 public VDI protocol legacy clipboard by-demand（不宣告 selection/serial），client grab→server request→client UTF-8 data exact bytes→server grab→client request→server UTF-8 data。固定繁中、emoji、LF 字串，僅輸出 markers，不讀寫真實 clipboard；App 使用正式 CocoaSpicePasteboard 與 adapter，注入唯一 named NSPasteboard（production default general 不變），先禁用 sharing 至 capability ready，再啟用與寫合成文字、poll、驗證 guest UTF-8 exact bytes、agent hot removal、清理並 releaseGlobally。Python 核對雙端順序、single TLS main、正常 agent removal。保留舊 gates。此輪僅驗證小型固定文字雙向，未驗證 selection extension、fragmented agent messages、oversize、invalid UTF-8、跨 session isolation 或 OS guest，待 CI 確認 wire framing/clipboard notification 路徑。

## Clipboard input guards and local isolation regression

CI #45552881114 passed actual TLS bidirectional UTF-8 Traditional Chinese/emoji/LF exact bytes and all existing gates; 1126/1126 workspace draws, weak controllers/canvases 0 after unhost. New CSSession overlay checks active clipboard/selection/main, 16 MiB before bridging, null data, valid UTF-8 (optional terminal NUL, reject embedded NUL), preserves negotiated CRLF conversion, rejects unsupported inbound/outbound types, guards release, filters pasteboard notifications by originating delegate. This does not bound spice-gtk allocations before the callback or fence all possible wire messages across reactivation. New independent packaged-app local security probe shares a unique named board between two real CocoaSpicePasteboard delegates: rejects invalid UTF-8/16 MiB+1 incoming delegate input and disabled reads/writes/clear, tests queued write cancellation on switch/re-enable, exact 16 MiB raw image-type storage and 32 MiB snapshot aggregate, rejects oversized local image cache. No system clipboard read/write, no image decoding. Python requires four exact markers; original real TLS clipboard test unchanged. These local tests are not yet full cross-session wire isolation or malformed-wire regression. Await CI.

CI #45554812412: Core success; App preparation failed on CSSession.m clipboard release replacement anchor, causing Generated.xcconfig missing in Release build. No runtime security result. Scope insertion to the named release callback and unique self declaration, preserve existing body, fail if callback boundaries/prologue missing. Add overlay unit coverage using pinned excerpts and a release-body variant with an intervening comment. All previous runtime gates unchanged. New CI pending.

## Two-session clipboard wire isolation

CI #45555868843 passes overlay regression, UTF-8 wire exchange, local invalid/oversize/disabled/generation/16 MiB item and 32 MiB snapshot gates, all earlier gates, 1128/1128 workspace draws and 0 final weak references. New independent two TLS main-channel fixtures use real SessionWorkspace (last tab selected), two production adapters sharing one unique named pasteboard. B exchanges distinct UTF-8 text first; A remains inactive for B exchange plus 3s hold while A sends grab/request/unsolicited data at 1s/1.2s/1.4s after caps. Board must retain B guest text; then select A and require distinct A host/guest exchange, keep B connected, verify cleanup. Per-fixture checks require exactly one client clipboard grab/request/data and matching text, A three attempted probes preceding first client grab, both single TLS mains. B is tested for outbound isolation after switch; not a full suite of late inbound B packets, all wire races, selection extension or oversized wire data. Timing based on bounded synthetic fixtures; if CI shows legitimate protocol housekeeping, inspect actual messages rather than relax blindly. Original gates retained; pending CI.

## Malformed clipboard payload wire regression

CI #45560266622 on 26aeb8a (automation MainActor cleanup fix) passes two-session isolation: role A three inactive probes then exactly 1 grab/request/data, role B exactly 1 grab/request/data; both expected UTF-8, 1091/1091 workspace draws, zero final weak controller/canvas. New independent agent-clipboard-invalid-full performs original bidirectional exchange, then fresh grab/request for each bounded malformed UTF-8 (C3 28), embedded NUL (x NUL y) and valid recovery string, spaced 2s apart. Named board client requires original valid text and unchanged changeCount until recovery, then recovered valid text and agent removal/cleanup. Server verifies three fresh requests/sends, Python validates exact ordered markers and TLS main. Existing single/multi clipboard and all other gates retained. This checks malformed text payloads, not malformed message framing, oversize network allocation or all switching races. Await CI.

## Delayed clipboard response after tab switch

CI #45562063123 passes bounded malformed UTF-8/embedded NUL wire test, exact 3 requests/sends and recovery, prior two-session isolation and all other gates; 1126/1126 workspace draws, zero final weak refs. Add independent late-reply isolation mode (original isolation retained). B first completes normal exchange, then sends another grab while active; actual second request must be logged before switching. Python creates request barrier from fixture log, app confirms barrier and switches to A, completes distinct A exchange, flushes A-ready marker; Python then opens send barrier to B. B sends valid delayed text and records VDI drain, Python opens delivered barrier. App requires A board value and changeCount unchanged during wait and 1s grace, both connections alive, normal close; Python requires exact ordered markers, both TLS mains and B request count 2 rather than 1, no extra client grab/data. Uses temporary test-only file barriers, not production IPC or system clipboard. VDI drain means server read, not proof client handler executed; grace is bounded. Does not yet cover reactivation of same B before its old reply, all queued outbound races, or oversized wire payloads. Await CI.

## Clipboard request epoch / reactivation

CI #45563633617 passed gated late reply while B inactive, B requested/sent/drained=1, B requests=2, 1116/1116 workspace draws, final weak refs zero. New CSSession overlay serializes app clipboard delegate/enabled updates on CSMain worker; increments epoch on activation/delegate changes and channel replacement/destruction. Outstanding request ledger keyed by clipboard type retains stale entries across tab activation; data consumes entry before validation, rejects missing/stale epochs, and queued request/notify recheck epoch/main/active. Copy signal-owned offered type array before dispatch (bounded 32) and ignore unknown types. Swift adapter uses new API; worker sync is safe only while callbacks do not synchronously wait on AppKit, existing pasteboard writes are async. Legacy protocol has no individual reply ID: if peer never returns a pending type, new same-type grabs remain blocked until reply or channel replacement, intentionally fail closed; cannot distinguish malicious duplicate from a later valid same-type response, nor all release/notification races. New independent gated B→A→B variant delivers B's old reply only after B reactivation, requires unchanged A board and count, both channels alive, existing server counts. Original background and invalid tests retained. No claims of complete race elimination or runtime success until CI. Oversize wire allocation and real OS still untested.

## Bounded large clipboard wire regression

CI #45578291591 on 593e6af passed gated B→A→B reactivation (old reply preserved A board/count), original clipboard/invalid/isolation and all workspace gates, 1122/1122 QXL draws and zero final weak refs. Add independent agent-clipboard-bulk-full mode: initial valid exchange, fresh grab/request, fixed 16 MiB ASCII A, fresh grab/request, 16 MiB+1 ASCII B, fresh grab/request, small valid recovery. Server uses a bounded allocation of VDI chunks (VD_AGENT_MAX_DATA_SIZE) with one logical VDAgentMessage header, no arbitrary size input, logs exact sizes and full drains; frees buffer after drain or teardown. App checks exact boundary content, then only permits recovery (any unexpected changeCount/content fails); both use unique named board. Python requires all markers, sizes, 3 requests/sends, 2 drains, TLS main, agent removal. Original gates retained. This validates size policy at CocoaSpice/pasteboard boundary over network, not a strict bound on upstream spice-gtk reassembly allocations; spice-gtk max-clipboard property exists but its semantics do not establish a preallocation limit. No production change to that property in this commit. Fixed 35s synthetic agent lifetime; 42s app deadline, 50s process timeout. CI pending; bulk transport timing and real guest behavior not yet verified.

## Actual IOSurface / Metal scanout copy probe

CI #45581166202 on 53756a9 passed actual 16 MiB accepted / 16 MiB+1 rejected, 8193 VDI chunks each, 3 requests, 2 bulk drains, small-text recovery and all existing gates; 1100/1100 workspace draws, final weak refs zero. Add independent packaged-app scanout runtime probe using a real IOSurfaceCreate BGRA 64×64, unconnected isolated CSDisplay and real CSMetalRenderer command queue. Calls the patched production rebuildScanoutTextureWithSurface/copyScanoutRect/resetScanout, checks pre-fence texture nil, private storage/no IOSurface alias, first partial damage forces full copy, producer overwrites source after completion without changing shadow, second partial changes center only, reset while GPU copy pending prevents stale publication, invalid width rejected. GPU readback uses real blits to shared buffer and waits only in test helper; Python requires exact six markers, timeout 30s. Test uses no real server fd/IOSurface lookup, no gl_draw_done wire ack, no on-screen drawable; not a substitute for real UTM host/guest transport or PVE validation. Local test helper compiled into app, only explicit probe flag, no network connection. Await CI for SDK import/init/link and GPU runtime.

CI #45583565414 attempt 1: core success, app cancelled, log unavailable; retry attempt 2: core success, app compiled and all five scanout GPU markers (full/private/partial/stale/bounds) observed, but no final MRV_SCANOUT_RUNTIME_OK, stderr empty. Exact failing instruction not established; previous probe called Swift continuation created in MainActor from worker and tore down session while final copy callback still executing. Defer test teardown on CSMain worker (existing overlay uses explicit idle GSource), clear display reference, release independent IOSurface and session, dispatch completion on main queue; preserve all GPU checks and require explicit reset/surface/session/main completion markers, report subprocess exit code. Keep view/renderer alive until completion. No production scanout code changes this round, not proof of full cleanup until CI. Remaining multi/workspace gates were not executed in failed attempt 2 because test suite stops on first assertion; prior green run remains evidence only for prior HEAD.

## Scanout renderer queue transition / detached recovery

CI #45588355567 on 41fbd77 passed all ten scanout GPU/cleanup markers, both core/app, all prior regression gates; 1092/1092 workspace draws and zero final weak refs. Extend isolated IOSurface probe with two real CSMetalRenderer instances on the same device and distinct command queues. After first red/full and green/partial copies, retain old private texture, switch renderer array to replacement and fill source blue; small damage must force full blue copy into distinct private allocation while old texture retains green center/red exterior on original queue. Detach all renderers and require synchronous completion, no published texture/queue, full-copy recovery flag. Reattach original renderer, fill yellow; require distinct full-copy allocation and unchanged replacement blue texture. Original stale reset/invalid bounds/cleanup markers preserved, new three ordered markers required. Test manipulates isolated renderer array on worker, exercises production copyScanoutRect queue-change branch; does not test real UI attach/remove ordering, simultaneously in-flight old render passes, visible drawable or wire GL transport. No production behavior changes this round. Await CI.

## Scanout real Metal drawable presentation

CI #45590685855 on 190c202 passed 13 scanout markers (queue switch/no-renderer/recovery included), all prior regression gates, 1099/1099 workspace draws and zero final weak refs. Preserve headless scanout gate, add separate visible MTKView mode with 64×64 explicit drawable, BGRA8, framebuffer readback enabled, real renderer delegate. After queue recovery yellow shadow, prepare real CSDisplay vertices and invalidate via worker after installing one-shot smokeRegionHandler on main. Require actual drawable center+four exterior yellow pixels, then copy center blue patch and overwrite entire producer IOSurface red before presenting; require blue center/yellow exterior on actual drawable, then re-present same retained texture with no further source update and require same pixels. Callback arrives on main, posts next phase to worker; original stale fence/bounds/cleanup checks preserved. Python requires three extra markers in exact order and both separate modes; bounded process timeout. No production render behavior change, not actual host FD passing or gl_draw_done network handshake, not every in-flight queue race. Await CI.

## Final supply-chain evidence review (stage 1)

CI #45593321050 on 1d85659 passes both scanout modes including real drawable full/partial/private/refresh markers, all prior integration gates, 1122/1122 workspace draws, zero final weak refs. 60.632s soak CPU 4.96% of one core, RSS 423.64→443.55 MiB, after close 182.83 MiB; 4-round churn +2.72 MiB. Debug/Release ARM64 and ad-hoc DMG signature/embedded SBOM verified; direct lock spice-gtk 0.43_1, glib 2.90.1, gstreamer 1.28.9, CocoaSpice d8d29fc. 34 observed kegs OSV coverage complete per CI log, artifact 15013295173 exists, actual advisory IDs and notice inventory not visible in prior log; do not claim zero advisories. New audit verifier checks report hashes, exact observed keg identity set and statuses, complete flag derived from rows, notice archive inventory/path/hash and member set, prints per-keg IDs and missing notices plus summary. Preview preserves explicit incomplete scans, draft workflow additionally requires verified complete coverage plus existing reviewed_distribution human gate; matches still require applicability review, not automatic clearance. Unit regression tests reject missing rows, inconsistent status/coverage, modified notice content, and incomplete release scan. No release run, no version upgrades; does not cover static dependencies, all upstream vulnerabilities, notarization, licensing determination, or PVE runtime. Await CI and inspect actual emitted IDs/notice statuses before further review.

## Missing notice recovery (stage 2)

CI #45596255639 on ff7ea68 core/app green: 34 observed Homebrew kegs, complete OSV query, zero advisory IDs, 31 notice candidate sets, three missing glib 2.90.1/json-glib 1.10.8/sqlite 3.54.1; 1108/1108 workspace draws and zero final weak refs. Add fallback only for these three when local candidates absent, exact current homebrew/core stable version+revision match, approved GNOME/SQLite HTTPS hosts including redirects, checksum and bounded download, streaming tar member count/expansion/per-file limits, no extraction, ignore links/traversal. SQLite public-domain declaration header candidate (up to 4096 bytes) when found, not a synthetic license. Archive stores version/source URL+SHA metadata; verifier checks metadata and member provenance. Network/version/checksum failure remains explicit missing review. Unit tests exercise version mismatch, host rejection, tar link/traversal, SQLite header bounds, candidate ZIP and failed fallback. No dependency upgrade, no legal clearance, no release or project license choice. Current formula version match is not exact bottle build source/patch proof. Await CI.

## Notice directory fix and diagnostic file permissions (final review stage 1)

CI #45598768734 on 8ad59bb core/app green, 34 observed keg OSV queries complete, 0 IDs; GLib and SQLite source fallbacks verified with expected metadata, JSON-GLib source verified but no recognized candidates, 33/34 notice sets. Upstream GNOME/json-glib 1.10.8 tree exposes LICENSES/LGPL-2.1-or-later.txt, MIT.txt, CC0-1.0.txt; extend bounded source member selection to regular files under LICENSES directories, retaining traversal/link/size/count checks and test synthetic SPDX-named members. Actual tar content must still be verified by CI. 1122/1122 workspace draws, final weak refs zero, CPU 4.58% one core, churn +2.42 MiB. Reviewed diagnostics call sites: currently fixed messages and bounded resolution/timing/count values, no direct ticket/host log at inspected call sites. Found open(...,0600) only controls creation; existing readable legacy file can retain permissions. Tighten verified owned regular single-link active log via fchmod(0600), create new log directory 0700, reject final directory symlink/foreign owner/shared-write, refuse rotation of foreign-owned files, recheck directory before prune. Unit tests existing 0644 file, directory symlink and 0777 directory. Existing inactive rotated files are not retroactively chmodded; ACLs, intermediate symlinks, directory rename races/same-user adversary and multi-process rotation not fully addressed. No claim of full privacy or complete final review; next review test-only entry points and wire trust boundaries. No release or merge. Await CI.

## Final code audit: explicit integration-probe launch policy

CI #45601192954 on 4437e09 passes all gates, 34/34 observed keg notices, zero OSV IDs, glib/json-glib/sqlite source fallback checksums recorded, 1091/1091 workspace draws, zero final weak refs and +2.44 MiB churn. Review found packaged Release app previously selected probe mode whenever any argv element matched a flag. Preserve exact tested artifact but require `MRV_ENABLE_INTEGRATION_PROBES=1`, exactly one recognized mode as first argument and exact operand count; validate agent mode and reject empty/flag-like operands. Rejected launches exit 2 with a fixed marker before portable worker/window initialization or importing files; normal Finder launch unchanged. Core tests cover all 18 modes and malformed argv, actual copied DMG smoke runs five negative cases then existing positive smoke. Existing Python TLS/SPICE harnesses explicitly opt in. This is accidental invocation prevention, not an OS security boundary or removal of compiled probe code; existing loopback/synthetic ticket/clipboard guards retained. No dependency changes or distribution approval. Await CI.

## Final code audit: transport input boundaries

CI #45603971515 on e437877 ended with both jobs cancelled and no step metadata; no verified probe result or compiler failure. Last complete green HEAD remains 4437e09. Review found host only checked nonempty, proxy URL only checked scheme/host, and programmatically constructed profiles could bypass parser. Add shared transport checks at parser and SpiceEngineAdapter before native allocation/connection: reject post-INI control/whitespace and URL delimiters in host, zero TLS port, controls/empty ticket or certificate subject; restrict proxy to http/https CONNECT endpoint, empty/root path, no query/fragment, valid port when present, no decoded controls in user/password/host. Preserve direct hostnames, IPv4/IPv6 forms, spaces in certificate DN and percent-encoded proxy credential spaces; no changes to TLS trust, proxy credentials support, or DNS resolution. Add localized fixed errors without input echo and parser/native-boundary regression tests. This is not full host grammar validation or proof of native HTTP parser equivalence, and deliberately rejects multiline credentials/subjects and non-root proxy paths. Prior explicit launch tests retained; await combined CI. No merge or release.

## Transport validation compatibility regression fix

CI #45606948717 on d5b1ba1: App Debug/Release, copied-DMG MRV_PROBE_LAUNCH_GATE_OK, TLS/auth, both scanout modes, 34/34 notice candidates and zero OSV IDs passed; workspace 1105/1105 draws, final weak refs zero, +2.52 MiB churn. Core failed only testFormatSpecifiersInHostAreLiteral and testSpiceProxyURIHostUsesProxyIP (invalidHost). PVE proxy CONNECT destination is an opaque signed pseudo-host (Proxmox support forum thread 36577; PVE spiceproxy service); existing app recognizes pvespiceproxy: and legacy spiceproxy://. Permit only exact case-insensitive spiceproxy:// prefix with configured validated proxy and nonempty safe suffix, preserve original token byte-for-byte; normal host and proxy endpoint validation unchanged. Existing status tests retain assertions, format-specifier case constructs a UI-only profile to exercise literal interpolation separately; parser explicitly rejects that invalid host. Add positive/negative opaque-host tests including direct transport guard, missing proxy, unsafe suffix and control characters. No normalization of signed token and no claim of actual PVE wire compatibility until live PVE test. No credential lifecycle changes until combined CI green. Await CI.

## Final code audit: minimize retained transport credentials in UI

CI #45636470011 on cabf7c1 green core/app, probe launch gate OK, opaque PVE SPICE destination compatibility restored, 34 observed keg OSV no matches and 34 notice candidate sets, both scanout modes OK, 1123/1123 workspace draws, final weak refs zero, +2.83 MiB churn. Review found SessionController retained full ConnectionProfile even after failure/disconnect, although consumers only need title, filtered address, hotkeys and unknown field names. Replace stored profile type with SessionPresentationProfile containing only these display fields (no ticket, raw opaque destination, proxy URL, CA, subject or source path). Pass original profile directly to engine as before. Keep only pending eligible source identity privately until first success/cancel/fail/disconnect; preserve cleanup preference and existing identity checks through source-only overload. Update status view and add core tests for structural projection, unmodified credentials reaching mock engine, metadata preservation, and stale source cleanup rejection. This changes the public controller profile type; parser/engine ConnectionProfile unchanged. Arbitrary user-supplied title/field names may themselves contain secrets; this is data minimization, not a general sanitizer. Native spice-gtk may need credentials for subsequent channel authentication; do not clear them at Main Channel connect. Native teardown and byte-level zeroization remain unverified; Swift strings, parser temporaries and caller copies are not guaranteed wiped. No release or main merge. Await CI.


## Final code audit: isolate packaged GStreamer discovery

CI #45660904838 attempt 2 on a5610a0 passed core/app after the first app job was cancelled. UI credential projection validated; final workspace weak refs zero, churn +3.22 MiB. Review confirmed gst_init(NULL, NULL) runs on the CocoaSpice worker and versioned plugin environment paths take precedence. Packaged app now pins both system paths to bundle, clears both extra plugin paths, pins both scanner variables, uses fresh per-launch mkdtemp 0700 registry directory and 0600 cache, removes inherited registry/debug/tracer settings, checks failures before native startup and requires scanner during packaging. Local Xcode/Homebrew fallback remains. Normal termination and startup smoke remove temporary registry; abrupt termination and other explicit exit-based probes can leave private temporary files until OS cleanup. Startup probe joins worker, checks registry permissions, inspects actual GstRegistry plugin filenames with realpath and requires coreelements; DMG smoke adds a poisoned environment launch with harmless scanner trap and preexisting external cache, requires real registry marker and unchanged trap/cache. Not proof against a same-user attacker, tampered bundle, pre-main dynamic loader injection, all GStreamer extension variables, or full OpenSSL configuration/provider isolation. No production credential clearing change or release. Await CI.


## Final code audit: native terminal credential minimization

CI #45672292520 on 23a61e5 green core/app including MRV_GST_ENV_ISOLATION_OK; final workspace weak refs zero, churn +2.44 MiB. Review found Swift callback tasks intentionally retain originating CSConnection until identity fencing; native SpiceSession properties could outlive adapter reference. Add explicit terminal-only PVE disconnect on GLib worker, call spice_session_disconnect before clearing existing SpiceURI username/password in place and session password/host (PVE opaque signed token). Verify empty properties, keep only boolean in adapter, cover configure failure and immediate connect failure; preserve ordinary CocoaSpice disconnect API and retain live credentials for later channel auth. Existing actual loopback valid ticket three reconnects and wrong-ticket failure now require cleanup markers; each also configures a separate offline synthetic authenticated proxy, confirms credentials present then absent and repeated terminal cleanup works, no proxy connection. Overlay anchor tests require ordering and worker call count. This is property/reference minimization, not byte-level zeroization or proof of no copies in GSocketClient, TLS, migration sessions, Swift/GLib allocations, crash dumps or library logs; upstream source retrieval was unavailable, documented public API used and actual locked-library CI is required. No release or main merge. Await CI.


## Final code audit: portable OpenSSL configuration and provider provenance

CI #45675451790 on 01454f2 green core/app, actual MRV_NATIVE_CREDENTIAL_CLEANUP_OK valid-ticket and wrong-ticket; GStreamer isolation retained, final weak refs zero, churn +2.50 MiB. Observed OpenSSL keg openssl@3 3.5.9. Review found inherited OPENSSL_CONF/SSLKEYLOGFILE/trust variables and provider directory selected by unrelated opt aliases (including openssl@4). Packager derives provider directory from exactly one resolved libcrypto in actual Mach-O closure, rejects escaping paths and conflicting provider dependencies, seals a minimal no-includes configuration in signed app and always creates module directory. Packaged launch requires config/module directory, overrides config, include, provider and engine paths, clears selected tracing/keylog variables, and prevents ambient default trust path inheritance (explicit validated PVE CA unchanged). Local Xcode behavior unchanged. DMG verifier requires exact config bytes and directory; unit test covers matching keg, absent/ambiguous crypto and escaping module symlink. Original TLS tests retained; three additional actual TLS cases inject config with nonexistent provider selection, external module/engine paths, ambient trusted CA and SSLKEYLOGFILE; trusted link must work, wrong CA and subject must send no application bytes, no keylog file may appear. This is behavior validation after app startup, not a direct enumeration of loaded providers, proof of pre-main safety, FIPS validation or a complete security boundary against same-user/bundle tampering. Disables inherited enterprise OpenSSL config in packaged build by design; no dependency upgrade, main merge or release. Await CI.


## OpenSSL canonical path test compatibility

CI #45726921936 on d853d56: App green, actual MRV_OPENSSL_ENV_ISOLATION_OK with trusted poisoned config REDQ, wrong CA/subject no application data or plaintext, prior GStreamer/native credential gates passed, final weak refs zero, churn +2.42 MiB. Core failed one packaging assertion: production resolves /var to /private/var on macOS, fixture expected unnormalized path. Compare expected canonical path and add positive symlinked crypto directory alias regression; existing escape and ambiguous crypto rejection unchanged. No production modifications, no test removed. Await combined CI before new security changes. No merge/release.
