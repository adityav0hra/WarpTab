import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Vision

enum IntegrationFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

private var assertions = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw IntegrationFailure.assertion(message) }
    assertions += 1
}

private func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

private func waitForFixtureWindows(timeout: TimeInterval = 5) throws {
    let required = CommandLine.arguments.contains("--focus-stability-only")
        ? Set(["WarpTab Small Window", "WarpTab Large Window"])
        : Set(["WarpTab Test — Alpha", "WarpTab Test — Beta", "WarpTab Native Tab — One"])
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let titles = try? fixtureWindows().compactMap({ attribute($0, kAXTitleAttribute) as? String }),
           required.isSubset(of: Set(titles)) { return }
        wait(0.1)
    } while Date() < deadline
    throw IntegrationFailure.assertion("Fixture windows did not finish opening")
}

private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func booleanAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
    let value = attribute(element, name)
    if let boolean = value as? Bool { return boolean }
    return (value as? NSNumber)?.boolValue
}

private func fixtureApplication() throws -> NSRunningApplication {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.fixture").first else {
        throw IntegrationFailure.assertion("Fixture application is not running")
    }
    return app
}

private func fixtureAXApplication() throws -> AXUIElement {
    AXUIElementCreateApplication(try fixtureApplication().processIdentifier)
}

private func fixtureWindows() throws -> [AXUIElement] {
    (attribute(try fixtureAXApplication(), kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

private func fixtureWindow(titled title: String) throws -> AXUIElement {
    guard let window = try fixtureWindows().first(where: {
        attribute($0, kAXTitleAttribute) as? String == title
    }) else { throw IntegrationFailure.assertion("Missing fixture window: \(title)") }
    return window
}

private func focusFixtureWindow(_ title: String) throws {
    let app = try fixtureApplication()
    let appElement = try fixtureAXApplication()
    let window = try fixtureWindow(titled: title)
    if app.isHidden { app.unhide() }
    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, window)
    AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    wait(0.22)
}

private func focusedFixtureTitle() throws -> String? {
    guard let focused = attribute(try fixtureAXApplication(), kAXFocusedWindowAttribute) else { return nil }
    return attribute(focused as! AXUIElement, kAXTitleAttribute) as? String
}

private func activateFixtureAsFrontmost(timeout: TimeInterval = 3) throws {
    let app = try fixtureApplication()
    let appElement = try fixtureAXApplication()
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        app.activate(options: [.activateAllWindows])
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        wait(0.1)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.warptab.fixture" { return }
    } while Date() < deadline
    throw IntegrationFailure.assertion("Fixture could not become the frontmost application")
}

private func activeDestination() throws -> String {
    guard let application = NSWorkspace.shared.frontmostApplication else { return "unknown" }
    let bundle = application.bundleIdentifier ?? "unknown"
    if bundle == "com.warptab.fixture" {
        return "\(bundle):\(try focusedFixtureTitle() ?? "untitled")"
    }
    let axApplication = AXUIElementCreateApplication(application.processIdentifier)
    if let focusedWindowValue = attribute(axApplication, kAXFocusedWindowAttribute) {
        let focusedWindow = focusedWindowValue as! AXUIElement
        if let title = attribute(focusedWindow, kAXTitleAttribute) as? String, !title.isEmpty {
            return "\(bundle):\(title)"
        }
    }
    return bundle
}

private func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, repeatValue: Int64 = 0) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
    event.flags = flags
    event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatValue)
    event.post(tap: .cghidEventTap)
}

private func press(_ keyCode: CGKeyCode, flags: CGEventFlags = [.maskAlternate], repeatValue: Int64 = 0) {
    postKey(keyCode, down: true, flags: flags, repeatValue: repeatValue)
    postKey(keyCode, down: false, flags: flags)
    wait(0.04)
}

