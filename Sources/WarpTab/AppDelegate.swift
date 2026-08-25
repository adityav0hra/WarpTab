import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let isBackgroundLaunch = CommandLine.arguments.contains("--background")
    private let preferences = WarpPreferences()
    private let previewCache = PreviewCache()
    private lazy var store = WindowStore(preferences: preferences)
    private var configuredShortcut: SwitcherShortcut {
        let stored = SwitcherShortcut(storageValue: UserDefaults.standard.string(forKey: "customShortcut") ?? "")
        return stored.map { $0.isReserved ? .defaultShortcut : $0 } ?? .defaultShortcut
    }
    private var configuredLayout: SwitcherLayout {
        SwitcherLayout(rawValue: UserDefaults.standard.string(forKey: "switcherLayout") ?? "") ?? .list
    }
    private lazy var switcher = SwitcherPanelController(
        store: store,
        shortcut: configuredShortcut,
        layout: configuredLayout,
        previewCache: previewCache
    )
    private lazy var dockPreviews = DockPreviewController(
        store: store,
        preferences: preferences,
        previewCache: previewCache
    )
    // The global hotkey owns this callback for the full application lifetime.
    // Capture strongly so the switcher controller cannot disappear while the
    // Carbon handler remains registered.
    private lazy var monitor = ShortcutMonitor(shortcut: configuredShortcut) { event in
        self.handle(event)
    }
    private lazy var settingsWindow = SettingsWindowController(
        initiallyEnabled: UserDefaults.standard.object(forKey: "switcherEnabled") as? Bool ?? true,
        initiallySelectedShortcut: configuredShortcut,
        initiallySelectedLayout: configuredLayout,
        onEnabledChange: { [weak self] enabled in self?.setSwitcherEnabled(enabled) },
        onShortcutChange: { [weak self] shortcut in self?.setShortcut(shortcut) ?? false },
        onLayoutChange: { [weak self] layout in self?.setLayout(layout) },
        onOpenAccessibility: { [weak self] in self?.openAccessibilitySettings() },
        onOpenWindowOptions: { [weak self] in self?.showWindowOptions() },
        onClose: { [weak self] in self?.settingsDidClose() }
    )
    private lazy var windowOptions = WindowOptionsController(preferences: preferences, store: store)
    private var statusItem: NSStatusItem?
    private var shortcutMenuItem: NSMenuItem?
    private var listLayoutMenuItem: NSMenuItem?
    private var thumbnailLayoutMenuItem: NSMenuItem?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppIcon.make()
        configureMainMenu()
        configureStatusItem()
        ensureLaunchAtLoginEnabled()
        if isBackgroundLaunch {
            _ = AXIsProcessTrusted()
        } else {
            requestAccessibilityPermission()
        }
        store.start()
        dockPreviews.start()
        ensureMonitorStarted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.ensureMonitorStarted()
        }
        if !isBackgroundLaunch {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        monitor.stop()
        dockPreviews.stop()
        store.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureMonitorStarted()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    private func handle(_ event: ShortcutEvent) {
        switch event {
        case .cycle(let backwards, let scope):
            switcher.cycle(backwards: backwards, scope: scope)
        case .navigate(let direction):
            switcher.navigate(direction)
        case .searchCharacter(let character):
            switcher.appendSearchCharacter(character)
        case .deleteSearchCharacter:
            switcher.deleteSearchCharacter()
        case .action(let action):
            switcher.perform(action)
        case .commit:
            switcher.commitSelection()
        case .cancel:
            switcher.handleEscape()
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func ensureLaunchAtLoginEnabled() {
        // The explicit launch agent passes --background, which lets WarpTab
        // start without creating a window or Dock icon. The main-app login
        // item cannot pass that launch mode, so remove it to avoid duplicate
        // or visible launches at sign-in.
        let loginItem = SMAppService.mainApp
        if loginItem.status == .enabled {
            do {
                try loginItem.unregister()
            } catch {
                NSLog("WarpTab could not replace its visible login item: \(error.localizedDescription)")
            }
        }

        installLaunchAgentFallback()
    }

    private func installLaunchAgentFallback() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasPrefix("/Applications/") else { return }

        let fileManager = FileManager.default
        let launchAgents = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let agentURL = launchAgents.appendingPathComponent("com.warptab.launch-at-login.plist")
        let configuration: [String: Any] = [
            "Label": "com.warptab.launch-at-login",
            "ProgramArguments": ["/usr/bin/open", "-g", bundlePath, "--args", "--background"],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]

        do {
            try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: configuration,
                format: .xml,
                options: 0
            )
            if (try? Data(contentsOf: agentURL)) != data {
                try data.write(to: agentURL, options: .atomic)
            }
        } catch {
            NSLog("WarpTab could not install its launch-at-login fallback: \(error.localizedDescription)")
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "WarpTab")

        let menu = NSMenu()
        let title = NSMenuItem(title: "WarpTab", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Open WarpTab…", action: #selector(showSettings), keyEquivalent: ",")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        let shortcutItem = NSMenuItem(title: "Shortcut: \(configuredShortcut.displayName)", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        shortcutMenuItem = shortcutItem
        let sameAppItem = NSMenuItem(
            title: "Same app: \(SwitcherShortcut.sameApplicationShortcut.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        sameAppItem.isEnabled = false
        menu.addItem(sameAppItem)

        let viewStyleItem = NSMenuItem(title: "View Style", action: nil, keyEquivalent: "")
        let viewStyleMenu = NSMenu(title: "View Style")
        for layout in SwitcherLayout.allCases {
            let item = NSMenuItem(
                title: layout.displayName,
                action: #selector(changeLayoutFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = layout.rawValue
            item.state = layout == configuredLayout ? .on : .off
            viewStyleMenu.addItem(item)
            if layout == .list { listLayoutMenuItem = item }
            if layout == .thumbnails { thumbnailLayoutMenuItem = item }
        }
        viewStyleItem.submenu = viewStyleMenu
        menu.addItem(viewStyleItem)

        menu.addItem(.separator())
        let permissionItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit WarpTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "WarpTab")
        appMenu.addItem(withTitle: "About WarpTab", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WarpTab", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit WarpTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        NSApplication.shared.windowsMenu = windowMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    private func setSwitcherEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "switcherEnabled")
        if enabled {
            ensureMonitorStarted()
        } else {
            monitor.stop()
            settingsWindow.refreshPermissionStatus(listenerRunning: false)
        }
    }

    private func setShortcut(_ shortcut: SwitcherShortcut) -> Bool {
        guard monitor.changeShortcut(to: shortcut) else { return false }
        UserDefaults.standard.set(shortcut.storageValue, forKey: "customShortcut")
        switcher.updateShortcut(shortcut)
        shortcutMenuItem?.title = "Shortcut: \(shortcut.displayName)"
        settingsWindow.refreshPermissionStatus(listenerRunning: monitor.isRunning)
        return true
    }

    private func setLayout(_ layout: SwitcherLayout) {
        UserDefaults.standard.set(layout.rawValue, forKey: "switcherLayout")
        switcher.updateLayout(layout)
        settingsWindow.updateLayoutSelection(layout)
        listLayoutMenuItem?.state = layout == .list ? .on : .off
        thumbnailLayoutMenuItem?.state = layout == .thumbnails ? .on : .off
        if layout == .thumbnails, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    @objc private func changeLayoutFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let layout = SwitcherLayout(rawValue: rawValue) else { return }
        setLayout(layout)
    }

    private func ensureMonitorStarted() {
        let enabled = UserDefaults.standard.object(forKey: "switcherEnabled") as? Bool ?? true
        guard enabled else {
            settingsWindow.refreshPermissionStatus(listenerRunning: false)
            return
        }

        if !monitor.isRunning {
            _ = monitor.start()
        }
        settingsWindow.refreshPermissionStatus(listenerRunning: monitor.isRunning)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func showSettings() {
        NSApplication.shared.setActivationPolicy(.regular)
        settingsWindow.showWindow(nil)
        ensureMonitorStarted()
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow.window?.makeKeyAndOrderFront(nil)
    }

    private func showWindowOptions() {
        NSApplication.shared.setActivationPolicy(.regular)
        windowOptions.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        windowOptions.window?.makeKeyAndOrderFront(nil)
    }

    private func settingsDidClose() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
