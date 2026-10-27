import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MacRemoteViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(model.settings)
                .environment(\.locale, model.settings.language.locale)
                .onAppear { appDelegate.model = model }
                .onOpenURL { url in
                    model.open(urls: [url])
                }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.string(.openVVEllipsis, language: model.settings.language)) {
                    model.chooseFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu(L10n.string(.menuSession, language: model.settings.language)) {
                Button(L10n.string(.sendCtrlAltDel, language: model.settings.language)) {
                    model.session?.sendSecureAttention()
                }
                .disabled(model.session == nil)
                Button(L10n.string(.releasePointer, language: model.settings.language)) {
                    model.session?.releaseKeys()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.settings)
                .environment(\.locale, model.settings.language.locale)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        preparePortableRuntime()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model?.open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
