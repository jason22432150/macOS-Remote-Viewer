import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let language = settings.language
        Form {
            Section(L10n.string(.settingsMouse, language: language)) {
                Picker(
                    L10n.string(.scrollDirection, language: language),
                    selection: $settings.preferences.scrollWheelDirection
                ) {
                    Text(L10n.string(.scrollNatural, language: language)).tag(ScrollWheelDirection.natural)
                    Text(L10n.string(.scrollReversed, language: language)).tag(ScrollWheelDirection.reversed)
                }
                .pickerStyle(.segmented)
            }

            Section(L10n.string(.settingsLanguage, language: language)) {
                Picker(
                    L10n.string(.language, language: language),
                    selection: $settings.preferences.language
                ) {
                    ForEach(AppLanguage.allCases) { item in
                        Text(item.nativeName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L10n.string(.settingsConnectionFile, language: language)) {
                Toggle(
                    L10n.string(.deleteVVAfterConnect, language: language),
                    isOn: $settings.preferences.deleteVVFileAfterConnect
                )
                Text(L10n.string(.deleteVVAfterConnectHelp, language: language))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 280)
        .padding(8)
    }
}
