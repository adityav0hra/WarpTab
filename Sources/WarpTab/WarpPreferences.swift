import AppKit

enum SwitcherScreenPlacement: String, CaseIterable {
    case activeWindow
    case mousePointer
    case mainDisplay

    var displayName: String {
        switch self {
        case .activeWindow: return "Active Window Display"
        case .mousePointer: return "Mouse Pointer Display"
        case .mainDisplay: return "Main Display"
        }
    }
}

enum WindowDisplayScope: String, CaseIterable {
    case allDisplays
    case currentDisplay

    var displayName: String {
        switch self {
        case .allDisplays: return "All Displays"
        case .currentDisplay: return "Current Display Only"
        }
    }
}

enum NativeTabBehavior: String, CaseIterable {
    case grouped
    case individual

    var displayName: String {
        switch self {
        case .grouped: return "Treat Tab Group as One Window"
        case .individual: return "Show Native Tabs Individually"
        }
    }
}

enum DockPreviewSize: String, CaseIterable {
    case small
    case `default`

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .default: return "Default"
        }
    }
}

enum DockDoubleClickMinimizeScope: String, CaseIterable {
    case allWindows
    case topWindow

    var displayName: String {
        switch self {
        case .allWindows: return "All Windows"
        case .topWindow: return "Top Window"
        }
    }
}

final class WarpPreferences {
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    var searchEnabled: Bool {
        get { defaults.bool(forKey: "searchEnabled") }
        set { set(newValue, forKey: "searchEnabled") }
    }

    var previewsEnabled: Bool {
        get { defaults.bool(forKey: "previewsEnabled") }
        set { set(newValue, forKey: "previewsEnabled") }
    }

    var dockPreviewsEnabled: Bool {
        get { defaults.bool(forKey: "dockPreviewsEnabled") }
        set { set(newValue, forKey: "dockPreviewsEnabled") }
    }

    var dockPreviewCloseEnabled: Bool {
        get { defaults.bool(forKey: "dockPreviewCloseEnabled") }
        set { set(newValue, forKey: "dockPreviewCloseEnabled") }
    }

    var quitAppWhenLastWindowClosed: Bool {
        get { defaults.bool(forKey: "quitAppWhenLastWindowClosed") }
        set { set(newValue, forKey: "quitAppWhenLastWindowClosed") }
    }

    var dockPreviewSize: DockPreviewSize {
        get { DockPreviewSize(rawValue: defaults.string(forKey: "dockPreviewSize") ?? "") ?? .default }
        set { set(newValue.rawValue, forKey: "dockPreviewSize") }
    }

    var dockPreviewShowMinimized: Bool {
        get { defaults.bool(forKey: "dockPreviewShowMinimized") }
        set { set(newValue, forKey: "dockPreviewShowMinimized") }
    }

    var dockPreviewShowHiddenApplications: Bool {
        get { defaults.bool(forKey: "dockPreviewShowHiddenApplications") }
        set { set(newValue, forKey: "dockPreviewShowHiddenApplications") }
    }

    var dockPreviewShowFullscreen: Bool {
        get { defaults.bool(forKey: "dockPreviewShowFullscreen") }
        set { set(newValue, forKey: "dockPreviewShowFullscreen") }
    }

    var minimizeFrontmostWindowOnDockClick: Bool {
        get { defaults.bool(forKey: "minimizeFrontmostWindowOnDockClick") }
        set { set(newValue, forKey: "minimizeFrontmostWindowOnDockClick") }
    }

    var chooseWindowOnMultiWindowDockClick: Bool {
        get { defaults.bool(forKey: "chooseWindowOnMultiWindowDockClick") }
        set { set(newValue, forKey: "chooseWindowOnMultiWindowDockClick") }
    }

    var minimizeAllWindowsOnDockDoubleClick: Bool {
        get { defaults.bool(forKey: "minimizeAllWindowsOnDockDoubleClick") }
        set { set(newValue, forKey: "minimizeAllWindowsOnDockDoubleClick") }
    }

    var dockDoubleClickMinimizeScope: DockDoubleClickMinimizeScope {
        get {
            DockDoubleClickMinimizeScope(
                rawValue: defaults.string(forKey: "dockDoubleClickMinimizeScope") ?? ""
            ) ?? .allWindows
        }
        set { set(newValue.rawValue, forKey: "dockDoubleClickMinimizeScope") }
    }

