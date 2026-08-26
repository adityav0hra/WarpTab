import AppKit
import ApplicationServices

final class DockAppShortcutController {
    private struct Target {
        let bundleIdentifier: String?
        let applicationURL: URL
    }

    func openApp(at index: Int) {
        guard let target = dockTargets().dropFirst(index).first else { return }

        if let bundleIdentifier = target.bundleIdentifier,
           let application = NSRunningApplication.runningApplications(
               withBundleIdentifier: bundleIdentifier
           ).first {
            revealAllWindows(of: application)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: target.applicationURL,
            configuration: configuration
        ) { [weak self] application, error in
            if let error {
                NSLog("WarpTab could not open Dock app: \(error.localizedDescription)")
                return
            }
            if let application {
                DispatchQueue.main.async { [weak self] in self?.revealAllWindows(of: application) }
            }
        }
    }

    private func dockTargets() -> [Target] {
        var targets: [Target] = []
        if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            targets.append(Target(bundleIdentifier: "com.apple.finder", applicationURL: finderURL))
        }

        guard let entries = CFPreferencesCopyAppValue(
            "persistent-apps" as CFString,
            "com.apple.dock" as CFString
        ) as? [[String: Any]] else { return targets }

        for entry in entries {
            guard let tileData = entry["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String,
                  let storedURL = URL(string: urlString),
                  storedURL.pathExtension == "app" else { continue }
            let bundleIdentifier = tileData["bundle-identifier"] as? String
            let currentURL = bundleIdentifier.flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            } ?? storedURL
            targets.append(Target(
                bundleIdentifier: bundleIdentifier,
                applicationURL: currentURL
            ))
        }
        return targets
    }

    private func revealAllWindows(of application: NSRunningApplication) {
        application.unhide()

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        restoreAndRaiseWindows(of: appElement)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        // Unhiding and moving between Spaces settle asynchronously. Reapply the
        // all-window restore so minimized windows do not get left behind.
        for delay in [0.08, 0.25, 0.60] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak application] in
                guard let self, let application, !application.isTerminated else { return }
                application.unhide()
                let element = AXUIElementCreateApplication(application.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 1.0)
                self.restoreAndRaiseWindows(of: element)
                application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }
    }

    private func restoreAndRaiseWindows(of applicationElement: AXUIElement) {
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
        let windows = rawWindows as? [AXUIElement] else { return }

        for window in windows {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }
}
