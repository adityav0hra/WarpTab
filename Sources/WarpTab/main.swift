import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
// NSApplication.delegate is weak. Keep the delegate—and therefore the
// shortcut monitor and switcher controllers—alive for the entire event loop.
withExtendedLifetime(delegate) {
    application.run()
}
