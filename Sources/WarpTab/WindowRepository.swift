import AppKit
import ApplicationServices

struct SwitchableWindow {
    let application: NSRunningApplication
    let title: String
    let rawTitle: String?
    let appName: String
    let icon: NSImage
    let windowID: CGWindowID?
    let appWindowIndex: Int
    let isMinimized: Bool
    let isCurrent: Bool
}

private struct AccessibilityWindowInfo {
    let title: String?
    let isMinimized: Bool
}

final class WindowRepository {
    var onTitlesUpdated: (() -> Void)?

    private let titleStateLock = NSLock()
    private var accessibilityWindowCache: [pid_t: [AccessibilityWindowInfo]] = [:]
    private var titleRefreshInProgress = false
    private let titleRefreshQueue = DispatchQueue(
        label: "com.warptab.window-title-refresh",
        qos: .userInitiated
    )

    func currentWindows(refreshTitles: Bool = true) -> [SwitchableWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var perAppIndex: [pid_t: Int] = [:]
        var candidates: [(app: NSRunningApplication, pid: pid_t, appName: String, rawTitle: String?, windowID: CGWindowID?, index: Int)] = []

        for window in info {
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  !app.isTerminated else { continue }

            if let bounds = window[kCGWindowBounds as String] as? [String: NSNumber] {
                let width = bounds["Width"]?.doubleValue ?? 0
                let height = bounds["Height"]?.doubleValue ?? 0
                guard width >= 120, height >= 80 else { continue }
            }

            let appName = app.localizedName ?? (window[kCGWindowOwnerName as String] as? String) ?? "Application"
            let rawTitle = (window[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let windowID = (window[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
            let index = perAppIndex[pid, default: 0]
            perAppIndex[pid] = index + 1
            candidates.append((app, pid, appName, rawTitle?.isEmpty == false ? rawTitle : nil, windowID, index))
        }

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ownPID && $0.activationPolicy == .regular && !$0.isTerminated
        }
        let appsByPID = Dictionary(runningApps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let accessibilityWindows = cachedWindows()
        if refreshTitles { refreshTitleCache(for: appsByPID) }

        var representedIndices: [pid_t: Set<Int>] = [:]
        var result = candidates.enumerated().map { position, candidate in
            let cached = accessibilityWindows[candidate.pid] ?? []
            let availableVisible = cached.enumerated().filter {
                !$0.element.isMinimized && !(representedIndices[candidate.pid]?.contains($0.offset) ?? false)
            }
            let matched = candidate.rawTitle.flatMap { title in
                availableVisible.first { $0.element.title == title }
            } ?? (availableVisible.indices.contains(candidate.index) ? availableVisible[candidate.index] : nil)
            let accessibilityIndex = matched?.offset ?? candidate.index
            let accessibilityInfo = matched?.element
            representedIndices[candidate.pid, default: []].insert(accessibilityIndex)

            let resolvedTitle = candidate.rawTitle ?? accessibilityInfo?.title
            let displayTitle = resolvedTitle?.isEmpty == false ? resolvedTitle! : candidate.appName
            let icon = candidate.app.icon
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: candidate.appName)
                ?? NSImage()
            return SwitchableWindow(
                application: candidate.app,
                title: displayTitle,
                rawTitle: resolvedTitle,
                appName: candidate.appName,
                icon: icon,
                windowID: candidate.windowID,
                appWindowIndex: accessibilityIndex,
                isMinimized: accessibilityInfo?.isMinimized ?? false,
                isCurrent: position == 0
            )
        }

        let cachedPIDs = accessibilityWindows.keys.sorted { left, right in
            let leftName = appsByPID[left]?.localizedName ?? ""
            let rightName = appsByPID[right]?.localizedName ?? ""
            let comparison = leftName.localizedStandardCompare(rightName)
            return comparison == .orderedSame ? left < right : comparison == .orderedAscending
        }
        for pid in cachedPIDs {
            guard let cached = accessibilityWindows[pid] else { continue }
            guard let app = appsByPID[pid] else { continue }
            let appName = app.localizedName ?? "Application"
            let icon = app.icon
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: appName)
                ?? NSImage()
            for (index, info) in cached.enumerated()
                where !(representedIndices[pid]?.contains(index) ?? false) {
                result.append(SwitchableWindow(
                    application: app,
                    title: info.title?.isEmpty == false ? info.title! : appName,
                    rawTitle: info.title,
                    appName: appName,
                    icon: icon,
                    windowID: nil,
                    appWindowIndex: index,
                    isMinimized: info.isMinimized,
                    isCurrent: false
                ))
            }
        }
        return result
    }

    func thumbnail(for window: SwitchableWindow) -> NSImage? {
        guard let windowID = window.windowID,
              let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
              ) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    func warmTitleCache() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let appsByPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        refreshTitleCache(for: appsByPID)
    }

    private func cachedWindows() -> [pid_t: [AccessibilityWindowInfo]] {
        titleStateLock.lock()
        defer { titleStateLock.unlock() }
        return accessibilityWindowCache
    }

    private func refreshTitleCache(for appsByPID: [pid_t: NSRunningApplication]) {
        titleStateLock.lock()
        guard !titleRefreshInProgress else {
            titleStateLock.unlock()
            return
        }
        titleRefreshInProgress = true
        titleStateLock.unlock()

        titleRefreshQueue.async { [weak self] in
            guard let self else { return }
            var refreshed: [pid_t: [AccessibilityWindowInfo]] = [:]
            for (pid, app) in appsByPID {
                refreshed[pid] = self.windowInfo(for: app)
            }

            self.titleStateLock.lock()
            self.accessibilityWindowCache = refreshed
            self.titleRefreshInProgress = false
            let callback = self.onTitlesUpdated
            self.titleStateLock.unlock()

            DispatchQueue.main.async { callback?() }
        }
    }

    private func windowInfo(for app: NSRunningApplication) -> [AccessibilityWindowInfo] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.18)
        guard let values = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return values.compactMap { element in
            let role = attribute(element, kAXRoleAttribute) as? String
            let subrole = attribute(element, kAXSubroleAttribute) as? String
            guard role == kAXWindowRole,
                  subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else {
                return nil
            }
            let title = (attribute(element, kAXTitleAttribute) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isMinimized = (attribute(element, kAXMinimizedAttribute) as? Bool) ?? false
            return AccessibilityWindowInfo(
                title: title?.isEmpty == false ? title : nil,
                isMinimized: isMinimized
            )
        }
    }

