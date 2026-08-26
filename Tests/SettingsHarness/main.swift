import AppKit
import ApplicationServices

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
    return result
}

func string(_ element: AXUIElement, _ attribute: String) -> String? {
    value(element, attribute) as? String
}

func descendants(of root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = [root]
    var cursor = 0
    while cursor < result.count {
        let element = result[cursor]
        cursor += 1
        if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
            result.append(contentsOf: children)
        }
    }
    return result
}

func waitUntil(_ timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return condition()
}

func appPreferenceString(_ key: String) -> String? {
    let appID = "com.warptab.app" as CFString
    CFPreferencesAppSynchronize(appID)
    return CFPreferencesCopyAppValue(key as CFString, appID) as? String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.warptab.app"
}) else {
    fputs("FAIL: WarpTab is not running\n", stderr)
    exit(1)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)
app.activate()
require(waitUntil(3) {
    ((value(axApp, kAXWindowsAttribute) as? [AXUIElement])?.isEmpty == false)
}, "settings window opens")

func find(_ title: String) -> AXUIElement? {
    descendants(of: axApp).first {
        string($0, kAXTitleAttribute) == title ||
            string($0, kAXDescriptionAttribute) == title ||
            string($0, kAXValueAttribute) == title
    }
}

func press(_ title: String) {
    guard let element = find(title) else {
        fputs("FAIL: missing control \(title)\n", stderr)
        exit(1)
    }
    require(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success, "\(title) is clickable")
}

func role(_ element: AXUIElement) -> String? {
    string(element, kAXRoleAttribute)
}

func point(_ value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &result) ? result : nil
}

func size(_ value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &result) ? result : nil
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let origin = point(value(element, kAXPositionAttribute)),
          let dimensions = size(value(element, kAXSizeAttribute)) else { return nil }
    return CGRect(origin: origin, size: dimensions)
}

func pressSidebar(_ title: String) {
    if let button = descendants(of: axApp).first(where: {
        role($0) == kAXButtonRole && (
            string($0, kAXTitleAttribute) == title ||
            string($0, kAXDescriptionAttribute) == title
        )
    }) {
        require(
            AXUIElementPerformAction(button, kAXPressAction as CFString) == .success,
            "\(title) sidebar item is selectable"
        )
        return
    }
    guard let label = descendants(of: axApp).filter({
        role($0) == kAXStaticTextRole && string($0, kAXValueAttribute) == title
    }).min(by: {
        (point(value($0, kAXPositionAttribute))?.x ?? .greatestFiniteMagnitude) <
            (point(value($1, kAXPositionAttribute))?.x ?? .greatestFiniteMagnitude)
    }) else {
        fputs("FAIL: missing sidebar item \(title)\n", stderr)
        exit(1)
    }
    var current = label
    while let parent = value(current, kAXParentAttribute).map({ $0 as! AXUIElement }) {
        if role(parent) == kAXButtonRole {
            require(
                AXUIElementPerformAction(parent, kAXPressAction as CFString) == .success,
                "\(title) sidebar item is selectable"
            )
            return
        }
        if role(parent) == kAXRowRole {
            if AXUIElementSetAttributeValue(
                parent,
                kAXSelectedAttribute as CFString,
                kCFBooleanTrue
            ) == .success {
                print("PASS: \(title) sidebar item is selectable")
                return
            }
            guard let origin = point(value(parent, kAXPositionAttribute)),
                  let dimensions = size(value(parent, kAXSizeAttribute)) else {
                fputs("FAIL: sidebar geometry for \(title) is unavailable\n", stderr)
                exit(1)
            }
            let center = CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
            CGWarpMouseCursorPosition(center)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: center, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
            print("PASS: \(title) sidebar item is selectable")
            return
        }
        current = parent
    }
    fputs("FAIL: sidebar row for \(title) is unavailable\n", stderr)
    exit(1)
}

