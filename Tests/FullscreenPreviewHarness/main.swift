import AppKit
import ApplicationServices
import CoreGraphics

enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        if case .assertion(let message) = self { return message }
        return "failure"
    }
}

private var assertions = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw HarnessFailure.assertion(message) }
    assertions += 1
    print("PASS: \(message)")
}

private func waitUntil(_ timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
    } while Date() < deadline
    return false
}

private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

private func axBounds(_ element: AXUIElement) -> CGRect? {
    guard let rawPosition = attribute(element, kAXPositionAttribute),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(),
          let rawSize = attribute(element, kAXSizeAttribute),
          CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
          AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: position, size: size)
}

private func cgWindow(pid: pid_t, title: String) -> (CGWindowID, CGRect, Bool)? {
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    for window in windows {
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              window[kCGWindowName as String] as? String == title,
              let number = window[kCGWindowNumber as String] as? NSNumber,
              let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { continue }
        return (
            CGWindowID(number.uint32Value),
            bounds,
            (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        )
    }
    return nil
}

private func warpWindow(
    application: NSRunningApplication,
    element: AXUIElement,
    windowID: CGWindowID,
    bounds: CGRect,
    isFullscreen: Bool,
    isOnScreen: Bool
) -> WarpWindow {
    WarpWindow(
        identity: "\(application.processIdentifier):fullscreen-preview-test",
        application: application,
        axWindow: element,
        axTab: nil,
        title: "WarpTab Live Preview",
        rawTitle: "WarpTab Live Preview",
        appName: "WarpTabFixture",
        bundleIdentifier: application.bundleIdentifier,
        icon: application.icon ?? NSImage(),
        windowID: windowID,
        bounds: bounds,
        screenIdentifier: nil,
        isFocused: true,
        isMinimized: false,
        isHidden: false,
        isFullscreen: isFullscreen,
        isOnScreen: isOnScreen,
        isWindowlessApplication: false,
        nativeTabCount: 0,
        lastFocusedAt: nil
    )
}

private func pixels(_ image: NSImage) -> [UInt8]? {
    var proposed = CGRect(origin: .zero, size: image.size)
    guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
    let width = 64
    let height = 48
    var values = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = values.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return rendered ? values : nil
}

private func averageDifference(_ left: [UInt8], _ right: [UInt8]) -> Double {
    guard left.count == right.count else { return 0 }
    var total = 0
    for index in stride(from: 0, to: left.count, by: 4) {
        total += abs(Int(left[index]) - Int(right[index]))
        total += abs(Int(left[index + 1]) - Int(right[index + 1]))
        total += abs(Int(left[index + 2]) - Int(right[index + 2]))
    }
    return Double(total) / Double((left.count / 4) * 3)
}

private func capture(
    cache: PreviewCache,
    window: WarpWindow,
    forceRefresh: Bool,
    timeout: TimeInterval = 2
) throws -> NSImage {
    var result: NSImage?
    if let immediate = cache.image(for: window, forceRefresh: forceRefresh, refresh: { _, image in
        result = image
    }), !forceRefresh {
        return immediate
    }
    guard waitUntil(timeout, condition: { result != nil }), let result else {
        throw HarnessFailure.assertion("Preview capture did not complete")
    }
    return result
}

do {
    try expect(AXIsProcessTrusted(), "Accessibility permission is available")
    try expect(CGPreflightScreenCaptureAccess(), "Screen Recording permission is available")
    guard let application = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.warptab.fixture"
    ).first else { throw HarnessFailure.assertion("Fixture application is unavailable") }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    guard let windowElement = (attribute(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first,
          let normalSource = cgWindow(pid: application.processIdentifier, title: "WarpTab Live Preview") else {
        throw HarnessFailure.assertion("Normal fixture window is unavailable")
    }

    let cache = PreviewCache()
    cache.prepare()
    let normalWindow = warpWindow(
        application: application,
        element: windowElement,
        windowID: normalSource.0,
        bounds: normalSource.1,
        isFullscreen: false,
        isOnScreen: normalSource.2
    )
    let normalCaptureStarted = Date()
    let normalImage = try capture(cache: cache, window: normalWindow, forceRefresh: false)
    let normalCaptureLatency = Date().timeIntervalSince(normalCaptureStarted)
    print(String(format: "Normal preview capture latency: %.0f ms", normalCaptureLatency * 1_000))
    try expect(pixels(normalImage) != nil, "Normal window preview captured")
    try expect(normalCaptureLatency < 0.5, "Cold preview capture completes in under 500 ms")

    try expect(
        AXUIElementSetAttributeValue(windowElement, "AXFullScreen" as CFString, kCFBooleanTrue) == .success,
        "Fixture accepts a full-screen transition"
    )
    try expect(waitUntil(6) {
        (attribute(windowElement, "AXFullScreen") as? NSNumber)?.boolValue == true
    }, "Fixture entered a full-screen Space")
    guard waitUntil(3, condition: {
        cgWindow(pid: application.processIdentifier, title: "WarpTab Live Preview") != nil
    }), let fullScreenSource = cgWindow(pid: application.processIdentifier, title: "WarpTab Live Preview") else {
        throw HarnessFailure.assertion("Full-screen CoreGraphics window is unavailable")
    }
    guard let fullScreenAXBounds = axBounds(windowElement) else {
        throw HarnessFailure.assertion("Full-screen Accessibility bounds are unavailable")
    }

    let fullScreenWindow = warpWindow(
        application: application,
        element: windowElement,
        windowID: fullScreenSource.0,
        bounds: fullScreenAXBounds,
        isFullscreen: true,
        isOnScreen: fullScreenSource.2
    )
    var transitionedImage: NSImage?
    let fullScreenCaptureStarted = Date()
    let staleImmediate = cache.image(for: fullScreenWindow, forceRefresh: false) { _, image in
        transitionedImage = image
    }
    try expect(staleImmediate == nil, "Full-screen transition does not reuse the normal-Space thumbnail")
    try expect(waitUntil(2) { transitionedImage != nil }, "Full-screen window preview captured")
    let fullScreenCaptureLatency = Date().timeIntervalSince(fullScreenCaptureStarted)
    print(String(format: "Full-screen preview capture latency: %.0f ms", fullScreenCaptureLatency * 1_000))
    try expect(fullScreenCaptureLatency < 0.5, "Full-screen preview capture completes in under 500 ms")
    guard let fullScreenImage = transitionedImage, let baseline = pixels(fullScreenImage) else {
        throw HarnessFailure.assertion("Full-screen preview pixels are unavailable")
    }
    let expectedAspectRatio = fullScreenAXBounds.width / max(1, fullScreenAXBounds.height)
    let capturedAspectRatio = fullScreenImage.size.width / max(1, fullScreenImage.size.height)
    print(String(
        format: "Full-screen aspect ratio: %.3f captured (%0.fx%0.f) / %.3f Accessibility (%0.fx%0.f)",
        capturedAspectRatio,
        fullScreenImage.size.width,
        fullScreenImage.size.height,
        expectedAspectRatio,
        fullScreenAXBounds.width,
        fullScreenAXBounds.height
    ))
    try expect(
        abs(log(capturedAspectRatio / expectedAspectRatio)) < 0.06,
        "Full-screen preview uses the current Space aspect ratio"
    )

    let refreshStarted = Date()
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.warptab.fixture.update-preview"),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
    var refreshedImage: NSImage?
    _ = cache.image(for: fullScreenWindow, forceRefresh: true) { _, image in
        refreshedImage = image
    }
    try expect(waitUntil(0.5) {
        guard let refreshedImage, let updated = pixels(refreshedImage) else { return false }
        return averageDifference(baseline, updated) > 5
    }, "Full-screen live preview refreshes after its content changes")
    let refreshLatency = Date().timeIntervalSince(refreshStarted)
    try expect(refreshLatency < 0.5, "Full-screen live preview refresh completes in under 500 ms")
    print(String(format: "Full-screen refresh latency: %.0f ms", refreshLatency * 1_000))
    print("WarpTab full-screen preview test passed: \(assertions) assertions")
} catch {
    fputs("WarpTab full-screen preview test failed: \(error)\n", stderr)
    exit(1)
}
