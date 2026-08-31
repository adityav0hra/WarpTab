import AppKit
import ApplicationServices
import CoreGraphics

final class WindowStore {
    var onChange: (() -> Void)?
    var onDockPreviewChange: (() -> Void)?
    var onPreviewInvalidation: ((String) -> Void)?

    let preferences: WarpPreferences
    let mru = MRUManager()
    let activator = WindowActivator()

    private let stateLock = NSLock()
    private var storedWindows: [WarpWindow] = []
    private var refreshInProgress = false
    private var refreshRequested = false
    private var refreshWorkItem: DispatchWorkItem?
    private let refreshQueue = DispatchQueue(label: "com.warptab.window-store", qos: .userInitiated)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var observedWindows: [pid_t: [Int: AXUIElement]] = [:]
    private var observedTabs: [pid_t: [Int: AXUIElement]] = [:]
    private var safetyTimer: Timer?
    private var started = false
    private var lifecycleGeneration: UInt64 = 0

    init(preferences: WarpPreferences) {
        self.preferences = preferences
        preferences.onChange = { [weak self] in
            self?.onChange?()
            self?.onDockPreviewChange?()
            self?.requestRefresh()
        }
    }

    deinit {
        stop()
    }

    func start() {
        guard !started else { return }
        started = true
        lifecycleGeneration &+= 1
        installWorkspaceObservers()
        requestRefresh(immediate: true)
        // Some applications do not reliably emit every AX notification, so
        // retain a short recovery scan to keep minimized and Space state fresh.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.requestRefresh()
        }
    }

    func stop() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        refreshWorkItem?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        for observer in axObservers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObservers.removeAll()
        observedWindows.removeAll()
        observedTabs.removeAll()
        started = false
        lifecycleGeneration &+= 1
    }

    func requestRefresh(immediate: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self, started else { return }
            refreshWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.beginRefresh() }
            refreshWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.06), execute: item)
        }
    }

    func allWindows() -> [WarpWindow] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedWindows
    }

    func focusedWindow() -> WarpWindow? {
        let windows = allWindows()
        if let focused = windows.first(where: \.isFocused) { return focused }
        guard let identity = currentFocusedIdentity() else { return nil }
        return windows.first { $0.identity == identity }
    }

    func switchableWindows(on targetScreenIdentifier: String?) -> [WarpWindow] {
        let filtered = WindowFilter.apply(
            to: allWindows(),
            options: preferences.filterOptions,
            targetScreenIdentifier: targetScreenIdentifier
        )
        return mru.ordered(filtered)
    }

    func dockPreviewWindows(bundleIdentifier: String) -> [WarpWindow] {
        mru.ordered(DockPreviewFilter.apply(
            to: allWindows(),
            bundleIdentifier: bundleIdentifier,
            options: preferences.dockPreviewFilterOptions
        ))
    }

    func beginSwitching() {
        // Promote the exact window that is frontmost at the moment the shortcut
        // is pressed. Event-driven refreshes are normally enough, but a user can
        // focus another window and invoke WarpTab before the async scan finishes.
        if let identity = currentFocusedIdentity() {
            mru.observeFocused(identity)
        }
        mru.beginSwitching()
    }

    func cancelSwitching() {
        mru.cancelSwitching()
    }

    func commit(_ window: WarpWindow) {
        mru.commit(window)
        activator.activate(window)
        requestRefresh()
    }

    func runningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
    }

    private func currentFocusedIdentity() -> String? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let candidates = allWindows().filter {
            $0.application.processIdentifier == application.processIdentifier
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0].identity }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        // Preserve exact first-window ordering without letting a busy
        // application stall the shortcut for macOS's usual 100+ ms AX wait.
        // The observer-fed focus bit below remains the fallback.
        AXUIElementSetMessagingTimeout(appElement, 0.04)
        guard let focused = warpAXElement(attribute(appElement, kAXFocusedWindowAttribute)) else {
            return candidates.first(where: \.isFocused)?.identity
        }
        var focusedCandidates = candidates.filter {
            guard let element = $0.axWindow else { return false }
            return CFEqual(element, focused)
        }
        if focusedCandidates.isEmpty,
           let focusedTitle = (attribute(focused, kAXTitleAttribute) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !focusedTitle.isEmpty {
            focusedCandidates = candidates.filter { window in
                guard let element = window.axWindow else { return false }
                return (attribute(element, kAXTitleAttribute) as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == focusedTitle
            }
        }
        guard !focusedCandidates.isEmpty else { return candidates.first(where: \.isFocused)?.identity }
        if focusedCandidates.count == 1 { return focusedCandidates[0].identity }

        return focusedCandidates.first(where: { window in
            guard let tab = window.axTab else { return false }
            return (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true
        })?.identity ?? focusedCandidates.first(where: \.isFocused)?.identity ?? focusedCandidates[0].identity
    }

    private func beginRefresh() {
        guard started else { return }
        stateLock.lock()
        if refreshInProgress {
            refreshRequested = true
            stateLock.unlock()
            return
        }
        refreshInProgress = true
        stateLock.unlock()

        let displays = DisplaySnapshot.current()
        let previous = allWindows()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let generation = lifecycleGeneration
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let result = self.discoverWindows(
                displays: displays,
                retaining: previous,
                frontmostPID: frontmostPID
            )
            DispatchQueue.main.async {
                self.stateLock.lock()
                let shouldApply = self.started && self.lifecycleGeneration == generation
                self.refreshInProgress = false
                let runAgain = self.refreshRequested
                self.refreshRequested = false
                self.stateLock.unlock()
                if shouldApply { self.apply(result) }
                if runAgain, self.started { self.requestRefresh(immediate: true) }
            }
        }
    }

    private func apply(_ windows: [WarpWindow]) {
        let focused = windows.first(where: \.isFocused)?.identity
        mru.observeFocused(focused)
        mru.reconcile(with: windows)
        let enriched = windows.map { window in
            WarpWindow(
                identity: window.identity,
                application: window.application,
                axWindow: window.axWindow,
                axTab: window.axTab,
                title: window.title,
                rawTitle: window.rawTitle,
                appName: window.appName,
                bundleIdentifier: window.bundleIdentifier,
                icon: window.icon,
                windowID: window.windowID,
                bounds: window.bounds,
                screenIdentifier: window.screenIdentifier,
                isFocused: window.isFocused,
                isMinimized: window.isMinimized,
                isHidden: window.isHidden,
                isFullscreen: window.isFullscreen,
                isOnScreen: window.isOnScreen,
                isWindowlessApplication: window.isWindowlessApplication,
                nativeTabCount: window.nativeTabCount,
                lastFocusedAt: mru.lastFocusDate(for: window.identity)
            )
        }
        stateLock.lock()
        storedWindows = enriched
        stateLock.unlock()
        installAXObservers(for: enriched)
        onChange?()
        onDockPreviewChange?()
    }

    private func mergeRetainedWindows(
        _ discovered: [WarpWindow],
        retaining previous: [WarpWindow]
    ) -> [WarpWindow] {
        guard !previous.isEmpty else { return discovered }
        let discoveredIdentities = Set(discovered.map(\.identity))
        let discoveredElements = discovered.compactMap(\.axWindow)
        let livePIDs = Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(\.processIdentifier))
        let retained = previous.compactMap { window -> WarpWindow? in
            guard !discoveredIdentities.contains(window.identity),
                  !window.isWindowlessApplication,
                  livePIDs.contains(window.application.processIdentifier),
                  let element = window.axWindow,
                  !discoveredElements.contains(where: { CFEqual($0, element) }),
                  isSwitchable(element) else { return nil }
            return WarpWindow(
                identity: window.identity,
                application: window.application,
                axWindow: element,
                axTab: window.axTab,
                title: window.title,
                rawTitle: window.rawTitle,
                appName: window.appName,
                bundleIdentifier: window.bundleIdentifier,
                icon: window.icon,
                windowID: window.windowID,
                bounds: window.bounds,
                screenIdentifier: window.screenIdentifier,
                isFocused: false,
                isMinimized: window.isMinimized,
                isHidden: window.application.isHidden,
                isFullscreen: window.isFullscreen,
                isOnScreen: false,
                isWindowlessApplication: false,
                nativeTabCount: window.nativeTabCount,
                lastFocusedAt: window.lastFocusedAt
            )
        }
        return discovered + retained
    }

    private func discoverWindows(
        displays: [DisplaySnapshot],
        retaining previous: [WarpWindow],
        frontmostPID: pid_t?
    ) -> [WarpWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ownPID && $0.activationPolicy == .regular && !$0.isTerminated
        }
        let cgWindows = cgWindowCandidates()
        let cgByPID = Dictionary(grouping: cgWindows, by: \.pid)
        var results: [WarpWindow] = []

        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.22)
            let focusedElement = warpAXElement(attribute(appElement, kAXFocusedWindowAttribute))
            let axWindows = (attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            var unusedCandidates = cgByPID[app.processIdentifier] ?? []
            var usableWindowCount = 0
            var seenNativeTabGroups = Set<CFHashCode>()

            for element in axWindows {
                guard isSwitchable(element) else { continue }
                let minimized = (attribute(element, kAXMinimizedAttribute) as? Bool) ?? false
                let title = ((attribute(element, kAXTitleAttribute) as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let rawBounds = bounds(of: element)
                guard minimized || rawBounds.width >= 120 && rawBounds.height >= 80 else { continue }
                let nativeTabGroup = preferences.nativeTabBehavior == .individual
                    ? nativeWindowTabGroup(in: element, application: app)
                    : nil
                let nativeTabs = nativeTabGroup?.tabs ?? []
                if nativeTabs.count > 1 {
                    guard let nativeTabGroup,
                          seenNativeTabGroups.insert(nativeTabGroup.identity).inserted else { continue }
                }
                let tabCandidates: [NativeTabCandidate?] = nativeTabs.count > 1
                    ? nativeTabs.map(Optional.some)
                    : [nil]
                usableWindowCount += tabCandidates.count

                let matchIndex = bestCandidateIndex(title: title, bounds: rawBounds, candidates: unusedCandidates)
                let candidate = matchIndex.map { unusedCandidates.remove(at: $0) }
                let appKitBounds = convertToAppKit(rawBounds, displays: displays)
                let screenID = bestScreen(for: appKitBounds, displays: displays)?.identifier
                let appName = app.localizedName ?? candidate?.ownerName ?? "Application"
                let icon = app.icon
                    ?? NSImage(systemSymbolName: "app", accessibilityDescription: appName)
                    ?? NSImage()
                let windowIdentity = "\(app.processIdentifier):ax:\(CFHash(element))"
                // AXFocusedWindow is the application's last focused window even
                // when that application is in the background. Only the system's
                // frontmost application may contribute the global focused item.
                let windowIsFocused = app.processIdentifier == frontmostPID &&
                    (focusedElement.map { CFEqual($0, element) } ?? false)
                for tab in tabCandidates {
                    let itemTitle = tab?.title ?? (title.isEmpty ? appName : title)
                    let identity = if let tab, let nativeTabGroup {
                        "\(app.processIdentifier):ax-tab-group:\(nativeTabGroup.identity):tab:\(CFHash(tab.element))"
                    } else {
                        windowIdentity
                    }
                    results.append(WarpWindow(
                        identity: identity,
                        application: app,
                        axWindow: element,
                        axTab: tab?.element,
                        title: itemTitle,
                        rawTitle: itemTitle == appName ? nil : itemTitle,
                        appName: appName,
                        bundleIdentifier: app.bundleIdentifier,
                        icon: icon,
                        windowID: candidate?.windowID,
                        bounds: appKitBounds,
                        screenIdentifier: screenID,
                        isFocused: windowIsFocused && (tab?.isSelected ?? true),
                        isMinimized: minimized,
                        isHidden: app.isHidden,
                        isFullscreen: (attribute(element, "AXFullScreen") as? Bool) ?? false,
                        isOnScreen: candidate?.isOnScreen ?? false,
                        isWindowlessApplication: false,
                        nativeTabCount: nativeTabs.count,
                        lastFocusedAt: nil
                    ))
                }
            }

            if usableWindowCount == 0 {
                let appName = app.localizedName ?? "Application"
                let icon = app.icon
                    ?? NSImage(systemSymbolName: "app", accessibilityDescription: appName)
                    ?? NSImage()
                results.append(WarpWindow(
                    identity: "\(app.processIdentifier):application",
                    application: app,
                    axWindow: nil,
                    axTab: nil,
                    title: appName,
                    rawTitle: nil,
                    appName: appName,
                    bundleIdentifier: app.bundleIdentifier,
                    icon: icon,
                    windowID: nil,
                    bounds: .zero,
                    screenIdentifier: nil,
                    isFocused: app.processIdentifier == frontmostPID,
                    isMinimized: false,
                    isHidden: app.isHidden,
                    isFullscreen: false,
                    isOnScreen: false,
                    isWindowlessApplication: true,
                    nativeTabCount: 0,
                    lastFocusedAt: nil
                ))
            }
        }
        // Accessibility may omit windows on another Space. Validate and merge
        // retained windows here so Accessibility IPC never stalls the UI thread.
        var seenIdentities = Set<String>()
        let uniqueResults = results.filter { seenIdentities.insert($0.identity).inserted }
        return mergeRetainedWindows(uniqueResults, retaining: previous)
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.requestRefresh()
            }
        }
        workspaceObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.requestRefresh(immediate: true) }
        )
    }

    private func installAXObservers(for windows: [WarpWindow]) {
        let activePIDs = Set(windows.map { $0.application.processIdentifier })
        let obsoletePIDs = axObservers.keys.filter { !activePIDs.contains($0) }
        for pid in obsoletePIDs {
            guard let observer = axObservers[pid] else { continue }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            axObservers.removeValue(forKey: pid)
            observedWindows.removeValue(forKey: pid)
            observedTabs.removeValue(forKey: pid)
        }

        for pid in activePIDs where axObservers[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, warpTabAXObserverCallback, &observer) == .success,
                  let observer else { continue }
            axObservers[pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            let appElement = AXUIElementCreateApplication(pid)
            for notification in [
                kAXFocusedWindowChangedNotification,
                kAXMainWindowChangedNotification,
                kAXWindowCreatedNotification
            ] {
                AXObserverAddNotification(
                    observer,
                    appElement,
                    notification as CFString,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
        }

        let windowNotifications = [
            kAXUIElementDestroyedNotification,
            kAXMovedNotification,
            kAXResizedNotification,
            kAXTitleChangedNotification,
            kAXValueChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification
        ]
        let windowsByPID = Dictionary(grouping: windows, by: { $0.application.processIdentifier })
        for (pid, appWindows) in windowsByPID {
            guard let observer = axObservers[pid] else { continue }

            // A native tab group intentionally produces several WarpWindow
            // entries backed by the same AX window. Deduplicate instead of
            // using Dictionary(uniqueKeysWithValues:), which would trap.
            var currentWindows: [Int: AXUIElement] = [:]
            for window in appWindows {
                if let element = window.axWindow {
                    currentWindows[Int(CFHash(element))] = element
                }
            }
            reconcileObservedElements(
                observer: observer,
                previous: &observedWindows[pid, default: [:]],
                current: currentWindows,
                notifications: windowNotifications
            )

            var currentTabs: [Int: AXUIElement] = [:]
            for window in appWindows {
                if let element = window.axTab {
                    currentTabs[Int(CFHash(element))] = element
                }
            }
            reconcileObservedElements(
                observer: observer,
                previous: &observedTabs[pid, default: [:]],
                current: currentTabs,
                notifications: [kAXValueChangedNotification]
            )
        }
    }

    private func reconcileObservedElements(
        observer: AXObserver,
        previous: inout [Int: AXUIElement],
        current: [Int: AXUIElement],
        notifications: [String]
    ) {
        for (identity, element) in previous where current[identity] == nil {
            for notification in notifications {
                AXObserverRemoveNotification(observer, element, notification as CFString)
            }
        }
        for (identity, element) in current where previous[identity] == nil {
            for notification in notifications {
                AXObserverAddNotification(
                    observer,
                    element,
                    notification as CFString,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
        }
        previous = current
    }

    fileprivate func handleAXEvent(element: AXUIElement, notification: String) {
        let identity = "\(pid(of: element)):ax:\(CFHash(element))"
        if notification == kAXFocusedWindowChangedNotification ||
            notification == kAXMainWindowChangedNotification ||
            notification == kAXValueChangedNotification,
           let focusedIdentity = currentFocusedIdentity() {
            mru.observeFocused(focusedIdentity)
        }
        if notification == kAXMovedNotification ||
            notification == kAXResizedNotification ||
            notification == kAXUIElementDestroyedNotification {
            onPreviewInvalidation?(identity)
        }
        requestRefresh()
    }

    private func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private func isSwitchable(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        guard role == kAXWindowRole else { return false }
        return subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    private func nativeWindowTabGroup(
        in window: AXUIElement,
        application: NSRunningApplication
    ) -> NativeTabGroup? {
        guard NativeTabSupport.allowsIndividualTabs(bundleIdentifier: application.bundleIdentifier),
              let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement],
              let tabGroup = children.first(where: {
                  attribute($0, kAXRoleAttribute) as? String == "AXTabGroup"
              }),
              let tabs = attribute(tabGroup, kAXTabsAttribute) as? [AXUIElement],
              tabs.count > 1 else { return nil }

        let candidates: [NativeTabCandidate] = tabs.compactMap { tab in
            guard attribute(tab, kAXSubroleAttribute) as? String == "AXTabButton",
                  let tabWindow = warpAXElement(attribute(tab, kAXWindowAttribute)),
                  CFEqual(tabWindow, window),
                  supportsAction(tab, kAXPressAction),
                  let title = (attribute(tab, kAXTitleAttribute) as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let selected = (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue ?? false
            return NativeTabCandidate(element: tab, title: title, isSelected: selected)
        }
        return NativeTabGroup(identity: CFHash(tabGroup), tabs: candidates)
    }

    private func supportsAction(_ element: AXUIElement, _ action: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return false }
        return actions.contains(action)
    }

    private func bounds(of element: AXUIElement) -> CGRect {
        var position = CGPoint.zero
        var size = CGSize.zero
        if let value = warpAXValue(attribute(element, kAXPositionAttribute)) {
            AXValueGetValue(value, .cgPoint, &position)
        }
        if let value = warpAXValue(attribute(element, kAXSizeAttribute)) {
            AXValueGetValue(value, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }

    private func convertToAppKit(_ bounds: CGRect, displays: [DisplaySnapshot]) -> CGRect {
        let mainTop = displays.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        return CGRect(x: bounds.origin.x, y: mainTop - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    private func bestScreen(for bounds: CGRect, displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        displays.max { left, right in
            left.frame.intersection(bounds).area < right.frame.intersection(bounds).area
        }
    }

    private func bestCandidateIndex(
        title: String,
        bounds: CGRect,
        candidates: [CGWindowCandidate]
    ) -> Int? {
        if !title.isEmpty {
            let titled = candidates.indices.filter { candidates[$0].title == title }
            if let exact = titled.max(by: { left, right in
                candidates[left].bounds.intersection(bounds).area < candidates[right].bounds.intersection(bounds).area
            }) {
                return exact
            }
        }
        guard let best = candidates.indices.max(by: { left, right in
            candidates[left].bounds.intersection(bounds).area < candidates[right].bounds.intersection(bounds).area
        }) else { return nil }
        return candidates[best].bounds.intersection(bounds).area > 0 ? best : nil
    }

    private func cgWindowCandidates() -> [CGWindowCandidate] {
        let info = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return info.compactMap { window in
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = window[kCGWindowNumber as String] as? NSNumber,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return CGWindowCandidate(
                pid: pid,
                windowID: CGWindowID(number.uint32Value),
                title: ((window[kCGWindowName as String] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                ownerName: window[kCGWindowOwnerName as String] as? String,
                bounds: bounds,
                isOnScreen: (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            )
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

private struct CGWindowCandidate {
    let pid: pid_t
    let windowID: CGWindowID
    let title: String
    let ownerName: String?
    let bounds: CGRect
    let isOnScreen: Bool
}

private struct NativeTabCandidate {
    let element: AXUIElement
    let title: String
    let isSelected: Bool
}

private struct NativeTabGroup {
    let identity: CFHashCode
    let tabs: [NativeTabCandidate]
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}

private func warpTabAXObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let store = Unmanaged<WindowStore>.fromOpaque(refcon).takeUnretainedValue()
    store.handleAXEvent(element: element, notification: notification as String)
}