private func openSwitcher(backwards: Bool = false) {
    let flags: CGEventFlags = backwards ? [.maskAlternate, .maskShift] : [.maskAlternate]
    postKey(58, down: true, flags: [.maskAlternate])
    if backwards { postKey(56, down: true, flags: flags) }
    press(48, flags: flags)
    wait(0.32)
}

private func openSameApplicationSwitcher(backwards: Bool = false) {
    let flags: CGEventFlags = backwards ? [.maskAlternate, .maskShift] : [.maskAlternate]
    postKey(58, down: true, flags: [.maskAlternate])
    if backwards { postKey(56, down: true, flags: flags) }
    press(50, flags: flags)
    wait(0.32)
}

private func releaseSwitcherModifiers(backwards: Bool = false) {
    if backwards { postKey(56, down: false, flags: [.maskAlternate]) }
    postKey(58, down: false, flags: [])
    wait(0.8)
}

private func releaseSwitcherModifiersAndObserve(
    bundleIdentifier: String,
    backwards: Bool = false
) -> Bool {
    if backwards { postKey(56, down: false, flags: [.maskAlternate]) }
    postKey(58, down: false, flags: [])
    let deadline = Date().addingTimeInterval(0.6)
    var observed = false
    repeat {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
            observed = true
        }
        wait(0.02)
    } while Date() < deadline
    return observed
}

private func typeSearch(_ text: String) throws {
    let codes: [Character: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
        "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
        "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
        "v": 9, "w": 13, "x": 7, "y": 16, "z": 6, " ": 49
    ]
    for character in text.lowercased() {
        guard let code = codes[character] else {
            throw IntegrationFailure.assertion("No key mapping for search character \(character)")
        }
        press(code)
    }
    wait(0.25)
}

private func warpTabOverlayWindow() -> CGWindowID? {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return windows.compactMap { info -> (CGWindowID, CGFloat)? in
        guard (info[kCGWindowOwnerName as String] as? String) == "WarpTab",
              let number = info[kCGWindowNumber as String] as? NSNumber,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.width > 200, bounds.height > 40 else { return nil }
        return (CGWindowID(number.uint32Value), bounds.width * bounds.height)
    }.max(by: { $0.1 < $1.1 })?.0
}

private func warpTabCompactOverlayWindow() -> CGWindowID? {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return windows.compactMap { info -> CGWindowID? in
        guard (info[kCGWindowOwnerName as String] as? String) == "WarpTab",
              let number = info[kCGWindowNumber as String] as? NSNumber,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.width >= 260, bounds.width < 1_000,
              bounds.height >= 80, bounds.height < 750 else { return nil }
        return CGWindowID(number.uint32Value)
    }.first
}

private func visibleWindowOrder() -> [(owner: String, title: String, bounds: CGRect)] {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return windows.compactMap { info in
        guard let owner = info[kCGWindowOwnerName as String] as? String,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
        return (owner, info[kCGWindowName as String] as? String ?? "", bounds)
    }
}

private func showWarpTabSettings() throws {
    guard let warpTab = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.app").first else {
        throw IntegrationFailure.assertion("WarpTab is not running")
    }
    warpTab.activate(options: [.activateIgnoringOtherApps])
    press(43, flags: [.maskCommand])
    let deadline = Date().addingTimeInterval(3)
    repeat {
        let hasSettings = visibleWindowOrder().contains {
            $0.owner == "WarpTab" && $0.bounds.width >= 700 && $0.bounds.height >= 500
        }
        if hasSettings,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.warptab.app" { return }
        wait(0.1)
    } while Date() < deadline
    throw IntegrationFailure.assertion("WarpTab Settings did not become the frontmost reference window")
}

private func overlayText() throws -> String {
    guard let windowID = warpTabOverlayWindow(),
          let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]
          ) else { throw IntegrationFailure.assertion("Could not capture WarpTab overlay") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
}

