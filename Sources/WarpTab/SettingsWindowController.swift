import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onEnabledChange: (Bool) -> Void
    private let onShortcutChange: (SwitcherShortcut) -> Bool
    private let onLayoutChange: (SwitcherLayout) -> Void
    private let onOpenAccessibility: () -> Void
    private let onOpenWindowOptions: () -> Void
    private let onClose: () -> Void

    private let enabledSwitch = NSSwitch()
    private let shortcutRecorder: ShortcutRecorderButton
    private let headerStatusDot = NSView()
    private let headerStatusLabel = NSTextField(labelWithString: "Inactive")
    private let headerShortcutLabel = NSTextField(labelWithString: "")
    private let permissionTitle = NSTextField(labelWithString: "Accessibility")
    private let permissionDescription = NSTextField(labelWithString: "")
    private let permissionStatusDot = NSView()
    private let permissionStatusLabel = NSTextField(labelWithString: "Granted")
    private let permissionButton = NSButton()
    private let listStyleCard = SwitcherStyleCard(layout: .list)
    private let thumbnailStyleCard = SwitcherStyleCard(layout: .thumbnails)

    init(
        initiallyEnabled: Bool,
        initiallySelectedShortcut: SwitcherShortcut,
        initiallySelectedLayout: SwitcherLayout,
        onEnabledChange: @escaping (Bool) -> Void,
        onShortcutChange: @escaping (SwitcherShortcut) -> Bool,
        onLayoutChange: @escaping (SwitcherLayout) -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onOpenWindowOptions: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onEnabledChange = onEnabledChange
        self.onShortcutChange = onShortcutChange
        self.onLayoutChange = onLayoutChange
        self.onOpenAccessibility = onOpenAccessibility
        self.onOpenWindowOptions = onOpenWindowOptions
        self.onClose = onClose
        self.shortcutRecorder = ShortcutRecorderButton(shortcut: initiallySelectedShortcut)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 630),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        configureWindow(
            window,
            enabled: initiallyEnabled,
            shortcut: initiallySelectedShortcut,
            layout: initiallySelectedLayout
        )
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
    }

    func refreshPermissionStatus(listenerRunning: Bool) {
        let trusted = AXIsProcessTrusted()
        updateHeaderStatus(active: trusted && listenerRunning)

        if trusted {
            permissionTitle.stringValue = "Accessibility"
            permissionDescription.stringValue = "WarpTab can discover and focus your windows."
            permissionStatusDot.isHidden = false
            permissionStatusLabel.isHidden = false
            permissionStatusLabel.stringValue = "Granted"
            permissionButton.title = "Settings…"
        } else {
            permissionTitle.stringValue = "Accessibility required"
            permissionDescription.stringValue = "WarpTab needs Accessibility access to switch between windows."
            permissionStatusDot.isHidden = true
            permissionStatusLabel.isHidden = true
            permissionButton.title = "Open Settings"
        }
    }

    func updateLayoutSelection(_ layout: SwitcherLayout) {
        listStyleCard.isSelected = layout == .list
        thumbnailStyleCard.isSelected = layout == .thumbnails
    }

    private func configureWindow(
        _ window: NSWindow,
        enabled: Bool,
        shortcut: SwitcherShortcut,
        layout: SwitcherLayout
    ) {
        window.title = "WarpTab"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 740, height: 610)
        window.maxSize = NSSize(width: 920, height: 700)
        window.isReleasedWhenClosed = false
        window.center()

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = background

        headerShortcutLabel.stringValue = shortcut.displayName
        enabledSwitch.state = enabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        enabledSwitch.setAccessibilityLabel("Enable WarpTab")

        shortcutRecorder.onShortcut = { [weak self] candidate in
            guard let self else { return false }
            let accepted = self.onShortcutChange(candidate)
            if accepted { self.headerShortcutLabel.stringValue = candidate.displayName }
            return accepted
        }
        shortcutRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 136).isActive = true

        listStyleCard.target = self
        listStyleCard.action = #selector(selectStyle(_:))
        thumbnailStyleCard.target = self
        thumbnailStyleCard.action = #selector(selectStyle(_:))
        updateLayoutSelection(layout)

        permissionButton.target = self
        permissionButton.action = #selector(openAccessibility)
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.setAccessibilityLabel("Open Accessibility settings")

        let header = makeHeader()
        let windowSwitching = makeWindowSwitchingSection()
        let appearance = makeAppearanceSection()
        let permissions = makePermissionsSection()
        let content = NSStackView(views: [header, windowSwitching, appearance, permissions])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 36),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -36),
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: 44),
            content.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -28),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            windowSwitching.widthAnchor.constraint(equalTo: content.widthAnchor),
            appearance.widthAnchor.constraint(equalTo: content.widthAnchor),
            permissions.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        refreshPermissionStatus(listenerRunning: false)
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView(image: AppIcon.make())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 58),
            icon.heightAnchor.constraint(equalToConstant: 58)
        ])
        icon.setAccessibilityLabel("WarpTab app icon")

        let title = NSTextField(labelWithString: "WarpTab")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = .labelColor

        let subtitle = NSTextField(labelWithString: "Switch windows instantly")
        subtitle.font = .systemFont(ofSize: 12.5, weight: .regular)
        subtitle.textColor = .secondaryLabelColor

        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3

        let identity = NSStackView(views: [icon, titles])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 15

        configureDot(headerStatusDot)
        headerStatusLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        headerStatusLabel.textColor = .secondaryLabelColor
        let status = NSStackView(views: [headerStatusDot, headerStatusLabel])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 7

        headerShortcutLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        headerShortcutLabel.textColor = .secondaryLabelColor
        headerShortcutLabel.alignment = .right
        let state = NSStackView(views: [status, headerShortcutLabel])
        state.orientation = .vertical
        state.alignment = .trailing
        state.spacing = 6

        let spacer = NSView()
        let header = NSStackView(views: [identity, spacer, state])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.heightAnchor.constraint(equalToConstant: 64).isActive = true
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        identity.setContentHuggingPriority(.required, for: .horizontal)
        state.setContentHuggingPriority(.required, for: .horizontal)
        return header
    }

    private func makeWindowSwitchingSection() -> NSView {
        let enabledRow = makeSettingRow(
            title: "Enable WarpTab",
            description: "Keep WarpTab available for window switching.",
            accessory: enabledSwitch
        )
        let shortcutRow = makeSettingRow(
            title: "Keyboard Shortcut",
            description: "Shortcut used to open WarpTab.",
            accessory: shortcutRecorder
        )
        let sameAppShortcut = NSTextField(labelWithString: SwitcherShortcut.sameApplicationShortcut.displayName)
        sameAppShortcut.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        sameAppShortcut.textColor = .secondaryLabelColor
        sameAppShortcut.setAccessibilityLabel("Same-application shortcut \(SwitcherShortcut.sameApplicationShortcut.displayName)")
        let sameAppRow = makeSettingRow(
            title: "Same Application",
            description: "Switch between windows of the current application.",
            accessory: sameAppShortcut
        )
        let optionsButton = NSButton(title: "Window & Display Options…", target: self, action: #selector(openWindowOptions))
        optionsButton.bezelStyle = .rounded
        optionsButton.controlSize = .small
        optionsButton.setAccessibilityLabel("Open window and display options")
        let optionsRow = makeSettingRow(
            title: "Window Options",
            description: "Choose which windows appear and where the switcher opens.",
            accessory: optionsButton
        )
        let rows = NSStackView(views: [
            enabledRow, insetSeparator(), shortcutRow, insetSeparator(),
            sameAppRow, insetSeparator(), optionsRow
        ])
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 0
        return makeSection(
            title: "Window Switching",
            symbol: "rectangle.on.rectangle",
            content: surface(around: rows)
        )
    }

    private func makeAppearanceSection() -> NSView {
        let cards = NSStackView(views: [listStyleCard, thumbnailStyleCard])
        cards.orientation = .horizontal
        cards.alignment = .height
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.heightAnchor.constraint(equalToConstant: 112).isActive = true
        return makeSection(title: "Appearance", symbol: "rectangle.grid.2x2", content: cards)
    }

    private func makePermissionsSection() -> NSView {
        permissionTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        permissionTitle.textColor = .labelColor
        permissionDescription.font = .systemFont(ofSize: 12, weight: .regular)
        permissionDescription.textColor = .secondaryLabelColor
        permissionDescription.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [permissionTitle, permissionDescription])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureDot(permissionStatusDot)
        permissionStatusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        permissionStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        permissionStatusLabel.textColor = .secondaryLabelColor
        let granted = NSStackView(views: [permissionStatusDot, permissionStatusLabel])
        granted.orientation = .horizontal
        granted.alignment = .centerY
        granted.spacing = 6

        let right = NSStackView(views: [granted, permissionButton])
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 12
        right.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [text, NSView(), right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 14)
        row.heightAnchor.constraint(equalToConstant: 70).isActive = true

        return makeSection(
            title: "Permissions",
            symbol: "hand.raised",
            content: surface(around: row)
        )
    }

    private func makeSection(title: String, symbol: String, content: NSView) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16)
        ])

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        let heading = NSStackView(views: [icon, label])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 7

        let section = NSStackView(views: [heading, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeSettingRow(title: String, description: String, accessory: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        let descriptionLabel = NSTextField(labelWithString: description)
        descriptionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        descriptionLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [titleLabel, descriptionLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessory.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        let row = NSStackView(views: [labels, spacer, accessory])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        row.heightAnchor.constraint(equalToConstant: 61).isActive = true
        return row
    }

    private func surface(around content: NSView) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.7).cgColor
        view.layer?.cornerRadius = 13
        view.layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    private func insetSeparator() -> NSView {
        let container = NSView()
        container.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.38).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1)
        ])
        return container
    }

    private func configureDot(_ dot: NSView) {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    private func updateHeaderStatus(active: Bool) {
        headerStatusLabel.stringValue = active ? "Active" : "Inactive"
        headerStatusDot.layer?.backgroundColor = (active ? NSColor.systemGreen : NSColor.secondaryLabelColor).cgColor
        headerStatusLabel.setAccessibilityLabel(active ? "WarpTab is active" : "WarpTab is inactive")
    }

    @objc private func toggleEnabled() {
        onEnabledChange(enabledSwitch.state == .on)
    }

    @objc private func selectStyle(_ sender: SwitcherStyleCard) {
        updateLayoutSelection(sender.layout)
        onLayoutChange(sender.layout)
    }

    @objc private func openAccessibility() {
        onOpenAccessibility()
    }

    @objc private func openWindowOptions() {
        onOpenWindowOptions()
    }
}

