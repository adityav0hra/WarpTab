import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// WarpTab is a menu-bar utility by default. Opening its settings promotes it
// to a regular Dock application only for as long as that window is visible.
application.setActivationPolicy(.accessory)
// NSApplication.delegate is weak. Keep the delegate—and therefore the
// shortcut monitor and switcher controllers—alive for the entire event loop.
withExtendedLifetime(delegate) {
    application.run()
}
