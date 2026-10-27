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
        .onAppear { syncScrollWheel() }
        .onChange(of: model.settings.preferences.scrollWheelDirection) { _, _ in
            syncScrollWheel()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.session?.releaseKeys()
        }
    }

    private func syncScrollWheel() {
        router.invertScrollWheel = model.settings.preferences.invertScrollWheel
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
        let language = model.settings.language
        VStack(spacing: 20) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Mac Remote Viewer")
                .font(.largeTitle.weight(.semibold))
            Text(L10n.string(.welcomeSubtitle, language: language))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button(L10n.string(.openVVEllipsis, language: language)) {
                model.chooseFile()
            }
            .keyboardShortcut(.defaultAction)
            if let error = model.welcomeError {
                Text(error.userMessage(language: language))
                    .foregroundStyle(.red)
                    .frame(maxWidth: 480)
            }
            Text(L10n.string(.welcomeLimitation, language: language))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
