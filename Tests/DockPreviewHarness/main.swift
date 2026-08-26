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
private func dockPreviewImage() -> CGImage? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    guard let window = windows.first(where: {
        $0[kCGWindowOwnerName as String] as? String == "WarpTab" &&
        $0[kCGWindowName as String] as? String == "Dock Window Previews"
    }), let number = window[kCGWindowNumber as String] as? NSNumber else { return nil }
    return CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        CGWindowID(number.uint32Value),
        [.boundsIgnoreFraming, .bestResolution]
    )
}
private func previewPixels(_ image: CGImage) -> [UInt8]? {
    let width = 64
    let height = 48
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return rendered ? pixels : nil
}
private func averagePixelDifference(_ left: [UInt8], _ right: [UInt8]) -> Double {
    guard left.count == right.count, !left.isEmpty else { return 0 }
    var total = 0
    for index in stride(from: 0, to: left.count, by: 4) {
        total += abs(Int(left[index]) - Int(right[index]))
        total += abs(Int(left[index + 1]) - Int(right[index + 1]))
        total += abs(Int(left[index + 2]) - Int(right[index + 2]))
    }
    return Double(total) / Double((left.count / 4) * 3)
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
private func movePointerToFixtureDockItem(_ dockRoot: AXUIElement) -> CGPoint? {
    var center: CGPoint?
    for attempt in 0..<4 {
        guard let dockItem = descendants(dockRoot).first(where: { item in
            guard attribute(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
                  let url = attribute(item, kAXURLAttribute) as? URL else { return false }
            return Bundle(url: url)?.bundleIdentifier == "com.warptab.fixture"
        }), let origin = point(attribute(dockItem, kAXPositionAttribute)),
           let dimensions = size(attribute(dockItem, kAXSizeAttribute)) else { return nil }
        center = CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
        if attempt == 0 {
            let display = CGDisplayBounds(CGMainDisplayID())
            let distances = [
                abs(center!.x - display.minX), abs(display.maxX - center!.x),
                abs(center!.y - display.minY), abs(display.maxY - center!.y)
            ]
            var revealPoint = center!
            switch distances.firstIndex(of: distances.min()!) {
            case 0: revealPoint.x = display.minX + 1
            case 1: revealPoint.x = display.maxX - 1
            case 2: revealPoint.y = display.minY + 1
            default: revealPoint.y = display.maxY - 1
            }
            let start = CGEvent(source: nil)?.location ?? revealPoint
            for step in 1...24 {
                let progress = CGFloat(step) / 24
                let next = CGPoint(
                    x: start.x + (revealPoint.x - start.x) * progress,
                    y: start.y + (revealPoint.y - start.y) * progress
                )
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: next, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                wait(0.02)
            }
            wait(1.0)
            continue
        }
        CGWarpMouseCursorPosition(center!)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center!, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        wait(0.22)
    }
    return center
}

do {
    try expect(AXIsProcessTrusted(), "Accessibility permission is available")
    let originalPointer = CGEvent(source: nil)!.location
    defer { CGWarpMouseCursorPosition(originalPointer) }

    let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!
    let dockRoot = AXUIElementCreateApplication(dock.processIdentifier)
    guard descendants(dockRoot).contains(where: { item in
        guard attribute(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
              let url = attribute(item, kAXURLAttribute) as? URL else { return false }
        return Bundle(url: url)?.bundleIdentifier == "com.warptab.fixture"
    }) else {
        throw Failure.assertion("Fixture Dock item is unavailable")
    }

    let fixtureApplication = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.warptab.fixture"
    ).first!
    let fixtureApplicationElement = AXUIElementCreateApplication(fixtureApplication.processIdentifier)
    if CommandLine.arguments.contains("--prepare-minimized") {
        for fixtureWindow in attribute(fixtureApplicationElement, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            AXUIElementSetAttributeValue(fixtureWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
        wait(1.4)
    }
    if CommandLine.arguments.contains("--prepare-hidden") {
        fixtureApplication.hide()
        wait(1.4)
    }

    guard movePointerToFixtureDockItem(dockRoot) != nil else {
        throw Failure.assertion("Fixture Dock item cannot be hovered")
    }
    if CommandLine.arguments.contains("--expect-hidden") ||
        CommandLine.arguments.contains("--expect-filtered-hidden") {
        wait(1.8)
        let description = CommandLine.arguments.contains("--expect-filtered-hidden")
            ? "Excluded special-state windows remain hidden"
            : "Disabled Dock previews remain hidden"
        try expect(!dockPreviewIsVisible(), description)
        print("WarpTab hidden Dock preview test passed: \(assertions) assertions")
        exit(0)
    }
    try expect(waitUntil(2) { dockPreviewIsVisible() }, "Dock hover opens window previews")
    if CommandLine.arguments.contains("--expect-double-click-minimize-all") ||
        CommandLine.arguments.contains("--expect-double-click-minimize-top") ||
        CommandLine.arguments.contains("--expect-double-click-preserved") {
        let fixtureRoot = AXUIElementCreateApplication(fixtureApplication.processIdentifier)
        guard let dockCenter = movePointerToFixtureDockItem(dockRoot),
              let fixtureWindows = attribute(fixtureRoot, kAXWindowsAttribute) as? [AXUIElement],
              fixtureWindows.count > 1 else {
            throw Failure.assertion("Multi-window fixture or Dock item is unavailable")
        }
        let initiallyFocusedWindow = attribute(fixtureRoot, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        for clickState in [1, 2] {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: type,
                    mouseCursorPosition: dockCenter,
                    mouseButton: .left
                )!
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                event.post(tap: .cghidEventTap)
            }
            wait(0.06)
        }
        if CommandLine.arguments.contains("--expect-double-click-minimize-all") {
            try expect(waitUntil(2) {
                fixtureWindows.allSatisfy {
                    (attribute($0, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true
                }
            }, "Fast Dock double-click minimizes every window of the app")
            try expect(!dockPreviewIsVisible(), "Minimizing all windows dismisses Dock previews")
            print("WarpTab Dock double-click minimize-all test passed: \(assertions) assertions")
        } else if CommandLine.arguments.contains("--expect-double-click-minimize-top") {
            guard let focusedWindow = initiallyFocusedWindow else {
                throw Failure.assertion("The fixture's top window is unavailable")
            }
            try expect(waitUntil(2) {
                (attribute(focusedWindow, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true
            }, "Top-window mode minimizes the app's top window")
            try expect(fixtureWindows.filter { !CFEqual($0, focusedWindow) }.allSatisfy {
                (attribute($0, kAXMinimizedAttribute) as? NSNumber)?.boolValue != true
            }, "Top-window mode preserves the app's other windows")
            try expect(!dockPreviewIsVisible(), "Minimizing the top window dismisses Dock previews")
            print("WarpTab Dock double-click top-window test passed: \(assertions) assertions")
        } else {
            wait(0.4)
            try expect(fixtureWindows.allSatisfy {
                (attribute($0, kAXMinimizedAttribute) as? NSNumber)?.boolValue != true
            }, "Disabling double-click minimize preserves every app window")
            try expect(dockPreviewIsVisible(), "Disabled double-click minimize leaves the window chooser open")
            print("WarpTab disabled Dock double-click test passed: \(assertions) assertions")
        }
        exit(0)
    }
    if CommandLine.arguments.contains("--expect-multi-window-chooser") {
        let fixtureRoot = AXUIElementCreateApplication(fixtureApplication.processIdentifier)
        guard let initiallyFocused = attribute(fixtureRoot, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }),
              let firstDockCenter = movePointerToFixtureDockItem(dockRoot) else {
            throw Failure.assertion("Frontmost fixture window or Dock item is unavailable")
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: firstDockCenter, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        wait(0.4)
        try expect(dockPreviewIsVisible(), "Clicking a frontmost multi-window app keeps its previews open")
        try expect((attribute(initiallyFocused, kAXMinimizedAttribute) as? NSNumber)?.boolValue != true,
                   "Multi-window choosing takes priority over Dock-click minimize")

        let mainDisplay = CGDisplayBounds(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: mainDisplay.midX, y: mainDisplay.midY))
        try expect(waitUntil(1) { !dockPreviewIsVisible() }, "Moving away closes the chooser before the background-app check")
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first!
        finder.activate(options: [.activateIgnoringOtherApps])
        wait(0.4)
        guard let secondDockCenter = movePointerToFixtureDockItem(dockRoot) else {
            throw Failure.assertion("Background fixture Dock item is unavailable")
        }
        try expect(waitUntil(2) { dockPreviewIsVisible() }, "Hover restores the background app's previews")
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: secondDockCenter, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        wait(0.4)
        try expect(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
                   "Clicking a background multi-window app does not activate all of its windows")
        try expect(dockPreviewIsVisible(), "The chooser remains open until a window is selected")

        let warpTab = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.app").first!
        let warpTabRoot = AXUIElementCreateApplication(warpTab.processIdentifier)
        var beta: AXUIElement?
        try expect(waitUntil(2) {
            guard let previewWindow = (attribute(warpTabRoot, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
                attribute($0, kAXTitleAttribute) as? String == "Dock Window Previews"
            }) else { return false }
            beta = descendants(previewWindow).first {
                attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                    label($0).contains("Open WarpTab Test — Beta")
            }
            return beta != nil
        }, "The exact Beta preview is available")
        guard let beta else { throw Failure.assertion("Beta preview is unavailable") }
        try expect(click(beta), "A preview can be selected after intercepting the Dock click")
        try expect(waitUntil(2) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.warptab.fixture",
                  let focused = attribute(fixtureRoot, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else {
                return false
            }
            return attribute(focused, kAXTitleAttribute) as? String == "WarpTab Test — Beta"
        }, "Only the selected window is activated")
        print("WarpTab multi-window Dock chooser test passed: \(assertions) assertions")
        exit(0)
    }
    if CommandLine.arguments.contains("--expect-active-dock-minimize") {
        let fixtureRoot = AXUIElementCreateApplication(fixtureApplication.processIdentifier)
        guard let focusedWindow = attribute(fixtureRoot, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }),
              let dockCenter = movePointerToFixtureDockItem(dockRoot) else {
            throw Failure.assertion("Active fixture window or Dock item is unavailable")
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: dockCenter, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        try expect(waitUntil(2) {
            (attribute(focusedWindow, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true
        }, "Clicking the frontmost app's Dock icon minimizes its active window")
        try expect(!dockPreviewIsVisible(), "Minimizing from the Dock dismisses previews")
        print("WarpTab active Dock-click minimize test passed: \(assertions) assertions")
        exit(0)
    }
    if CommandLine.arguments.contains("--expect-live-refresh") {
        wait(2.0)
        guard let baselineImage = dockPreviewImage(),
              let baseline = previewPixels(baselineImage) else {
            throw Failure.assertion("Initial live preview image is unavailable")
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.warptab.fixture.update-preview"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        try expect(waitUntil(5) {
            guard let updatedImage = dockPreviewImage(),
                  let updated = previewPixels(updatedImage) else { return false }
            return averagePixelDifference(baseline, updated) > 5
        }, "Visible Dock thumbnails refresh when window contents change")
        print("WarpTab live Dock preview refresh test passed: \(assertions) assertions")
        exit(0)
    }
    if CommandLine.arguments.contains("--expect-special-visible") {
        try expect(dockPreviewIsVisible(), "Configured special-state windows remain available in Dock previews")
        print("WarpTab special-state Dock preview test passed: \(assertions) assertions")
        exit(0)
    }
    if CommandLine.arguments.contains("--expect-small") {
        try expect((dockPreviewBounds()?.height ?? 10_000) < 170, "Small Dock previews use a shorter panel")
        print("WarpTab small Dock preview test passed: \(assertions) assertions")
        exit(0)
    }
    let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
    CGWarpMouseCursorPosition(CGPoint(x: mainDisplayBounds.midX, y: mainDisplayBounds.midY))
    try expect(waitUntil(1) { !dockPreviewIsVisible() }, "Moving away dismisses Dock previews")
    guard movePointerToFixtureDockItem(dockRoot) != nil else {
        throw Failure.assertion("Fixture Dock item cannot be re-hovered")
    }
    try expect(waitUntil(2) { dockPreviewIsVisible() }, "Returning to the Dock reopens previews")

    if CommandLine.arguments.contains("--test-dock-click") {
        let fixtureRoot = AXUIElementCreateApplication(fixtureApplication.processIdentifier)
        let focusedBeforeClick = attribute(fixtureRoot, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        guard let dockCenter = movePointerToFixtureDockItem(dockRoot) else {
            throw Failure.assertion("Fixture Dock item cannot be clicked")
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: dockCenter, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        try expect(waitUntil(1) { !dockPreviewIsVisible() }, "Clicking the Dock icon dismisses its previews")
        if let focusedBeforeClick {
            try expect((attribute(focusedBeforeClick, kAXMinimizedAttribute) as? NSNumber)?.boolValue != true,
                       "Disabling Dock-click minimize preserves the active window")
        }
        wait(0.7)
        try expect(!dockPreviewIsVisible(), "Dock previews stay hidden while the pointer remains on the clicked icon")
        CGWarpMouseCursorPosition(CGPoint(x: mainDisplayBounds.midX, y: mainDisplayBounds.midY))
        wait(0.3)
        guard movePointerToFixtureDockItem(dockRoot) != nil else {
            throw Failure.assertion("Fixture Dock item cannot be hovered after clicking")
        }
        try expect(waitUntil(2) { dockPreviewIsVisible() }, "Leaving and hovering the Dock icon again restores previews")

    }

    let warpTab = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.app").first!
    let warpTabRoot = AXUIElementCreateApplication(warpTab.processIdentifier)
    let expectedOpenButtonCount: Int
    if CommandLine.arguments.contains("--last-window-quit") ||
        CommandLine.arguments.contains("--last-window-keep-open") {
        expectedOpenButtonCount = 1
    } else if CommandLine.arguments.contains("--expect-aspect-fit") {
        expectedOpenButtonCount = 2
    } else {
        expectedOpenButtonCount = 4
    }
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

    if CommandLine.arguments.contains("--expect-aspect-fit") {
        guard let portrait = openButtons.first(where: { label($0).contains("WarpTab Portrait Preview") }),
              let portraitSize = size(attribute(portrait, kAXSizeAttribute)),
              let wide = openButtons.first(where: { label($0).contains("WarpTab Wide Preview") }),
              let wideSize = size(attribute(wide, kAXSizeAttribute)) else {
            throw Failure.assertion("Aspect-ratio preview cards are unavailable")
        }
        try expect(portraitSize.width < 120 && portraitSize.height > 145,
                   "Portrait previews become narrower instead of letterboxed")
        try expect(wideSize.width > 220 && wideSize.height < 120,
                   "Wide previews become shorter instead of letterboxed")
        print("WarpTab adaptive Dock preview test passed: \(assertions) assertions")
        exit(0)
    }

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
    let frontmostBeforeClose = NSWorkspace.shared.frontmostApplication
    let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    finder?.activate(options: [.activateIgnoringOtherApps])
    try expect(waitUntil(2) {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }, "A different application is frontmost before closing a background preview")
    try expect(click(alphaClose), "A window can be clicked closed from its preview")
    let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warptab.fixture").first!
    let fixtureRoot = AXUIElementCreateApplication(fixture.processIdentifier)
    try expect(waitUntil(2) {
        let windows = attribute(fixtureRoot, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return !windows.contains { label($0).contains("WarpTab Test — Alpha") }
    }, "Closing a preview closes the exact window")
    try expect(!fixture.isTerminated, "Closing a non-final window does not quit the app")
    try expect(waitUntil(1) {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }, "Closing a background preview does not raise the app's remaining windows")

    if CommandLine.arguments.contains("--close-background-only") {
        print("WarpTab background Dock-preview close test passed: \(assertions) assertions")
        exit(0)
    }

    if let frontmostBeforeClose, !frontmostBeforeClose.isTerminated {
        frontmostBeforeClose.activate(options: [.activateIgnoringOtherApps])
    }

    guard movePointerToFixtureDockItem(dockRoot) != nil else {
        throw Failure.assertion("Fixture Dock item cannot be hovered after closing")
    }
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
        guard let dockCenter = movePointerToFixtureDockItem(dockRoot) else {
            throw Failure.assertion("Fixture Dock item cannot be secondary-clicked")
        }
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
