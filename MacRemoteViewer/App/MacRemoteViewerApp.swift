import AppKit
import SwiftUI
import MetalKit
import Darwin

@main
struct MacRemoteViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 單一 `Window`：Finder 雙擊不可再建 WindowGroup 場景。
        // 第二扇主窗會對同一 SPICE session 再掛 Metal renderer，畫面會黑掉或卡住。
        Window("Mac Remote Viewer", id: "main") {
            ContentView()
                .environment(appDelegate.model)
                .environment(appDelegate.model.settings)
                .environment(\.locale, appDelegate.model.settings.language.locale)
        }
        // Finder 開檔只走 AppDelegate；SwiftUI 若也收 external event 會重建 ContentView，
        // 第一個連線的 Metal renderer 會被卸掉，畫面卡住。
        .handlesExternalEvents(matching: [])
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.string(.openVVEllipsis, language: appDelegate.model.settings.language)) {
                    appDelegate.model.chooseFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu(L10n.string(.menuSession, language: appDelegate.model.settings.language)) {
                Button(L10n.string(.sendCtrlAltDel, language: appDelegate.model.settings.language)) {
                    appDelegate.model.session?.sendSecureAttention()
                }
                .disabled(appDelegate.model.session == nil)
                Button(L10n.string(.releasePointer, language: appDelegate.model.settings.language)) {
                    if let canvas = NSApp.keyWindow?.firstResponder as? RemoteCanvasView {
                        canvas.releaseCapture()
                    } else {
                        appDelegate.model.session?.releaseKeys()
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .environment(appDelegate.model.settings)
                .environment(\.locale, appDelegate.model.settings.language.locale)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let incomingFiles = IncomingURLBuffer()
    private var isWaitingToPresentMainWindow = false
    /// 已在畫面上、帶 Metal 的那扇主窗。關多餘窗時必須對這個物件，不可改選最前面那扇。
    private weak var keptMainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        preparePortableRuntime()
        NSWindow.allowsAutomaticWindowTabbing = false
        incomingFiles.setHandler { [model] urls in
            model.open(urls: urls)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        incomingFiles.handle(urls)
        presentMainWindowWhenReady()
        closeExtraMainWindowsAfterSceneUpdate()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        incomingFiles.handle([URL(fileURLWithPath: filename)])
        presentMainWindowWhenReady()
        closeExtraMainWindowsAfterSceneUpdate()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 安裝後立刻登錄文件類型，否則 Finder「打開方式」可能看不到這個 App。
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        presentMainWindowWhenReady()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--startup-smoke-test") {
            runStartupSmokeTest()
        } else if let index = arguments.firstIndex(of: "--loopback-tls-probe") {
            guard index + 1 < arguments.count else { Darwin.exit(2) }
            runLoopbackTLSProbe(file: URL(fileURLWithPath: arguments[index + 1]))
        } else if let index = arguments.firstIndex(of: "--loopback-spice-auth-probe") {
            guard index + 1 < arguments.count else { Darwin.exit(2) }
            runLoopbackSpiceAuthProbe(file: URL(fileURLWithPath: arguments[index + 1]))
        } else if let index = arguments.firstIndex(of: "--loopback-spice-display-probe") {
            guard index + 1 < arguments.count else { Darwin.exit(2) }
            runLoopbackSpiceDisplayProbe(file: URL(fileURLWithPath: arguments[index + 1]))
        } else if let index = arguments.firstIndex(of: "--loopback-spice-multi-probe") {
            guard arguments.count == index + 5 else { Darwin.exit(2) }
            runLoopbackSpiceMultiProbe(files: arguments[(index + 1)...].map {
                URL(fileURLWithPath: $0)
            })
        }
    }

    /// Four simultaneous real connections, one shared GPU device, four isolated canvases.
    /// All canvases remain visible in a test-only grid so a headless/occluded view
    /// cannot prevent the background rendering checks. No clipboard or guest input.
    private func runLoopbackSpiceMultiProbe(files: [URL]) {
        Task { @MainActor in
            let expected: [Set<UInt32>] = [
                [0xff0000, 0x00ff00], [0x0000ff, 0xffff00],
                [0x00ffff, 0xff00ff], [0xffffff, 0x808080],
            ]
            let rect = CGRect(x: 0, y: 0, width: 640, height: 480)
            let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            var controllers: [SessionController] = []
            var canvases: [RemoteCanvasView] = []
            var observed = Array(repeating: Set<UInt32>(), count: 4)
            var foreign = Set<Int>()
            var live = Set(0..<4)
            func cleanUp() {
                for canvas in canvases {
                    canvas.setSmokePixelHandler(nil)
                    canvas.prepareForRemoval()
                }
                for controller in controllers { controller.cancel() }
                window.orderOut(nil)
            }
            do {
                let profiles = try files.map { file in
                    let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                    let profile = try VVParser().parse(data: data)
                    guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                          profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile else {
                        throw SessionError.cancelled
                    }
                    return profile
                }
                guard profiles.count == 4, Set(profiles.map(\.tlsPort)).count == 4,
                      let device = MTLCreateSystemDefaultDevice() else {
                    throw SessionError.engineUnavailable
                }
                let grid = NSView(frame: rect)
                window.contentView = grid
                for i in 0..<4 {
                    let controller = SessionController(engine: SpiceEngineAdapter(),
                        connectionTimeout: .seconds(8), displayTimeout: .seconds(12))
                    controller.setClipboardSharingEnabled(false)
                    let canvas = RemoteCanvasView(
                        frame: CGRect(x: (i % 2) * 320, y: (i / 2) * 240, width: 320, height: 240),
                        device: device)
                    canvas.controller = controller
                    canvas.setActive(i == 0)
                    canvas.setupMetal()
                    canvas.setSmokePixelHandler { pixel in
                        let rgb = pixel & 0x00ffffff
                        // Initial empty black surfaces are allowed, but cannot
                        // satisfy either expected color. Any foreign color fails.
                        if expected[i].contains(rgb) { observed[i].insert(rgb) }
                        else if rgb != 0 {
                            if foreign.insert(i).inserted {
                                print("MRV_MULTI_FOREIGN session=\(i) rgb=\(String(rgb, radix: 16))")
                            }
                        }
                    }
                    grid.addSubview(canvas)
                    controllers.append(controller)
                    canvases.append(canvas)
                }
                window.makeKeyAndOrderFront(nil)
                // Open all four before yielding to the main actor.
                for i in 0..<4 { controllers[i].open(profiles[i]) }

                func validatePhase(active: Int) async throws {
                    for i in live { canvases[i].setActive(i == active) }
                    // Reset observations for each phase: require fresh draws, not
                    // cached success from the previous foreground selection.
                    for i in live { observed[i].removeAll() }
                    let deadline = ContinuousClock.now + .seconds(12)
                    while ContinuousClock.now < deadline {
                        guard foreign.isEmpty else { throw SessionError.unknown(code: "foreign-color") }
                        for i in live {
                            let controller = controllers[i]
                            if case .failed = controller.state { throw SessionError.network }
                            if controller.state == .disconnected { throw SessionError.disconnected }
                            canvases[i].attachRendererIfNeeded()
                            canvases[i].updateViewport()
                        }
                        if live.allSatisfy({ i in
                            controllers[i].state == .connected &&
                            controllers[i].displaySize == RemoteFrame(width: 640, height: 480) &&
                            controllers[i].hasRenderedFrame && observed[i] == expected[i] &&
                            canvases[i].preferredFramesPerSecond == (i == active ? 60 : 15)
                        }) { return }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    for i in live.sorted() {
                        print("MRV_MULTI_DIAGNOSTIC session=\(i) connected=\(controllers[i].state == .connected) rendered=\(controllers[i].hasRenderedFrame) samples=\(observed[i].count)")
                    }
                    throw SessionError.displayTimeout
                }

                for active in 0..<4 {
                    try await validatePhase(active: active)
                    print("MRV_MULTI_PHASE_OK active=\(active) live=4 targets=60,15")
                }
                // Disconnect one renderer while the remaining three continue.
                canvases[1].setSmokePixelHandler(nil)
                canvases[1].prepareForRemoval()
                canvases[1].removeFromSuperview()
                controllers[1].cancel()
                live.remove(1)
                try await validatePhase(active: 2)
                guard controllers[1].state == .disconnected,
                      controllers[1].displaySize == nil, !controllers[1].hasRenderedFrame,
                      foreign.isEmpty else { throw SessionError.cancelled }
                print("MRV_MULTI_CLOSE_OK live=3")
                for i in 0..<4 {
                    if let elapsed = controllers[i].firstFrameMilliseconds {
                        print("MRV_MULTI_FIRST_FRAME session=\(i) ms=\(elapsed)")
                    }
                }
                cleanUp()
                print("MRV_MULTI_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                cleanUp()
                print("MRV_MULTI_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    /// Exercise actual display callbacks and Metal completion using the production canvas.
    private func runLoopbackSpiceDisplayProbe(file: URL) {
        Task { @MainActor in
            let engine = SpiceEngineAdapter()
            let controller = SessionController(engine: engine,
                connectionTimeout: .seconds(8), displayTimeout: .seconds(12))
            let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            do {
                let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                let profile = try VVParser().parse(data: data)
                guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                      profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile,
                      let device = MTLCreateSystemDefaultDevice() else {
                    throw SessionError.cancelled
                }
                controller.setClipboardSharingEnabled(false)
                let canvas = RemoteCanvasView(frame: frame, device: device)
                canvas.controller = controller
                canvas.setupMetal()
                window.contentView = canvas
                window.makeKeyAndOrderFront(nil)
                for round in 0..<2 {
                    var colors = Set<UInt32>()
                    canvas.setSmokePixelHandler { pixel in
                        let rgb = pixel & 0x00ffffff
                        if colors.count < 16 && colors.insert(rgb).inserted {
                            print("MRV_PIXEL_SAMPLE round=\(round + 1) rgb=\(String(rgb, radix: 16))")
                        }
                    }
                    controller.open(profile)
                    let deadline = ContinuousClock.now + .seconds(15)
                    while ContinuousClock.now < deadline {
                        if case .failed = controller.state { throw SessionError.network }
                        if controller.state == .disconnected { throw SessionError.disconnected }
                        canvas.attachRendererIfNeeded()
                        canvas.updateViewport()
                        if controller.state == .connected,
                           controller.displaySize == RemoteFrame(width: 640, height: 480),
                           controller.hasRenderedFrame, colors.contains(0x00ff0000),
                           colors.contains(0x0000ff00) { break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard controller.state == .connected,
                          controller.displaySize == RemoteFrame(width: 640, height: 480),
                          controller.hasRenderedFrame, let elapsed = controller.firstFrameMilliseconds,
                          colors.contains(0x00ff0000), colors.contains(0x0000ff00) else {
                        print("MRV_DISPLAY_DIAGNOSTIC connected=\(controller.state == .connected) display=\(controller.displaySize != nil) rendered=\(controller.hasRenderedFrame) samples=\(colors.count)")
                        throw SessionError.displayTimeout
                    }
                    print("MRV_SPICE_DISPLAY_ROUND_OK \(round + 1) 640x480 first-frame-ms=\(elapsed) pixels=red,green")
                    canvas.setSmokePixelHandler(nil)
                    controller.cancel()
                    try await Task.sleep(for: .milliseconds(200))
                    guard controller.state == .disconnected, !controller.hasRenderedFrame,
                          controller.displaySize == nil else { throw SessionError.cancelled }
                }
                canvas.prepareForRemoval()
                window.orderOut(nil)
                print("MRV_SPICE_DISPLAY_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                controller.cancel()
                window.orderOut(nil)
                print("MRV_SPICE_DISPLAY_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    /// A real SPICE server supplies the main channel, not a guest display.
    /// Reuse the same engine/controller to exercise disconnect and reconnect.
    private func runLoopbackSpiceAuthProbe(file: URL) {
        Task { @MainActor in
            let engine = SpiceEngineAdapter()
            let controller = SessionController(engine: engine,
                connectionTimeout: .seconds(8), displayTimeout: .seconds(10))
            do {
                let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                let profile = try VVParser().parse(data: data)
                guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                      profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile else {
                    throw SessionError.cancelled
                }
                controller.setClipboardSharingEnabled(false)
                for round in 0..<3 {
                    controller.open(profile)
                    let deadline = ContinuousClock.now + .seconds(10)
                    while controller.state == .connecting && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    if case .failed(.authenticationRejected) = controller.state, round == 0 {
                        controller.cancel()
                        print("MRV_SPICE_AUTH_REJECTED")
                        fflush(nil)
                        Darwin.exit(0)
                    }
                    guard controller.state == .connected else { throw SessionError.network }
                    // Allow initial main-channel messages to run before cancelling.
                    try await Task.sleep(for: .milliseconds(150))
                    guard controller.state == .connected else { throw SessionError.network }
                    controller.cancel()
                    guard controller.state == .disconnected else { throw SessionError.cancelled }
                    // Drain callbacks from the old connection before opening again.
                    try await Task.sleep(for: .milliseconds(150))
                    guard controller.state == .disconnected else { throw SessionError.cancelled }
                    print("MRV_SPICE_AUTH_ROUND_OK \(round + 1)")
                }
                print("MRV_SPICE_AUTH_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                controller.cancel()
                print("MRV_SPICE_AUTH_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    /// Integration-only probe. Restrict it to a synthetic loopback profile; never
    /// send a real PVE ticket or enable clipboard, source deletion or a proxy.
    private func runLoopbackTLSProbe(file: URL) {
        Task { @MainActor in
            let engine = SpiceEngineAdapter()
            let controller = SessionController(engine: engine, connectionTimeout: .seconds(12))
            do {
                let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                let profile = try VVParser().parse(data: data)
                guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                      profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile else {
                    throw SessionError.cancelled
                }
                controller.setClipboardSharingEnabled(false)
                controller.open(profile)
                let deadline = ContinuousClock.now + .seconds(15)
                while ContinuousClock.now < deadline {
                    switch controller.state {
                    case .failed(let error):
                        // Do not expose certificate contents, credentials or raw library messages.
                        print(error == .tls ? "MRV_TLS_PROBE_REJECTED_TLS" : "MRV_TLS_PROBE_TERMINAL")
                        controller.cancel()
                        fflush(nil)
                        Darwin.exit(0)
                    case .disconnected:
                        controller.cancel()
                        print("MRV_TLS_PROBE_TERMINAL")
                        fflush(nil)
                        Darwin.exit(0)
                    case .connected:
                        // The fixture implements TLS and observes the link header only.
                        throw SessionError.unknown(code: "unexpected-connected")
                    default:
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                throw SessionError.network
            } catch {
                controller.cancel()
                print("MRV_TLS_PROBE_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    /// Explicit test mode only. No .vv, credentials, network connection or guest input.
    private func runStartupSmokeTest() {
        Task { @MainActor in
            do {
                guard let device = MTLCreateSystemDefaultDevice(),
                      device.makeCommandQueue() != nil else {
                    throw SessionError.engineUnavailable
                }
                let engine = SpiceEngineAdapter()
                try engine.startWorker()
                // Let SwiftUI create and present its main scene before reporting success.
                let deadline = ContinuousClock.now + .seconds(10)
                while !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
                    guard ContinuousClock.now < deadline else {
                        throw SessionError.engineUnavailable
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                // A distinct, machine-readable sentinel, emitted only after all checks.
                print("MRV_STARTUP_SMOKE_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                print("MRV_STARTUP_SMOKE_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        presentMainWindowWhenReady()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 開檔回呼可能早於 SwiftUI 建立視窗；沒有可顯示視窗時下一輪再試。
    /// `application(_:open:)` 與 `didFinishLaunching` 會連續觸發，合併成一次 retry。
    private func presentMainWindowWhenReady() {
        let first = presentAndRememberMainWindow()
        guard WindowPresentationPolicy.shouldRetryAfterSceneReady(first) else { return }
        guard !isWaitingToPresentMainWindow else { return }
        isWaitingToPresentMainWindow = true
        DispatchQueue.main.async { [self] in
            isWaitingToPresentMainWindow = false
            _ = presentAndRememberMainWindow()
        }
    }

    /// `Window(id:)` 仍可能在開檔回呼之後才插入多餘主窗；延後一到兩輪再關。
    private func closeExtraMainWindowsAfterSceneUpdate() {
        DispatchQueue.main.async { [self] in
            logWindowOutcome(
                AppWindowPresenter.closeExtraMainWindows(
                    application: NSApp,
                    keeping: keptMainWindow
                )
            )
            DispatchQueue.main.async { [self] in
                logWindowOutcome(
                    AppWindowPresenter.closeExtraMainWindows(
                        application: NSApp,
                        keeping: keptMainWindow
                    )
                )
            }
        }
    }

    @discardableResult
    private func presentAndRememberMainWindow() -> WindowPresentationAction {
        let outcome = AppWindowPresenter.present(application: NSApp, keeping: keptMainWindow)
        keptMainWindow = outcome.keptWindow
        logWindowOutcome(outcome)
        return outcome.action
    }

    private func logWindowOutcome(_ outcome: WindowPresentationOutcome) {
        guard outcome.windowCount > 1 || outcome.extraClosedCount > 0 else { return }
        model.settings.fileLog.write(
            level: "INFO",
            message: "window-present count=\(outcome.windowCount) extras-closed=\(outcome.extraClosedCount) remembered=\(outcome.keptWindow != nil)",
            sessionID: "window"
        )
    }
}

/// 前景決策後要記住哪扇主窗，以及關掉了幾扇多餘窗。
struct WindowPresentationOutcome {
    let action: WindowPresentationAction
    let keptWindow: NSWindow?
    let windowCount: Int
    let extraClosedCount: Int
}

/// 把主視窗叫到前景。雙擊 `.vv` 時 Finder 仍可能保持 active。
@MainActor
enum AppWindowPresenter {
    @discardableResult
    static func present(
        application: NSApplication,
        keeping keptWindow: NSWindow?
    ) -> WindowPresentationOutcome {
        let windows = application.windows
        let candidates = windows.map(candidate(from:))
        let action = WindowPresentationPolicy.action(for: candidates)
        activate(application)
        switch action {
        case .none:
            break
        case .orderFront(let index):
            windows[index].makeKeyAndOrderFront(nil)
        case .deminiaturizeAndOrderFront(let index):
            windows[index].deminiaturize(nil)
            windows[index].makeKeyAndOrderFront(nil)
        }
        return closeExtraMainWindows(
            windows: windows,
            candidates: candidates,
            action: action,
            keeping: keptWindow
        )
    }

    static func closeExtraMainWindows(
        application: NSApplication,
        keeping keptWindow: NSWindow?
    ) -> WindowPresentationOutcome {
        let windows = application.windows
        let candidates = windows.map(candidate(from:))
        return closeExtraMainWindows(
            windows: windows,
            candidates: candidates,
            action: WindowPresentationPolicy.action(for: candidates),
            keeping: keptWindow
        )
    }

    private static func closeExtraMainWindows(
        windows: [NSWindow],
        candidates: [WindowPresentationCandidate],
        action: WindowPresentationAction,
        keeping keptWindow: NSWindow?
    ) -> WindowPresentationOutcome {
        let rememberedIndex = keptWindow.flatMap { kept in
            windows.firstIndex(where: { $0 === kept })
        }
        let keptIndex = WindowPresentationPolicy.keptIndexForClosingExtras(
            rememberedIndex: rememberedIndex,
            action: action
        )
        var extraClosedCount = 0
        if let keptIndex {
            for index in WindowPresentationPolicy.extraMainWindowIndices(in: candidates, keptIndex: keptIndex) {
                windows[index].close()
                extraClosedCount += 1
            }
        }
        let nextKept: NSWindow?
        if let keptIndex {
            nextKept = windows[keptIndex]
        } else {
            nextKept = keptWindow
        }
        return WindowPresentationOutcome(
            action: action,
            keptWindow: nextKept,
            windowCount: windows.count,
            extraClosedCount: extraClosedCount
        )
    }

    private static func candidate(from window: NSWindow) -> WindowPresentationCandidate {
        WindowPresentationCandidate(
            canBecomeMain: window.canBecomeMain,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isPanel: window is NSPanel
                || window.styleMask.contains(.utilityWindow)
                || window.styleMask.contains(.nonactivatingPanel)
        )
    }

    private static func activate(_ application: NSApplication) {
        application.unhide(nil)
        // Finder 用文件啟動時，無參數的 `activate()` 不會搶前景。
        application.activate(ignoringOtherApps: true)
    }
}

/// 在 `gst_init` 之前設定可攜 runtime 路徑。
/// 打包後的 App 使用 bundle 內 plugin／OpenSSL modules；本機 Xcode 執行才退回 Homebrew。
private func preparePortableRuntime() {
    let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let fileManager = FileManager.default
    let gstPlugins = contents.appendingPathComponent("Resources/gstreamer-1.0", isDirectory: true)
    let scanner = contents.appendingPathComponent("MacOS/gst-plugin-scanner")
    let opensslModules = contents.appendingPathComponent("Resources/ossl-modules", isDirectory: true)

    if fileManager.fileExists(atPath: gstPlugins.path) {
        setenv("GST_PLUGIN_SYSTEM_PATH", gstPlugins.path, 1)
        setenv("GST_PLUGIN_PATH", gstPlugins.path, 1)
    } else if getenv("GST_PLUGIN_PATH") == nil {
        let homebrewPlugins = [
            "/opt/homebrew/lib/gstreamer-1.0",
            "/usr/local/lib/gstreamer-1.0",
        ]
        for path in homebrewPlugins where fileManager.fileExists(atPath: path) {
            setenv("GST_PLUGIN_PATH", path, 0)
            setenv("GST_PLUGIN_SYSTEM_PATH", path, 0)
            break
        }
    }

    if fileManager.fileExists(atPath: scanner.path) {
        setenv("GST_PLUGIN_SCANNER", scanner.path, 1)
    }

    if fileManager.fileExists(atPath: opensslModules.path) {
        setenv("OPENSSL_MODULES", opensslModules.path, 1)
    }
}
