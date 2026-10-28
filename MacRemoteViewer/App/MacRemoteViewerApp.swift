import AppKit
import SwiftUI

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
                    appDelegate.model.session?.releaseKeys()
                    NSApp.keyWindow?.makeFirstResponder(nil)
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
