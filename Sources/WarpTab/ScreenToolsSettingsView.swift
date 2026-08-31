import SwiftUI

struct ScreenToolsSettingsView: View {
    @ObservedObject var controller: ScreenToolsController
    let preferences: WarpPreferences
    let screenRecordingGranted: Bool
    let openScreenRecordingSettings: () -> Void
    @Binding var showsTextCaptureInWarpTabMenu: Bool
    @Binding var showsColorPickerInWarpTabMenu: Bool

    var body: some View {
        SettingsPage(
            title: "Screen Tools",
            description: "Capture text and colours directly from any display. Screen content is processed locally on this Mac."
        ) {
            SettingsSection(title: "Text Capture") {
                SettingRow(
                    "Copy Text from Screen",
                    description: "Select an area of the screen and copy recognized text to the clipboard."
                ) {
                    OptionalShortcutRecorderRepresentable(
                        shortcut: controller.textCaptureShortcut,
                        onShortcut: controller.setTextCaptureShortcut
                    )
                    .frame(width: 150)
                }
                Divider()
                SettingRow(
                    "Show in WarpTab menu",
                    description: "Add Copy Text from Screen to WarpTab’s menu-bar menu."
                ) {
                    Toggle("", isOn: $showsTextCaptureInWarpTabMenu)
                        .labelsHidden()
                        .accessibilityLabel("Show Copy Text in WarpTab menu")
                }
                Divider()
                SettingRow(
                    "Detect QR Codes",
                    description: "Show the contents of QR codes found in the selected area."
                ) {
                    Toggle("", isOn: preferenceBinding(\.detectScreenQRCodes)).labelsHidden()
                }
                Divider()
                SettingRow(
                    "Text recognition is performed locally on this Mac.",
                    description: "No selected image, recognized text, or QR code content is uploaded."
                ) {
                    EmptyView()
                }
                if !screenRecordingGranted {
                    Divider()
                    SettingRow(
                        "Screen Recording required",
                        description: "Text Capture needs permission to capture the selected pixels."
                    ) {
                        Button("Open System Settings", action: openScreenRecordingSettings)
                            .controlSize(.small)
                    }
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Try Text Capture") { controller.copyTextFromScreen() }
                        .accessibilityLabel("Try Copy Text from Screen")
                }
                .padding(.vertical, 2)
            }

            SettingsSection(title: "Color Picker") {
                SettingRow(
                    "Pick Color from Screen",
                    description: "Pick a colour anywhere on screen and copy it in your preferred format."
                ) {
                    OptionalShortcutRecorderRepresentable(
                        shortcut: controller.colorPickerShortcut,
                        onShortcut: controller.setColorPickerShortcut
                    )
                    .frame(width: 150)
                }
                Divider()
                SettingRow(
                    "Show in WarpTab menu",
                    description: "Add Pick Color from Screen to WarpTab’s menu-bar menu."
                ) {
                    Toggle("", isOn: $showsColorPickerInWarpTabMenu)
                        .labelsHidden()
                        .accessibilityLabel("Show Color Picker in WarpTab menu")
                }
                Divider()
                SettingRow("Copy Format", description: "Choose the format copied for selected colours.") {
                    Picker("", selection: preferenceBinding(\.screenColorCopyFormat)) {
                        ForEach(ScreenColorCopyFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                Divider()
                SettingRow(
                    "Automatically Copy Result",
                    description: "Immediately copy the selected colour in the preferred format."
                ) {
                    Toggle("", isOn: preferenceBinding(\.screenColorAutomaticallyCopies)).labelsHidden()
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Try Color Picker") { controller.pickColorFromScreen() }
                        .accessibilityLabel("Try Pick Color from Screen")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func preferenceBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<WarpPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { value in
                preferences[keyPath: keyPath] = value
                controller.objectWillChange.send()
            }
        )
    }
}
