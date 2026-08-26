import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import SwiftUI

final class SystemSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: WarpTabSettingsModel
    private let onClose: () -> Void

    init(
        preferences: WarpPreferences,
        store: WindowStore,
        initiallyEnabled: Bool,
        initiallySelectedShortcut: SwitcherShortcut,
        initiallySelectedLayout: SwitcherLayout,
        initiallyEnablesStayAwake: Bool,
        initiallyShowsAwakeInWarpTabMenu: Bool,
        initiallyShowsViewStyleInWarpTabMenu: Bool,
        initiallyShowsClipboardInWarpTabMenu: Bool,
        initiallyShowsClipboardStatusItem: Bool,
        initiallyShowsAwakeStatusItem: Bool,
        initiallyShowsSoundStatusItem: Bool,
        onEnabledChange: @escaping (Bool) -> Void,
        onShortcutChange: @escaping (SwitcherShortcut) -> Bool,
        onLayoutChange: @escaping (SwitcherLayout) -> Void,
        onStayAwakeEnabledChange: @escaping (Bool) -> Void,
        onShowAwakeInWarpTabMenuChange: @escaping (Bool) -> Void,
        onShowViewStyleInWarpTabMenuChange: @escaping (Bool) -> Void,
        onShowClipboardInWarpTabMenuChange: @escaping (Bool) -> Void,
        onShowClipboardStatusItemChange: @escaping (Bool) -> Void,
        onShowAwakeStatusItemChange: @escaping (Bool) -> Void,
        onShowSoundStatusItemChange: @escaping (Bool) -> Void,
        onClearClipboard: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        model = WarpTabSettingsModel(
            preferences: preferences,
            store: store,
            enabled: initiallyEnabled,
            shortcut: initiallySelectedShortcut,
            layout: initiallySelectedLayout,
            stayAwakeEnabled: initiallyEnablesStayAwake,
            showsAwakeInWarpTabMenu: initiallyShowsAwakeInWarpTabMenu,
            showsViewStyleInWarpTabMenu: initiallyShowsViewStyleInWarpTabMenu,
            showsClipboardInWarpTabMenu: initiallyShowsClipboardInWarpTabMenu,
            showsClipboardStatusItem: initiallyShowsClipboardStatusItem,
            showsAwakeStatusItem: initiallyShowsAwakeStatusItem,
            showsSoundStatusItem: initiallyShowsSoundStatusItem,
            onEnabledChange: onEnabledChange,
            onShortcutChange: onShortcutChange,
            onLayoutChange: onLayoutChange,
            onStayAwakeEnabledChange: onStayAwakeEnabledChange,
            onShowAwakeInWarpTabMenuChange: onShowAwakeInWarpTabMenuChange,
            onShowViewStyleInWarpTabMenuChange: onShowViewStyleInWarpTabMenuChange,
            onShowClipboardInWarpTabMenuChange: onShowClipboardInWarpTabMenuChange,
            onShowClipboardStatusItemChange: onShowClipboardStatusItemChange,
            onShowAwakeStatusItemChange: onShowAwakeStatusItemChange,
            onShowSoundStatusItemChange: onShowSoundStatusItemChange,
            onClearClipboard: onClearClipboard,
            onOpenAccessibility: onOpenAccessibility
        )
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = "WarpTab Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 560)
        window.setFrameAutosaveName("WarpTabSettingsWindow")
        window.contentView = NSHostingView(rootView: WarpTabSettingsRootView(model: model))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        model.refresh()
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func refreshPermissionStatus(listenerRunning: Bool) {
        model.refreshPermissionStatus(listenerRunning: listenerRunning)
    }

    func updateLayoutSelection(_ layout: SwitcherLayout) {
        model.layout = layout
    }

    func showSoundSettings() {
        model.selection = .sound
        showWindow(nil)
    }
}

private struct SettingsApplication: Identifiable, Hashable {
    let id: String
    let name: String
}

private final class WarpTabSettingsModel: ObservableObject {
    let preferences: WarpPreferences
    private let store: WindowStore
    private let onEnabledChange: (Bool) -> Void
    private let onShortcutChange: (SwitcherShortcut) -> Bool
    private let onLayoutChange: (SwitcherLayout) -> Void
    private let onStayAwakeEnabledChange: (Bool) -> Void
    private let onShowAwakeInWarpTabMenuChange: (Bool) -> Void
    private let onShowViewStyleInWarpTabMenuChange: (Bool) -> Void
    private let onShowClipboardInWarpTabMenuChange: (Bool) -> Void
    private let onShowClipboardStatusItemChange: (Bool) -> Void
    private let onShowAwakeStatusItemChange: (Bool) -> Void
    private let onShowSoundStatusItemChange: (Bool) -> Void
    let onClearClipboard: () -> Void
    let onOpenAccessibility: () -> Void

    @Published var enabled: Bool
    @Published var shortcut: SwitcherShortcut
    @Published var layout: SwitcherLayout
    @Published var stayAwakeEnabled: Bool
    @Published var showsAwakeInWarpTabMenu: Bool
    @Published var showsViewStyleInWarpTabMenu: Bool
    @Published var showsClipboardInWarpTabMenu: Bool
    @Published var showsClipboardStatusItem: Bool
    @Published var showsAwakeStatusItem: Bool
    @Published var showsSoundStatusItem: Bool
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published var listenerRunning = false
    @Published var selection: SettingsDestination? = .windowSwitcher
    @Published var availableApplications: [SettingsApplication] = []
    @Published var excludedApplications: [SettingsApplication] = []
    @Published var selectedExcludedIdentifier: String?

