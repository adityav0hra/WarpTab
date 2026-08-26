import AppIntents
import CoreFoundation
import SwiftUI
import WidgetKit

@available(macOS 26.0, *)
struct OpenSoundMixerIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sound Mixer"
    static let description = IntentDescription("Open WarpTab’s Sound Mixer controls.")
    func perform() async throws -> some IntentResult {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.warptab.openSoundMixer" as CFString),
            nil,
            nil,
            true
        )
        return .result()
    }
}

@available(macOS 26.0, *)
struct SoundMixerControl: ControlWidget {
    static let kind = "com.warptab.app.controls.sound-mixer"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(
                action: OpenSoundMixerIntent()
            ) {
                Label("Sound Mixer", systemImage: "speaker.wave.2")
            }
        }
        .displayName("Sound Mixer")
        .description("Open WarpTab’s per-app volume and output controls.")
    }
}

@main
struct WarpTabControlsBundle: WidgetBundle {
    var body: some Widget {
        if #available(macOS 26.0, *) {
            SoundMixerControl()
        }
    }
}
