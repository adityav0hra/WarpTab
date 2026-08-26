import AppKit
import Combine
import CoreAudio
import SwiftUI

struct SoundMenuView: View {
    @EnvironmentObject private var sound: SoundManager
    @ObservedObject private var viewState = SoundMenuViewState()

    enum Section: String, CaseIterable, Identifiable {
        case mixer = "Mixer"
        case outputs = "Outputs"
        case microphone = "Mic"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Section", selection: $viewState.section) {
                ForEach(Section.allCases) { section in Text(section.rawValue).tag(section) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Group {
                switch viewState.section {
                case .mixer: mixer
                case .outputs: outputs
                case .microphone: microphones
                }
            }
            .frame(maxHeight: 370)

            Divider()
            footer
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .alert("Sound", isPresented: Binding(
            get: { sound.errorMessage != nil },
            set: { if !$0 { sound.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { sound.errorMessage = nil }
        } message: { Text(sound.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sound").font(.subheadline)
                Text(sound.selectedOutput?.name ?? "No output").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { sound.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh audio devices")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var mixer: some View {
        ScrollView {
            VStack(spacing: 0) {
                masterVolume
                Divider().padding(.leading, 38)
                let visibleApps = sound.apps.filter {
                    $0.isProducingAudio && !sound.preference(for: $0).isHidden
                }
                if visibleApps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No apps playing audio")
                            .font(.subheadline)
                        Text("Apps appear here when they connect to Core Audio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                        .frame(height: 145)
                } else {
                    ForEach(visibleApps) { app in
                        AppMixerRow(app: app, outputs: sound.outputs)
                            .environmentObject(sound)
                        Divider().padding(.leading, 38)
                    }
                }
            }
        }
    }

    private var masterVolume: some View {
        HStack(spacing: 7) {
            Button { sound.toggleOutputMute() } label: {
                Image(systemName: sound.outputMuted ? "speaker.slash" : "speaker.wave.1")
                    .fontWeight(.light)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(get: { sound.outputVolume }, set: { sound.setOutputVolume($0) }),
                in: 0...1
            )
            .controlSize(.mini)
            .frame(width: 132)

            Picker("Output", selection: Binding(
                get: { sound.selectedOutput?.uid ?? "" },
                set: { uid in
                    if let device = sound.outputs.first(where: { $0.uid == uid }) {
                        sound.chooseOutput(device)
                    }
                }
            )) {
                ForEach(sound.outputs) { Text($0.name).tag($0.uid) }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 105)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private var outputs: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("OUTPUT SWITCHER").sectionLabel()
                ForEach(sound.outputs) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.iconName).fontWeight(.light).frame(width: 18).foregroundStyle(device.id == sound.selectedOutputID ? .primary : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).lineLimit(1)
                            if device.id == sound.selectedOutputID { Text("Current output").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { sound.toggleFavorite(device) } label: {
                            Image(systemName: sound.favorites.contains(device.uid) ? "star.fill" : "star").foregroundStyle(sound.favorites.contains(device.uid) ? .yellow : .secondary)
                        }.buttonStyle(.plain).help("Include when cycling outputs")
                        if device.id != sound.selectedOutputID {
                            Button("Use") { sound.chooseOutput(device) }.controlSize(.small)
                        } else { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
                Divider()
                Button { sound.cycleFavoriteOutput() } label: {
                    HStack {
                        Label("Cycle favorite outputs", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text("⌃⌥O").foregroundStyle(.secondary)
                    }
                }
                    .disabled(sound.favorites.isEmpty)
                Toggle("Lower volume when headphones disconnect", isOn: $sound.reduceOnDisconnect)
                    .font(.subheadline)
            }
            .padding(10)
        }
    }

    private var microphones: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button { sound.toggleAllMicrophones() } label: {
                    HStack {
                        Image(systemName: sound.microphonesMuted ? "mic.slash" : "mic")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sound.microphonesMuted ? "Unmute every microphone" : "Mute every microphone")
                            Text("All connected inputs · ⌃⌥M").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)

                Text("PINNED INPUT").sectionLabel()
                ForEach(sound.inputs) { device in
                    Button { sound.chooseInput(device) } label: {
                        HStack {
                            Image(systemName: device.iconName).frame(width: 22)
                            Text(device.name).lineLimit(1)
                            Spacer()
                            if device.id == sound.selectedInputID { Image(systemName: "pin").foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
                Text("The selected input stays pinned when apps or devices try to change it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private var footer: some View {
        HStack {
            Text("Driver-free · Core Audio")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private final class SoundMenuViewState: ObservableObject {
    @Published var section: SoundMenuView.Section = .mixer
}

private struct AppMixerRow: View {
    @EnvironmentObject private var sound: SoundManager
    let app: AudioApp
    let outputs: [AudioDevice]

    private var preference: AppAudioPreference { sound.preference(for: app) }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app").resizable().foregroundStyle(.secondary) }
            }
            .scaledToFit().frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).font(.caption).lineLimit(1)
                    if app.isProducingAudio { Circle().fill(.green).frame(width: 5, height: 5).help("Playing audio") }
                    Spacer()
                    Menu { Button("Hide from mixer") { update { $0.isHidden = true } } } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                HStack(spacing: 7) {
                    Slider(value: Binding(
                        get: { Double(preference.volumePercent) },
                        set: { setVolume(Int($0.rounded())) }
                    ), in: 0...200, step: 1)
                    .controlSize(.mini)
                    .frame(width: 128)

                    Picker("Output", selection: Binding(
                        get: { preference.outputUID ?? "" },
                        set: { uid in update { $0.outputUID = uid.isEmpty ? nil : uid } }
                    )) {
                        Text("System output").tag("")
                        ForEach(outputs) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 102)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private func setVolume(_ value: Int) {
        let clamped = min(max(value, 0), 200)
        update { $0.volumePercent = clamped }
    }

    private func update(_ body: (inout AppAudioPreference) -> Void) {
        var copy = preference
        body(&copy)
        sound.setPreference(copy, for: app)
    }
}

private extension View {
    func sectionLabel() -> some View {
        font(.caption2).foregroundStyle(.secondary).tracking(0.5)
    }
}
