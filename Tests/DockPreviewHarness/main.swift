import AppKit
import ApplicationServices
import CoreGraphics

enum Failure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { if case .assertion(let message) = self { return message }; return "failure" }
}

private var assertions = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure.assertion(message) }
    assertions += 1
    print("PASS: \(message)")
}
private func wait(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
private func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 7 else { return [] }
    let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return children + children.flatMap { descendants($0, depth: depth + 1) }
}
private func point(_ value: AnyObject?) -> CGPoint? {
    guard let value = value.map({ $0 as! AXValue }) else { return nil }
    var result = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &result) ? result : nil
}
private func size(_ value: AnyObject?) -> CGSize? {
    guard let value = value.map({ $0 as! AXValue }) else { return nil }
    var result = CGSize.zero
    return AXValueGetValue(value, .cgSize, &result) ? result : nil
}
private func dockPreviewIsVisible() -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return windows.contains {
        $0[kCGWindowOwnerName as String] as? String == "WarpTab" &&
        $0[kCGWindowName as String] as? String == "Dock Window Previews"
    }
}
private func dockPreviewBounds() -> CGRect? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    guard let window = windows.first(where: {
        $0[kCGWindowOwnerName as String] as? String == "WarpTab" &&
        $0[kCGWindowName as String] as? String == "Dock Window Previews"
    }), let dictionary = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
}
private func label(_ element: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
        .compactMap { attribute(element, $0) as? String }
        .joined(separator: " ")
}
private func waitUntil(_ timeout: Double, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        wait(0.05)
    } while Date() < deadline
    return false
}
private func click(_ element: AXUIElement) -> Bool {
    guard let origin = point(attribute(element, kAXPositionAttribute)),
          let dimensions = size(attribute(element, kAXSizeAttribute)) else { return false }
    let center = CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
    CGWarpMouseCursorPosition(center)
    wait(0.08)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: center, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    return true
}

