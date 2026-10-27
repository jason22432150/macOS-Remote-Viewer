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