    init(
        preferences: WarpPreferences,
        store: WindowStore,
        enabled: Bool,
        shortcut: SwitcherShortcut,
        layout: SwitcherLayout,
        stayAwakeEnabled: Bool,
        showsAwakeInWarpTabMenu: Bool,
        showsViewStyleInWarpTabMenu: Bool,
        showsClipboardInWarpTabMenu: Bool,
        showsClipboardStatusItem: Bool,
        showsAwakeStatusItem: Bool,
        showsSoundStatusItem: Bool,
        onEnabledChange: @escaping (Bool) -> Void,
        onShortcutChange: @escaping (SwitcherShortcut) -> Bool,
        onLayoutChange: @escaping (SwitcherLayout) -> Void,
        onStayAwakeEnabledChange: @escaping (Bool) -> Void,
        onShowAwakeInWarpTabMenuChange: @escaping (Bool) -> Void,
        onShowViewStyleInWarpTabMenuChange: @escaping (Bool) -> Void,
        onShowClipboardInWarpTabMenuChange: @escaping (Bool) -> Void,
        onShowClipboardStatusItemChange: @escaping (Bool) -> Void,
        onShowAwakeStatusItemChange: @escaping (Bool) -> Void,
        onShowSoundStatusItemChange: @escaping (Bool) -> Void,
        onClearClipboard: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.store = store
        self.enabled = enabled
        self.shortcut = shortcut
        self.layout = layout
        self.stayAwakeEnabled = stayAwakeEnabled
        self.showsAwakeInWarpTabMenu = showsAwakeInWarpTabMenu
        self.showsViewStyleInWarpTabMenu = showsViewStyleInWarpTabMenu
        self.showsClipboardInWarpTabMenu = showsClipboardInWarpTabMenu
        self.showsClipboardStatusItem = showsClipboardStatusItem
        self.showsAwakeStatusItem = showsAwakeStatusItem
        self.showsSoundStatusItem = showsSoundStatusItem
        self.onEnabledChange = onEnabledChange
        self.onShortcutChange = onShortcutChange
        self.onLayoutChange = onLayoutChange
        self.onStayAwakeEnabledChange = onStayAwakeEnabledChange
        self.onShowAwakeInWarpTabMenuChange = onShowAwakeInWarpTabMenuChange
        self.onShowViewStyleInWarpTabMenuChange = onShowViewStyleInWarpTabMenuChange
        self.onShowClipboardInWarpTabMenuChange = onShowClipboardInWarpTabMenuChange
        self.onShowClipboardStatusItemChange = onShowClipboardStatusItemChange
        self.onShowAwakeStatusItemChange = onShowAwakeStatusItemChange
        self.onShowSoundStatusItemChange = onShowSoundStatusItemChange
        self.onClearClipboard = onClearClipboard
        self.onOpenAccessibility = onOpenAccessibility
        refresh()
    }

    var active: Bool { enabled && accessibilityGranted && listenerRunning }

    func refresh() {
        enabled = UserDefaults.standard.object(forKey: "switcherEnabled") as? Bool ?? true
        shortcut = SwitcherShortcut(
            storageValue: UserDefaults.standard.string(forKey: "customShortcut") ?? ""
        ).map { $0.isReserved ? .defaultShortcut : $0 } ?? .defaultShortcut
        layout = SwitcherLayout(
            rawValue: UserDefaults.standard.string(forKey: "switcherLayout") ?? ""
        ) ?? .list
        stayAwakeEnabled = UserDefaults.standard.object(forKey: "stayAwakeFeatureEnabled") as? Bool ?? true
        showsAwakeInWarpTabMenu = UserDefaults.standard.object(forKey: "showAwakeInWarpTabMenu") as? Bool ?? true
        showsViewStyleInWarpTabMenu = UserDefaults.standard.object(forKey: "showViewStyleInWarpTabMenu") as? Bool ?? true
        showsClipboardInWarpTabMenu = UserDefaults.standard.object(forKey: "showClipboardInWarpTabMenu") as? Bool ?? true
        showsClipboardStatusItem = UserDefaults.standard.bool(forKey: "showClipboardStatusItem")
        showsAwakeStatusItem = UserDefaults.standard.bool(forKey: "showAwakeStatusItem")
        showsSoundStatusItem = UserDefaults.standard.object(forKey: "showSoundStatusItem") as? Bool ?? true
        refreshPermissionStatus(listenerRunning: listenerRunning)
        refreshApplications()
        objectWillChange.send()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        onEnabledChange(value)
    }

    func setShortcut(_ candidate: SwitcherShortcut) -> Bool {
        guard onShortcutChange(candidate) else { return false }
        shortcut = candidate
        return true
    }

    func setLayout(_ value: SwitcherLayout) {
        layout = value
        onLayoutChange(value)
    }

    func setShowsAwakeStatusItem(_ value: Bool) {
        showsAwakeStatusItem = value
        onShowAwakeStatusItemChange(value)
    }

    func setShowsSoundStatusItem(_ value: Bool) {
        showsSoundStatusItem = value
        onShowSoundStatusItemChange(value)
    }

    func setShowsClipboardInWarpTabMenu(_ value: Bool) {
        showsClipboardInWarpTabMenu = value
        onShowClipboardInWarpTabMenuChange(value)
    }

    func setShowsClipboardStatusItem(_ value: Bool) {
        showsClipboardStatusItem = value
        onShowClipboardStatusItemChange(value)
    }

    func setStayAwakeEnabled(_ value: Bool) {
        stayAwakeEnabled = value
        onStayAwakeEnabledChange(value)
    }

    func setShowsAwakeInWarpTabMenu(_ value: Bool) {
        showsAwakeInWarpTabMenu = value
        onShowAwakeInWarpTabMenuChange(value)
    }

    func setShowsViewStyleInWarpTabMenu(_ value: Bool) {
        showsViewStyleInWarpTabMenu = value
        onShowViewStyleInWarpTabMenuChange(value)
    }

