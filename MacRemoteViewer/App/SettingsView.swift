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

                ScrollSensitivitySlider(
                    title: L10n.string(.mouseWheelSensitivity, language: language),
                    help: L10n.string(.mouseWheelSensitivityHelp, language: language),
                    value: $settings.preferences.mouseWheelSensitivity,
                    language: language
                )
                ScrollSensitivitySlider(
                    title: L10n.string(.trackpadScrollSensitivity, language: language),
                    help: L10n.string(.trackpadScrollSensitivityHelp, language: language),
                    value: $settings.preferences.trackpadScrollSensitivity,
                    language: language
                )
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

            Section(L10n.string(.settingsDisplay, language: language)) {
                Toggle(
                    L10n.string(.matchResolutionToWindow, language: language),
                    isOn: $settings.preferences.matchGuestResolutionToWindow
                )
                Text(L10n.string(.matchResolutionToWindowHelp, language: language))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(L10n.string(.commonResolutions, language: language))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(RemoteResolutionPreset.common) { preset in
                        Button(preset.displayName) {
                            settings.selectResolutionPreset(preset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(settings.isSelectedPreset(preset) ? Color.accentColor : nil)
                    }
                }
                Button(L10n.string(.resetResolution, language: language)) {
                    settings.resetResolutionToMatchWindow()
                }
                Text(L10n.string(.resetResolutionHelp, language: language))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(L10n.string(.clipboardAndResolutionHelp, language: language))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(L10n.string(.keyboardHelp, language: language))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.string(.settingsDiagnostics, language: language)) {
                Toggle(
                    L10n.string(.recordLogs, language: language),
                    isOn: $settings.preferences.loggingEnabled
                )
                Text(L10n.string(.recordLogsHelp, language: language))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(L10n.string(.openLogFolder, language: language)) {
                    model.revealLogFolder()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 640)
        .padding(8)
    }
}

/// 滾動靈敏度滑桿：範圍與 `ScrollSensitivity` 共用。
private struct ScrollSensitivitySlider: View {
    let title: String
    let help: String
    @Binding var value: Double
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedValue)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: $value,
                in: ScrollSensitivity.minimum...ScrollSensitivity.maximum,
                step: ScrollSensitivity.step
            ) {
                Text(title)
            } minimumValueLabel: {
                Text(L10n.string(.scrollSensitivitySlow, language: language))
            } maximumValueLabel: {
                Text(L10n.string(.scrollSensitivityFast, language: language))
            }
            Text(help)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var formattedValue: String {
        value.formatted(
            .number.precision(.fractionLength(0...2)).locale(language.locale)
        ) + "×"
    }
}
