import AppKit

enum SwitcherLayout: String, CaseIterable {
    case list
    case thumbnails

    var displayName: String {
        switch self {
        case .list: return "List"
        case .thumbnails: return "Thumbnails"
        }
    }
}

final class SwitcherPanelController: NSWindowController {
    private let repository: WindowRepository
    private var windows: [SwitchableWindow] = []
    private var rows: [WindowRowView] = []
    private var selectedIndex = 0
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private var shortcut: SwitcherShortcut
    private var layout: SwitcherLayout

    init(repository: WindowRepository, shortcut: SwitcherShortcut, layout: SwitcherLayout) {
        self.repository = repository
        self.shortcut = shortcut
        self.layout = layout
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 510, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        configurePanel(panel)
        repository.onTitlesUpdated = { [weak self] in self?.refreshVisibleRows() }
    }

    required init?(coder: NSCoder) { nil }

    func updateShortcut(_ shortcut: SwitcherShortcut) {
        self.shortcut = shortcut
    }

    func updateLayout(_ layout: SwitcherLayout) {
        self.layout = layout
        guard isVisible else { return }
        rebuildRows()
        showPanel()
    }

    func cycle(backwards: Bool) {
        if !isVisible {
            windows = repository.currentWindows()
            guard !windows.isEmpty else { return }
            selectedIndex = windows.count > 1 && windows.first?.isCurrent == true ? 1 : 0
            rebuildRows()
            showPanel()
        } else {
            let delta = backwards ? -1 : 1
            selectedIndex = (selectedIndex + delta + windows.count) % windows.count
            updateSelection()
        }
    }

    func commitSelection() {
        guard isVisible, windows.indices.contains(selectedIndex) else { return }
        let selection = windows[selectedIndex]
        window?.orderOut(nil)
        repository.focus(selection)
    }

    func cancel() {
        window?.orderOut(nil)
    }

    private var isVisible: Bool { window?.isVisible == true }

    private func configurePanel(_ panel: NSPanel) {
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .utilityWindow

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        // Attach the document before activating a constraint that references
        // the scroll view's clip view; otherwise the views have no common
        // ancestor and AppKit raises an exception on the first hotkey.
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: effect.topAnchor, constant: 9),
            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 9),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -9),
            scrollView.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -9)
        ])
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows = windows.enumerated().map { index, item in
            let row = WindowRowView(
                window: item,
                number: index + 1,
                layout: layout,
                thumbnail: layout == .thumbnails ? repository.thumbnail(for: item) : nil
            )
            row.onClick = { [weak self] in
                guard let self else { return }
                selectedIndex = index
                updateSelection()
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }

        if layout == .list {
            stack.spacing = 3
            for row in rows {
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            }
        } else {
            stack.spacing = 8
            for start in stride(from: 0, to: rows.count, by: 4) {
                let end = min(start + 4, rows.count)
                let cells: [NSView] = Array(rows[start..<end])
                let gridRow = NSStackView(views: cells)
                gridRow.orientation = .horizontal
                gridRow.alignment = .height
                gridRow.distribution = .fillEqually
                gridRow.spacing = 8
                gridRow.translatesAutoresizingMaskIntoConstraints = false
                gridRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                let rowContainer = NSView()
                rowContainer.translatesAutoresizingMaskIntoConstraints = false
                rowContainer.addSubview(gridRow)
                stack.addArrangedSubview(rowContainer)
                NSLayoutConstraint.activate([
                    rowContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
                    rowContainer.heightAnchor.constraint(equalToConstant: 136),
                    gridRow.centerXAnchor.constraint(equalTo: rowContainer.centerXAnchor),
                    gridRow.topAnchor.constraint(equalTo: rowContainer.topAnchor),
                    gridRow.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor),
                    gridRow.widthAnchor.constraint(
                        equalTo: rowContainer.widthAnchor,
                        multiplier: CGFloat(cells.count) / 4.0
                    )
                ])
            }
        }
        updateSelection()
    }

    private func refreshVisibleRows() {
        guard isVisible else { return }
        let previousIndex = selectedIndex
        windows = repository.currentWindows(refreshTitles: false)
        guard !windows.isEmpty else {
            cancel()
            return
        }
        selectedIndex = min(previousIndex, windows.count - 1)
        rebuildRows()
        showPanel()
    }

    private func updateSelection() {
        for (index, row) in rows.enumerated() { row.isSelected = index == selectedIndex }
        if rows.indices.contains(selectedIndex) {
            rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds)
        }
    }

    private func showPanel() {
        guard let panel = window else { return }

        if layout == .list {
            let visibleCount = min(windows.count, 8)
            let height = CGFloat(18 + visibleCount * 43)
            panel.setContentSize(NSSize(width: 480, height: height))
        } else {
            let rowCount = Int(ceil(Double(windows.count) / 4.0))
            let visibleRows = min(max(rowCount, 1), 3)
            panel.setContentSize(NSSize(width: 820, height: CGFloat(18 + visibleRows * 144)))
        }

        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        updateSelection()
    }
}