func verifyDockControlAlignment() {
    guard let previewLabel = find("Preview size"),
          let previewFrame = frame(previewLabel),
          let defaultSegment = find("Default"),
          let nearestToggle = descendants(of: axApp)
            .filter({ role($0) == kAXCheckBoxRole && frame($0) != nil })
            .min(by: {
                abs(frame($0)!.midY - previewFrame.midY) < abs(frame($1)!.midY - previewFrame.midY)
            }),
          let toggleFrame = frame(nearestToggle) else {
        fputs("FAIL: Dock control geometry is unavailable\n", stderr)
        exit(1)
    }
    var selectorElement = defaultSegment
    var current = defaultSegment
    while let parent = value(current, kAXParentAttribute).map({ $0 as! AXUIElement }) {
        guard let parentFrame = frame(parent),
              parentFrame.width <= 260,
              parentFrame.height <= 50 else { break }
        selectorElement = parent
        current = parent
    }
    guard let selectorFrame = frame(selectorElement) else {
        fputs("FAIL: Dock selector frame is unavailable\n", stderr)
        exit(1)
    }
    // SwiftUI's segmented picker exposes only its radio-group content to AX;
    // account for the equal native inset inside the configured 170-point frame.
    let selectorOuterMaxX = selectorFrame.maxX + max(0, 170 - selectorFrame.width) / 2
    require(abs(selectorOuterMaxX - toggleFrame.maxX) <= 12,
            "Dock preview size selector aligns with the trailing control column")
}

require(find("Window Switcher") != nil, "Window Switcher page is present")
require(find("Dock") != nil, "Dock sidebar item is present")
require(find("Window Snapping") != nil, "Window Snapping sidebar item is present")
require(find("Quit WarpTab from settings") != nil, "settings sidebar quit button is present")

if CommandLine.arguments.contains("--quit-confirmation-only") {
    require(app.terminate(), "quit request is accepted")
    require(waitUntil(2) { find("Quit WarpTab?") != nil }, "quit confirmation appears")
    press("Cancel")
    require(waitUntil(2) { !app.isTerminated }, "cancelling keeps WarpTab running")
    require(app.terminate(), "second quit request is accepted")
    require(waitUntil(2) { find("Quit WarpTab?") != nil }, "quit confirmation appears again")
    guard let confirmButton = descendants(of: axApp).first(where: {
        role($0) == kAXButtonRole && string($0, kAXTitleAttribute) == "Quit WarpTab"
    }) else {
        fputs("FAIL: missing Quit WarpTab confirmation button\n", stderr)
        exit(1)
    }
    require(
        AXUIElementPerformAction(confirmButton, kAXPressAction as CFString) == .success,
        "Quit WarpTab confirmation is clickable"
    )
    require(waitUntil(3) { app.isTerminated }, "confirming quits WarpTab")
    print("Quit confirmation checks completed.")
    exit(0)
}

if CommandLine.arguments.contains("--dock-geometry-only") {
    pressSidebar("Dock")
    require(waitUntil(2) { find("Dock window previews") != nil }, "Dock page opens")
    verifyDockControlAlignment()
    print("Settings Dock geometry checks completed.")
    exit(0)
}

if CommandLine.arguments.contains("--snap-assist-style-only") {
    pressSidebar("Window Snapping")
    require(waitUntil(2) { find("Snap Assist view") != nil }, "Window Snapping page opens")
    press("List Snap Assist view")
    require(waitUntil(2) {
        UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "snapAssistLayout") == "list"
    }, "List Snap Assist illustration updates the existing preference")
    press("Thumbnails Snap Assist view")
    require(waitUntil(2) {
        UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "snapAssistLayout") == "thumbnails"
    }, "Thumbnail Snap Assist illustration updates the existing preference")
    print("Settings Snap Assist style checks completed.")
    exit(0)
}

