import AppKit
import SwiftUI

if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-sound-preview"),
   CommandLine.arguments.indices.contains(flagIndex + 1) {
    MainActor.assumeIsolated {
        let outputPath = CommandLine.arguments[flagIndex + 1]
        let manager = SoundManager()
        let hostingView = NSHostingView(
            rootView: NativeSoundMenuView(onOpenSettings: {})
                .environmentObject(manager)
                .preferredColorScheme(.dark)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: 330, height: max(fittingSize.height, 180)))
        hostingView.layoutSubtreeIfNeeded()
        if let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: outputPath))
            }
        }
    }
    exit(EXIT_SUCCESS)
}

MainActor.assumeIsolated {
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
}
