import AppKit
import ApplicationServices
import CoreGraphics

struct WarpWindow {
    let identity: String
    let application: NSRunningApplication
    let axWindow: AXUIElement?
    let axTab: AXUIElement?
    let title: String
    let rawTitle: String?
    let appName: String
    let bundleIdentifier: String?
    let icon: NSImage
    let windowID: CGWindowID?
    let bounds: CGRect
    let screenIdentifier: String?
    let isFocused: Bool
    let isMinimized: Bool
    let isHidden: Bool
    let isFullscreen: Bool
    let isOnScreen: Bool
    let isWindowlessApplication: Bool
    let nativeTabCount: Int
    let lastFocusedAt: Date?
}

struct DisplaySnapshot: Equatable {
    let identifier: String
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat

    static func current() -> [DisplaySnapshot] {
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return DisplaySnapshot(
                identifier: number?.stringValue ?? NSStringFromRect(screen.frame),
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                scale: screen.backingScaleFactor
            )
        }
    }
}

extension NSScreen {
    static var warpHardwareMain: NSScreen? {
        let mainDisplayIdentifier = CGMainDisplayID()
        return screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == mainDisplayIdentifier
        } ?? screens.first
    }

    var warpIdentifier: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? NSStringFromRect(frame)
    }
}