if CommandLine.arguments.contains("--snap-behavior-illustrations-only") {
    pressSidebar("Window Snapping")
    require(waitUntil(2) { find("After minimizing") != nil }, "Window Snapping behavior illustrations open")

    press("Let macOS choose")
    require(waitUntil(2) {
        UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "snapMinimizeFocusBehavior") == "systemDefault"
    }, "Let macOS choose illustration updates the existing preference")
    press("Activate window behind")
    require(waitUntil(2) {
        UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "snapMinimizeFocusBehavior") == "activateWindowBehind"
    }, "Activate window behind illustration updates the existing preference")

    press("Control active window")
    require(waitUntil(2) {
        UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "snapUpAfterMinimizeBehavior") == "controlActiveWindow"
    }, "Control active window illustration updates the existing preference")
    press("Restore minimized window")
    require(waitUntil(2) {
        UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "snapUpAfterMinimizeBehavior") == "restoreMinimizedWindow"
    }, "Restore minimized window illustration updates the existing preference")

    print("Settings Snap behavior illustration checks completed.")
    exit(0)
}

if CommandLine.arguments.contains("--speaker-volume-slider-only") {
    pressSidebar("Sound Mixer")
    require(waitUntil(2) { find("Speaker volume after disconnect") != nil }, "Speaker volume slider is present")
    guard let slider = find("Speaker volume after disconnect") else { exit(1) }
    require(
        AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: 0.65)) == .success,
        "Speaker volume slider accepts a value"
    )
    require(waitUntil(2) {
        abs((UserDefaults(suiteName: "com.warptab.app")?.double(forKey: "soundDisconnectVolume") ?? 0) - 0.65) < 0.001
    }, "Speaker volume slider updates the existing preference")
    print("Settings speaker volume slider checks completed.")
    exit(0)
}

if CommandLine.arguments.contains("--native-tabs-illustrations-only") {
    pressSidebar("Window Switcher")
    require(waitUntil(2) { find("Native window tabs") != nil }, "Native window tabs illustrations are present")
    press("Show Native Tabs Individually")
    require(waitUntil(2) {
        UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "nativeTabBehavior") == "individual"
    }, "Individual-tabs illustration updates the existing preference")
    press("Treat Tab Group as One Window")
    require(waitUntil(2) {
        UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "nativeTabBehavior") == "grouped"
    }, "Grouped-tabs illustration updates the existing preference")
    print("Settings native-tabs illustration checks completed.")
    exit(0)
}

if CommandLine.arguments.contains("--dock-double-click-illustrations-only") {
    pressSidebar("Dock")
    require(waitUntil(2) { find("Double-click minimizes") != nil }, "Dock double-click illustrations are present")
    press("Top Window double-click option")
    require(waitUntil(2) {
        find("Top Window double-click option").flatMap { string($0, kAXValueAttribute) } == "Selected"
    }, "Top-window illustration finishes updating its selected state")
    require(waitUntil(2) {
        appPreferenceString("dockDoubleClickMinimizeScope") == "topWindow"
    }, "Top-window illustration updates the existing preference")
    press("All Windows double-click option")
    require(waitUntil(2) {
        find("All Windows double-click option").flatMap { string($0, kAXValueAttribute) } == "Selected"
    }, "All-windows illustration finishes updating its selected state")
    require(waitUntil(2) {
        appPreferenceString("dockDoubleClickMinimizeScope") == "allWindows"
    }, "All-windows illustration updates the existing preference")
    print("Settings Dock double-click illustration checks completed.")
    exit(0)
}

pressSidebar("Window Switcher")
require(waitUntil(3) { find("Appearance") != nil }, "Appearance section is present")
require(find("Show View Style in menu bar") != nil, "View Style menu visibility option is present")
require(find("Enable Window Switcher") != nil, "enable control is accessible")
require(find("Keyboard shortcut") != nil, "shortcut recorder is accessible")
require(find("Same Application") != nil, "same-application shortcut row is present")
require(find("Same-application shortcut ⌥ `") != nil, "Option-Grave shortcut is exposed accessibly")

press("Keyboard shortcut")
RunLoop.current.run(until: Date().addingTimeInterval(0.15))
let shortcutFlags: CGEventFlags = [.maskControl, .maskAlternate]
let shortcutDown = CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: true)!
shortcutDown.flags = shortcutFlags
shortcutDown.post(tap: .cghidEventTap)
let shortcutUp = CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: false)!
shortcutUp.flags = shortcutFlags
shortcutUp.post(tap: .cghidEventTap)
require(waitUntil(2) {
    UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "customShortcut")?.hasPrefix("3,") == true
}, "shortcut recorder accepts a custom modified key")