    func preferenceBinding<Value>(_ keyPath: ReferenceWritableKeyPath<WarpPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { value in
                self.preferences[keyPath: keyPath] = value
                self.objectWillChange.send()
            }
        )
    }

    func refreshPermissionStatus(listenerRunning: Bool) {
        self.listenerRunning = listenerRunning
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openSystemAudioRecordingSettings() {
        openScreenRecordingSettings()
    }

    func refreshApplications() {
        let excluded = preferences.excludedBundleIdentifiers
        availableApplications = store.runningApplications().compactMap { application in
            guard let identifier = application.bundleIdentifier,
                  !excluded.contains(identifier) else { return nil }
            return SettingsApplication(id: identifier, name: application.localizedName ?? identifier)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        excludedApplications = excluded.map { identifier in
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
                ?? identifier
            return SettingsApplication(id: identifier, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if let selectedExcludedIdentifier,
           excludedApplications.contains(where: { $0.id == selectedExcludedIdentifier }) {
            self.selectedExcludedIdentifier = selectedExcludedIdentifier
        } else {
            selectedExcludedIdentifier = excludedApplications.first?.id
        }
    }

    func exclude(_ identifier: String) {
        preferences.excludedBundleIdentifiers.insert(identifier)
        refreshApplications()
    }

    func removeSelectedExclusion() {
        guard let selectedExcludedIdentifier else { return }
        preferences.excludedBundleIdentifiers.remove(selectedExcludedIdentifier)
        refreshApplications()
    }
}

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case windowSwitcher
    case sound
    case dock
    case windowSnapping
    case stayAwake
    case windowsFeatures
    case permissions
    case about

    var id: String { rawValue }
}

private struct WarpTabSettingsRootView: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: AppIcon.make())
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                        .accessibilityHidden(true)
                    Text("WarpTab")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 18)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("WarpTab")

                List(selection: $model.selection) {
                    sidebarSectionLabel("Features")
                    sidebarItem("Window Switcher", symbol: "rectangle.on.rectangle", destination: .windowSwitcher)
                    sidebarItem("Dock", symbol: "dock.rectangle", destination: .dock)
                    sidebarItem("Window Snapping", symbol: "rectangle.split.3x1", destination: .windowSnapping)
                    sidebarItem("Sound Mixer", symbol: "speaker.wave.2", destination: .sound)
                    sidebarItem("Stay Awake", symbol: "cup.and.saucer", destination: .stayAwake)
                    sidebarItem("Windows Extras", symbol: "command", destination: .windowsFeatures)

                    sidebarSectionLabel("Permissions", topPadding: 12)
                    sidebarItem("Permissions", symbol: "hand.raised", destination: .permissions)
                }
                .listStyle(.sidebar)

                Divider()
                HStack(spacing: 4) {
                    Button {
                        model.selection = .about
                    } label: {
                        Label("About WarpTab", systemImage: "info.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .foregroundStyle(model.selection == .about ? Color.white : Color.primary)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(model.selection == .about ? Color.accentColor : Color.clear)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About WarpTab")

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Quit WarpTab")
                    .accessibilityLabel("Quit WarpTab from settings")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            Group {
                switch model.selection ?? .windowSwitcher {
                case .windowSwitcher: WindowSwitcherSettingsPage(model: model)
                case .sound: SoundSettingsPage(model: model)
                case .dock: DockSettingsPage(model: model)
                case .windowSnapping: WindowSnappingPage(model: model)
                case .stayAwake: StayAwakeSettingsPage(model: model)
                case .windowsFeatures: WindowsFeaturesSettingsPage(model: model)
                case .permissions: PermissionsSettingsPage(model: model)
                case .about: AboutWarpTabPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 560)
        .toggleStyle(.switch)
    }

    private func sidebarItem(_ title: String, symbol: String, destination: SettingsDestination) -> some View {
        Label(title, systemImage: symbol).tag(destination)
    }

    private func sidebarSectionLabel(_ title: String, topPadding: CGFloat = 2) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: topPadding, leading: 8, bottom: 4, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct StayAwakeSettingsPage: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        SettingsPage(title: "Stay Awake", description: "Prevent your Mac and display from sleeping when you need uninterrupted activity.") {
            SettingsSection(title: "Availability") {
                SettingRow("Enable Stay Awake", description: "Make Stay Awake available from WarpTab.") {
                    Toggle("", isOn: Binding(
                        get: { model.stayAwakeEnabled },
                        set: model.setStayAwakeEnabled
                    ))
                    .labelsHidden()
                }
                Divider()
                SettingRow("Show in WarpTab menu", description: "Include Keep Mac Awake in WarpTab’s menu list.") {
                    Toggle("", isOn: Binding(
                        get: { model.showsAwakeInWarpTabMenu },
                        set: model.setShowsAwakeInWarpTabMenu
                    ))
                    .labelsHidden()
                }
                .disabled(!model.stayAwakeEnabled)
                Divider()
                SettingRow("Show in menu bar", description: "Add a separate coffee-cup icon for one-click access.") {
                    Toggle("", isOn: Binding(
                        get: { model.showsAwakeStatusItem },
                        set: model.setShowsAwakeStatusItem
                    ))
                    .labelsHidden()
                }
                .disabled(!model.stayAwakeEnabled)
            }
        }
    }
}

private struct WindowsFeaturesSettingsPage: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        SettingsPage(title: "Windows Extras", description: "Use familiar Windows keyboard and clipboard behaviors on macOS.") {
            SettingsSection(title: "Dock Shortcuts") {
                SettingRow(
                    "Open Dock apps",
                    description: "Press Command-1 through Command-0 to reveal every window of that Dock app. Use Command-Option-number for the number key's special character."
                ) {
                    Toggle("", isOn: model.preferenceBinding(\.dockAppShortcutsEnabled))
                        .labelsHidden()
                }
            }

            SettingsSection(title: "File Shortcuts") {
                SettingRow("Cut and paste files", description: "Use Command-X to cut Finder files and Command-V to move them.") {
                    Toggle("", isOn: model.preferenceBinding(\.finderCutPasteEnabled)).labelsHidden()
                }
                Divider()
                SettingRow("F2 to rename files", description: "Press F2 to rename the selected Finder file or folder.") {
                    Toggle("", isOn: model.preferenceBinding(\.finderF2RenameEnabled)).labelsHidden()
                }
            }

            SettingsSection(title: "Window Buttons") {
                SettingRow("Green button maximizes", description: "Make the green window button maximize and restore instead of entering a separate full-screen Space.") {
                    Toggle("", isOn: model.preferenceBinding(\.greenButtonMaximizes)).labelsHidden()
                }
                Divider()
                SettingRow("Shift-green uses full screen", description: "Hold Shift while clicking green to enter the normal macOS full-screen Space.") {
                    Toggle("", isOn: model.preferenceBinding(\.shiftGreenUsesFullScreen)).labelsHidden()
                }
                .disabled(!model.preferences.greenButtonMaximizes)
                Divider()
                SettingRow("Quit after closing the last window", description: "Make the red close button quit an app when its final window is closed.") {
                    Toggle("", isOn: model.preferenceBinding(\.quitOnLastWindowClose)).labelsHidden()
                }
                Divider()
                SettingRow("Shift-close keeps app running", description: "Hold Shift while clicking red to close the final window without quitting the app.") {
                    Toggle("", isOn: model.preferenceBinding(\.shiftCloseKeepsAppRunning)).labelsHidden()
                }
                .disabled(!model.preferences.quitOnLastWindowClose)
            }

            SettingsSection(title: "Window Shortcuts") {
                SettingRow("Command-M minimizes all windows", description: "Minimize every window of the active app. Press Command-M again to bring them all back.") {
                    Toggle("", isOn: model.preferenceBinding(\.commandMMinimizesAllWindows)).labelsHidden()
                }
            }