private final class WindowRowView: NSView {
    var isSelected = false { didSet { updateAppearance() } }
    var onClick: (() -> Void)?

    init(
        window: SwitchableWindow,
        number: Int,
        layout: SwitcherLayout,
        thumbnail: NSImage?
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        if layout == .thumbnails {
            configureThumbnail(window: window, number: number, thumbnail: thumbnail)
            installClickTarget()
            updateAppearance()
            return
        }

        let icon = NSImageView(image: window.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: window.title)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let subtitleText = window.isMinimized ? "\(window.appName)  ·  Minimized" : window.appName
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.font = .systemFont(ofSize: 9.5, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let key = NSTextField(labelWithString: number <= 99 ? "\(number)" : "")
        key.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        key.textColor = .tertiaryLabelColor
        key.alignment = .right
        key.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(labels)
        addSubview(key)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -12),
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            key.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.widthAnchor.constraint(equalToConstant: 34)
        ])
        installClickTarget()
        updateAppearance()
    }

    private func configureThumbnail(window: SwitchableWindow, number: Int, thumbnail: NSImage?) {
        let preview = NSView()
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        preview.layer?.cornerRadius = 7
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false

        let previewImage = NSImageView(image: thumbnail ?? window.icon)
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewImage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewImage.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewImage.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewImage.setContentHuggingPriority(.defaultLow, for: .vertical)
        preview.addSubview(previewImage)

        let appIcon = NSImageView(image: window.icon)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: window.title)
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let numberLabel = NSTextField(labelWithString: "\(number)")
        numberLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        numberLabel.textColor = .tertiaryLabelColor
        numberLabel.alignment = .right
        numberLabel.translatesAutoresizingMaskIntoConstraints = false

        let minimizedBadge = NSTextField(labelWithString: window.isMinimized ? "Minimized" : "")
        minimizedBadge.font = .systemFont(ofSize: 8.5, weight: .medium)
        minimizedBadge.textColor = .secondaryLabelColor
        minimizedBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(preview)
        addSubview(appIcon)
        addSubview(title)
        addSubview(minimizedBadge)
        addSubview(numberLabel)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            preview.heightAnchor.constraint(equalToConstant: 94),
            previewImage.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            previewImage.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            previewImage.widthAnchor.constraint(lessThanOrEqualTo: preview.widthAnchor),
            previewImage.heightAnchor.constraint(lessThanOrEqualTo: preview.heightAnchor),
            thumbnail == nil
                ? previewImage.widthAnchor.constraint(equalToConstant: 48)
                : previewImage.widthAnchor.constraint(equalTo: preview.widthAnchor),
            thumbnail == nil
                ? previewImage.heightAnchor.constraint(equalToConstant: 48)
                : previewImage.heightAnchor.constraint(equalTo: preview.heightAnchor),
            appIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            appIcon.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
            appIcon.widthAnchor.constraint(equalToConstant: 17),
            appIcon.heightAnchor.constraint(equalToConstant: 17),
            title.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            minimizedBadge.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            minimizedBadge.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            numberLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            numberLabel.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 22),
            title.trailingAnchor.constraint(lessThanOrEqualTo: numberLabel.leadingAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func installClickTarget() {
        let clickTarget = ClickOnlyView(frame: .zero)
        clickTarget.onClick = { [weak self] in self?.onClick?() }
        clickTarget.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clickTarget)
        NSLayoutConstraint.activate([
            clickTarget.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickTarget.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickTarget.topAnchor.constraint(equalTo: topAnchor),
            clickTarget.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func updateAppearance() {
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.38).cgColor
    }
}

private final class ClickOnlyView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