private func selectedNativeTabTitle() throws -> String? {
    for window in try fixtureWindows() {
        guard let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement],
              let group = children.first(where: { attribute($0, kAXRoleAttribute) as? String == "AXTabGroup" }),
              let tabs = attribute(group, kAXTabsAttribute) as? [AXUIElement] else { continue }
        if let selected = tabs.first(where: { booleanAttribute($0, kAXValueAttribute) == true }) {
            return attribute(selected, kAXTitleAttribute) as? String
        }
    }
    return nil
}

private func selectFixtureNativeTab(_ title: String) throws {
    let deadline = Date().addingTimeInterval(2)
    repeat {
        for window in try fixtureWindows() {
            guard let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement],
                  let group = children.first(where: { attribute($0, kAXRoleAttribute) as? String == "AXTabGroup" }),
                  let tabs = attribute(group, kAXTabsAttribute) as? [AXUIElement],
                  let tab = tabs.first(where: { attribute($0, kAXTitleAttribute) as? String == title }) else { continue }
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
            wait(0.35)
            if (try? fixtureWindow(titled: title)) != nil {
                try focusFixtureWindow(title)
                return
            }
        }
        wait(0.1)
    } while Date() < deadline
    throw IntegrationFailure.assertion("Missing fixture native tab: \(title)")
}

private func resetFocusHistory() throws {
    try focusFixtureWindow("WarpTab Test — Alpha")
    try focusFixtureWindow("WarpTab Test — Beta")
    try selectFixtureNativeTab("WarpTab Native Tab — One")
    wait(0.35)
}

