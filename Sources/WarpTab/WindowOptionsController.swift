import AppKit
import CoreGraphics

final class WindowOptionsController: NSWindowController {
    private let preferences: WarpPreferences
    private let store: WindowStore

    private let searchSwitch = NSSwitch()
    private let previewsSwitch = NSSwitch()
    private let dockPreviewsSwitch = NSSwitch()
    private let dockCloseSwitch = NSSwitch()
    private let quitLastWindowSwitch = NSSwitch()
    private let dockPreviewSizeControl = NSSegmentedControl(
        labels: DockPreviewSize.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let minimizedSwitch = NSSwitch()
    private let hiddenSwitch = NSSwitch()
    private let fullscreenSwitch = NSSwitch()
    private let spacesSwitch = NSSwitch()
    private let windowlessSwitch = NSSwitch()
    private let placementPopup = NSPopUpButton()
    private let displayPopup = NSPopUpButton()
    private let nativeTabsPopup = NSPopUpButton()
    private let addExclusionPopup = NSPopUpButton()
    private let exclusionsPopup = NSPopUpButton()
    private let removeExclusionButton = NSButton()
    private let screenRecordingStatus = NSTextField(labelWithString: "")

    init(preferences: WarpPreferences, store: WindowStore) {
        self.preferences = preferences
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configure(window)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        refreshControls()
        super.showWindow(sender)
        window?.center()
    }

    private func configure(_ window: NSWindow) {
        window.title = "Window & Display Options"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

        configureSwitch(searchSwitch, action: #selector(changeSearch))
        configureSwitch(previewsSwitch, action: #selector(changePreviews))
        configureSwitch(dockPreviewsSwitch, action: #selector(changeDockPreviews))
        configureSwitch(dockCloseSwitch, action: #selector(changeDockClose))
        configureSwitch(quitLastWindowSwitch, action: #selector(changeQuitLastWindow))
        configureSwitch(minimizedSwitch, action: #selector(changeMinimized))
        configureSwitch(hiddenSwitch, action: #selector(changeHidden))
        configureSwitch(fullscreenSwitch, action: #selector(changeFullscreen))
        configureSwitch(spacesSwitch, action: #selector(changeSpaces))
        configureSwitch(windowlessSwitch, action: #selector(changeWindowless))
        dockPreviewSizeControl.target = self
        dockPreviewSizeControl.action = #selector(changeDockPreviewSize)
        dockPreviewSizeControl.controlSize = .small
        dockPreviewSizeControl.setAccessibilityLabel("Dock preview size")

        placementPopup.addItems(withTitles: SwitcherScreenPlacement.allCases.map(\.displayName))
        placementPopup.target = self
        placementPopup.action = #selector(changePlacement)
        displayPopup.addItems(withTitles: WindowDisplayScope.allCases.map(\.displayName))
        displayPopup.target = self
        displayPopup.action = #selector(changeDisplayScope)
        nativeTabsPopup.addItems(withTitles: NativeTabBehavior.allCases.map(\.displayName))
        nativeTabsPopup.target = self
        nativeTabsPopup.action = #selector(changeNativeTabBehavior)

        addExclusionPopup.target = self
        addExclusionPopup.action = #selector(addExclusion)
        exclusionsPopup.target = self
        removeExclusionButton.title = "Remove"
        removeExclusionButton.target = self
        removeExclusionButton.action = #selector(removeExclusion)
        removeExclusionButton.bezelStyle = .rounded
        removeExclusionButton.controlSize = .small

        let recordingButton = NSButton(title: "Settings…", target: self, action: #selector(openScreenRecordingSettings))
        recordingButton.bezelStyle = .rounded
        recordingButton.controlSize = .small
        let recordingAccessory = NSStackView(views: [screenRecordingStatus, recordingButton])
        recordingAccessory.orientation = .horizontal
        recordingAccessory.alignment = .centerY
        recordingAccessory.spacing = 10

        let exclusionsAccessory = NSStackView(views: [exclusionsPopup, removeExclusionButton])
        exclusionsAccessory.orientation = .horizontal
        exclusionsAccessory.alignment = .centerY
        exclusionsAccessory.spacing = 8
        exclusionsPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        addExclusionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let rows = NSStackView(views: [
            sectionTitle("Switcher"),
            row("Keyboard search", "Type while the switcher is open to filter windows.", searchSwitch),
            row("Window previews", "Show live thumbnails when screen recording access is available.", previewsSwitch),
            row("Switcher location", "Choose which screen displays the switcher.", placementPopup),
            row("Window scope", "Show windows from every display or the current display only.", displayPopup),
            sectionTitle("Dock Previews"),
            row("Dock window previews", "Hover over a running app in the Dock to see its open windows.", dockPreviewsSwitch),
            row("Preview size", "Choose the size of window previews shown above the Dock.", dockPreviewSizeControl),
            row("Close windows from previews", "Show a close button on each Dock window preview.", dockCloseSwitch),
            row("Quit after closing last window", "Quit an app when its final window is closed from a preview.", quitLastWindowSwitch),
            sectionTitle("Included Windows"),
            row("Minimized windows", "Include minimized windows.", minimizedSwitch),
            row("Hidden applications", "Include windows from hidden applications.", hiddenSwitch),
            row("Full-screen windows", "Include full-screen windows.", fullscreenSwitch),
            row("Other Spaces", "Include discoverable windows from other Spaces.", spacesSwitch),
            row("Apps without windows", "Include running apps that currently have no window.", windowlessSwitch),
            row("Native window tabs", "Group AppKit window tabs or show them separately when reliably exposed.", nativeTabsPopup),
            sectionTitle("Excluded Applications"),
            row("Add application", "Keep an application's windows out of WarpTab.", addExclusionPopup),
            row("Excluded", "Select an application and remove it from the exclusion list.", exclusionsAccessory),
            sectionTitle("Permissions"),
            row("Screen Recording", "Optional permission used only for window thumbnails.", recordingAccessory)
        ])
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22),
            rows.widthAnchor.constraint(equalToConstant: 572)
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        window.contentView = scroll
        refreshControls()
    }

    private func configureSwitch(_ control: NSSwitch, action: Selector) {
        control.target = self
        control.action = action
    }

    private func sectionTitle(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let box = NSView()
        box.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            box.heightAnchor.constraint(equalToConstant: 28)
        ])
        return box
    }

    private func row(_ title: String, _ description: String, _ accessory: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let descriptionLabel = NSTextField(labelWithString: description)
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, descriptionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let stack = NSStackView(views: [text, NSView(), accessory])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        stack.layer?.cornerRadius = 10
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        return stack
    }

    private func refreshControls() {
        searchSwitch.state = preferences.searchEnabled ? .on : .off
        previewsSwitch.state = preferences.previewsEnabled ? .on : .off
        dockPreviewsSwitch.state = preferences.dockPreviewsEnabled ? .on : .off
        dockCloseSwitch.state = preferences.dockPreviewCloseEnabled ? .on : .off
        quitLastWindowSwitch.state = preferences.quitAppWhenLastWindowClosed ? .on : .off
        dockPreviewSizeControl.selectedSegment = DockPreviewSize.allCases.firstIndex(of: preferences.dockPreviewSize) ?? 1
        refreshDockPreviewControlStates()
        minimizedSwitch.state = preferences.showMinimized ? .on : .off
        hiddenSwitch.state = preferences.showHiddenApplications ? .on : .off
        fullscreenSwitch.state = preferences.showFullscreen ? .on : .off
        spacesSwitch.state = preferences.showOtherSpaces ? .on : .off
        windowlessSwitch.state = preferences.showWindowlessApps ? .on : .off
        placementPopup.selectItem(at: SwitcherScreenPlacement.allCases.firstIndex(of: preferences.screenPlacement) ?? 0)
        displayPopup.selectItem(at: WindowDisplayScope.allCases.firstIndex(of: preferences.displayScope) ?? 0)
        nativeTabsPopup.selectItem(at: NativeTabBehavior.allCases.firstIndex(of: preferences.nativeTabBehavior) ?? 0)
        screenRecordingStatus.stringValue = CGPreflightScreenCaptureAccess() ? "● Granted" : "Not granted"
        screenRecordingStatus.textColor = CGPreflightScreenCaptureAccess() ? .systemGreen : .secondaryLabelColor
        refreshExclusionMenus()
    }

    private func refreshExclusionMenus() {
        addExclusionPopup.removeAllItems()
        addExclusionPopup.addItem(withTitle: "Choose an application…")
        let excluded = preferences.excludedBundleIdentifiers
        for app in store.runningApplications() {
            guard let identifier = app.bundleIdentifier, !excluded.contains(identifier) else { continue }
            addExclusionPopup.addItem(withTitle: app.localizedName ?? identifier)
            addExclusionPopup.lastItem?.representedObject = identifier
        }
        exclusionsPopup.removeAllItems()
        if excluded.isEmpty {
            exclusionsPopup.addItem(withTitle: "No excluded applications")
            exclusionsPopup.isEnabled = false
            removeExclusionButton.isEnabled = false
        } else {
            exclusionsPopup.isEnabled = true
            removeExclusionButton.isEnabled = true
            for identifier in excluded.sorted() {
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                    .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
                    ?? identifier
                exclusionsPopup.addItem(withTitle: name)
                exclusionsPopup.lastItem?.representedObject = identifier
            }
        }
    }

    @objc private func changeSearch() { preferences.searchEnabled = searchSwitch.state == .on }
    @objc private func changePreviews() { preferences.previewsEnabled = previewsSwitch.state == .on }
    @objc private func changeDockPreviews() {
        preferences.dockPreviewsEnabled = dockPreviewsSwitch.state == .on
        refreshDockPreviewControlStates()
    }
    @objc private func changeDockClose() {
        preferences.dockPreviewCloseEnabled = dockCloseSwitch.state == .on
        refreshDockPreviewControlStates()
    }
    @objc private func changeQuitLastWindow() {
        preferences.quitAppWhenLastWindowClosed = quitLastWindowSwitch.state == .on
    }

    @objc private func changeDockPreviewSize() {
        guard DockPreviewSize.allCases.indices.contains(dockPreviewSizeControl.selectedSegment) else { return }
        preferences.dockPreviewSize = DockPreviewSize.allCases[dockPreviewSizeControl.selectedSegment]
    }
    @objc private func changeMinimized() { preferences.showMinimized = minimizedSwitch.state == .on }
    @objc private func changeHidden() { preferences.showHiddenApplications = hiddenSwitch.state == .on }
    @objc private func changeFullscreen() { preferences.showFullscreen = fullscreenSwitch.state == .on }
    @objc private func changeSpaces() { preferences.showOtherSpaces = spacesSwitch.state == .on }
    @objc private func changeWindowless() { preferences.showWindowlessApps = windowlessSwitch.state == .on }

    @objc private func changePlacement() {
        preferences.screenPlacement = SwitcherScreenPlacement.allCases[placementPopup.indexOfSelectedItem]
    }

    @objc private func changeDisplayScope() {
        preferences.displayScope = WindowDisplayScope.allCases[displayPopup.indexOfSelectedItem]
    }

    @objc private func changeNativeTabBehavior() {
        preferences.nativeTabBehavior = NativeTabBehavior.allCases[nativeTabsPopup.indexOfSelectedItem]
    }

    @objc private func addExclusion() {
        guard let identifier = addExclusionPopup.selectedItem?.representedObject as? String else { return }
        preferences.excludedBundleIdentifiers.insert(identifier)
        refreshExclusionMenus()
    }

    @objc private func removeExclusion() {
        guard let identifier = exclusionsPopup.selectedItem?.representedObject as? String else { return }
        preferences.excludedBundleIdentifiers.remove(identifier)
        refreshExclusionMenus()
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private func refreshDockPreviewControlStates() {
        let previewsEnabled = dockPreviewsSwitch.state == .on
        dockPreviewSizeControl.isEnabled = previewsEnabled
        dockCloseSwitch.isEnabled = previewsEnabled
        quitLastWindowSwitch.isEnabled = previewsEnabled && dockCloseSwitch.state == .on
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