            SettingsSection(title: "Clipboard") {
                SettingRow("Clipboard history", description: "Press Option-V to open your recent clipboard items.") {
                    Toggle("", isOn: model.preferenceBinding(\.clipboardHistoryEnabled)).labelsHidden()
                }
                Divider()
                SettingRow("Show in WarpTab menu", description: "Include Clipboard History in WarpTab’s main menu.") {
                    Toggle("", isOn: Binding(
                        get: { model.showsClipboardInWarpTabMenu },
                        set: model.setShowsClipboardInWarpTabMenu
                    )).labelsHidden()
                }
                Divider()
                SettingRow("Show in menu bar", description: "Add a separate clipboard icon for one-click access.") {
                    Toggle("", isOn: Binding(
                        get: { model.showsClipboardStatusItem },
                        set: model.setShowsClipboardStatusItem
                    )).labelsHidden()
                }
                Divider()
                SettingRow("Plain text on click", description: "Clicking removes formatting and hyperlinks. Shift-click preserves the original formatting.") {
                    Toggle("", isOn: model.preferenceBinding(\.clipboardPlainTextOnClick)).labelsHidden()
                }
                Divider()
                SettingRow("Clear clipboard when Mac sleeps", description: "Remove the current clipboard and its in-memory history whenever the Mac sleeps.") {
                    Toggle("", isOn: model.preferenceBinding(\.clearClipboardOnSleep)).labelsHidden()
                }
                Divider()
                SettingRow("Clear clipboard now", description: "Remove the current clipboard and every item in WarpTab history.") {
                    Button("Clear", action: model.onClearClipboard).controlSize(.small)
                }
            }

            SettingsSection(title: "Typing") {
                SettingRow("Hold keys to repeat", description: "Holding A types aaaaa instead of opening the macOS accent popup. Restart open apps after changing this setting.") {
                    Toggle("", isOn: model.preferenceBinding(\.repeatKeysOnHold)).labelsHidden()
                }
                Divider()
                SettingRow("Control-letter accent chooser", description: "Press Control with a supported letter to choose its accented forms.") {
                    Toggle("", isOn: model.preferenceBinding(\.controlAccentChooserEnabled)).labelsHidden()
                }
            }
        }
    }
}

private struct WindowSwitcherSettingsPage: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        SettingsPage(title: "Window Switcher", description: "Configure how WarpTab switches between windows.") {
            SettingsSection(title: "Keyboard") {
                SettingRow("Enable Window Switcher", description: "Keep WarpTab available for window switching.") {
                    Toggle("", isOn: Binding(get: { model.enabled }, set: model.setEnabled)).labelsHidden()
                }
                Divider()
                SettingRow("Window Switcher shortcut", description: "Shortcut used to open WarpTab.") {
                    ShortcutRecorderRepresentable(shortcut: model.shortcut, onShortcut: model.setShortcut)
                        .frame(minWidth: 132, minHeight: 28)
                }
                Divider()
                SettingRow("Same Application", description: "Switch between windows of the current application.") {
                    Text(SwitcherShortcut.sameApplicationShortcut.displayName)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Same-application shortcut \(SwitcherShortcut.sameApplicationShortcut.displayName)")
                }
                Divider()
                SettingRow("Keyboard search", description: "Type while the switcher is open to filter windows.") {
                    Toggle("", isOn: model.preferenceBinding(\.searchEnabled)).labelsHidden()
                }
            }

            SettingsSection(title: "Windows") {
                toggleRow("Minimized windows", "Include minimized windows.", binding: model.preferenceBinding(\.showMinimized))
                Divider()
                toggleRow("Hidden applications", "Include windows from hidden applications.", binding: model.preferenceBinding(\.showHiddenApplications))
                Divider()
                toggleRow("Full-screen windows", "Include full-screen windows.", binding: model.preferenceBinding(\.showFullscreen))
                Divider()
                toggleRow("Other Spaces", "Include discoverable windows from other Spaces.", binding: model.preferenceBinding(\.showOtherSpaces))
                Divider()
                toggleRow("Apps without windows", "Include running apps that currently have no window.", binding: model.preferenceBinding(\.showWindowlessApps))
                Divider()
                NativeTabStyleSelector(model: model)
            }

            SettingsSection(title: "Appearance") {
                SwitcherStyleSelector(model: model)
                Divider()
                SettingRow("Show View Style in menu bar", description: "Show the View Style submenu in WarpTab’s menu.") {
                    Toggle("", isOn: Binding(
                        get: { model.showsViewStyleInWarpTabMenu },
                        set: model.setShowsViewStyleInWarpTabMenu
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Show View Style menu item")
                }
                Divider()
                SettingRow("Switcher location", description: "Choose which screen displays the switcher.") {
                    Picker("", selection: model.preferenceBinding(\.screenPlacement)) {
                        ForEach(SwitcherScreenPlacement.allCases, id: \.rawValue) { value in
                            Text(value.displayName).tag(value)
                        }
                    }.labelsHidden().frame(width: 210)
                }
                Divider()
                SettingRow("Window scope", description: "Show windows from every display or the current display only.") {
                    Picker("", selection: model.preferenceBinding(\.displayScope)) {
                        ForEach(WindowDisplayScope.allCases, id: \.rawValue) { value in
                            Text(value.displayName).tag(value)
                        }
                    }.labelsHidden().frame(width: 190)
                }
            }

            SettingsSection(title: "Excluded Applications") {
                SettingRow("Add application", description: "Keep an application's windows out of WarpTab.") {
                    Menu("Choose Application…") {
                        if model.availableApplications.isEmpty {
                            Text("No applications available")
                        } else {
                            ForEach(model.availableApplications) { application in
                                Button(application.name) { model.exclude(application.id) }
                            }
                        }
                    }
                }
                Divider()
                SettingRow("Excluded", description: "Remove an application from the exclusion list.") {
                    HStack(spacing: 8) {
                        Picker("", selection: $model.selectedExcludedIdentifier) {
                            if model.excludedApplications.isEmpty {
                                Text("No excluded applications").tag(String?.none)
                            } else {
                                ForEach(model.excludedApplications) { application in
                                    Text(application.name).tag(Optional(application.id))
                                }
                            }
                        }.labelsHidden().frame(width: 190)
                        Button("Remove", action: model.removeSelectedExclusion)
                            .disabled(model.selectedExcludedIdentifier == nil)
                    }
                }
            }
        }
    }

