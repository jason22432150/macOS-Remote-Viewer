import SwiftUI

struct RemoteSessionView: View {
    @Environment(AppModel.self) private var model
    var controller: SessionController
    var router: InputRouter

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                RemoteDisplayView(controller: controller, router: router)
                    .background(Color.black)
                if showsOverlay {
                    overlay
                }
            }
            statusBar
        }
        .navigationTitle(controller.profile?.title ?? "SPICE")
        .onChange(of: controller.agent.supportsClipboard) { _, supports in
            if supports {
                model.clipboardTransportSync(controller)
            }
        }
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
            Button("關閉") { model.closeSession() }
            Spacer()
            Button("傳送文字") {
                Task { await controller.clipboard.sendLocalTextManually() }
            }
            Button("取得文字") {
                Task { await controller.clipboard.fetchRemoteTextManually() }
            }
            Picker("剪貼簿", selection: Binding(
                get: { model.clipboardMode },
                set: { model.applyClipboardMode($0) }
            )) {
                Text("關閉").tag(ClipboardMode.off)
                Text("手動").tag(ClipboardMode.manual)
                Text("自動").tag(ClipboardMode.automatic)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            Button("Ctrl+Alt+Del") { controller.sendSecureAttention() }
            Button("全螢幕") { NSApp.keyWindow?.toggleFullScreen(nil) }
        }
        .padding(8)
    }

    private var overlay: some View {
        VStack(spacing: 12) {
            switch controller.state {
            case .connecting:
                ProgressView()
                Text("連線中…")
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(error.userMessage)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if error.isRetryableWithNewFile {
                    Button("開啟新的 .vv") { model.chooseFile() }
                }
                Button("返回") { model.closeSession() }
            case .disconnecting, .disconnected:
                Text("已斷線")
                Button("返回") { model.closeSession() }
            default:
                EmptyView()
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusBar: some View {
        HStack {
            Text(statusText)
            Spacer()
            if let hint = controller.unknownFieldHint {
                Text(hint).foregroundStyle(.secondary)
            }
            if !controller.agent.isConnected {
                Text("無 guest agent").foregroundStyle(.orange)
            } else if !controller.agent.supportsClipboard {
                Text("剪貼簿不可用").foregroundStyle(.orange)
            }
            if let error = controller.clipboard.lastError {
                Text(error.userMessage).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch controller.state {
        case .idle: return "待命"
        case .parsing: return "解析連線檔"
        case .connecting: return "連線中"
        case .connected: return "已連線"
        case .disconnecting: return "中斷中"
        case .disconnected: return "已斷線"
        case .failed: return "失敗"
        }
    }
}

private extension AppModel {
    func clipboardTransportSync(_ controller: SessionController) {
        controller.clipboard.isWindowActive = true
    }
}
