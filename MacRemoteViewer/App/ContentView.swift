import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var router = InputRouter()

    var body: some View {
        Group {
            if let session = model.session {
                RemoteSessionView(controller: session, router: router)
            } else {
                WelcomeView()
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.session?.clipboard.isWindowActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.session?.releaseKeys()
            model.session?.clipboard.isWindowActive = false
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    model.open(urls: [url])
                }
            }
        }
        return true
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Mac Remote Viewer")
                .font(.largeTitle.weight(.semibold))
            Text("雙擊或拖入 PVE 下載的 .vv 連線檔，即可開啟 SPICE 遠端畫面。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("開啟 .vv…") {
                model.chooseFile()
            }
            .keyboardShortcut(.defaultAction)
            if let error = model.welcomeError {
                Text(error.userMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 480)
            }
            Text("第一版僅支援 SPICE + TLS。票證過期時請重新從 PVE 下載，不會自動更新。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
