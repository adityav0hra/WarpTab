import AppKit

enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

private let application = NSWorkspace.shared.frontmostApplication
    ?? NSWorkspace.shared.runningApplications.first { !$0.isTerminated }!
private var passed = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw HarnessFailure.assertion(message) }
    passed += 1
}

private func window(
    _ identity: String,
    app: String = "Fixture",
    title: String? = nil,
    bundle: String? = "test.fixture",
    screen: String? = "display-1",
    minimized: Bool = false,
    hidden: Bool = false,
    fullscreen: Bool = false,
    onScreen: Bool = true,
    windowless: Bool = false
) -> WarpWindow {
    WarpWindow(
        identity: identity, application: application, axWindow: nil, axTab: nil,
        title: title ?? identity, rawTitle: title, appName: app,
        bundleIdentifier: bundle,
        icon: NSImage(size: NSSize(width: 16, height: 16)),
        windowID: nil, bounds: NSRect(x: 0, y: 0, width: 800, height: 600),
        screenIdentifier: screen, isFocused: false,
        isMinimized: minimized, isHidden: hidden,
        isFullscreen: fullscreen, isOnScreen: onScreen,
        isWindowlessApplication: windowless, nativeTabCount: 0, lastFocusedAt: nil
    )
}

private func testMRU() throws {
    let manager = MRUManager()
    let alpha = window("alpha")
    let beta = window("beta")
    let gamma = window("gamma")
    manager.reconcile(with: [alpha, beta, gamma])
    manager.observeFocused("beta")
    manager.observeFocused("alpha")
    try expect(manager.ordered([alpha, beta, gamma]).map(\.identity) == ["alpha", "beta", "gamma"], "MRU focus order")
    let orderedForSwitching = manager.ordered([alpha, beta, gamma])
    let quickIndex = SwitcherSequence.initialSelectionIndex(windowCount: orderedForSwitching.count, backwards: false)
    try expect(orderedForSwitching.first?.identity == "alpha", "Current window remains visible as item one")
    try expect(quickIndex == 1 && orderedForSwitching[quickIndex!].identity == "beta", "Quick switch preselects the next MRU window")
    try expect(SwitcherSequence.initialSelectionIndex(windowCount: 3, backwards: true) == 2, "Reverse switch starts at the previous item")
    manager.beginSwitching()
    manager.observeFocused("gamma")
    try expect(manager.ordered([alpha, beta, gamma]).map(\.identity) == ["alpha", "beta", "gamma"], "MRU suspension")
    manager.commit(gamma)
    try expect(manager.ordered([alpha, beta, gamma]).map(\.identity) == ["gamma", "alpha", "beta"], "MRU commit")
    manager.beginSwitching()
    manager.observeFocused("beta")
    manager.cancelSwitching()
    try expect(manager.ordered([alpha, beta, gamma]).first?.identity == "gamma", "MRU cancellation")
    manager.reconcile(with: [alpha, beta])
    try expect(manager.lastFocusDate(for: "gamma") == nil, "MRU destroyed-window cleanup")
}

private func testSearch() throws {
    let safari = window("safari", app: "Safari", title: "ChatGPT")
    let terminal = window("terminal", app: "Terminal", title: "server")
    let editor = window("editor", app: "Visual Studio Code", title: "discord-bot")
    let windows = [safari, terminal, editor]
    try expect(WindowSearch.results(for: "saf", in: windows).map(\.identity) == ["safari"], "Application-name search")
    try expect(WindowSearch.results(for: "chat", in: windows).map(\.identity) == ["safari"], "Window-title search")
    try expect(WindowSearch.results(for: "disc", in: windows).map(\.identity) == ["editor"], "Substring search")
    try expect(WindowSearch.results(for: "vsc", in: windows).map(\.identity) == ["editor"], "Fuzzy subsequence search")
    try expect(WindowSearch.results(for: "", in: windows).map(\.identity) == windows.map(\.identity), "Empty search preserves MRU")
    try expect(WindowSearch.results(for: "not-present", in: windows).isEmpty, "No-match search")
}

