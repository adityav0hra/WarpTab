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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let isBackgroundLaunch = CommandLine.arguments.contains("--background")
    private let preferences = WarpPreferences()
    private let mouseSettings = MouseSettings()
    private lazy var mouseEventManager = MouseEventManager(settings: mouseSettings)
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
        previewCache: previewCache,
        preferences: preferences
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
    private lazy var screenTools = ScreenToolsController(preferences: preferences)
    private let awakeController = AwakeController()
    private var awakeFeatureEnabled = UserDefaults.standard.object(forKey: "stayAwakeFeatureEnabled") as? Bool ?? false
    private var showsAwakeInWarpTabMenu = UserDefaults.standard.object(forKey: "showAwakeInWarpTabMenu") as? Bool ?? false
    private var showsViewStyleInWarpTabMenu = UserDefaults.standard.object(forKey: "showViewStyleInWarpTabMenu") as? Bool ?? false
    private var showsClipboardInWarpTabMenu = UserDefaults.standard.object(forKey: "showClipboardInWarpTabMenu") as? Bool ?? false
    private var showsScreenTextInWarpTabMenu = UserDefaults.standard.object(forKey: "showScreenTextInWarpTabMenu") as? Bool ?? false
    private var showsColorPickerInWarpTabMenu = UserDefaults.standard.object(forKey: "showColorPickerInWarpTabMenu") as? Bool ?? false
    private var showsWarpTabStatusItem = UserDefaults.standard.object(forKey: "showWarpTabStatusItem") as? Bool ?? true
    private var showsClipboardStatusItem: Bool {
        UserDefaults.standard.bool(forKey: "showClipboardStatusItem")
    }
    private var showsSoundStatusItem: Bool {
        UserDefaults.standard.object(forKey: "showSoundStatusItem") as? Bool ?? false
    }
    // The global hotkey owns this callback for the full application lifetime.
    // Capture strongly so the switcher controller cannot disappear while the
    // Carbon handler remains registered.
    private lazy var monitor = ShortcutMonitor(shortcut: configuredShortcut) { event in
        self.handle(event)
    }
    private var settingsWindow: SystemSettingsWindowController?
    private var statusItem: NSStatusItem?
    private var awakeStatusItem: NSStatusItem?
    private var clipboardStatusItem: NSStatusItem?
    private var soundStatusItemController: SoundStatusItemController?
    private var listLayoutMenuItem: NSMenuItem?
    private var thumbnailLayoutMenuItem: NSMenuItem?
    private var awakeMenuItem: NSMenuItem?
    private var clipboardMenuItem: NSMenuItem?
    private var screenTextMenuItem: NSMenuItem?
    private var colorPickerMenuItem: NSMenuItem?
    private var viewStyleMenuItem: NSMenuItem?
    private var viewStyleSeparatorMenuItem: NSMenuItem?
    private var permissionTimer: Timer?
    private var windowStoreRunning = false
    private var dockPreviewsRunning = false
    private var windowsBehaviorsRunning = false
    private var mouseMonitorRunning = false
    private var screenToolsRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppIcon.make()
        preferences.onFeatureChange = { [weak self] in
            Task { @MainActor in self?.refreshFeatureLifecycles(requestPermission: true) }
        }
        mouseSettings.onEnabledChange = { [weak self] _ in
            Task { @MainActor in self?.refreshFeatureLifecycles() }
        }
        configureMainMenu()
        if showsWarpTabStatusItem { configureStatusItem() }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            handleSoundMixerDarwinNotification,
            soundMixerDarwinNotificationName.rawValue,
            nil,
            .deliverImmediately
        )
        updateClipboardStatusItemPresence()
        if showsSoundStatusItem { updateSoundStatusItemPresence() }
        if CommandLine.arguments.contains("--show-sound-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.soundController(createIfNeeded: true)?.showPreviewWindow()
            }
        }
        ensureLaunchAtLoginEnabled()
        refreshFeatureLifecycles(requestPermission: !isBackgroundLaunch)
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
        if monitor.isRunning { monitor.stop() }
        if mouseMonitorRunning { mouseEventManager.stop() }
        if dockPreviewsRunning { dockPreviews.stop() }
        if windowsBehaviorsRunning { windowsBehaviors.stop() }
        if screenToolsRunning { screenTools.stop() }
        if windowStoreRunning { store.stop() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshFeatureLifecycles()
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
            guard isSwitcherEnabled else { return }
            switcher.cycle(backwards: backwards, scope: scope)
        case .navigate(let direction):
            guard isSwitcherEnabled else { return }
            switcher.navigate(direction)
        case .searchCharacter(let character):
            guard isSwitcherEnabled else { return }
            switcher.appendSearchCharacter(character)
        case .deleteSearchCharacter:
            guard isSwitcherEnabled else { return }
            switcher.deleteSearchCharacter()
        case .action(let action):
            guard isSwitcherEnabled else { return }
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
        guard statusItem == nil else { return }
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

        let screenTextItem = NSMenuItem(
            title: "Copy Text from Screen",
            action: #selector(copyTextFromScreenFromMenu),
            keyEquivalent: ""
        )
        screenTextItem.target = self
        screenTextItem.isHidden = !showsScreenTextInWarpTabMenu
        menu.addItem(screenTextItem)
        screenTextMenuItem = screenTextItem

        let colorPickerItem = NSMenuItem(
            title: "Pick Color from Screen",
            action: #selector(pickColorFromScreenFromMenu),
            keyEquivalent: ""
        )
        colorPickerItem.target = self
        colorPickerItem.isHidden = !showsColorPickerInWarpTabMenu
        menu.addItem(colorPickerItem)
        colorPickerMenuItem = colorPickerItem

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

    private func setScreenTextMenuItemVisible(_ visible: Bool) {
        showsScreenTextInWarpTabMenu = visible
        UserDefaults.standard.set(visible, forKey: "showScreenTextInWarpTabMenu")
        screenTextMenuItem?.isHidden = !visible
    }

    private func setColorPickerMenuItemVisible(_ visible: Bool) {
        showsColorPickerInWarpTabMenu = visible
        UserDefaults.standard.set(visible, forKey: "showColorPickerInWarpTabMenu")
        colorPickerMenuItem?.isHidden = !visible
    }

    private func setWarpTabStatusItemVisible(_ visible: Bool) {
        showsWarpTabStatusItem = visible
        UserDefaults.standard.set(visible, forKey: "showWarpTabStatusItem")
        if visible {
            configureStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            clipboardMenuItem = nil
            screenTextMenuItem = nil
            colorPickerMenuItem = nil
            awakeMenuItem = nil
            viewStyleMenuItem = nil
            viewStyleSeparatorMenuItem = nil
            listLayoutMenuItem = nil
            thumbnailLayoutMenuItem = nil
        }
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
        if showsSoundStatusItem {
            soundController(createIfNeeded: true)?.setMenuBarItemVisible(true)
        } else {
            soundStatusItemController?.removeFromMenuBar()
            soundStatusItemController = nil
        }
    }

    @MainActor
    private func soundController(createIfNeeded: Bool) -> SoundStatusItemController? {
        if soundStatusItemController == nil, createIfNeeded {
            soundStatusItemController = SoundStatusItemController(
                showMenuBarItem: showsSoundStatusItem,
                animationsEnabled: preferences.animationsEnabled,
                onOpenSettings: { [weak self] in self?.showSoundSettings() },
                onDismiss: { [weak self] in
                    guard let self, !showsSoundStatusItem else { return }
                    soundStatusItemController = nil
                }
            )
        }
        return soundStatusItemController
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
        refreshFeatureLifecycles(requestPermission: enabled)
    }

    private func setShortcut(_ shortcut: SwitcherShortcut) -> Bool {
        guard monitor.changeShortcut(to: shortcut) else { return false }
        UserDefaults.standard.set(shortcut.storageValue, forKey: "customShortcut")
        switcher.updateShortcut(shortcut)
        settingsWindow?.refreshPermissionStatus(listenerRunning: monitor.isRunning)
        return true
    }

    private func setLayout(_ layout: SwitcherLayout) {
        UserDefaults.standard.set(layout.rawValue, forKey: "switcherLayout")
        switcher.updateLayout(layout)
        settingsWindow?.updateLayoutSelection(layout)
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
        let enabled = UserDefaults.standard.object(forKey: "switcherEnabled") as? Bool ?? false
        guard enabled else {
            if monitor.isRunning { monitor.stop() }
            settingsWindow?.refreshPermissionStatus(listenerRunning: false)
            return
        }

        if !monitor.isRunning {
            _ = monitor.start()
        }
        settingsWindow?.refreshPermissionStatus(listenerRunning: monitor.isRunning)
    }

    private var isSwitcherEnabled: Bool {
        UserDefaults.standard.object(forKey: "switcherEnabled") as? Bool ?? false
    }

    private var needsWindowsBehaviorTap: Bool {
        preferences.dockAppShortcutsEnabled ||
            preferences.finderCutPasteEnabled ||
            preferences.finderF2RenameEnabled ||
            preferences.clipboardHistoryEnabled ||
            preferences.clearClipboardOnSleep ||
            preferences.repeatKeysOnHold ||
            preferences.controlAccentChooserEnabled ||
            preferences.greenButtonMaximizes ||
            preferences.quitOnLastWindowClose ||
            preferences.commandMMinimizesAllWindows ||
            preferences.windowSnappingEnabled
    }

    private var hasScreenToolShortcut: Bool {
        preferences.screenTextCaptureShortcutStorageValue != nil ||
            preferences.screenColorPickerShortcutStorageValue != nil
    }

    private func refreshFeatureLifecycles(requestPermission: Bool = false) {
        let switcherEnabled = isSwitcherEnabled
        let dockEnabled = preferences.dockPreviewsEnabled
        let behaviorsEnabled = needsWindowsBehaviorTap
        let mouseEnabled = mouseSettings.isEnabled
        let needsAccessibility = switcherEnabled || dockEnabled || behaviorsEnabled || mouseEnabled
        let trusted = AXIsProcessTrusted()

        if switcherEnabled { switcher.updateAnimationsEnabled(preferences.animationsEnabled) }
        if dockEnabled { dockPreviews.updateAnimationsEnabled(preferences.animationsEnabled) }
        soundStatusItemController?.setAnimationsEnabled(preferences.animationsEnabled)

        if hasScreenToolShortcut {
            if !screenToolsRunning {
                screenTools.start()
                screenToolsRunning = true
            }
        } else if screenToolsRunning {
            screenTools.stop()
            screenToolsRunning = false
        }

        guard trusted || !needsAccessibility else {
            stopAccessibilityFeatures()
            if requestPermission { requestAccessibilityPermission() }
            schedulePermissionRetry()
            settingsWindow?.refreshPermissionStatus(listenerRunning: false)
            return
        }

        let needsStore = switcherEnabled || dockEnabled || preferences.windowSnappingEnabled
        if needsStore, !windowStoreRunning {
            store.start()
            windowStoreRunning = true
        } else if !needsStore, windowStoreRunning {
            store.stop()
            windowStoreRunning = false
        }

        if switcherEnabled {
            ensureMonitorStarted()
        } else if monitor.isRunning {
            monitor.stop()
            switcher.cancel()
        }

        if dockEnabled, !dockPreviewsRunning {
            dockPreviews.start()
            dockPreviewsRunning = true
        } else if !dockEnabled, dockPreviewsRunning {
            dockPreviews.stop()
            dockPreviewsRunning = false
        }

        if behaviorsEnabled {
            if !windowsBehaviorsRunning || !windowsBehaviors.isRunning {
                windowsBehaviors.start()
                windowsBehaviorsRunning = true
            }
        } else if windowsBehaviorsRunning {
            windowsBehaviors.stop()
            windowsBehaviorsRunning = false
        }

        if mouseEnabled {
            if !mouseEventManager.isRunning {
                mouseMonitorRunning = mouseEventManager.start()
            } else {
                mouseMonitorRunning = true
            }
        } else if mouseMonitorRunning {
            mouseEventManager.stop()
            mouseMonitorRunning = false
        }

        let needsRetry = needsAccessibility && (
            (switcherEnabled && !monitor.isRunning) ||
                (behaviorsEnabled && !windowsBehaviors.isRunning) ||
                (mouseEnabled && !mouseEventManager.isRunning)
        )
        if needsRetry { schedulePermissionRetry() } else { stopPermissionRetry() }
        settingsWindow?.refreshPermissionStatus(listenerRunning: monitor.isRunning)
    }

    private func stopAccessibilityFeatures() {
        if monitor.isRunning { monitor.stop() }
        if mouseMonitorRunning {
            mouseEventManager.stop()
            mouseMonitorRunning = false
        }
        if dockPreviewsRunning {
            dockPreviews.stop()
            dockPreviewsRunning = false
        }
        if windowsBehaviorsRunning {
            windowsBehaviors.stop()
            windowsBehaviorsRunning = false
        }
        if windowStoreRunning {
            store.stop()
            windowStoreRunning = false
        }
    }

    private func schedulePermissionRetry() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFeatureLifecycles() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func stopPermissionRetry() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func makeSettingsWindow() -> SystemSettingsWindowController {
        if let settingsWindow { return settingsWindow }
        let controller = SystemSettingsWindowController(
            preferences: preferences,
            store: store,
            screenTools: screenTools,
            mouseSettings: mouseSettings,
            mouseEventManager: mouseEventManager,
            initiallyEnabled: isSwitcherEnabled,
            initiallySelectedShortcut: configuredShortcut,
            initiallySelectedLayout: configuredLayout,
            initiallyEnablesStayAwake: awakeFeatureEnabled,
            initiallyShowsAwakeInWarpTabMenu: showsAwakeInWarpTabMenu,
            initiallyShowsViewStyleInWarpTabMenu: showsViewStyleInWarpTabMenu,
            initiallyShowsClipboardInWarpTabMenu: showsClipboardInWarpTabMenu,
            initiallyShowsScreenTextInWarpTabMenu: showsScreenTextInWarpTabMenu,
            initiallyShowsColorPickerInWarpTabMenu: showsColorPickerInWarpTabMenu,
            initiallyShowsWarpTabStatusItem: showsWarpTabStatusItem,
            initiallyShowsClipboardStatusItem: showsClipboardStatusItem,
            initiallyShowsAwakeStatusItem: UserDefaults.standard.bool(forKey: "showAwakeStatusItem"),
            initiallyShowsSoundStatusItem: showsSoundStatusItem,
            onEnabledChange: { [weak self] enabled in self?.setSwitcherEnabled(enabled) },
            onShortcutChange: { [weak self] shortcut in self?.setShortcut(shortcut) ?? false },
            onLayoutChange: { [weak self] layout in self?.setLayout(layout) },
            onStayAwakeEnabledChange: { [weak self] enabled in self?.setStayAwakeFeatureEnabled(enabled) },
            onShowAwakeInWarpTabMenuChange: { [weak self] visible in self?.setAwakeMenuItemVisible(visible) },
            onShowViewStyleInWarpTabMenuChange: { [weak self] visible in self?.setViewStyleMenuItemVisible(visible) },
            onShowClipboardInWarpTabMenuChange: { [weak self] visible in self?.setClipboardMenuItemVisible(visible) },
            onShowScreenTextInWarpTabMenuChange: { [weak self] visible in self?.setScreenTextMenuItemVisible(visible) },
            onShowColorPickerInWarpTabMenuChange: { [weak self] visible in self?.setColorPickerMenuItemVisible(visible) },
            onShowWarpTabStatusItemChange: { [weak self] visible in self?.setWarpTabStatusItemVisible(visible) },
            onShowClipboardStatusItemChange: { [weak self] visible in self?.setClipboardStatusItemVisible(visible) },
            onShowAwakeStatusItemChange: { [weak self] visible in self?.setAwakeStatusItemVisible(visible) },
            onShowSoundStatusItemChange: { [weak self] visible in
                Task { @MainActor in self?.setSoundStatusItemVisible(visible) }
            },
            onClearClipboard: { [weak self] in self?.windowsBehaviors.clearClipboard() },
            onOpenAccessibility: { [weak self] in self?.openAccessibilitySettings() },
            onClose: { [weak self] in self?.settingsDidClose() }
        )
        settingsWindow = controller
        return controller
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func showSettings() {
        NSApplication.shared.setActivationPolicy(.regular)
        let settingsWindow = makeSettingsWindow()
        settingsWindow.showWindow(nil)
        refreshFeatureLifecycles()
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow.window?.makeKeyAndOrderFront(nil)
    }

    private func showSoundSettings() {
        NSApplication.shared.setActivationPolicy(.regular)
        let settingsWindow = makeSettingsWindow()
        settingsWindow.showSoundSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow.window?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    fileprivate func openSoundMixerFromSystemControl() {
        if settingsWindow?.window?.isVisible == true {
            settingsWindow?.close()
        }

        let controller = soundController(createIfNeeded: true)

        if dismissControlCenterIfOpen() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.soundController(createIfNeeded: true)?.showFromSystemControl()
            }
        } else {
            controller?.showFromSystemControl()
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

    @objc private func copyTextFromScreenFromMenu() {
        screenTools.copyTextFromScreen()
    }

    @objc private func pickColorFromScreenFromMenu() {
        screenTools.pickColorFromScreen()
    }

    private func settingsDidClose() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
