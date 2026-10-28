import AppKit
import SwiftUI

@main
struct MacRemoteViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.model)
                .environment(appDelegate.model.settings)
                .environment(\.locale, appDelegate.model.settings.language.locale)
                // 已開啟的視窗優先收下 Finder 事件，避免再拆一扇新窗。
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        // `*`：冷啟動雙擊 `.vv` 時仍要建立／顯示 WindowGroup。
        // 空集合會讓 SwiftUI 認為沒有 scene 要處理開檔，App 只出現在 Dock。
        .handlesExternalEvents(matching: ["*"])
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        preparePortableRuntime()
        incomingFiles.setHandler { [model] urls in
            model.open(urls: urls)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        incomingFiles.handle(urls)
        presentMainWindowWhenReady()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        incomingFiles.handle([URL(fileURLWithPath: filename)])
        presentMainWindowWhenReady()
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
        let first = AppWindowPresenter.present(application: NSApp)
        guard WindowPresentationPolicy.shouldRetryAfterSceneReady(first) else { return }
        guard !isWaitingToPresentMainWindow else { return }
        isWaitingToPresentMainWindow = true
        DispatchQueue.main.async { [self] in
            isWaitingToPresentMainWindow = false
            _ = AppWindowPresenter.present(application: NSApp)
        }
    }
}

/// 把主視窗叫到前景。雙擊 `.vv` 時 Finder 仍可能保持 active。
@MainActor
enum AppWindowPresenter {
    @discardableResult
    static func present(application: NSApplication) -> WindowPresentationAction {
        let windows = application.windows
        let action = WindowPresentationPolicy.action(for: windows.map(candidate(from:)))
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
        return action
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