private func testFiltering() throws {
    try expect(SwitcherWindowScope.allWindows.includes(processIdentifier: 42), "All-window switcher scope")
    try expect(SwitcherWindowScope.application(42).includes(processIdentifier: 42), "Same-application scope includes matching process")
    try expect(!SwitcherWindowScope.application(42).includes(processIdentifier: 7), "Same-application scope excludes other processes")
    let normal = window("normal", bundle: "test.normal")
    let minimized = window("minimized", minimized: true)
    let hidden = window("hidden", hidden: true, onScreen: false)
    let fullscreen = window("fullscreen", fullscreen: true)
    let otherSpace = window("space", onScreen: false)
    let windowless = window("windowless", windowless: true)
    let excluded = window("excluded", bundle: "test.excluded")
    let restrictive = WindowFilterOptions(
        showMinimized: false, showHiddenApplications: false,
        showFullscreen: false, showOtherSpaces: false,
        showWindowlessApps: false, currentDisplayOnly: false,
        excludedBundleIdentifiers: ["test.excluded"]
    )
    try expect(WindowFilter.apply(
        to: [normal, minimized, hidden, fullscreen, otherSpace, windowless, excluded],
        options: restrictive, targetScreenIdentifier: nil, ownProcessIdentifier: -1
    ).map(\.identity) == ["normal"], "All visibility rules")

    let inclusive = WindowFilterOptions(
        showMinimized: true, showHiddenApplications: true,
        showFullscreen: true, showOtherSpaces: false,
        showWindowlessApps: true, currentDisplayOnly: false,
        excludedBundleIdentifiers: []
    )
    let inclusiveResults = WindowFilter.apply(
        to: [minimized, hidden, fullscreen, otherSpace, windowless],
        options: inclusive, targetScreenIdentifier: nil, ownProcessIdentifier: -1
    ).map(\.identity)
    try expect(inclusiveResults.contains("minimized"), "Minimized filter")
    try expect(inclusiveResults.contains("hidden"), "Hidden filter")
    try expect(inclusiveResults.contains("fullscreen"), "Fullscreen filter")
    try expect(inclusiveResults.contains("windowless"), "Windowless filter")
    try expect(!inclusiveResults.contains("space"), "Other-Space filter")

    let currentDisplay = WindowFilterOptions(
        showMinimized: true, showHiddenApplications: true,
        showFullscreen: true, showOtherSpaces: true,
        showWindowlessApps: false, currentDisplayOnly: true,
        excludedBundleIdentifiers: []
    )
    let first = window("first", screen: "display-1")
    let second = window("second", screen: "display-2")
    try expect(WindowFilter.apply(
        to: [first, second], options: currentDisplay,
        targetScreenIdentifier: "display-2", ownProcessIdentifier: -1
    ).map(\.identity) == ["second"], "Current-display filter")
    try expect(WindowFilter.apply(
        to: [first, second], options: currentDisplay,
        targetScreenIdentifier: nil, ownProcessIdentifier: -1
    ).count == 2, "Disconnected-display fallback")

    let dockWindows = [
        window("dock-normal"),
        window("dock-minimized", minimized: true),
        window("dock-hidden", hidden: true),
        window("dock-fullscreen", fullscreen: true),
        window("dock-windowless", windowless: true),
        window("other-app", bundle: "test.other")
    ]
    let dockInclusive = DockPreviewFilter.apply(
        to: dockWindows,
        bundleIdentifier: "test.fixture",
        options: DockPreviewFilterOptions(
            showMinimized: true,
            showHiddenApplications: true,
            showFullscreen: true
        )
    )
    try expect(
        dockInclusive.map(\.identity) == ["dock-normal", "dock-minimized", "dock-hidden", "dock-fullscreen"],
        "Dock previews include enabled minimized, hidden, and full-screen windows"
    )
    let dockRestrictive = DockPreviewFilter.apply(
        to: dockWindows,
        bundleIdentifier: "test.fixture",
        options: DockPreviewFilterOptions(
            showMinimized: false,
            showHiddenApplications: false,
            showFullscreen: false
        )
    )
    try expect(dockRestrictive.map(\.identity) == ["dock-normal"], "Dock preview visibility filters")
}

