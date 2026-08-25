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
    guard let label = descendants(of: axApp).first(where: {
        role($0) == kAXStaticTextRole && string($0, kAXValueAttribute) == title
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

require(find("Window Switcher") != nil, "Window Switcher page is present")
require(find("Dock") != nil, "Dock sidebar item is present")
require(find("Window Snapping") != nil, "Window Snapping sidebar item is present")
require(find("Appearance") != nil, "Appearance section is present")
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

pressSidebar("Window Snapping")
require(waitUntil(2) { find("Coming Soon") != nil }, "Window Snapping shows only its Coming Soon page")

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
