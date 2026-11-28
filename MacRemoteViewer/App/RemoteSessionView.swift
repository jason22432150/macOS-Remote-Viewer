import SwiftUI

struct RemoteSessionView: View {
    @Environment(AppModel.self) private var model
    var controller: SessionController
    @State private var router = InputRouter()
    var isActive: Bool = true

    private var language: AppLanguage { model.settings.language }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                RemoteDisplayView(
                    controller: controller,
                    router: router,
                    displaySize: controller.displaySize,
                    isActive: isActive,
                    useNativeDisplayPixels: model.settings.preferences.useNativeDisplayPixels,
                    relativeMouseRequested: controller.relativeMouseRequested,
                    sessionConnected: controller.state == .connected
                )
                    .background(Color.black)
                if showsOverlay {
                    overlay
                }
            }
            statusBar
        }
        .navigationTitle(controller.profile?.title ?? "SPICE")
        .onAppear { syncMouseInput() }
        .onChange(of: model.settings.preferences) { _, _ in syncMouseInput() }
    }

    private func syncMouseInput() {
        let preferences = model.settings.preferences
        router.invertScrollWheel = preferences.invertScrollWheel
        router.horizontalScrollCompatibility = preferences.horizontalScrollCompatibility
        router.mouseWheelSensitivity = preferences.mouseWheelSensitivity
        router.trackpadScrollSensitivity = preferences.trackpadScrollSensitivity
        router.sideButton4 = preferences.sideButton4
        router.sideButton5 = preferences.sideButton5
    }

    private var showsOverlay: Bool {
        switch controller.state {
        case .connected:
            return false
        default:
            return true
        }
    }

    private var toolbar: some View {
        HStack {
            Button(L10n.string(.close, language: language)) { model.closeSession(controller.sessionID) }
            Spacer()
            Button(L10n.string(.ctrlAltDel, language: language)) { controller.sendSecureAttention() }
                .disabled(controller.state != .connected)
            Button(L10n.string(controller.relativeMouseRequested ? .relativeMouseOff : .relativeMouseOn, language: language)) {
                controller.setRelativeMouseMode(!controller.relativeMouseRequested)
            }
            .disabled(controller.state != .connected)
            .help(L10n.string(.relativeMouseHelp, language: language))
            Button(L10n.string(.fullscreen, language: language)) { NSApp.keyWindow?.toggleFullScreen(nil) }
        }
        .padding(8)
    }

    private var overlay: some View {
        VStack(spacing: 12) {
            switch controller.state {
            case .connecting:
                ProgressView()
                Text(L10n.string(.connectingEllipsis, language: language))
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(error.userMessage(language: language))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                recoveryControls
                Button(L10n.string(.back, language: language)) { model.closeSession(controller.sessionID) }
            case .disconnecting, .disconnected:
                Text(L10n.string(controller.state == .disconnecting ? .statusDisconnecting : .disconnected,
                                 language: language))
                recoveryControls
                Button(L10n.string(.back, language: language)) { model.closeSession(controller.sessionID) }
            default:
                EmptyView()
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var recoveryControls: some View {
        if controller.state.canOpenFreshConnectionFile {
            Text(L10n.string(.freshConnectionHint, language: language))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(L10n.string(.openNewVV, language: language)) {
                model.chooseRecoveryFile()
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(statusText)
            if let remoteIP = SessionStatusText.remoteIP(fromPresentation: controller.profile, language: language) {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(remoteIP)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if let names = controller.profile?.unknownFieldNames, !names.isEmpty {
                Text(L10n.string(.ignoredFieldCount, language: language, String(names.count)))
                    .foregroundStyle(.secondary)
            }
            if let milliseconds = controller.firstFrameMilliseconds {
                Text("\(L10n.string(.firstFrame, language: language)): \(milliseconds) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if controller.firstFrameDelayed {
                Text(L10n.string(.firstFrameDelayed, language: language)).foregroundStyle(.orange)
            } else if controller.state == .connected {
                Text(L10n.string(.waitingFirstFrame, language: language)).foregroundStyle(.secondary)
            }
            if let frame = controller.displaySize {
                Text("\(frame.width)×\(frame.height)")
                    .monospacedDigit()
            }
            if !controller.agent.isConnected {
                Text(L10n.string(.noGuestAgent, language: language)).foregroundStyle(.orange)
            } else if !controller.agent.supportsMonitorsConfig {
                Text(L10n.string(.cannotAdjustResolution, language: language)).foregroundStyle(.orange)
            } else if controller.guestDidNotApplyResolution {
                Text(L10n.string(.guestDidNotApplyResolution, language: language)).foregroundStyle(.orange)
            } else if !controller.agent.supportsClipboard {
                Text(L10n.string(.clipboardUnavailable, language: language)).foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch controller.state {
        case .idle: return L10n.string(.statusIdle, language: language)
        case .parsing: return L10n.string(.statusParsing, language: language)
        case .connecting: return L10n.string(.statusConnecting, language: language)
        case .connected: return L10n.string(.statusConnected, language: language)
        case .disconnecting: return L10n.string(.statusDisconnecting, language: language)
        case .disconnected: return L10n.string(.statusDisconnected, language: language)
        case .failed: return L10n.string(.statusFailed, language: language)
        }
    }
}
