import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var router = InputRouter()

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                WelcomeView()
            } else {
                sessionWorkspace
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .onAppear { syncMouseInput() }
        // 監看整包 preferences，之後新增滑鼠相關欄位時不必再漏接 onChange。
        .onChange(of: model.settings.preferences) { _, _ in
            syncMouseInput()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.releaseKeysOnAll()
        }
    }

    /// 所有仍連線的 Metal 畫面都留在視窗裡，只用 zIndex 蓋住背景分頁。
    /// 不可用 `.id`／opacity 卸載畫面：CocoaSpice 會因此卡住共用 spice thread。
    private var sessionWorkspace: some View {
        VStack(spacing: 0) {
            if model.showsTabBar {
                SessionTabBar()
            }
            if let error = model.welcomeError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(error.userMessage(language: model.settings.language))
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    Button {
                        model.welcomeError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string(.close, language: model.settings.language))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            ZStack {
                ForEach(model.sessions) { session in
                    RemoteSessionView(
                        controller: session,
                        router: router,
                        isActive: session.sessionID == model.selectedSessionID
                    )
                    .zIndex(session.sessionID == model.selectedSessionID ? 1 : 0)
                    .allowsHitTesting(session.sessionID == model.selectedSessionID)
                }
            }
        }
    }

    private func syncMouseInput() {
        let preferences = model.settings.preferences
        router.invertScrollWheel = preferences.invertScrollWheel
        router.mouseWheelSensitivity = preferences.mouseWheelSensitivity
        router.trackpadScrollSensitivity = preferences.trackpadScrollSensitivity
        router.sideButton4 = preferences.sideButton4
        router.sideButton5 = preferences.sideButton5
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

/// 兩個以上連線時顯示的分頁列；關閉分頁不會動到其他連線。
struct SessionTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.sessions) { session in
                SessionTabItem(
                    title: SessionTabPolicy.tabTitle(
                        profileTitle: session.profile?.title ?? "",
                        fallback: "SPICE"
                    ),
                    isSelected: session.sessionID == model.selectedSessionID,
                    language: model.settings.language,
                    onSelect: { model.selectSession(session.sessionID) },
                    onClose: { model.closeSession(session.sessionID) }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

private struct SessionTabItem: View {
    let title: String
    let isSelected: Bool
    let language: AppLanguage
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(title, action: onSelect)
                .buttonStyle(.plain)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help(L10n.string(.close, language: language))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.clear)
        )
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let language = model.settings.language
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
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
