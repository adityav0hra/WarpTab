import AppKit
import ApplicationServices

final class WindowActivator {
    func activate(_ window: WarpWindow) {
        if window.isWindowlessApplication {
            window.application.unhide()
            window.application.activate(options: [.activateIgnoringOtherApps])
            return
        }

        guard let element = window.axWindow else {
            window.application.unhide()
            window.application.activate(options: [.activateIgnoringOtherApps])
            return
        }

        let appElement = AXUIElementCreateApplication(window.application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        window.application.unhide()
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        performActivation(window: window, appElement: appElement, element: element)

        // Space transitions and deminiaturization complete asynchronously.
        // Reassert the exact target after AppKit/WindowServer settle.
        for delay in [0.06, 0.18, 0.40, 0.85] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.performActivation(window: window, appElement: appElement, element: element)
            }
        }
    }

    func close(_ window: WarpWindow) {
        guard let element = window.axWindow else { return }
        if let tab = window.axTab {
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
        }
        if let rawButton = attribute(element, kAXCloseButtonAttribute) {
            let button = rawButton as! AXUIElement
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    func minimize(_ window: WarpWindow) {
        guard let element = window.axWindow else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    func hideApplication(_ window: WarpWindow) {
        window.application.hide()
    }

    private func performActivation(
        window: WarpWindow,
        appElement: AXUIElement,
        element: AXUIElement
    ) {
        window.application.unhide()
        window.application.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let tab = window.axTab {
            AXUIElementSetAttributeValue(tab, kAXValueAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
