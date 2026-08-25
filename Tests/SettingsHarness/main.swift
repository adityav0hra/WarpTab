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

let mainElements = descendants(of: axApp)
require(find("Window Switching") != nil, "Window Switching section is present")
require(find("Appearance") != nil, "Appearance section is present")
require(find("Permissions") != nil, "Permissions section is present")
require(find("Enable WarpTab") != nil, "enable control is accessible")
require(find("Keyboard shortcut") != nil, "shortcut recorder is accessible")
require(find("Same Application") != nil, "same-application shortcut row is present")
require(find("Same-application shortcut ⌥ `") != nil, "Option-Grave shortcut is exposed accessibly")

press("Keyboard shortcut")
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
}, "thumbnail card updates the persisted layout")

press("List switcher style")
require(waitUntil(2) {
    UserDefaults(suiteName: "com.warptab.app")?.string(forKey: "switcherLayout") == "list"
}, "list card switches the persisted layout back")

press("Open window and display options")
require(waitUntil(2) {
    ((value(axApp, kAXWindowsAttribute) as? [AXUIElement])?.contains {
        string($0, kAXTitleAttribute) == "Window & Display Options"
    }) == true
}, "advanced window options open")

for expected in [
    "Keyboard search", "Window previews", "Switcher location", "Window scope", "Dock window previews",
    "Preview size", "Close windows from previews", "Quit after closing last window",
    "Minimized windows", "Hidden applications", "Full-screen windows", "Other Spaces",
    "Apps without windows", "Native window tabs", "Excluded Applications", "Screen Recording"
] {
    require(find(expected) != nil, "\(expected) option is present")
}

if let windows = value(axApp, kAXWindowsAttribute) as? [AXUIElement] {
    for window in windows {
        if let closeButton = value(window, kAXCloseButtonAttribute).map({ $0 as! AXUIElement }) {
            _ = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        }
    }
}
require(waitUntil(2) { app.activationPolicy == .accessory }, "closing settings removes WarpTab from the Dock")

print("Settings UI checks completed.")
