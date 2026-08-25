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
private func waitUntil(_ timeout: Double, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        wait(0.05)
    } while Date() < deadline
    return false
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
    let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
    CGWarpMouseCursorPosition(CGPoint(x: mainDisplayBounds.midX, y: mainDisplayBounds.midY))
    try expect(waitUntil(1) { !dockPreviewIsVisible() }, "Moving away dismisses Dock previews")
    CGWarpMouseCursorPosition(CGPoint(x: dockOrigin.x + dockSize.width / 2, y: dockOrigin.y + dockSize.height / 2))
    try expect(waitUntil(2) { dockPreviewIsVisible() }, "Returning to the Dock reopens previews")

    let warpTab = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.app").first!
    let warpTabRoot = AXUIElementCreateApplication(warpTab.processIdentifier)
    guard let previewWindow = (attribute(warpTabRoot, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
        attribute($0, kAXTitleAttribute) as? String == "Dock Window Previews"
    }) else { throw Failure.assertion("Preview panel is not accessible") }
    let buttons = descendants(previewWindow).filter {
        attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
    }
    try expect(buttons.count >= 4, "Every fixture window has a clickable preview card")
    guard let beta = buttons.first(where: {
        (attribute($0, kAXTitleAttribute) as? String)?.contains("WarpTab Test — Beta") == true ||
        (attribute($0, kAXDescriptionAttribute) as? String)?.contains("WarpTab Test — Beta") == true
    }), let betaOrigin = point(attribute(beta, kAXPositionAttribute)),
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
    let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.fixture").first!
    let fixtureRoot = AXUIElementCreateApplication(fixture.processIdentifier)
    try expect(waitUntil(2) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.warptab.fixture",
              let focused = attribute(fixtureRoot, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return false }
        return attribute(focused, kAXTitleAttribute) as? String == "WarpTab Test — Beta"
    }, "Clicking a preview focuses the exact window")
    try expect(waitUntil(1) { !dockPreviewIsVisible() }, "Clicking closes the Dock preview panel")
    print("WarpTab Dock preview tests passed: \(assertions) assertions")
} catch {
    fputs("WarpTab Dock preview tests failed: \(error)\n", stderr)
    exit(1)
}
