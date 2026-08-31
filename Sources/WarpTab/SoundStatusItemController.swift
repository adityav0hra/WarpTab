import AppKit
import SwiftUI

@MainActor
final class SoundStatusItemController: NSObject {
    private let soundManager = SoundManager()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var systemControlAnchorWindow: NSWindow?
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var previewWindow: NSWindow?
    private let onOpenSettings: () -> Void
    private let onDismiss: () -> Void

    init(
        showMenuBarItem: Bool = true,
        animationsEnabled: Bool = false,
        onOpenSettings: @escaping () -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.onOpenSettings = onOpenSettings
        self.onDismiss = onDismiss
        super.init()

        popover.behavior = .transient
        popover.animates = animationsEnabled
        popover.delegate = self
        popover.contentSize = NSSize(width: 330, height: 158)
        popover.contentViewController = NSHostingController(
            rootView: NativeSoundMenuView(onOpenSettings: onOpenSettings).environmentObject(soundManager)
        )

        if showMenuBarItem {
            installMenuBarItem()
        }
    }

    private func installMenuBarItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            let symbol = NSImage(
                systemSymbolName: "speaker.wave.2",
                accessibilityDescription: "Sound Mixer"
            )
            button.image = symbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .light)
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Sound Mixer"
        }
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        if visible {
            installMenuBarItem()
        } else {
            removeFromMenuBar()
        }
    }

    func setAnimationsEnabled(_ enabled: Bool) {
        popover.animates = enabled
    }

    func removeFromMenuBar() {
        popover.performClose(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            soundManager.setInterfaceVisible(true)
            updatePopoverSize()
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            startOutsideClickMonitoring()
        }
    }

    func showPopover() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        showPopover(relativeTo: button)
    }

    func showFromSystemControl() {
        if let button = statusItem?.button {
            showPopover(relativeTo: button)
            return
        }

        guard !popover.isShown else { return }
        soundManager.setInterfaceVisible(true)
        updatePopoverSize()

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let anchorX = min(max(mouseLocation.x, visibleFrame.minX + 180), visibleFrame.maxX - 20)
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: anchorX, y: visibleFrame.maxY - 1, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        anchorWindow.contentView = anchorView
        anchorWindow.backgroundColor = .clear
        anchorWindow.isOpaque = false
        anchorWindow.hasShadow = false
        anchorWindow.ignoresMouseEvents = true
        anchorWindow.level = .statusBar
        anchorWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        anchorWindow.isReleasedWhenClosed = false
        systemControlAnchorWindow = anchorWindow
        anchorWindow.orderFrontRegardless()

        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startOutsideClickMonitoring()
    }

    func showPopover(relativeTo anchorView: NSView) {
        guard !popover.isShown else { return }
        soundManager.setInterfaceVisible(true)
        updatePopoverSize()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startOutsideClickMonitoring()
    }

    func showPreviewWindow() {
        soundManager.setInterfaceVisible(true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: NativeSoundMenuView(onOpenSettings: onOpenSettings).environmentObject(soundManager)
        )
        window.center()
        previewWindow = window
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func updatePopoverSize() {
        let showOnlyPlaying = UserDefaults.standard.object(forKey: "soundShowOnlyPlayingApps") as? Bool ?? true
        let count = soundManager.apps.filter {
            (!showOnlyPlaying || $0.isProducingAudio) && !soundManager.preference(for: $0).isHidden
        }.count
        let height = count == 0 ? 158 : min(132 + CGFloat(count) * 58, 364)
        popover.contentSize = NSSize(width: 330, height: height)
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.performClose(nil)
            }
        }

        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            let mixerWindow = self.popover.contentViewController?.view.window
            let statusItemWindow = self.statusItem?.button?.window
            if event.window !== mixerWindow && event.window !== statusItemWindow {
                self.popover.performClose(nil)
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
    }
}

extension SoundStatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        soundManager.setInterfaceVisible(false)
        stopOutsideClickMonitoring()
        systemControlAnchorWindow?.orderOut(nil)
        systemControlAnchorWindow = nil
        onDismiss()
    }
}