    func focus(_ window: SwitchableWindow) {
        let appElement = AXUIElementCreateApplication(window.application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        guard let values = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else { return }

        let usableWindows = values.filter { element in
            let role = attribute(element, kAXRoleAttribute) as? String
            let subrole = attribute(element, kAXSubroleAttribute) as? String
            return role == kAXWindowRole &&
                (subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole)
        }

        let titleMatch = window.rawTitle.flatMap { desiredTitle in
            usableWindows.first { element in
                let title = (attribute(element, kAXTitleAttribute) as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return title == desiredTitle
            }
        }
        let indexedMatch = usableWindows.indices.contains(window.appWindowIndex)
            ? usableWindows[window.appWindowIndex]
            : usableWindows.first
        let indexedTitleMatches = indexedMatch.map { element in
            guard let desiredTitle = window.rawTitle else { return true }
            let title = (attribute(element, kAXTitleAttribute) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title == desiredTitle
        } ?? false
        guard let element = indexedTitleMatches ? indexedMatch : (titleMatch ?? indexedMatch) else { return }

        window.application.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        // Restoring a minimized window is asynchronous in several apps. Retry
        // after AppKit has processed the deminiaturize request so the selected
        // window, rather than merely its application, receives focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            window.application.activate(options: [.activateIgnoringOtherApps])
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            window.application.activate(options: [.activateIgnoringOtherApps])
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
