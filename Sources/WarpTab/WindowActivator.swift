import AppKit
import ApplicationServices

final class WindowActivator {
    struct FocusSnapshot {
        let application: NSRunningApplication
        let window: AXUIElement?
    }

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
        if window.application.isHidden {
            window.application.unhide()
        }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)

        // Make the exact target the application's main/key window before asking
        // macOS to activate the application. Activating first can promote every
        // window in that application above the app the user is leaving.
        selectTabIfNeeded(window, fallback: element)
        let activationElement = activationElement(for: window, fallback: element)
        focus(activationElement, in: appElement)
        window.application.activate(options: [.activateIgnoringOtherApps])
        focus(activationElement, in: appElement)
        // Focusing the shared AppKit window can restore its previously selected
        // tab. Reassert the exact requested tab after the window is key.
        selectTabIfNeeded(window, fallback: element)

        // Space transitions and deminiaturization complete asynchronously.
        // Reassert only the selected window after WindowServer settles. Do not
        // reactivate the whole app: that caused sibling windows to rise and the
        // previously focused window to flash during quick switching.
        for delay in [0.08, 0.22, 0.50] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak application = window.application] in
                guard let self, let application, !application.isTerminated else { return }
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                self.selectTabIfNeeded(window, fallback: element)
                let target = self.activationElement(for: window, fallback: element)
                if delay < 0.1,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
                    self.focus(target, in: appElement)
                    application.activate(options: [.activateIgnoringOtherApps])
                }
                self.focus(target, in: appElement)
                self.selectTabIfNeeded(window, fallback: element)
            }
        }
    }

    func captureFocus() -> FocusSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let focusedWindow = attribute(appElement, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        return FocusSnapshot(application: application, window: focusedWindow)
    }

    func restoreFocus(_ snapshot: FocusSnapshot) {
        guard !snapshot.application.isTerminated else { return }
        let appElement = AXUIElementCreateApplication(snapshot.application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        if let window = snapshot.window {
            focus(window, in: appElement)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != snapshot.application.processIdentifier {
            snapshot.application.activate(options: [.activateIgnoringOtherApps])
        }
        if let window = snapshot.window {
            focus(window, in: appElement)
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

    private func activationElement(for window: WarpWindow, fallback element: AXUIElement) -> AXUIElement {
        currentTab(for: window, in: element)
            .flatMap { attribute($0, kAXWindowAttribute) }
            .map { $0 as! AXUIElement } ?? element
    }

    private func selectTabIfNeeded(_ window: WarpWindow, fallback element: AXUIElement) {
        if let tab = currentTab(for: window, in: element) {
            AXUIElementSetAttributeValue(tab, kAXValueAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
        }
    }

    private func currentTab(for window: WarpWindow, in element: AXUIElement) -> AXUIElement? {
        guard window.axTab != nil else { return nil }
        let expectedTitle = window.rawTitle ?? window.title
        let appElement = AXUIElementCreateApplication(window.application.processIdentifier)
        let liveWindows = (attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for candidateWindow in [element] + liveWindows {
            if let children = attribute(candidateWindow, kAXChildrenAttribute) as? [AXUIElement],
               let group = children.first(where: {
                   attribute($0, kAXRoleAttribute) as? String == "AXTabGroup"
               }),
               let tabs = attribute(group, kAXTabsAttribute) as? [AXUIElement],
               let current = tabs.first(where: {
                   (attribute($0, kAXTitleAttribute) as? String)?
                       .trimmingCharacters(in: .whitespacesAndNewlines) == expectedTitle
               }) {
                return current
            }
        }
        return window.axTab
    }

    private func focus(_ element: AXUIElement, in appElement: AXUIElement) {
        AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