    private func toggleRow(_ title: String, _ description: String, binding: Binding<Bool>) -> some View {
        SettingRow(title, description: description) { Toggle("", isOn: binding).labelsHidden() }
    }
}

private struct NativeTabStyleSelector: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Native window tabs").font(.body)
                Text("Choose whether a native tab group appears as one window or as individual tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                behaviorCard(.grouped)
                behaviorCard(.individual)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func behaviorCard(_ behavior: NativeTabBehavior) -> some View {
        let selected = model.preferences.nativeTabBehavior == behavior
        return Button {
            model.preferenceBinding(\.nativeTabBehavior).wrappedValue = behavior
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                NativeTabIllustration(behavior: behavior, selected: selected)
                    .frame(height: 56)

                HStack(spacing: 7) {
                    Text(behavior == .grouped ? "One window" : "Individual tabs")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(selected ? 0.9 : 0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor),
                        lineWidth: selected ? 1.25 : 0.5
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 220)
        .accessibilityLabel(behavior.displayName)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct NativeTabIllustration: View {
    let behavior: NativeTabBehavior
    let selected: Bool

    private var ink: Color {
        selected ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.62)
    }

    var body: some View {
        Group {
            switch behavior {
            case .grouped:
                ZStack {
                    windowBody
                        .frame(width: 132, height: 48)

                    HStack(spacing: 3) {
                        tab(width: 34, active: true)
                        tab(width: 34, active: false)
                        tab(width: 34, active: false)
                    }
                    .offset(y: -16)

                    VStack(alignment: .leading, spacing: 4) {
                        line(width: 70)
                        line(width: 48).opacity(0.6)
                    }
                    .offset(x: -18, y: 8)
                }
            case .individual:
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(index == 0 ? Color.accentColor.opacity(0.48) : ink.opacity(0.5))
                                .frame(height: 7)
                            VStack(alignment: .leading, spacing: 3) {
                                line(width: index == 1 ? 28 : 32)
                                line(width: 21).opacity(0.55)
                            }
                            .padding(5)
                        }
                        .frame(width: 48, height: 47, alignment: .top)
                        .background(ink.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(index == 0 ? Color.accentColor.opacity(0.65) : ink.opacity(0.38), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityHidden(true)
    }

    private var windowBody: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(ink.opacity(0.14))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.65) : ink.opacity(0.4), lineWidth: 1)
            }
    }

    private func tab(width: CGFloat, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.48) : ink.opacity(0.42))
            .frame(width: width, height: 8)
    }

    private func line(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(ink)
            .frame(width: width, height: 3)
    }
}

private struct SoundSettingsPage: View {
    @ObservedObject var model: WarpTabSettingsModel
    @AppStorage("soundShowOnlyPlayingApps") private var showOnlyPlayingApps = true
    @AppStorage("reduceOnDisconnect") private var reduceOnDisconnect = true
    @AppStorage("soundDisconnectVolume") private var disconnectVolume = 0.25
    @AppStorage("soundPinInput") private var pinInput = true
    @AppStorage("soundGlobalShortcutsEnabled") private var globalShortcutsEnabled = true

