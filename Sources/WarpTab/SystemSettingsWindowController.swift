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
        onEnabledChange: @escaping (Bool) -> Void,
        onShortcutChange: @escaping (SwitcherShortcut) -> Bool,
        onLayoutChange: @escaping (SwitcherLayout) -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        model = WarpTabSettingsModel(
            preferences: preferences,
            store: store,
            enabled: initiallyEnabled,
            shortcut: initiallySelectedShortcut,
            layout: initiallySelectedLayout,
            onEnabledChange: onEnabledChange,
            onShortcutChange: onShortcutChange,
            onLayoutChange: onLayoutChange,
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
    let onOpenAccessibility: () -> Void

    @Published var enabled: Bool
    @Published var shortcut: SwitcherShortcut
    @Published var layout: SwitcherLayout
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
        onEnabledChange: @escaping (Bool) -> Void,
        onShortcutChange: @escaping (SwitcherShortcut) -> Bool,
        onLayoutChange: @escaping (SwitcherLayout) -> Void,
        onOpenAccessibility: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.store = store
        self.enabled = enabled
        self.shortcut = shortcut
        self.layout = layout
        self.onEnabledChange = onEnabledChange
        self.onShortcutChange = onShortcutChange
        self.onLayoutChange = onLayoutChange
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
    case dock
    case windowSnapping
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
                    Section("Features") {
                        sidebarItem("Window Switcher", symbol: "rectangle.on.rectangle", destination: .windowSwitcher)
                        sidebarItem("Dock", symbol: "dock.rectangle", destination: .dock)
                        sidebarItem("Window Snapping", symbol: "rectangle.split.3x1", destination: .windowSnapping)
                    }
                    Section("Permissions") {
                        sidebarItem("Permissions", symbol: "hand.raised", destination: .permissions)
                    }
                }
                .listStyle(.sidebar)

                Divider()
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
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
                .accessibilityLabel("About WarpTab")
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            Group {
                switch model.selection ?? .windowSwitcher {
                case .windowSwitcher: WindowSwitcherSettingsPage(model: model)
                case .dock: DockSettingsPage(model: model)
                case .windowSnapping: WindowSnappingPage()
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
                SettingRow("Native window tabs", description: "Choose how reliably exposed AppKit window tabs are represented.") {
                    Picker("", selection: model.preferenceBinding(\.nativeTabBehavior)) {
                        ForEach(NativeTabBehavior.allCases, id: \.rawValue) { value in
                            Text(value.displayName).tag(value)
                        }
                    }.labelsHidden().frame(width: 230)
                }
            }

            SettingsSection(title: "Appearance") {
                SwitcherStyleSelector(model: model)
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
                    Picker("", selection: model.preferenceBinding(\.dockPreviewSize)) {
                        ForEach(DockPreviewSize.allCases, id: \.rawValue) { value in Text(value.displayName).tag(value) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
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
                SettingRow("Double-click minimizes", description: "Choose whether to minimize every window or only the top window.") {
                    Picker("", selection: model.preferenceBinding(\.dockDoubleClickMinimizeScope)) {
                        ForEach(DockDoubleClickMinimizeScope.allCases, id: \.rawValue) { value in
                            Text(value.displayName).tag(value)
                        }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }.disabled(!model.preferences.dockPreviewsEnabled || !model.preferences.minimizeAllWindowsOnDockDoubleClick)
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

private struct WindowSnappingPage: View {
    var body: some View {
        SettingsPage(title: "Window Snapping", description: "Quickly position and resize windows using keyboard shortcuts.") {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Coming Soon").font(.title3.weight(.semibold))
                Text("Window Snapping is planned for a future WarpTab update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 64)
        }
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
