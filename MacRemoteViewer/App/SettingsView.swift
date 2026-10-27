import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Toggle("開發模式：成功連線後仍保留 .vv", isOn: Binding(
                get: { model.retainSourceFiles },
                set: { model.retainSourceFiles = $0 }
            ))
            Text("連線後由 SPICE vdagent 自動同步剪貼簿，並依視窗大小調整 guest 解析度。Guest 需安裝 spice-vdagent；不支援時改為本地縮放。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("部分鍵盤的 F11 需要搭配 Fn。釋放游標預設為 Ctrl+Alt+R。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
