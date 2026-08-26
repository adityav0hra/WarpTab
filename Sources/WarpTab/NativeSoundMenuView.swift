import AppKit
import Combine
import CoreAudio
import SwiftUI

struct NativeSoundMenuView: View {
    @EnvironmentObject private var sound: SoundManager
    @ObservedObject private var viewState = NativeSoundMenuViewState()
    @AppStorage("soundShowOnlyPlayingApps") private var showOnlyPlayingApps = true
    let onOpenSettings: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case mixer = "Mixer"
        case outputs = "Outputs"
        case microphone = "Microphone"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .mixer: return "speaker.wave.2"
            case .outputs: return "display"
            case .microphone: return "mic"
            }
        }
    }

    private var visibleApps: [AudioApp] {
        sound.apps.filter {
            (!showOnlyPlayingApps || $0.isProducingAudio) && !sound.preference(for: $0).isHidden
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch viewState.section {
            case .mixer: mixer
            case .outputs: outputs
            case .microphone: microphones
            }
        }
        .frame(width: 330)
        .background(.regularMaterial)
        .alert("Sound", isPresented: Binding(
            get: { sound.errorMessage != nil },
            set: { if !$0 { sound.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { sound.errorMessage = nil }
        } message: { Text(sound.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text("Sound Mixer").font(.system(size: 14, weight: .semibold))
                Text(sound.selectedOutput?.name ?? "No output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(Section.allCases) { section in toolbarButton(section) }
                Divider().frame(height: 18).padding(.horizontal, 3)
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape").frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Sound Settings")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func toolbarButton(_ section: Section) -> some View {
        Button { viewState.section = section } label: {
            Image(systemName: section.symbol)
                .symbolVariant(viewState.section == section ? .fill : .none)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(viewState.section == section ? Color.accentColor : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(viewState.section == section ? Color.primary.opacity(0.09) : Color.clear)
        }
        .help(section.rawValue)
        .accessibilityLabel(section.rawValue)
    }

    private var mixer: some View {
        VStack(spacing: 0) {
            masterVolume
            Divider()
            if visibleApps.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.slash").foregroundStyle(.tertiary)
                    Text("No apps are playing audio")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 68)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Playing Audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                        .padding(.bottom, 5)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleApps) { app in
                                NativeAppMixerRow(app: app, outputs: sound.outputs)
                                    .environmentObject(sound)
                                if app.id != visibleApps.last?.id { Divider().padding(.leading, 42) }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(visibleApps.count) * 58, 232))
                }
            }
        }
    }

    private var masterVolume: some View {
        HStack(spacing: 9) {
            Button { sound.toggleOutputMute() } label: {
                Image(systemName: sound.outputMuted ? "speaker.slash" : "speaker.wave.2").frame(width: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Slider(value: Binding(get: { sound.outputVolume }, set: { sound.setOutputVolume($0) }), in: 0...1)
                .controlSize(.small)

            NativeOutputMenu(
                title: sound.selectedOutput?.name ?? "No output",
                outputs: sound.outputs,
                selectedUID: sound.selectedOutput?.uid,
                includeSystemOutput: false,
                onSelect: { uid in
                    if let device = sound.outputs.first(where: { $0.uid == uid }) { sound.chooseOutput(device) }
                }
            )
            .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var outputs: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sound.outputs) { device in
                    HStack(spacing: 10) {
                        Button { sound.chooseOutput(device) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: device.iconName).frame(width: 20)
                                Text(device.name).lineLimit(1)
                                Spacer()
                                if device.id == sound.selectedOutputID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { sound.toggleFavorite(device) } label: {
                            Image(systemName: sound.favorites.contains(device.uid) ? "star.fill" : "star")
                                .foregroundStyle(sound.favorites.contains(device.uid) ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    Divider().padding(.leading, 42)
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private var microphones: some View {
        VStack(spacing: 0) {
            Button { sound.toggleAllMicrophones() } label: {
                HStack(spacing: 10) {
                    Image(systemName: sound.microphonesMuted ? "mic.slash" : "mic").frame(width: 20)
                    Text(sound.microphonesMuted ? "Unmute All Microphones" : "Mute All Microphones")
                    Spacer()
                    Text("⌃⌥M").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            ForEach(sound.inputs) { device in
                Button { sound.chooseInput(device) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: device.iconName).frame(width: 20)
                        Text(device.name).lineLimit(1)
                        Spacer()
                        if device.id == sound.selectedInputID {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider().padding(.leading, 42)
            }
        }
    }
}

private final class NativeSoundMenuViewState: ObservableObject {
    @Published var section: NativeSoundMenuView.Section = .mixer
}

private struct NativeAppMixerRow: View {
    @EnvironmentObject private var sound: SoundManager
    let app: AudioApp
    let outputs: [AudioDevice]
    private var preference: AppAudioPreference { sound.preference(for: app) }

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app").resizable().foregroundStyle(.secondary) }
            }
            .scaledToFit().frame(width: 22, height: 22)

            Text(app.name).font(.callout).lineLimit(1).frame(width: 78, alignment: .leading)

            Slider(value: Binding(
                get: { Double(preference.volumePercent) },
                set: { value in update { $0.volumePercent = min(max(Int(value.rounded()), 0), 200) } }
            ), in: 0...200, step: 1)
            .controlSize(.small)

            NativeOutputMenu(
                title: outputTitle,
                outputs: outputs,
                selectedUID: preference.outputUID,
                includeSystemOutput: true,
                onSelect: { uid in update { $0.outputUID = uid } }
            )
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu { Button("Hide from Mixer") { update { $0.isHidden = true } } }
    }

    private var outputTitle: String {
        guard let uid = preference.outputUID else { return "System" }
        return outputs.first(where: { $0.uid == uid })?.name ?? "System"
    }

    private func update(_ body: (inout AppAudioPreference) -> Void) {
        var copy = preference
        body(&copy)
        sound.setPreference(copy, for: app)
    }
}

private struct NativeOutputMenu: View {
    let title: String
    let outputs: [AudioDevice]
    let selectedUID: String?
    let includeSystemOutput: Bool
    let onSelect: (String?) -> Void

    var body: some View {
        Menu {
            if includeSystemOutput {
                Button { onSelect(nil) } label: {
                    if selectedUID == nil { Label("System Output", systemImage: "checkmark") }
                    else { Text("System Output") }
                }
                Divider()
            }
            ForEach(outputs) { device in
                Button { onSelect(device.uid) } label: {
                    if selectedUID == device.uid { Label(device.name, systemImage: "checkmark") }
                    else { Text(device.name) }
                }
            }
        } label: {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }
}