    var body: some View {
        SettingsPage(title: "Sound Mixer", description: "Configure WarpTab’s menu bar mixer, outputs, and microphones.") {
            SettingsSection(title: "Menu Bar") {
                SettingRow("Show Sound Mixer", description: "Show a separate Sound Mixer control in the menu bar.") {
                    Toggle("", isOn: Binding(
                        get: { model.showsSoundStatusItem },
                        set: model.setShowsSoundStatusItem
                    ))
                    .labelsHidden()
                }
            }

            SettingsSection(title: "Mixer") {
                SettingRow("Only show apps playing audio", description: "Keep inactive and background audio clients out of the mixer.") {
                    Toggle("", isOn: $showOnlyPlayingApps).labelsHidden()
                }
            }

            SettingsSection(title: "Outputs") {
                SettingRow("Lower volume after disconnect", description: "Protect against loud speaker playback when headphones disconnect.") {
                    Toggle("", isOn: $reduceOnDisconnect).labelsHidden()
                }
                Divider()
                SettingRow("Speaker volume", description: "Volume used after WarpTab detects that headphones disconnected.") {
                    HStack(spacing: 10) {
                        Slider(value: $disconnectVolume, in: 0...1, step: 0.05)
                            .accessibilityLabel("Speaker volume after disconnect")
                            .accessibilityValue("\(Int((disconnectVolume * 100).rounded())) percent")

                        Text("\(Int((disconnectVolume * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    .frame(width: 220)
                }
                .disabled(!reduceOnDisconnect)
            }

            SettingsSection(title: "Microphone") {
                SettingRow("Keep selected input pinned", description: "Restore your chosen microphone if macOS or another app changes it.") {
                    Toggle("", isOn: $pinInput).labelsHidden()
                }
            }

            SettingsSection(title: "Keyboard") {
                SettingRow("Sound shortcuts", description: "Use Control–Option–O to cycle favorite outputs and Control–Option–M to mute every microphone.") {
                    Toggle("", isOn: $globalShortcutsEnabled).labelsHidden()
                }
            }
        }
    }
}

private struct DockSettingsPage: View {
    @ObservedObject var model: WarpTabSettingsModel

    private var dockEnabled: Binding<Bool> { model.preferenceBinding(\.dockPreviewsEnabled) }
    private var closeEnabled: Binding<Bool> { model.preferenceBinding(\.dockPreviewCloseEnabled) }
    private var doubleClickEnabled: Binding<Bool> { model.preferenceBinding(\.minimizeAllWindowsOnDockDoubleClick) }

    var body: some View {
        SettingsPage(title: "Dock", description: "Configure WarpTab’s window previews and interactions in the Dock.") {
            SettingsSection(title: "Window Previews") {
                SettingRow("Dock window previews", description: "Hover over a running app in the Dock to see its open windows.") {
                    Toggle("", isOn: dockEnabled).labelsHidden()
                }
                Divider()
                SettingRow("Preview size", description: "Choose the size of previews shown above the Dock.") {
                    HStack {
                        Spacer(minLength: 0)
                        Picker("", selection: model.preferenceBinding(\.dockPreviewSize)) {
                            ForEach(DockPreviewSize.allCases, id: \.rawValue) { value in Text(value.displayName).tag(value) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    .frame(width: 250)
                }.disabled(!model.preferences.dockPreviewsEnabled)
                Divider()
                dockToggle("Include minimized windows", "Show minimized windows in Dock previews.", \.dockPreviewShowMinimized)
                Divider()
                dockToggle("Include hidden applications", "Show windows belonging to hidden apps.", \.dockPreviewShowHiddenApplications)
                Divider()
                dockToggle("Include full-screen windows", "Show full-screen windows in Dock previews.", \.dockPreviewShowFullscreen)
            }

            SettingsSection(title: "App Icon Clicks") {
                dockToggle("Choose window on app click", "For apps with multiple windows, show previews without activating every window.", \.chooseWindowOnMultiWindowDockClick)
                Divider()
                dockToggle("Minimize active window on click", "Click the frontmost single-window app's Dock icon to minimize it.", \.minimizeFrontmostWindowOnDockClick)
                Divider()
                SettingRow("Minimize on double-click", description: "Quickly double-click a multi-window app's Dock icon to minimize its windows.") {
                    Toggle("", isOn: doubleClickEnabled).labelsHidden()
                }.disabled(!model.preferences.dockPreviewsEnabled)
                Divider()
                DockDoubleClickScopeSelector(model: model)
                    .disabled(!model.preferences.dockPreviewsEnabled || !model.preferences.minimizeAllWindowsOnDockDoubleClick)
            }

            SettingsSection(title: "Preview Actions") {
                SettingRow("Close windows from previews", description: "Show a close button on each Dock window preview.") {
                    Toggle("", isOn: closeEnabled).labelsHidden()
                }.disabled(!model.preferences.dockPreviewsEnabled)
                Divider()
                SettingRow("Quit after closing last window", description: "Quit an app when its final window is closed from a preview.") {
                    Toggle("", isOn: model.preferenceBinding(\.quitAppWhenLastWindowClosed)).labelsHidden()
                }.disabled(!model.preferences.dockPreviewsEnabled || !model.preferences.dockPreviewCloseEnabled)
            }
        }
    }

    private func dockToggle(
        _ title: String,
        _ description: String,
        _ keyPath: ReferenceWritableKeyPath<WarpPreferences, Bool>
    ) -> some View {
        SettingRow(title, description: description) {
            Toggle("", isOn: model.preferenceBinding(keyPath)).labelsHidden()
        }.disabled(!model.preferences.dockPreviewsEnabled)
    }
}

private struct DockDoubleClickScopeSelector: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Double-click minimizes").font(.body)
                Text("Choose whether to minimize every window or only the top window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                scopeCard(.allWindows)
                scopeCard(.topWindow)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scopeCard(_ scope: DockDoubleClickMinimizeScope) -> some View {
        let selected = model.preferences.dockDoubleClickMinimizeScope == scope
        return Button {
            model.preferenceBinding(\.dockDoubleClickMinimizeScope).wrappedValue = scope
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                DockMinimizeScopeIllustration(scope: scope, selected: selected)
                    .frame(height: 56)

                HStack(spacing: 7) {
                    Text(scope.displayName)
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(selected ? 0.9 : 0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor),
                        lineWidth: selected ? 1.25 : 0.5
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 220)
        .accessibilityLabel("\(scope.displayName) double-click option")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct DockMinimizeScopeIllustration: View {
    let scope: DockDoubleClickMinimizeScope
    let selected: Bool

    private var ink: Color {
        selected ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.62)
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let isTop = index == 2
                    miniatureWindow(accented: isTop)
                        .frame(width: 62, height: 38)
                        .offset(x: CGFloat(index - 1) * 7, y: CGFloat(index - 1) * -5)
                        .opacity(scope == .allWindows || isTop ? 1 : 0.72)
                }
            }
            .frame(width: 82, height: 50)

            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)

            VStack(spacing: 4) {
                let barCount = scope == .allWindows ? 3 : 1
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index == 0 ? Color.accentColor.opacity(0.55) : ink.opacity(0.5))
                        .frame(width: 34 - CGFloat(index) * 4, height: 5)
                }
            }
            .frame(width: 36, height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityHidden(true)
    }

    private func miniatureWindow(accented: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(accented ? Color.accentColor.opacity(0.5) : ink.opacity(0.42))
                    .frame(height: 7)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(accented ? Color.accentColor.opacity(0.68) : ink.opacity(0.42), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct WindowSnappingPage: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        SettingsPage(title: "Window Snap", description: "Use familiar Windows-style directional window controls on macOS.") {
            SettingsSection(title: "Windows-Style Window Controls") {
                SettingRow(
                    "Enable Windows-style snapping",
                    description: "Move, resize, maximize, restore, and minimize the focused window based on its current placement."
                ) {
                    Toggle("", isOn: model.preferenceBinding(\.windowSnappingEnabled)).labelsHidden()
                }
                Divider()
                SnapMinimizeBehaviorSelector(model: model)
                .disabled(!model.preferences.windowSnappingEnabled)
                Divider()
                SnapUpBehaviorSelector(model: model)
                .disabled(!model.preferences.windowSnappingEnabled)
                Divider()
                SettingRow(
                    "Move snapping across displays",
                    description: "Continue directional snapping onto spatially adjacent monitors."
                ) {
                    Toggle("", isOn: model.preferenceBinding(\.windowSnapMoveAcrossDisplays)).labelsHidden()
                }
                .disabled(!model.preferences.windowSnappingEnabled)
                Divider()
                SettingRow(
                    "Show Snap Assist",
                    description: "Offer other individual windows for the remaining region after snapping."
                ) {
                    Toggle("", isOn: model.preferenceBinding(\.windowSnapAssistEnabled)).labelsHidden()
                }
                .disabled(!model.preferences.windowSnappingEnabled)
                Divider()
                SnapAssistStyleSelector(model: model)
                .disabled(!model.preferences.windowSnappingEnabled || !model.preferences.windowSnapAssistEnabled)
            }
            SettingsSection(title: "Directional Shortcuts") {
                snapShortcutRow("Move / Snap Left", shortcut: "⌃ ⇧ ←")
                Divider()
                snapShortcutRow("Move / Snap Right", shortcut: "⌃ ⇧ →")
                Divider()
                snapShortcutRow("Move / Snap Up", shortcut: "⌃ ⇧ ↑")
                Divider()
                snapShortcutRow("Move / Snap Down", shortcut: "⌃ ⇧ ↓")
            }
        }
    }

    private func snapShortcutRow(_ title: String, shortcut: String) -> some View {
        SettingRow(title, description: "Stateful window command") {
            Text(shortcut)
                .font(.system(.body, design: .rounded).weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("\(title) \(shortcut)")
        }
    }
}

private struct SnapMinimizeBehaviorSelector: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        SnapBehaviorSelector(
            title: "After minimizing",
            description: "Choose which window receives focus after Move / Snap Down minimizes the focused window."
        ) {
            ForEach(SnapMinimizeFocusBehavior.allCases, id: \.self) { behavior in
                SnapBehaviorCard(
                    title: behavior.displayName,
                    selected: model.preferences.snapMinimizeFocusBehavior == behavior,
                    illustration: .afterMinimizing(behavior)
                ) {
                    model.preferenceBinding(\.snapMinimizeFocusBehavior).wrappedValue = behavior
                }
            }
        }
    }
}

private struct SnapUpBehaviorSelector: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        SnapBehaviorSelector(
            title: "Next Up command",
            description: "Choose whether Move / Snap Up restores the last minimized window or controls the active window."
        ) {
            ForEach(SnapUpAfterMinimizeBehavior.allCases, id: \.self) { behavior in
                SnapBehaviorCard(
                    title: behavior.displayName,
                    selected: model.preferences.snapUpAfterMinimizeBehavior == behavior,
                    illustration: .nextUp(behavior)
                ) {
                    model.preferenceBinding(\.snapUpAfterMinimizeBehavior).wrappedValue = behavior
                }
            }
        }
    }
}

private struct SnapBehaviorSelector<Cards: View>: View {
    let title: String
    let description: String
    @ViewBuilder let cards: Cards

