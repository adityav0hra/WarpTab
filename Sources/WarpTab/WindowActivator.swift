import AppKit
import ApplicationServices

final class WindowActivator {
    struct FocusSnapshot {
        let application: NSRunningApplication
        let window: AXUIElement?
    }

    private var activationGeneration: UInt64 = 0

    func activate(_ window: WarpWindow) {
        activationGeneration &+= 1
        let generation = activationGeneration
        if window.isWindowlessApplication {
            window.application.unhide()
            window.application.activate(options: [.activateIgnoringOtherApps])
            return
        }

        guard let element = liveWindowElement(for: window) ?? window.axWindow else {
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
                guard let self,
                      self.activationGeneration == generation,
                      let application,
                      !application.isTerminated else { return }
                // A full-screen transition or rapid tab/window change can
                // replace the AX object after the preview was clicked. Resolve
                // it again for every repair pass instead of focusing a stale
                // element that macOS silently ignores.
                let currentElement = self.liveWindowElement(for: window) ?? element
                AXUIElementSetAttributeValue(currentElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                self.selectTabIfNeeded(window, fallback: currentElement)
                let target = self.activationElement(for: window, fallback: currentElement)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
                    self.focus(target, in: appElement)
                    application.activate(options: [.activateIgnoringOtherApps])
                }
                self.focus(target, in: appElement)
                self.selectTabIfNeeded(window, fallback: currentElement)
            }
        }
    }

    func captureFocus() -> FocusSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let focusedWindow = warpAXElement(attribute(appElement, kAXFocusedWindowAttribute))
        return FocusSnapshot(application: application, window: focusedWindow)
    }

    func restoreFocus(_ snapshot: FocusSnapshot) {
        activationGeneration &+= 1
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
        if let button = warpAXElement(attribute(element, kAXCloseButtonAttribute)) {
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
            .flatMap { warpAXElement(attribute($0, kAXWindowAttribute)) } ?? element
    }

    private func liveWindowElement(for window: WarpWindow) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(window.application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        let liveWindows = (attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard !liveWindows.isEmpty else { return nil }
        if let original = window.axWindow,
           let exact = liveWindows.first(where: { CFEqual($0, original) }) {
            return exact
        }

        // AX objects can be replaced while an application moves between
        // Spaces or leaves full screen. Resolve the same WindowServer window
        // by its live frame before using weaker title/size fallbacks.
        if let expectedFrame = windowServerFrame(for: window) {
            let ranked = liveWindows
                .compactMap { element -> (AXUIElement, CGFloat)? in
                    guard let frame = frame(of: element) else { return nil }
                    return (element, frameDistance(frame, expectedFrame))
                }
                .sorted { $0.1 < $1.1 }
            if let best = ranked.first,
               best.1 <= 8,
               (ranked.count == 1 || best.1 + 1 < ranked[1].1) {
                return best.0
            }
        }

        // rawTitle == nil represents a genuinely blank AX title. Do not turn
        // it into the display fallback (the app name), which cannot match the
        // live untitled window.
        let expectedTitle = window.rawTitle ?? ""
        let titled = liveWindows.filter {
            ((attribute($0, kAXTitleAttribute) as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines) == expectedTitle
        }
        if titled.count == 1 { return titled[0] }

        // Window titles can change between hover and click (especially in
        // browsers). Size is a bounded fallback only when it identifies one
        // window unambiguously; equal-size sibling windows must never be
        // selected by array order.
        let expectedSize = window.bounds.size
        guard expectedSize.width > 0, expectedSize.height > 0 else { return nil }
        let ranked = liveWindows
            .map { ($0, sizeDistance($0, expected: expectedSize)) }
            .filter { $0.1.isFinite }
            .sorted { $0.1 < $1.1 }
        guard let best = ranked.first else { return nil }
        if ranked.count == 1 || best.1 + 1 < ranked[1].1 { return best.0 }
        return nil
    }

    private func windowServerFrame(for window: WarpWindow) -> CGRect? {
        guard let windowID = window.windowID,
              let info = (CGWindowListCopyWindowInfo(
                [.optionIncludingWindow, .excludeDesktopElements],
                windowID
              ) as? [[String: Any]])?.first,
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == window.application.processIdentifier,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = warpAXValue(attribute(element, kAXPositionAttribute)),
              let sizeValue = warpAXValue(attribute(element, kAXSizeAttribute)) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func frameDistance(_ left: CGRect, _ right: CGRect) -> CGFloat {
        abs(left.minX - right.minX) + abs(left.minY - right.minY) +
            abs(left.width - right.width) + abs(left.height - right.height)
    }

    private func sizeDistance(_ element: AXUIElement, expected: CGSize) -> CGFloat {
        guard let value = warpAXValue(attribute(element, kAXSizeAttribute)) else {
            return .greatestFiniteMagnitude
        }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return .greatestFiniteMagnitude }
        return abs(size.width - expected.width) + abs(size.height - expected.height)
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
