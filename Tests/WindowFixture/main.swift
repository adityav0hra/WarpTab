import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var livePreviewObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--aspect-previews") {
            let portrait = makeWindow(title: "WarpTab Portrait Preview", origin: NSPoint(x: 120, y: 180))
            portrait.setContentSize(NSSize(width: 260, height: 620))
            portrait.tabbingMode = .disallowed
            let wide = makeWindow(title: "WarpTab Wide Preview", origin: NSPoint(x: 420, y: 420))
            wide.setContentSize(NSSize(width: 900, height: 200))
            wide.tabbingMode = .disallowed
            windows = [portrait, wide]
            portrait.orderFront(nil)
            wide.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        if CommandLine.arguments.contains("--live-preview") {
            let window = makeWindow(title: "WarpTab Live Preview", origin: NSPoint(x: 220, y: 420))
            window.tabbingMode = .disallowed
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.systemRed.cgColor
            windows = [window]
            livePreviewObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.warptab.fixture.update-preview"),
                object: nil,
                queue: .main
            ) { [weak window] _ in
                window?.contentView?.layer?.backgroundColor = NSColor.systemGreen.cgColor
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        if CommandLine.arguments.contains("--single-window") {
            let window = makeWindow(title: "WarpTab Single Window", origin: NSPoint(x: 220, y: 420))
            window.tabbingMode = .disallowed
            windows = [window]
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        if let stressIndex = CommandLine.arguments.firstIndex(of: "--stress"),
           CommandLine.arguments.indices.contains(stressIndex + 1),
           let count = Int(CommandLine.arguments[stressIndex + 1]), count > 0 {
            windows = (1...count).map { index in
                let column = CGFloat(index % 8)
                let row = CGFloat((index / 8) % 6)
                let window = makeWindow(
                    title: String(format: "WarpTab Stress %03d", index),
                    origin: NSPoint(x: 60 + column * 34, y: 620 - row * 28)
                )
                window.tabbingMode = .disallowed
                window.orderFront(nil)
                return window
            }
            windows.last?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let alpha = makeWindow(title: "WarpTab Test — Alpha", origin: NSPoint(x: 100, y: 500))
        let beta = makeWindow(title: "WarpTab Test — Beta", origin: NSPoint(x: 250, y: 350))
        alpha.tabbingMode = .disallowed
        beta.tabbingMode = .disallowed

        let firstTab = makeWindow(title: "WarpTab Native Tab — One", origin: NSPoint(x: 400, y: 250))
        let secondTab = makeWindow(title: "WarpTab Native Tab — Two", origin: NSPoint(x: 400, y: 250))
        firstTab.tabbingMode = .preferred
        secondTab.tabbingMode = .preferred
        firstTab.addTabbedWindow(secondTab, ordered: .above)

        windows = [alpha, beta, firstTab, secondTab]
        alpha.orderFront(nil)
        beta.orderFront(nil)
        firstTab.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func makeWindow(title: String, origin: NSPoint) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: 620, height: 400)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        window.contentView = content
        return window
    }
}

let application = NSApplication.shared
let delegate = FixtureDelegate()
application.delegate = delegate
application.run()