private func testPreferences() throws {
    let suite = "com.warptab.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = WarpPreferences(defaults: defaults)
    try expect(preferences.searchEnabled, "Search default")
    try expect(preferences.previewsEnabled, "Preview default")
    try expect(preferences.dockPreviewsEnabled, "Dock preview default")
    try expect(preferences.dockPreviewCloseEnabled, "Dock close-button default")
    try expect(!preferences.quitAppWhenLastWindowClosed, "Quit-after-last-window default")
    try expect(preferences.dockPreviewSize == .default, "Dock preview size default")
    try expect(preferences.dockPreviewShowMinimized, "Dock minimized-window default")
    try expect(preferences.dockPreviewShowHiddenApplications, "Dock hidden-app default")
    try expect(preferences.dockPreviewShowFullscreen, "Dock full-screen default")
    try expect(preferences.minimizeFrontmostWindowOnDockClick, "Dock-click minimize default")
    try expect(preferences.chooseWindowOnMultiWindowDockClick, "Multi-window Dock chooser default")
    try expect(preferences.minimizeAllWindowsOnDockDoubleClick, "Dock double-click minimize-all default")
    try expect(preferences.dockDoubleClickMinimizeScope == .allWindows, "Dock double-click scope default")
    try expect(preferences.showMinimized, "Minimized default")
    try expect(preferences.showHiddenApplications, "Hidden default")
    try expect(preferences.showFullscreen, "Fullscreen default")
    try expect(preferences.showOtherSpaces, "Other-Spaces default")
    try expect(!preferences.showWindowlessApps, "Windowless default")
    try expect(preferences.displayScope == .allDisplays, "Display scope default")
    var changes = 0
    preferences.onChange = { changes += 1 }
    preferences.showHiddenApplications = false
    preferences.dockPreviewsEnabled = false
    preferences.dockPreviewCloseEnabled = false
    preferences.quitAppWhenLastWindowClosed = true
    preferences.dockPreviewSize = .small
    preferences.dockPreviewShowMinimized = false
    preferences.dockPreviewShowHiddenApplications = false
    preferences.dockPreviewShowFullscreen = false
    preferences.minimizeFrontmostWindowOnDockClick = false
    preferences.chooseWindowOnMultiWindowDockClick = false
    preferences.minimizeAllWindowsOnDockDoubleClick = false
    preferences.dockDoubleClickMinimizeScope = .topWindow
    preferences.displayScope = .currentDisplay
    preferences.excludedBundleIdentifiers = ["test.excluded"]
    try expect(!preferences.showHiddenApplications, "Preference persistence")
    try expect(!preferences.dockPreviewsEnabled, "Dock preview preference persistence")
    try expect(!preferences.dockPreviewCloseEnabled, "Dock close-button preference persistence")
    try expect(preferences.quitAppWhenLastWindowClosed, "Quit-after-last-window preference persistence")
    try expect(preferences.dockPreviewSize == .small, "Dock preview size persistence")
    try expect(!preferences.dockPreviewShowMinimized, "Dock minimized-window preference persistence")
    try expect(!preferences.dockPreviewShowHiddenApplications, "Dock hidden-app preference persistence")
    try expect(!preferences.dockPreviewShowFullscreen, "Dock full-screen preference persistence")
    try expect(!preferences.minimizeFrontmostWindowOnDockClick, "Dock-click minimize preference persistence")
    try expect(!preferences.chooseWindowOnMultiWindowDockClick, "Multi-window Dock chooser preference persistence")
    try expect(!preferences.minimizeAllWindowsOnDockDoubleClick, "Dock double-click minimize-all preference persistence")
    try expect(preferences.dockDoubleClickMinimizeScope == .topWindow, "Dock double-click scope persistence")
    try expect(preferences.displayScope == .currentDisplay, "Display preference persistence")
    try expect(preferences.excludedBundleIdentifiers == ["test.excluded"], "Exclusion persistence")
    try expect(changes == 14, "Preference change notifications")
}

private func testNativeTabSafety() throws {
    try expect(NativeTabSupport.allowsIndividualTabs(bundleIdentifier: "com.apple.TextEdit"), "Native AppKit tab support")
    try expect(NativeTabSupport.allowsIndividualTabs(bundleIdentifier: "com.apple.finder"), "Finder native tab support")
    try expect(!NativeTabSupport.allowsIndividualTabs(bundleIdentifier: "com.apple.Safari"), "Safari website-tab exclusion")
    try expect(!NativeTabSupport.allowsIndividualTabs(bundleIdentifier: "com.google.Chrome"), "Chrome website-tab exclusion")
    try expect(!NativeTabSupport.allowsIndividualTabs(bundleIdentifier: "org.mozilla.firefox"), "Firefox website-tab exclusion")
}

private func testHardwareMainDisplayResolution() throws {
    let expectedIdentifier = String(CGMainDisplayID())
    try expect(
        NSScreen.warpHardwareMain?.warpIdentifier == expectedIdentifier,
        "Hardware main display resolution"
    )
}

do {
    try testMRU()
    try testSearch()
    try testFiltering()
    try testPreferences()
    try testNativeTabSafety()
    try testHardwareMainDisplayResolution()
    print("WarpTab engine tests passed: \(passed) assertions")
} catch {
    fputs("WarpTab engine tests failed: \(error)\n", stderr)
    exit(1)
}