    init(title: String, description: String, @ViewBuilder cards: () -> Cards) {
        self.title = title
        self.description = description
        self.cards = cards()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) { cards }
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum SnapBehaviorIllustrationKind {
    case afterMinimizing(SnapMinimizeFocusBehavior)
    case nextUp(SnapUpAfterMinimizeBehavior)
}

private struct SnapBehaviorCard: View {
    let title: String
    let selected: Bool
    let illustration: SnapBehaviorIllustrationKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                SnapBehaviorIllustration(kind: illustration, selected: selected)
                    .frame(height: 54)

                HStack(spacing: 7) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(selected ? 0.9 : 0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor),
                        lineWidth: selected ? 1.25 : 0.5
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 220)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct SnapBehaviorIllustration: View {
    let kind: SnapBehaviorIllustrationKind
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion ? 0.58 : (elapsed.truncatingRemainder(dividingBy: 2.8) / 2.8)
            illustration(progress: phase)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func illustration(progress: Double) -> some View {
        switch kind {
        case .afterMinimizing(let behavior):
            afterMinimizing(behavior, progress: progress)
        case .nextUp(let behavior):
            nextUp(behavior, progress: progress)
        }
    }

    private func afterMinimizing(_ behavior: SnapMinimizeFocusBehavior, progress: Double) -> some View {
        let motion = pulse(progress)
        let frontOpacity = max(0.08, 1 - motion * 1.35)
        return ZStack {
            miniatureWindow(accented: behavior == .activateWindowBehind && motion > 0.55)
                .frame(width: 72, height: 42)
                .offset(x: -15, y: -4)

            if behavior == .systemDefault {
                miniatureWindow(accented: motion > 0.72)
                    .frame(width: 62, height: 36)
                    .offset(x: 25, y: 3)
            }

            miniatureWindow(accented: motion < 0.4)
                .frame(width: 72, height: 42)
                .scaleEffect(x: 1 - motion * 0.45, y: 1 - motion * 0.72, anchor: .bottom)
                .offset(x: 10, y: motion * 25)
                .opacity(frontOpacity)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 32, height: 4)
                .offset(x: 10, y: 23)
                .opacity(motion)
        }
    }

