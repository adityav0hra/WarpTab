import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement

private let soundMixerDarwinNotificationName = CFNotificationName(
    "com.warptab.openSoundMixer" as CFString
)

private func handleSoundMixerDarwinNotification(
    center: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    name: CFNotificationName?,
    object: UnsafeRawPointer?,
    userInfo: CFDictionary?
) {
    guard let observer else { return }
    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async {
        appDelegate.openSoundMixerFromSystemControl()
    }
}

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
    private lazy var windowsBehaviors = WindowsBehaviorController(
        preferences: preferences,
        store: store,
        previewCache: previewCache
    )
    private let awakeController = AwakeController()
    private var awakeFeatureEnabled = UserDefaults.standard.object(forKey: "stayAwakeFeatureEnabled") as? Bool ?? true
    private var showsAwakeInWarpTabMenu = UserDefaults.standard.object(forKey: "showAwakeInWarpTabMenu") as? Bool ?? true
    private var showsViewStyleInWarpTabMenu = UserDefaults.standard.object(forKey: "showViewStyleInWarpTabMenu") as? Bool ?? true
    private var showsClipboardInWarpTabMenu = UserDefaults.standard.object(forKey: "showClipboardInWarpTabMenu") as? Bool ?? true
    private var showsClipboardStatusItem: Bool {
        UserDefaults.standard.bool(forKey: "showClipboardStatusItem")
    }
    private var showsSoundStatusItem: Bool {
        UserDefaults.standard.object(forKey: "showSoundStatusItem") as? Bool ?? true
    }
    // The global hotkey owns this callback for the full application lifetime.
    // Capture strongly so the switcher controller cannot disappear while the
    // Carbon handler remains registered.
    private lazy var monitor = ShortcutMonitor(shortcut: configuredShortcut) { event in
        self.handle(event)
    }
    private lazy var settingsWindow = SystemSettingsWindowController(
        preferences: preferences,
        store: store,
        initiallyEnabled: UserDefaults.standard.object(forKey: "switcherEnabled") as? Bool ?? true,
        initiallySelectedShortcut: configuredShortcut,
        initiallySelectedLayout: configuredLayout,
        initiallyEnablesStayAwake: awakeFeatureEnabled,
        initiallyShowsAwakeInWarpTabMenu: showsAwakeInWarpTabMenu,
        initiallyShowsViewStyleInWarpTabMenu: showsViewStyleInWarpTabMenu,
        initiallyShowsClipboardInWarpTabMenu: showsClipboardInWarpTabMenu,
        initiallyShowsClipboardStatusItem: showsClipboardStatusItem,
        initiallyShowsAwakeStatusItem: UserDefaults.standard.bool(forKey: "showAwakeStatusItem"),
        initiallyShowsSoundStatusItem: UserDefaults.standard.object(forKey: "showSoundStatusItem") as? Bool ?? true,
        onEnabledChange: { [weak self] enabled in self?.setSwitcherEnabled(enabled) },
        onShortcutChange: { [weak self] shortcut in self?.setShortcut(shortcut) ?? false },
        onLayoutChange: { [weak self] layout in self?.setLayout(layout) },
        onStayAwakeEnabledChange: { [weak self] enabled in self?.setStayAwakeFeatureEnabled(enabled) },
        onShowAwakeInWarpTabMenuChange: { [weak self] visible in self?.setAwakeMenuItemVisible(visible) },
        onShowViewStyleInWarpTabMenuChange: { [weak self] visible in self?.setViewStyleMenuItemVisible(visible) },
        onShowClipboardInWarpTabMenuChange: { [weak self] visible in self?.setClipboardMenuItemVisible(visible) },
        onShowClipboardStatusItemChange: { [weak self] visible in self?.setClipboardStatusItemVisible(visible) },
        onShowAwakeStatusItemChange: { [weak self] visible in self?.setAwakeStatusItemVisible(visible) },
        onShowSoundStatusItemChange: { [weak self] visible in
            Task { @MainActor in self?.setSoundStatusItemVisible(visible) }
        },
        onClearClipboard: { [weak self] in self?.windowsBehaviors.clearClipboard() },
        onOpenAccessibility: { [weak self] in self?.openAccessibilitySettings() },
        onClose: { [weak self] in self?.settingsDidClose() }
    )
    private var statusItem: NSStatusItem?
    private var awakeStatusItem: NSStatusItem?
    private var clipboardStatusItem: NSStatusItem?
    private var soundStatusItemController: SoundStatusItemController?
    private var listLayoutMenuItem: NSMenuItem?
    private var thumbnailLayoutMenuItem: NSMenuItem?
    private var awakeMenuItem: NSMenuItem?
    private var clipboardMenuItem: NSMenuItem?
    private var viewStyleMenuItem: NSMenuItem?
    private var viewStyleSeparatorMenuItem: NSMenuItem?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppIcon.make()
        configureMainMenu()
        configureStatusItem()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            handleSoundMixerDarwinNotification,
            soundMixerDarwinNotificationName.rawValue,
            nil,
            .deliverImmediately
        )
        updateClipboardStatusItemPresence()
        updateSoundStatusItemPresence()
        if CommandLine.arguments.contains("--show-sound-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.soundStatusItemController?.showPreviewWindow()
            }
        }
        ensureLaunchAtLoginEnabled()
        if isBackgroundLaunch {
            _ = AXIsProcessTrusted()
        } else {
            requestAccessibilityPermission()
        }
        store.start()
        dockPreviews.start()
        windowsBehaviors.start()
        ensureMonitorStarted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.ensureMonitorStarted()
        }
        if !isBackgroundLaunch {
            showSettings()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sender.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit WarpTab?"
        alert.informativeText = "Window switching and enabled background features will stop until you open WarpTab again."
        alert.addButton(withTitle: "Cancel")
        let quitButton = alert.addButton(withTitle: "Quit WarpTab")
        quitButton.hasDestructiveAction = true

        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            soundMixerDarwinNotificationName,
            nil
        )
        permissionTimer?.invalidate()
        awakeController.stop()
        monitor.stop()
        dockPreviews.stop()
        windowsBehaviors.stop()
        store.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureMonitorStarted()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "warptab" && $0.host == "sound-mixer" }) else { return }
        showSoundSettings()
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
        let symbol = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "WarpTab")
        item.button?.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .light)
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let title = NSMenuItem(title: "WarpTab", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Open WarpTab…", action: #selector(showSettings), keyEquivalent: ",")
        showItem.target = self
        menu.addItem(showItem)

        let clipboardItem = NSMenuItem(
            title: "Clipboard History…",
            action: #selector(showClipboardHistory),
            keyEquivalent: "v"
        )
        clipboardItem.keyEquivalentModifierMask = [.option]
        clipboardItem.target = self
        clipboardItem.isHidden = !showsClipboardInWarpTabMenu
        menu.addItem(clipboardItem)
        clipboardMenuItem = clipboardItem

        let awakeItem = NSMenuItem(
            title: "Keep Mac Awake",
            action: #selector(toggleStayAwake),
            keyEquivalent: ""
        )
        awakeItem.target = self
        menu.addItem(awakeItem)
        awakeMenuItem = awakeItem
        awakeItem.isHidden = !awakeFeatureEnabled || !showsAwakeInWarpTabMenu

        let viewStyleSeparator = NSMenuItem.separator()
        viewStyleSeparator.isHidden = !showsViewStyleInWarpTabMenu
        menu.addItem(viewStyleSeparator)
        viewStyleSeparatorMenuItem = viewStyleSeparator

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
        viewStyleItem.isHidden = !showsViewStyleInWarpTabMenu
        menu.addItem(viewStyleItem)
        self.viewStyleMenuItem = viewStyleItem

        item.menu = menu
        statusItem = item
        updateAwakeStatusItemPresence()
    }

    @objc private func toggleStayAwake() {
        guard awakeFeatureEnabled else { return }
        awakeController.toggle()
        updateAwakeUI()
    }

    private func setStayAwakeFeatureEnabled(_ enabled: Bool) {
        awakeFeatureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "stayAwakeFeatureEnabled")
        awakeMenuItem?.isHidden = !enabled || !showsAwakeInWarpTabMenu

        if !enabled {
            awakeController.stop()
            updateAwakeUI()
        }
        updateAwakeStatusItemPresence()
    }

    private func setAwakeMenuItemVisible(_ visible: Bool) {
        showsAwakeInWarpTabMenu = visible
        UserDefaults.standard.set(visible, forKey: "showAwakeInWarpTabMenu")
        awakeMenuItem?.isHidden = !awakeFeatureEnabled || !visible
    }

    private func setAwakeStatusItemVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "showAwakeStatusItem")
        updateAwakeStatusItemPresence()
    }

    private func setClipboardMenuItemVisible(_ visible: Bool) {
        showsClipboardInWarpTabMenu = visible
        UserDefaults.standard.set(visible, forKey: "showClipboardInWarpTabMenu")
        clipboardMenuItem?.isHidden = !visible
    }

    private func setClipboardStatusItemVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "showClipboardStatusItem")
        updateClipboardStatusItemPresence()
    }

    private func updateClipboardStatusItemPresence() {
        if showsClipboardStatusItem {
            guard clipboardStatusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = NSImage(
                    systemSymbolName: "doc.on.clipboard",
                    accessibilityDescription: "Clipboard History"
                )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .light))
                button.image?.isTemplate = true
                button.target = self
                button.action = #selector(showClipboardHistory)
                button.toolTip = "Clipboard History"
            }
            clipboardStatusItem = item
        } else if let item = clipboardStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            clipboardStatusItem = nil
        }
    }

    @MainActor
    private func setSoundStatusItemVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "showSoundStatusItem")
        updateSoundStatusItemPresence()
    }

    @MainActor
    private func updateSoundStatusItemPresence() {
        if soundStatusItemController == nil {
            soundStatusItemController = SoundStatusItemController(
                showMenuBarItem: showsSoundStatusItem
            ) { [weak self] in
                self?.showSoundSettings()
            }
        } else {
            soundStatusItemController?.setMenuBarItemVisible(showsSoundStatusItem)
        }
    }

    private func updateAwakeStatusItemPresence() {
        let visible = awakeFeatureEnabled && UserDefaults.standard.bool(forKey: "showAwakeStatusItem")

        if visible {
            guard awakeStatusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(toggleStayAwake)
            awakeStatusItem = item
            updateAwakeUI()
        } else if let item = awakeStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            awakeStatusItem = nil
        }
    }

    private func updateAwakeUI() {
        awakeMenuItem?.state = awakeController.isEnabled ? .on : .off
        awakeMenuItem?.title = awakeController.isEnabled ? "Mac Stays Awake" : "Keep Mac Awake"

        if let button = awakeStatusItem?.button {
            let description = awakeController.isEnabled ? "Stay Awake On — Mac Stays Awake" : "Stay Awake Off"
            button.image = NSImage(
                systemSymbolName: awakeController.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer",
                accessibilityDescription: description
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .light))
            button.image?.isTemplate = true
            button.toolTip = awakeController.isEnabled
                ? "Stay Awake On — click to allow sleep"
                : "Stay Awake Off — click to keep Mac awake"
        }
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

    private func setViewStyleMenuItemVisible(_ visible: Bool) {
        showsViewStyleInWarpTabMenu = visible
        UserDefaults.standard.set(visible, forKey: "showViewStyleInWarpTabMenu")
        viewStyleMenuItem?.isHidden = !visible
        viewStyleSeparatorMenuItem?.isHidden = !visible
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

    private func showSoundSettings() {
        NSApplication.shared.setActivationPolicy(.regular)
        settingsWindow.showSoundSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow.window?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    fileprivate func openSoundMixerFromSystemControl() {
        if settingsWindow.window?.isVisible == true {
            settingsWindow.close()
        }

        if dismissControlCenterIfOpen() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.soundStatusItemController?.showFromSystemControl()
            }
        } else {
            soundStatusItemController?.showFromSystemControl()
        }
    }

    private func dismissControlCenterIfOpen() -> Bool {
        guard let controlCenter = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.controlcenter"
        ).first else { return false }

        let applicationElement = AXUIElementCreateApplication(controlCenter.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement],
        !windows.isEmpty else { return false }

        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        return true
    }

    @objc private func showClipboardHistory() {
        windowsBehaviors.showClipboardHistory()
    }

    private func settingsDidClose() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
