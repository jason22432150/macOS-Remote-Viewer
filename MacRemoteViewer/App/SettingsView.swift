import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Picker("剪貼簿模式", selection: Binding(
                get: { model.clipboardMode },
                set: { model.applyClipboardMode($0) }
            )) {
                Text("關閉").tag(ClipboardMode.off)
                Text("手動（預設）").tag(ClipboardMode.manual)
                Text("自動").tag(ClipboardMode.automatic)
            }
            Toggle("開發模式：成功連線後仍保留 .vv", isOn: Binding(
                get: { model.retainSourceFiles },
                set: { model.retainSourceFiles = $0 }
            ))
            Text("自動模式僅在作用中視窗同步純文字，上限 1 MiB。超過會拒絕且不截斷。")
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