press("Thumbnails switcher style")
require(waitUntil(2) {
    UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "switcherLayout") == "thumbnails"
}, "thumbnail selector updates the persisted layout")

press("List switcher style")
require(waitUntil(2) {
    UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "switcherLayout") == "list"
}, "list selector switches the persisted layout back")

for expected in [
    "Keyboard search", "Switcher location", "Window scope",
    "Minimized windows", "Hidden applications", "Full-screen windows", "Other Spaces",
    "Apps without windows", "Native window tabs", "Excluded Applications"
] {
    require(find(expected) != nil, "\(expected) Window Switcher option is present")
}
require(find("Window previews") == nil, "Window previews option is removed")

guard let viewStyleMenuToggle = find("Show View Style menu item") else {
    fputs("FAIL: missing View Style menu visibility toggle\n", stderr)
    exit(1)
}
require(
    AXUIElementPerformAction(viewStyleMenuToggle, kAXPressAction as CFString) == .success,
    "View Style menu visibility toggle is clickable"
)
require(waitUntil(2) {
    UserDefaults(suiteName: "com.warptab.app")?.bool(forKey: "showViewStyleInWarpTabMenu") == false
}, "View Style menu visibility option persists")

pressSidebar("Dock")
require(waitUntil(2) { find("Dock window previews") != nil }, "Dock page opens")
for expected in [
    "Preview size", "Close windows from previews", "Quit after closing last window",
    "Include minimized windows", "Include hidden applications", "Include full-screen windows",
    "Minimize active window on click", "Choose window on app click",
    "Minimize on double-click", "Double-click minimizes"
] {
    require(find(expected) != nil, "\(expected) Dock option is present")
}

verifyDockControlAlignment()

pressSidebar("Window Snapping")
require(waitUntil(2) { find("Enable Windows-style snapping") != nil }, "Window Snapping settings page opens")
require(find("After minimizing") != nil, "Minimize focus choice is present")
require(find("Next Up command") != nil, "Up-after-minimize choice is present")
require(find("Activate window behind") != nil, "Activate-behind choice is present")
require(find("Restore minimized window") != nil, "Restore-minimized choice is present")
require(find("Move snapping across displays") != nil, "Cross-display option is present")
require(find("Show Snap Assist") != nil, "Snap Assist option is present")
require(find("Snap Assist view") != nil, "Snap Assist view choice is present")
require(find("Thumbnails Snap Assist view") != nil, "Thumbnail Snap Assist choice is present")
for expected in [
    "Move / Snap Left", "Move / Snap Right", "Move / Snap Up", "Move / Snap Down"
] {
    require(find(expected) != nil, "\(expected) shortcut is shown")
}

pressSidebar("Permissions")
require(waitUntil(2) { find("Accessibility") != nil && find("Screen Recording") != nil },
        "Permissions page exposes only permissions WarpTab uses")
require(find("Open System Settings") != nil, "permission settings action is present")

pressSidebar("About WarpTab")
let installedInfo = Bundle(path: "/Applications/WarpTab.app")?.infoDictionary
let installedVersion = installedInfo?["CFBundleShortVersionString"] as? String ?? "unknown"
let installedBuild = installedInfo?["CFBundleVersion"] as? String ?? "unknown"
require(
    waitUntil(2) { find("Version \(installedVersion) (\(installedBuild))") != nil },
    "About page uses the app's version metadata"
)

if let windows = value(axApp, kAXWindowsAttribute) as? [AXUIElement] {
    for window in windows {
        if let closeButton = value(window, kAXCloseButtonAttribute).map({ $0 as! AXUIElement }) {
            _ = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        }
    }
}
require(waitUntil(2) { app.activationPolicy == .accessory }, "closing settings removes WarpTab from the Dock")

print("Settings UI checks completed.")