do {
    try expect(AXIsProcessTrusted(), "Accessibility permission is available")
    let originalPointer = CGEvent(source: nil)!.location
    defer { CGWarpMouseCursorPosition(originalPointer) }

    let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!
    let dockRoot = AXUIElementCreateApplication(dock.processIdentifier)
    guard let dockItem = descendants(dockRoot).first(where: { item in
        guard attribute(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
              let url = attribute(item, kAXURLAttribute) as? URL else { return false }
        return Bundle(url: url)?.bundleIdentifier == "com.warptab.fixture"
    }), let dockOrigin = point(attribute(dockItem, kAXPositionAttribute)),
       let dockSize = size(attribute(dockItem, kAXSizeAttribute)) else {
        throw Failure.assertion("Fixture Dock item is unavailable")
    }

    CGWarpMouseCursorPosition(CGPoint(x: dockOrigin.x + dockSize.width / 2, y: dockOrigin.y + dockSize.height / 2))
    if CommandLine.arguments.contains("--expect-hidden") {
        wait(0.9)
        try expect(!dockPreviewIsVisible(), "Disabled Dock previews remain hidden")
        print("WarpTab disabled Dock preview test passed: \(assertions) assertions")
        exit(0)
    }
    try expect(waitUntil(2) { dockPreviewIsVisible() }, "Dock hover opens window previews")
    if CommandLine.arguments.contains("--expect-small") {
        try expect((dockPreviewBounds()?.height ?? 10_000) < 170, "Small Dock previews use a shorter panel")
        print("WarpTab small Dock preview test passed: \(assertions) assertions")
        exit(0)
    }
    let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
    CGWarpMouseCursorPosition(CGPoint(x: mainDisplayBounds.midX, y: mainDisplayBounds.midY))
    try expect(waitUntil(1) { !dockPreviewIsVisible() }, "Moving away dismisses Dock previews")
    CGWarpMouseCursorPosition(CGPoint(x: dockOrigin.x + dockSize.width / 2, y: dockOrigin.y + dockSize.height / 2))
    try expect(waitUntil(2) { dockPreviewIsVisible() }, "Returning to the Dock reopens previews")

    if CommandLine.arguments.contains("--test-dock-click") {
        let dockCenter = CGPoint(x: dockOrigin.x + dockSize.width / 2, y: dockOrigin.y + dockSize.height / 2)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: dockCenter, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        try expect(waitUntil(1) { !dockPreviewIsVisible() }, "Clicking the Dock icon dismisses its previews")
        wait(0.7)
        try expect(!dockPreviewIsVisible(), "Dock previews stay hidden while the pointer remains on the clicked icon")
        CGWarpMouseCursorPosition(CGPoint(x: mainDisplayBounds.midX, y: mainDisplayBounds.midY))
        wait(0.3)
        CGWarpMouseCursorPosition(dockCenter)
        try expect(waitUntil(2) { dockPreviewIsVisible() }, "Leaving and hovering the Dock icon again restores previews")

    }

    let warpTab = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.app").first!
    let warpTabRoot = AXUIElementCreateApplication(warpTab.processIdentifier)
    let expectedOpenButtonCount = CommandLine.arguments.contains("--last-window-quit") ||
        CommandLine.arguments.contains("--last-window-keep-open") ? 1 : 4
    var openButtons: [AXUIElement] = []
    var closeButtons: [AXUIElement] = []
    try expect(waitUntil(2) {
        guard let previewWindow = (attribute(warpTabRoot, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
            attribute($0, kAXTitleAttribute) as? String == "Dock Window Previews"
        }) else { return false }
        let buttons = descendants(previewWindow).filter {
            attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
        }
        openButtons = buttons.filter { label($0).contains("Open ") }
        closeButtons = buttons.filter { label($0).contains("Close ") }
        return openButtons.count >= expectedOpenButtonCount
    }, "Preview cards are accessible")

    if CommandLine.arguments.contains("--expect-no-close") {
        try expect(closeButtons.isEmpty, "Close buttons stay hidden when the feature is disabled")
        print("WarpTab disabled close-button test passed: \(assertions) assertions")
        exit(0)
    }

    if CommandLine.arguments.contains("--last-window-quit") ||
        CommandLine.arguments.contains("--last-window-keep-open") {
        guard let close = closeButtons.first(where: { label($0).contains("WarpTab Single Window") }) else {
            throw Failure.assertion("Single-window close button is unavailable")
        }
        try expect(click(close), "Last window can be clicked closed from its preview")
        if CommandLine.arguments.contains("--last-window-keep-open") {
            wait(1.2)
            try expect(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.fixture").isEmpty,
                       "Closing the final window leaves the app running when quit is disabled")
            print("WarpTab last-window keep-open test passed: \(assertions) assertions")
            exit(0)
        }
        try expect(waitUntil(3) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.fixture").isEmpty
        }, "Closing the final window quits the app when enabled")
        print("WarpTab last-window quit test passed: \(assertions) assertions")
        exit(0)
    }

    try expect(openButtons.count >= 4, "Every fixture window has a clickable preview card")
    try expect(closeButtons.count >= 4, "Every fixture window has a close button")
    guard let alphaClose = closeButtons.first(where: { label($0).contains("WarpTab Test — Alpha") }) else {
        throw Failure.assertion("Alpha close button is unavailable")
    }
    try expect(click(alphaClose), "A window can be clicked closed from its preview")
    let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.fixture").first!
    let fixtureRoot = AXUIElementCreateApplication(fixture.processIdentifier)
    try expect(waitUntil(2) {
        let windows = attribute(fixtureRoot, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return !windows.contains { label($0).contains("WarpTab Test — Alpha") }
    }, "Closing a preview closes the exact window")
    try expect(!fixture.isTerminated, "Closing a non-final window does not quit the app")

    CGWarpMouseCursorPosition(CGPoint(x: dockOrigin.x + dockSize.width / 2, y: dockOrigin.y + dockSize.height / 2))
    try expect(waitUntil(2) { dockPreviewIsVisible() }, "Dock previews remain available after closing a window")
    var refreshedPreviewWindow: AXUIElement?
    try expect(waitUntil(2) {
        refreshedPreviewWindow = (attribute(warpTabRoot, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
            attribute($0, kAXTitleAttribute) as? String == "Dock Window Previews"
        })
        return refreshedPreviewWindow != nil
    }, "Refreshed preview panel is accessible")
    guard let refreshedPreviewWindow else { throw Failure.assertion("Refreshed preview panel is unavailable") }
    let refreshedOpenButtons = descendants(refreshedPreviewWindow).filter {
        attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && label($0).contains("Open ")
    }
    guard let beta = refreshedOpenButtons.first(where: { label($0).contains("WarpTab Test — Beta") }),
       let betaOrigin = point(attribute(beta, kAXPositionAttribute)),
       let betaSize = size(attribute(beta, kAXSizeAttribute)) else {
        throw Failure.assertion("Beta preview card is unavailable")
    }

    let betaCenter = CGPoint(x: betaOrigin.x + betaSize.width / 2, y: betaOrigin.y + betaSize.height / 2)
    CGWarpMouseCursorPosition(betaCenter)
    wait(0.08)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: betaCenter, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    try expect(waitUntil(2) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.warptab.fixture",
              let focused = attribute(fixtureRoot, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return false }
        return attribute(focused, kAXTitleAttribute) as? String == "WarpTab Test — Beta"
    }, "Clicking a preview focuses the exact window")
    try expect(waitUntil(1) { !dockPreviewIsVisible() }, "Clicking closes the Dock preview panel")
    if CommandLine.arguments.contains("--test-dock-click") {
        let dockCenter = CGPoint(x: dockOrigin.x + dockSize.width / 2, y: dockOrigin.y + dockSize.height / 2)
        CGWarpMouseCursorPosition(dockCenter)
        try expect(waitUntil(2) { dockPreviewIsVisible() }, "Dock previews reopen before the secondary-click check")
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: dockCenter, mouseButton: .right)?
                .post(tap: .cghidEventTap)
        }
        try expect(waitUntil(1) { !dockPreviewIsVisible() },
                   "Two-finger or secondary clicking the Dock icon dismisses its previews")
        for keyDown in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: keyDown)?.post(tap: .cghidEventTap)
        }
    }
    print("WarpTab Dock preview tests passed: \(assertions) assertions")
} catch {
    fputs("WarpTab Dock preview tests failed: \(error)\n", stderr)
    exit(1)
}
