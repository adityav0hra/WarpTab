import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
final class SoundManager: ObservableObject {
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var apps: [AudioApp] = []
    @Published var selectedOutputID: AudioObjectID?
    @Published var selectedInputID: AudioObjectID?
    @Published var outputVolume: Double = 0
    @Published var outputMuted = false
    @Published var microphonesMuted = false
    @Published var favorites: Set<String> = [] { didSet { saveFavorites() } }
    @Published var reduceOnDisconnect = true { didSet { defaults.set(reduceOnDisconnect, forKey: Keys.reduceOnDisconnect) } }
    @Published private(set) var disconnectVolume = 0.25
    @Published private(set) var pinInput = true
    @Published private(set) var globalShortcutsEnabled = true
    @Published var errorMessage: String?

    private let service = CoreAudioService()
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var shortcutMonitor: GlobalShortcutMonitor?
    private var previousOutput: AudioDevice?
    private var perAppAudioEngineStorage: AnyObject?

    private enum Keys {
        static let appPreferences = "appAudioPreferences"
        static let favorites = "favoriteOutputs"
        static let reduceOnDisconnect = "reduceOnDisconnect"
        static let disconnectVolume = "soundDisconnectVolume"
        static let pinInput = "soundPinInput"
        static let globalShortcutsEnabled = "soundGlobalShortcutsEnabled"
        static let pinnedInput = "pinnedInput"
    }

    init() {
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        reduceOnDisconnect = defaults.object(forKey: Keys.reduceOnDisconnect) as? Bool ?? true
        disconnectVolume = defaults.object(forKey: Keys.disconnectVolume) as? Double ?? 0.25
        pinInput = defaults.object(forKey: Keys.pinInput) as? Bool ?? true
        globalShortcutsEnabled = defaults.object(forKey: Keys.globalShortcutsEnabled) as? Bool ?? true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        updateShortcutMonitor()
    }

    deinit { timer?.invalidate() }

    var selectedOutput: AudioDevice? { outputs.first { $0.id == selectedOutputID } }
    var selectedInput: AudioDevice? { inputs.first { $0.id == selectedInputID } }

