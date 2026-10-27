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
                .onAppear { appDelegate.model = model }
                .onOpenURL { url in
                    model.open(urls: [url])
                }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("開啟 .vv…") {
                    model.chooseFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("傳送 Ctrl+Alt+Del") {
                    model.session?.sendSecureAttention()
                }
                .disabled(model.session == nil)
                Button("釋放滑鼠／鍵盤") {
                    model.session?.releaseKeys()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                Divider()
                Button("傳送本機文字剪貼簿") {
                    Task { await model.session?.clipboard.sendLocalTextManually() }
                }
                .disabled(model.clipboardMode == .off)
                Button("取得遠端文字剪貼簿") {
                    Task { await model.session?.clipboard.fetchRemoteTextManually() }
                }
                .disabled(model.clipboardMode == .off)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func application(_ application: NSApplication, open urls: [URL]) {
        model?.open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