private func runTests() throws {
    try expect(AXIsProcessTrusted(), "Accessibility permission available to integration harness")
    try waitForFixtureWindows()

    if CommandLine.arguments.contains("--modifier-isolation-only") ||
        CommandLine.arguments.contains("--modifier-isolation-color-only") {
        let testsColorPicker = CommandLine.arguments.contains("--modifier-isolation-color-only")
        let shortcutKey = CGKeyCode(testsColorPicker ? kVK_ANSI_C : kVK_ANSI_T)
        let shortcutName = testsColorPicker ? "C" : "T"
        try activateFixtureAsFrontmost()
        postKey(CGKeyCode(kVK_Control), down: true, flags: [.maskControl])
        postKey(CGKeyCode(kVK_Option), down: true, flags: [.maskControl, .maskAlternate])
        press(shortcutKey, flags: [.maskControl, .maskAlternate])
        wait(0.35)
        try expect(
            warpTabCompactOverlayWindow() == nil,
            "Control-Option-\(shortcutName) does not open the Option-\(shortcutName) window switcher"
        )
        postKey(CGKeyCode(kVK_Option), down: false, flags: [.maskControl])
        postKey(CGKeyCode(kVK_Control), down: false, flags: [])
        press(CGKeyCode(kVK_Escape), flags: [])
        wait(0.25)

        try activateFixtureAsFrontmost()
        postKey(CGKeyCode(kVK_Option), down: true, flags: [.maskAlternate])
        press(shortcutKey, flags: [.maskAlternate])
        wait(0.35)
        try expect(
            warpTabCompactOverlayWindow() != nil,
            "Option-\(shortcutName) still opens the configured window switcher"
        )
        press(CGKeyCode(kVK_Escape), flags: [])
        postKey(CGKeyCode(kVK_Option), down: false, flags: [])
        print("WarpTab shortcut modifier-isolation test passed: \(assertions) assertions")
        return
    }

    if CommandLine.arguments.contains("--focus-stability-only") {
        let application = try fixtureApplication()
        let smallElement = try fixtureWindow(titled: "WarpTab Small Window")
        let largeElement = try fixtureWindow(titled: "WarpTab Large Window")
        func candidate(_ title: String, element: AXUIElement) -> WarpWindow {
            WarpWindow(
                identity: "focus-stability-\(title)",
                application: application,
                axWindow: element,
                axTab: nil,
                title: title,
                rawTitle: title,
                appName: "WarpTab Fixture",
                bundleIdentifier: "com.warptab.fixture",
                icon: application.icon ?? NSImage(),
                windowID: nil,
                bounds: .zero,
                screenIdentifier: nil,
                isFocused: false,
                isMinimized: false,
                isHidden: false,
                isFullscreen: false,
                isOnScreen: true,
                isWindowlessApplication: false,
                nativeTabCount: 1,
                lastFocusedAt: nil
            )
        }
        let activator = WindowActivator()
        activator.activate(candidate("WarpTab Small Window", element: smallElement))
        wait(0.03)
        activator.activate(candidate("WarpTab Large Window", element: largeElement))
        let deadline = Date().addingTimeInterval(1.0)
        var observedLarge = false
        var originalReappeared = false
        repeat {
            let title = try focusedFixtureTitle()
            if title == "WarpTab Large Window" { observedLarge = true }
            if observedLarge, title == "WarpTab Small Window" { originalReappeared = true }
            wait(0.005)
        } while Date() < deadline
        try expect(observedLarge, "The large destination window receives focus")
        try expect(!originalReappeared, "A superseded activation never flashes the original small window back")
        print("WarpTab focus-stability test passed: \(assertions) assertions")
        return
    }

    try resetFocusHistory()
    let initialFocusedTitle = try focusedFixtureTitle()
    try expect(initialFocusedTitle == "WarpTab Native Tab — One", "Fixture focus setup")

    if CommandLine.arguments.contains("--navigation-only") {
        openSwitcher()
        try expect(warpTabOverlayWindow() != nil, "First Option-Tab press opens the overlay")
        press(125)
        press(36)
        wait(0.5)
        try expect(warpTabOverlayWindow() == nil, "Arrow plus Enter commits and closes")
        postKey(58, down: false, flags: [])
        print("WarpTab switcher navigation test passed: \(assertions) assertions")
        return
    }

    if CommandLine.arguments.contains("--single-window-promotion-only") {
        try showWarpTabSettings()
        let application = try fixtureApplication()
        let element = try fixtureWindow(titled: "WarpTab Test — Beta")
        let candidate = WarpWindow(
            identity: "promotion-test-beta",
            application: application,
            axWindow: element,
            axTab: nil,
            title: "WarpTab Test — Beta",
            rawTitle: "WarpTab Test — Beta",
            appName: "WarpTab Fixture",
            bundleIdentifier: "com.warptab.fixture",
            icon: application.icon ?? NSImage(),
            windowID: nil,
            bounds: .zero,
            screenIdentifier: nil,
            isFocused: false,
            isMinimized: false,
            isHidden: false,
            isFullscreen: false,
            isOnScreen: true,
            isWindowlessApplication: false,
            nativeTabCount: 1,
            lastFocusedAt: nil
        )
        WindowActivator().activate(candidate)
        wait(0.8)
        let ordered = visibleWindowOrder()
        guard let settingsIndex = ordered.firstIndex(where: {
            $0.owner == "WarpTab" && $0.bounds.width >= 700 && $0.bounds.height >= 500
        }) else {
            throw IntegrationFailure.assertion("WarpTab Settings reference window disappeared")
        }
        let promotedFixtureWindows = ordered[..<settingsIndex].filter { $0.owner == "WarpTab Fixture" }
        print("Frontmost after switch: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        print("Window order through Settings: \(ordered[...settingsIndex].map { "\($0.owner):\($0.title)" })")
        print("Fixture windows promoted above Settings: \(promotedFixtureWindows.map(\.title))")
        try expect(promotedFixtureWindows.count == 1, "Switching promotes only the selected window, not every sibling window")
        print("WarpTab single-window promotion test passed: \(assertions) assertions")
        return
    }

    openSwitcher()
    try expect(warpTabOverlayWindow() != nil, "First Option-Tab press opens the overlay")
    try typeSearch("alpha")
    let initialText = try overlayText()
    print("Alpha search OCR:\n\(initialText)")
    try expect(initialText.contains("Alpha"), "Same-app Alpha window discovered")
    press(53)
    wait(0.25)
    try expect(warpTabOverlayWindow() == nil, "Escape closes the overlay")
    releaseSwitcherModifiers()
    let titleAfterEscape = try focusedFixtureTitle()
    try expect(titleAfterEscape == "WarpTab Native Tab — One", "Escape preserves the original window")

    try resetFocusHistory()
    openSwitcher()
    releaseSwitcherModifiers()
    let quickDestination = try activeDestination()
    print("Quick-switch destination: \(quickDestination)")
    try expect(
        quickDestination != "com.warptab.fixture:WarpTab Native Tab — One",
        "Quick Option-Tab activates the next MRU window"
    )

    try resetFocusHistory()
    openSwitcher()
    press(48, flags: [.maskAlternate], repeatValue: 1)
    wait(0.2)
    releaseSwitcherModifiers()
    let repeatDestination = try activeDestination()
    print("Repeated-Tab destination: \(repeatDestination)")
    try expect(repeatDestination != quickDestination, "Tab repeat advances selection beyond the quick-switch target")

    try resetFocusHistory()
    openSwitcher()
    press(125)
    press(36)
    wait(0.5)
    postKey(58, down: false, flags: [])
    try expect(warpTabOverlayWindow() == nil, "Arrow plus Enter commits and closes")
    let arrowDestination = try activeDestination()
    try expect(arrowDestination != "com.warptab.fixture:WarpTab Native Tab — One", "Arrow navigation changes the target")

    try resetFocusHistory()
    openSwitcher(backwards: true)
    try expect(warpTabOverlayWindow() != nil, "Reverse cycling opens the overlay")
    releaseSwitcherModifiers(backwards: true)
    let reverseDestination = try activeDestination()
    try expect(reverseDestination != quickDestination, "Option-Shift-Tab selects a different reverse target")

    try resetFocusHistory()
    openSwitcher()
    try typeSearch("alpha")
    let searchText = try overlayText()
    try expect(
        searchText.lowercased().contains("search") && searchText.lowercased().contains("alpha"),
        "Search text is displayed"
    )
    try expect(searchText.contains("Alpha"), "Window-title search filters to Alpha")
    press(36)
    wait(0.5)
    postKey(58, down: false, flags: [])
    let searchedTitle = try focusedFixtureTitle()
    try expect(searchedTitle == "WarpTab Test — Alpha", "Enter activates the searched window")
    try expect(warpTabOverlayWindow() == nil, "Enter closes the searched switcher before another shortcut session")

    let fixture = try fixtureApplication()
    fixture.activate()
    try focusFixtureWindow("WarpTab Test — Alpha")
    try focusFixtureWindow("WarpTab Test — Beta")
    try activateFixtureAsFrontmost()
    wait(0.25)
    try expect(
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.warptab.fixture",
        "Fixture is frontmost before same-application switching"
    )
    let sameAppStartingTitle = try focusedFixtureTitle()
    print("Same-application starting window: \(sameAppStartingTitle ?? "nil")")
    openSameApplicationSwitcher()
    let sameApplicationText = try overlayText()
    print("Same-application OCR:\n\(sameApplicationText)")
    try expect(sameApplicationText.contains("Alpha"), "Option-Grave includes another window from the current app")
    try expect(
        !sameApplicationText.contains("Safari") && !sameApplicationText.contains("Finder"),
        "Option-Grave excludes windows from other applications"
    )
    releaseSwitcherModifiers()
    try expect(
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.warptab.fixture",
        "Quick Option-Grave remains within the current application"
    )
    let sameAppDestination = try focusedFixtureTitle()
    print("Same-application destination: \(sameAppDestination ?? "nil")")
    try expect(sameAppDestination != sameAppStartingTitle, "Quick Option-Grave activates the next same-app MRU window")

    try focusFixtureWindow("WarpTab Test — Beta")
    let alpha = try fixtureWindow(titled: "WarpTab Test — Alpha")
    let minimizeResult = AXUIElementSetAttributeValue(alpha, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    wait(0.25)
    try expect(minimizeResult == .success, "Minimize request succeeds")
    try expect(booleanAttribute(alpha, kAXMinimizedAttribute) == true, "Fixture window enters minimized state")
    wait(0.35)
    openSwitcher()
    try typeSearch("alpha")
    let minimizedText = try overlayText()
    try expect(minimizedText.contains("Alpha"), "Minimized window remains searchable")
    press(36)
    wait(0.6)
    postKey(58, down: false, flags: [])
    try expect(booleanAttribute(alpha, kAXMinimizedAttribute) == false, "Selecting restores a minimized window")
    let restoredTitle = try focusedFixtureTitle()
    try expect(restoredTitle == "WarpTab Test — Alpha", "Restored minimized window receives focus")

    try selectFixtureNativeTab("WarpTab Native Tab — One")
    openSwitcher()
    try typeSearch("two")
    let nativeTabSearchText = try overlayText()
    try expect(nativeTabSearchText.contains("Native Tab") && nativeTabSearchText.contains("Two"), "Native-tab search finds the unselected tab")
    press(36)
    wait(0.6)
    postKey(58, down: false, flags: [])
    let nativeTabDeadline = Date().addingTimeInterval(2)
    var activatedNativeTab = try selectedNativeTabTitle()
    while activatedNativeTab != "WarpTab Native Tab — Two", Date() < nativeTabDeadline {
        wait(0.1)
        activatedNativeTab = try selectedNativeTabTitle()
    }
    print("Native tab activation: focused=\(try focusedFixtureTitle() ?? "nil"), selected=\(activatedNativeTab ?? "nil")")
    try expect(activatedNativeTab == "WarpTab Native Tab — Two", "Selecting a native tab presses the exact AX tab")
    wait(0.55)

    let hideResult = AXUIElementSetAttributeValue(
        try fixtureAXApplication(), kAXHiddenAttribute as CFString, kCFBooleanTrue
    )
    wait(0.35)
    try expect(hideResult == .success, "Hide request succeeds")
    let hiddenAXApplication = try fixtureAXApplication()
    try expect(
        booleanAttribute(hiddenAXApplication, kAXHiddenAttribute) == true,
        "Fixture application enters hidden state"
    )
    openSwitcher()
    try typeSearch("beta")
    let hiddenText = try overlayText()
    try expect(hiddenText.contains("Beta"), "Hidden application window remains searchable")
    press(36)
    wait(0.65)
    postKey(58, down: false, flags: [])
    let unhiddenAXApplication = try fixtureAXApplication()
    try expect(
        booleanAttribute(unhiddenAXApplication, kAXHiddenAttribute) == false,
        "Selecting a hidden window unhides its application"
    )
    let hiddenTitle = try focusedFixtureTitle()
    try expect(hiddenTitle == "WarpTab Test — Beta", "Exact hidden window receives focus")

    let beta = try fixtureWindow(titled: "WarpTab Test — Beta")
    try focusFixtureWindow("WarpTab Test — Beta")
    AXUIElementSetAttributeValue(beta, "AXFullScreen" as CFString, kCFBooleanTrue)
    wait(1.4)
    if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
        other.activate(options: [.activateAllWindows])
        wait(0.4)
    }
    openSwitcher()
    try typeSearch("beta")
    let fullscreenText = try overlayText()
    print("Fullscreen search OCR:\n\(fullscreenText)")
    try expect(booleanAttribute(beta, "AXFullScreen") == true, "Fixture window entered fullscreen")
    try expect(fullscreenText.contains("Beta"), "Fullscreen window remains searchable")
    press(36)
    wait(1.0)
    postKey(58, down: false, flags: [])
    try expect(booleanAttribute(beta, "AXFullScreen") == true, "Fullscreen state is preserved during activation")
    let fullscreenTitle = try focusedFixtureTitle()
    try expect(fullscreenTitle == "WarpTab Test — Beta", "Fullscreen window receives exact focus")
    AXUIElementSetAttributeValue(beta, "AXFullScreen" as CFString, kCFBooleanFalse)
    wait(1.0)

    try focusFixtureWindow("WarpTab Test — Alpha")
    openSwitcher()
    try typeSearch("alpha")
    press(46, flags: [.maskAlternate, .maskCommand])
    wait(0.35)
    press(53)
    press(53)
    releaseSwitcherModifiers()
    try expect(booleanAttribute(alpha, kAXMinimizedAttribute) == true, "Command-M minimizes the selected window")
    AXUIElementSetAttributeValue(alpha, kAXMinimizedAttribute as CFString, kCFBooleanFalse)

    try focusFixtureWindow("WarpTab Test — Alpha")
    openSwitcher()
    try typeSearch("alpha")
    press(4, flags: [.maskAlternate, .maskCommand])
    wait(0.35)
    press(53)
    press(53)
    releaseSwitcherModifiers()
    let hiddenByAction = try fixtureApplication().isHidden
    try expect(hiddenByAction, "Command-H hides the selected window's application")
    try fixtureApplication().unhide()
    wait(0.3)

    try focusFixtureWindow("WarpTab Test — Beta")
    openSwitcher()
    try typeSearch("beta")
    press(13, flags: [.maskAlternate, .maskCommand])
    wait(0.4)
    press(53)
    press(53)
    releaseSwitcherModifiers()
    let betaStillExists = try fixtureWindows().contains {
        attribute($0, kAXTitleAttribute) as? String == "WarpTab Test — Beta"
    }
    try expect(!betaStillExists, "Command-W closes the selected window")
}

private func runSameApplicationShortcutTests() throws {
    try expect(AXIsProcessTrusted(), "Accessibility permission available")
    try waitForFixtureWindows()
    try focusFixtureWindow("WarpTab Test — Alpha")
    try activateFixtureAsFrontmost()
    let startingTitle = try focusedFixtureTitle()

    openSameApplicationSwitcher()
    try expect(warpTabOverlayWindow() != nil, "Option-Grave opens the switcher")
    let text = try overlayText()
    print("Same-application shortcut OCR:\n\(text)")
    try expect(text.contains("Beta"), "Another current-app window is present")
    try expect(!text.contains("Safari") && !text.contains("Finder"), "Other applications are excluded")
    try expect(
        releaseSwitcherModifiersAndObserve(bundleIdentifier: "com.warptab.fixture"),
        "Quick release stays in the current application"
    )
    let quickDestination = try focusedFixtureTitle()
    try expect(quickDestination != startingTitle, "Quick release activates the next same-app window")

    try activateFixtureAsFrontmost()
    openSameApplicationSwitcher()
    press(50, flags: [.maskAlternate], repeatValue: 1)
    try expect(warpTabOverlayWindow() != nil, "Repeated Grave keeps the same-app switcher open")
    try expect(
        releaseSwitcherModifiersAndObserve(bundleIdentifier: "com.warptab.fixture"),
        "Repeated cycling cannot leave the current application"
    )

    try activateFixtureAsFrontmost()
    openSameApplicationSwitcher(backwards: true)
    try expect(warpTabOverlayWindow() != nil, "Option-Shift-Grave opens reverse same-app cycling")
    try expect(
        releaseSwitcherModifiersAndObserve(bundleIdentifier: "com.warptab.fixture", backwards: true),
        "Reverse cycling cannot leave the current application"
    )
}

do {
    if CommandLine.arguments.contains("--same-app-only") {
        try runSameApplicationShortcutTests()
        print("WarpTab same-application shortcut tests passed: \(assertions) assertions")
    } else {
        try runTests()
        print("WarpTab live integration tests passed: \(assertions) assertions")
    }
} catch {
    postKey(56, down: false, flags: [])
    postKey(58, down: false, flags: [])
    fputs("WarpTab live integration tests failed: \(error)\n", stderr)
    exit(1)
}