    func refresh() {
        syncPreferences()
        do {
            let oldOutput = selectedOutput
            let all = try service.devices()
            outputs = all.filter(\.hasOutput).sorted { $0.name < $1.name }
            inputs = all.filter(\.hasInput).sorted { $0.name < $1.name }
            selectedOutputID = service.defaultOutputID()
            selectedInputID = service.defaultInputID()
            if let outputID = selectedOutputID {
                outputVolume = Double(service.volume(of: outputID, scope: kAudioDevicePropertyScopeOutput))
                outputMuted = service.isMuted(outputID, scope: kAudioDevicePropertyScopeOutput)
            }
            microphonesMuted = !inputs.isEmpty && inputs.allSatisfy { service.isMuted($0.id, scope: kAudioDevicePropertyScopeInput) }
            if #available(macOS 14.2, *) {
                apps = service.audioApps()
                perAppAudioEngine().removeMissingApps(Set(apps.map(\.bundleIdentifier)))
            }
            enforcePinnedInput()
            handleDisconnect(oldOutput: oldOutput)
            previousOutput = selectedOutput
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setOutputVolume(_ value: Double) {
        outputVolume = min(max(value, 0), 1)
        guard let id = selectedOutputID else { return }
        do { try service.setVolume(Float(outputVolume), on: id, scope: kAudioDevicePropertyScopeOutput) }
        catch { errorMessage = error.localizedDescription }
    }

    func toggleOutputMute() {
        guard let id = selectedOutputID else { return }
        do {
            try service.setMuted(!outputMuted, device: id, scope: kAudioDevicePropertyScopeOutput)
            outputMuted.toggle()
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseOutput(_ device: AudioDevice) {
        do {
            try service.setDefaultOutput(device.id)
            selectedOutputID = device.id
            previousOutput = device
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseInput(_ device: AudioDevice) {
        do {
            try service.setDefaultInput(device.id)
            selectedInputID = device.id
            defaults.set(device.uid, forKey: Keys.pinnedInput)
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleFavorite(_ device: AudioDevice) {
        if favorites.contains(device.uid) { favorites.remove(device.uid) }
        else { favorites.insert(device.uid) }
    }

    func cycleFavoriteOutput() {
        let choices = outputs.filter { favorites.contains($0.uid) }
        guard !choices.isEmpty else { return }
        let next: AudioDevice
        if let current = selectedOutput, let index = choices.firstIndex(of: current) {
            next = choices[(index + 1) % choices.count]
        } else {
            next = choices[0]
        }
        chooseOutput(next)
    }

    func toggleAllMicrophones() {
        let newValue = !microphonesMuted
        var failures = 0
        for input in inputs {
            do { try service.setMuted(newValue, device: input.id, scope: kAudioDevicePropertyScopeInput) }
            catch { failures += 1 }
        }
        microphonesMuted = newValue
        if failures > 0 { errorMessage = "\(failures) microphone\(failures == 1 ? "" : "s") could not be changed." }
    }

    func preference(for app: AudioApp) -> AppAudioPreference {
        allPreferences()[app.bundleIdentifier] ?? AppAudioPreference()
    }

    func setPreference(_ preference: AppAudioPreference, for app: AudioApp) {
        var values = allPreferences()
        values[app.bundleIdentifier] = preference
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Keys.appPreferences) }
        applyLivePreference(preference, to: app)
        objectWillChange.send()
    }

    private func allPreferences() -> [String: AppAudioPreference] {
        guard let data = defaults.data(forKey: Keys.appPreferences) else { return [:] }
        return (try? JSONDecoder().decode([String: AppAudioPreference].self, from: data)) ?? [:]
    }

    private func saveFavorites() { defaults.set(Array(favorites), forKey: Keys.favorites) }

    private func applyLivePreference(_ preference: AppAudioPreference, to app: AudioApp) {
        guard #available(macOS 14.2, *) else {
            errorMessage = "Per-app audio controls require macOS 14.2 or later."
            return
        }
        let output = preference.outputUID.flatMap { uid in outputs.first(where: { $0.uid == uid }) }
            ?? selectedOutput
        guard let output else {
            errorMessage = "No audio output is available."
            return
        }
        do {
            try perAppAudioEngine().apply(app: app, volumePercent: preference.volumePercent, output: output)
        } catch {
            errorMessage = "Could not control \(app.name): \(error.localizedDescription)"
        }
    }

    @available(macOS 14.2, *)
    private func perAppAudioEngine() -> PerAppAudioEngine {
        if let engine = perAppAudioEngineStorage as? PerAppAudioEngine { return engine }
        let engine = PerAppAudioEngine()
        perAppAudioEngineStorage = engine
        return engine
    }

    private func enforcePinnedInput() {
        guard pinInput,
              let uid = defaults.string(forKey: Keys.pinnedInput),
              let pinned = inputs.first(where: { $0.uid == uid }),
              selectedInputID != pinned.id else { return }
        try? service.setDefaultInput(pinned.id)
        selectedInputID = pinned.id
    }

    private func handleDisconnect(oldOutput: AudioDevice?) {
        guard reduceOnDisconnect,
              let oldOutput,
              oldOutput.isHeadphoneLike,
              !outputs.contains(where: { $0.uid == oldOutput.uid }),
              let newID = selectedOutputID else { return }
        try? service.setVolume(Float(disconnectVolume), on: newID, scope: kAudioDevicePropertyScopeOutput)
        outputVolume = disconnectVolume
    }

    private func syncPreferences() {
        reduceOnDisconnect = defaults.object(forKey: Keys.reduceOnDisconnect) as? Bool ?? true
        disconnectVolume = defaults.object(forKey: Keys.disconnectVolume) as? Double ?? 0.25
        pinInput = defaults.object(forKey: Keys.pinInput) as? Bool ?? true
        let shortcutsEnabled = defaults.object(forKey: Keys.globalShortcutsEnabled) as? Bool ?? true
        if shortcutsEnabled != globalShortcutsEnabled {
            globalShortcutsEnabled = shortcutsEnabled
            updateShortcutMonitor()
        }
    }

    private func updateShortcutMonitor() {
        guard globalShortcutsEnabled else {
            shortcutMonitor = nil
            return
        }
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = GlobalShortcutMonitor(
            onCycleOutput: { [weak self] in Task { @MainActor in self?.cycleFavoriteOutput() } },
            onToggleMicrophones: { [weak self] in Task { @MainActor in self?.toggleAllMicrophones() } }
        )
    }
}