private final class SwitcherStyleCard: NSControl {
    let layout: SwitcherLayout
    var isSelected = false {
        didSet {
            updateAppearance()
        }
    }

    private let preview: StylePreviewView
    private let checkmark = NSImageView()
    private var isHovered = false

    init(layout: SwitcherLayout) {
        self.layout = layout
        self.preview = StylePreviewView(layout: layout)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let title = NSTextField(labelWithString: layout.displayName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        checkmark.contentTintColor = .controlAccentColor
        checkmark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            checkmark.widthAnchor.constraint(equalToConstant: 16),
            checkmark.heightAnchor.constraint(equalToConstant: 16)
        ])

        let labelRow = NSStackView(views: [title, NSView(), checkmark])
        labelRow.orientation = .horizontal
        labelRow.alignment = .centerY
        labelRow.spacing = 8

        let stack = NSStackView(views: [preview, labelRow])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            preview.heightAnchor.constraint(equalToConstant: 61)
        ])

        let clickTarget = NSButton(frame: .zero)
        clickTarget.title = ""
        clickTarget.isBordered = false
        clickTarget.isTransparent = true
        clickTarget.focusRingType = .none
        clickTarget.target = self
        clickTarget.action = #selector(handleClick(_:))
        clickTarget.translatesAutoresizingMaskIntoConstraints = false
        clickTarget.setAccessibilityElement(false)
        addSubview(clickTarget)
        NSLayoutConstraint.activate([
            clickTarget.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickTarget.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickTarget.topAnchor.constraint(equalTo: topAnchor),
            clickTarget.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setAccessibilityElement(true)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }

    override func accessibilityLabel() -> String? { layout.displayName + " switcher style" }

    override func accessibilityValue() -> Any? { isSelected }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    @objc private func handleClick(_ sender: Any?) {
        window?.makeFirstResponder(self)
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
            sendAction(action, to: target)
        } else {
            super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    private func updateAppearance() {
        let base = NSColor.controlBackgroundColor
        let background: NSColor
        if isSelected {
            background = base.blended(withFraction: 0.055, of: .controlAccentColor) ?? base
        } else if isHovered {
            background = base.blended(withFraction: 0.08, of: .labelColor) ?? base
        } else {
            background = base.withAlphaComponent(0.62)
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = (isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.68)
            : NSColor.separatorColor.withAlphaComponent(isHovered ? 0.62 : 0.38)).cgColor
        checkmark.isHidden = !isSelected
        preview.isSelected = isSelected
    }
}

private final class StylePreviewView: NSView {
    let layout: SwitcherLayout
    var isSelected = false { didSet { needsDisplay = true } }

    init(layout: SwitcherLayout) {
        self.layout = layout
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = isSelected ? NSColor.labelColor.withAlphaComponent(0.7) : NSColor.secondaryLabelColor.withAlphaComponent(0.58)
        color.setFill()

        switch layout {
        case .list:
            let rowHeight: CGFloat = 8
            let gap: CGFloat = 8
            let total = rowHeight * 3 + gap * 2
            var y = bounds.midY + total / 2 - rowHeight
            for index in 0..<3 {
                NSBezierPath(roundedRect: NSRect(x: 2, y: y, width: bounds.width - CGFloat(index * 18) - 8, height: rowHeight), xRadius: 3, yRadius: 3).fill()
                y -= rowHeight + gap
            }
        case .thumbnails:
            let gap: CGFloat = 8
            let width = (bounds.width - gap * 2 - 4) / 3
            let height: CGFloat = 45
            for index in 0..<3 {
                let rect = NSRect(x: 2 + CGFloat(index) * (width + gap), y: bounds.midY - height / 2, width: width, height: height)
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
        }
    }
}

private final class ShortcutRecorderButton: NSButton {
    var onShortcut: ((SwitcherShortcut) -> Bool)?
    private var shortcut: SwitcherShortcut
    private var isRecording = false

    init(shortcut: SwitcherShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        title = shortcut.displayName
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("Keyboard shortcut")
        setAccessibilityHelp("Press to record a new keyboard shortcut")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording(with: shortcut)
            return
        }

        let modifiers = SwitcherShortcut.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep()
            showTemporaryMessage("Add a modifier")
            return
        }

        let candidate = SwitcherShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers,
            keyLabel: SwitcherShortcut.keyLabel(for: event)
        )
        guard !candidate.isReserved else {
            NSSound.beep()
            showTemporaryMessage("Reserved by macOS")
            return
        }

        if onShortcut?(candidate) == true {
            shortcut = candidate
            finishRecording(with: candidate)
        } else {
            NSSound.beep()
            showTemporaryMessage("Unavailable")
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            title = shortcut.displayName
        }
        return super.resignFirstResponder()
    }

    private func finishRecording(with shortcut: SwitcherShortcut) {
        isRecording = false
        title = shortcut.displayName
        window?.makeFirstResponder(nil)
    }

    private func showTemporaryMessage(_ message: String) {
        title = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isRecording else { return }
            self.title = "Type shortcut…"
        }
    }
}
