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
        prepareHomebrewGStreamerPlugins()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model?.open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// 原型：動態 GStreamer 需要找得到 Homebrew plugin。發布版不得依賴此路徑。
private func prepareHomebrewGStreamerPlugins() {
    guard getenv("GST_PLUGIN_PATH") == nil else { return }
    let candidates = [
        "/opt/homebrew/lib/gstreamer-1.0",
        "/usr/local/lib/gstreamer-1.0",
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        setenv("GST_PLUGIN_PATH", path, 0)
        setenv("GST_PLUGIN_SYSTEM_PATH", path, 0)
        return
    }
}
