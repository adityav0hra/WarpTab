import Foundation

enum SwitcherWindowScope: Equatable {
    case allWindows
    case application(pid_t)

    func includes(processIdentifier: pid_t) -> Bool {
        switch self {
        case .allWindows: return true
        case .application(let pid): return pid == processIdentifier
        }
    }
}

struct WindowFilterOptions: Equatable {
    let showMinimized: Bool
    let showHiddenApplications: Bool
    let showFullscreen: Bool
    let showOtherSpaces: Bool
    let showWindowlessApps: Bool
    let currentDisplayOnly: Bool
    let excludedBundleIdentifiers: Set<String>
}

enum WindowFilter {
    static func apply(
        to windows: [WarpWindow],
        options: WindowFilterOptions,
        targetScreenIdentifier: String?,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> [WarpWindow] {
        windows.filter { window in
            if window.application.processIdentifier == ownProcessIdentifier { return false }
            if let bundle = window.bundleIdentifier,
               options.excludedBundleIdentifiers.contains(bundle) { return false }
            if window.isWindowlessApplication && !options.showWindowlessApps { return false }
            if window.isMinimized && !options.showMinimized { return false }
            if window.isHidden && !options.showHiddenApplications { return false }
            if window.isFullscreen && !options.showFullscreen { return false }
            if !options.showOtherSpaces,
               !window.isOnScreen,
               !window.isMinimized,
               !window.isHidden { return false }
            if options.currentDisplayOnly,
               let targetScreenIdentifier,
               window.screenIdentifier != targetScreenIdentifier { return false }
            return true
        }
    }
}