    var showMinimized: Bool {
        get { defaults.bool(forKey: "showMinimizedWindows") }
        set { set(newValue, forKey: "showMinimizedWindows") }
    }

    var showHiddenApplications: Bool {
        get { defaults.bool(forKey: "showHiddenApplications") }
        set { set(newValue, forKey: "showHiddenApplications") }
    }

    var showFullscreen: Bool {
        get { defaults.bool(forKey: "showFullscreenWindows") }
        set { set(newValue, forKey: "showFullscreenWindows") }
    }

    var showOtherSpaces: Bool {
        get { defaults.bool(forKey: "showOtherSpaces") }
        set { set(newValue, forKey: "showOtherSpaces") }
    }

    var showWindowlessApps: Bool {
        get { defaults.bool(forKey: "showWindowlessApps") }
        set { set(newValue, forKey: "showWindowlessApps") }
    }

    var screenPlacement: SwitcherScreenPlacement {
        get { SwitcherScreenPlacement(rawValue: defaults.string(forKey: "screenPlacement") ?? "") ?? .activeWindow }
        set { set(newValue.rawValue, forKey: "screenPlacement") }
    }

    var displayScope: WindowDisplayScope {
        get { WindowDisplayScope(rawValue: defaults.string(forKey: "displayScope") ?? "") ?? .allDisplays }
        set { set(newValue.rawValue, forKey: "displayScope") }
    }

    var nativeTabBehavior: NativeTabBehavior {
        get { NativeTabBehavior(rawValue: defaults.string(forKey: "nativeTabBehavior") ?? "") ?? .grouped }
        set { set(newValue.rawValue, forKey: "nativeTabBehavior") }
    }

    var excludedBundleIdentifiers: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedBundleIdentifiers") ?? []) }
        set {
            defaults.set(newValue.sorted(), forKey: "excludedBundleIdentifiers")
            onChange?()
        }
    }

    var filterOptions: WindowFilterOptions {
        WindowFilterOptions(
            showMinimized: showMinimized,
            showHiddenApplications: showHiddenApplications,
            showFullscreen: showFullscreen,
            showOtherSpaces: showOtherSpaces,
            showWindowlessApps: showWindowlessApps,
            currentDisplayOnly: displayScope == .currentDisplay,
            excludedBundleIdentifiers: excludedBundleIdentifiers
        )
    }

    var dockPreviewFilterOptions: DockPreviewFilterOptions {
        DockPreviewFilterOptions(
            showMinimized: dockPreviewShowMinimized,
            showHiddenApplications: dockPreviewShowHiddenApplications,
            showFullscreen: dockPreviewShowFullscreen
        )
    }

    func exclude(bundleIdentifier: String) {
        var values = excludedBundleIdentifiers
        values.insert(bundleIdentifier)
        excludedBundleIdentifiers = values
    }

    func include(bundleIdentifier: String) {
        var values = excludedBundleIdentifiers
        values.remove(bundleIdentifier)
        excludedBundleIdentifiers = values
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            "searchEnabled": true,
            "previewsEnabled": true,
            "dockPreviewsEnabled": true,
            "dockPreviewCloseEnabled": true,
            "quitAppWhenLastWindowClosed": false,
            "dockPreviewSize": DockPreviewSize.default.rawValue,
            "dockPreviewShowMinimized": true,
            "dockPreviewShowHiddenApplications": true,
            "dockPreviewShowFullscreen": true,
            "minimizeFrontmostWindowOnDockClick": true,
            "chooseWindowOnMultiWindowDockClick": true,
            "minimizeAllWindowsOnDockDoubleClick": true,
            "dockDoubleClickMinimizeScope": DockDoubleClickMinimizeScope.allWindows.rawValue,
            "showMinimizedWindows": true,
            "showHiddenApplications": true,
            "showFullscreenWindows": true,
            "showOtherSpaces": true,
            "showWindowlessApps": false,
            "screenPlacement": SwitcherScreenPlacement.activeWindow.rawValue,
            "displayScope": WindowDisplayScope.allDisplays.rawValue,
            "nativeTabBehavior": NativeTabBehavior.grouped.rawValue,
            "excludedBundleIdentifiers": []
        ])
    }

    private func set(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