    private func nextUp(_ behavior: SnapUpAfterMinimizeBehavior, progress: Double) -> some View {
        let motion = pulse(progress)
        let restoring = behavior == .restoreMinimizedWindow
        return ZStack {
            miniatureWindow(accented: !restoring)
                .frame(width: 72, height: 42)
                .offset(x: restoring ? -18 : 7, y: -4)
                .scaleEffect(!restoring ? 1 + motion * 0.05 : 1)

            miniatureWindow(accented: restoring && motion > 0.45)
                .frame(width: 70, height: 41)
                .scaleEffect(x: restoring ? 0.48 + motion * 0.52 : 0.48, y: restoring ? 0.12 + motion * 0.88 : 0.12, anchor: .bottom)
                .offset(x: restoring ? 15 : -21, y: restoring ? 21 - motion * 24 : 21)
                .opacity(restoring ? 0.3 + motion * 0.7 : 0.45)

            Image(systemName: "arrow.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .offset(x: restoring ? 15 : 7, y: 10 - motion * 19)
                .opacity(0.35 + motion * 0.65)
        }
    }

    private func miniatureWindow(accented: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.secondary.opacity(0.2))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(accented ? Color.accentColor.opacity(0.48) : Color.secondary.opacity(0.34))
                    .frame(height: 7)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(accented ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.38), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func pulse(_ progress: Double) -> Double {
        let triangular = progress < 0.5 ? progress * 2 : (1 - progress) * 2
        return triangular * triangular * (3 - 2 * triangular)
    }
}

private struct SnapAssistStyleSelector: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Snap Assist view").font(.body)
                Text("Choose how candidate windows appear in the remaining region.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                styleCard(.list)
                styleCard(.thumbnails)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func styleCard(_ layout: SnapAssistLayout) -> some View {
        let selected = model.preferences.snapAssistLayout == layout
        let illustrationLayout: SwitcherLayout = layout == .list ? .list : .thumbnails
        return Button {
            model.preferenceBinding(\.snapAssistLayout).wrappedValue = layout
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                SwitcherStyleIllustration(layout: illustrationLayout, selected: selected)
                    .frame(height: 58)

                HStack(spacing: 8) {
                    Text(layout.displayName)
                        .font(.callout.weight(.medium))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor)
                    .opacity(selected ? 0.9 : 0.55)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor),
                        lineWidth: selected ? 1.25 : 0.5
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 220)
        .accessibilityLabel("\(layout.displayName) Snap Assist view")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct PermissionsSettingsPage: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        SettingsPage(
            title: "Permissions",
            description: "WarpTab requires certain system permissions for its window management features to work correctly."
        ) {
            SettingsSection(title: "System Access") {
                PermissionRow(
                    title: "Accessibility",
                    description: "Allows WarpTab to discover, focus, and manage application windows.",
                    granted: model.accessibilityGranted,
                    buttonTitle: "Open System Settings",
                    action: model.onOpenAccessibility
                )
                Divider()
                PermissionRow(
                    title: "Screen Recording",
                    description: "Allows WarpTab to display live window thumbnails. Window switching works without it.",
                    granted: model.screenRecordingGranted,
                    buttonTitle: "Open System Settings",
                    action: model.openScreenRecordingSettings
                )
                Divider()
                PermissionInfoRow(
                    title: "System Audio Recording",
                    description: "Allows WarpTab to receive an app’s outgoing audio long enough to adjust its volume or send it to another output. Audio is processed in memory and is never saved or sent anywhere.",
                    status: "Requested on first use",
                    buttonTitle: "Open System Settings",
                    action: model.openSystemAudioRecordingSettings
                )
            }
        }
        .onAppear { model.refreshPermissionStatus(listenerRunning: model.listenerRunning) }
    }
}

private struct AboutWarpTabPage: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        SettingsPage(title: "About WarpTab", description: "Information about this installation of WarpTab.") {
            VStack(spacing: 14) {
                Image(nsImage: AppIcon.make())
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .accessibilityLabel("WarpTab app icon")
                Text("WarpTab").font(.title2.weight(.semibold))
                Text("Version \(version) (\(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
        }
    }
}

private struct SwitcherStyleSelector: View {
    @ObservedObject var model: WarpTabSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Switcher style").font(.body)
                Text("Choose the layout used by the existing window switcher.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                styleCard(.list)
                styleCard(.thumbnails)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func styleCard(_ layout: SwitcherLayout) -> some View {
        let selected = model.layout == layout
        return Button {
            model.setLayout(layout)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                SwitcherStyleIllustration(layout: layout, selected: selected)
                    .frame(height: 58)

                HStack(spacing: 8) {
                    Text(layout.displayName)
                        .font(.callout.weight(.medium))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor)
                    .opacity(selected ? 0.9 : 0.55)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor),
                        lineWidth: selected ? 1.25 : 0.5
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 220)
        .accessibilityLabel("\(layout.displayName) switcher style")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct SwitcherStyleIllustration: View {
    let layout: SwitcherLayout
    let selected: Bool

    private var ink: Color {
        selected ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.62)
    }

    var body: some View {
        GeometryReader { geometry in
            switch layout {
            case .list:
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(ink)
                                .frame(width: 11, height: 11)
                            VStack(alignment: .leading, spacing: 2) {
                                illustrationLine(width: geometry.size.width * (index == 1 ? 0.48 : 0.57), height: 3)
                                illustrationLine(width: geometry.size.width * 0.31, height: 2)
                                    .opacity(0.6)
                            }
                            Spacer(minLength: 3)
                            illustrationLine(width: 7, height: 2)
                                .opacity(0.55)
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(index == 0 ? Color.accentColor.opacity(0.16) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .frame(width: min(geometry.size.width, 164))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            case .thumbnails:
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(ink.opacity(0.82))
                                .frame(height: 38)
                            HStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(ink)
                                    .frame(width: 7, height: 7)
                                illustrationLine(width: index == 1 ? 20 : 24, height: 2.5)
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(3)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(index == 0 ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                        }
                        .frame(width: 50)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .accessibilityHidden(true)
    }

    private func illustrationLine(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(ink)
            .frame(width: width, height: height)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    init(title: String, description: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .top)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 20)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                }
        }
    }
}

private struct SettingRow<Accessory: View>: View {
    let title: String
    let description: String
    @ViewBuilder let accessory: Accessory

    init(_ title: String, description: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.description = description
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            accessory.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

private struct PermissionRow: View {
    let title: String
    let description: String
    let granted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        SettingRow(title, description: description) {
            HStack(spacing: 12) {
                Label(granted ? "Granted" : "Not Granted", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(granted ? Color.green : Color.secondary)
                Button(buttonTitle, action: action).controlSize(.small)
            }
        }
    }
}

private struct PermissionInfoRow: View {
    let title: String
    let description: String
    let status: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        SettingRow(title, description: description) {
            HStack(spacing: 12) {
                Label(status, systemImage: "waveform")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Button(buttonTitle, action: action).controlSize(.small)
            }
        }
    }
}

private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    let shortcut: SwitcherShortcut
    let onShortcut: (SwitcherShortcut) -> Bool

    func makeNSView(context: Context) -> SystemShortcutRecorderButton {
        let button = SystemShortcutRecorderButton(shortcut: shortcut)
        button.onShortcut = onShortcut
        return button
    }

    func updateNSView(_ button: SystemShortcutRecorderButton, context: Context) {
        button.onShortcut = onShortcut
        button.setShortcut(shortcut)
    }
}

private final class SystemShortcutRecorderButton: NSButton {
    var onShortcut: ((SwitcherShortcut) -> Bool)?
    private var shortcut: SwitcherShortcut
    private var isRecording = false

    init(shortcut: SwitcherShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        title = shortcut.displayName
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("Keyboard shortcut")
        setAccessibilityHelp("Press to record a new keyboard shortcut")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func setShortcut(_ value: SwitcherShortcut) {
        guard !isRecording else { return }
        shortcut = value
        title = value.displayName
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording()
            return
        }
        let modifiers = SwitcherShortcut.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep()
            showTemporaryMessage("Add a modifier")
            return
        }
        let candidate = SwitcherShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers,
            keyLabel: SwitcherShortcut.keyLabel(for: event)
        )
        guard !candidate.isReserved else {
            NSSound.beep()
            showTemporaryMessage("Reserved by macOS")
            return
        }
        if onShortcut?(candidate) == true {
            shortcut = candidate
            finishRecording()
        } else {
            NSSound.beep()
            showTemporaryMessage("Unavailable")
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { finishRecording() }
        return super.resignFirstResponder()
    }

    private func finishRecording() {
        isRecording = false
        title = shortcut.displayName
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    private func showTemporaryMessage(_ message: String) {
        title = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isRecording else { return }
            self.title = "Type shortcut…"
        }
    }
}
