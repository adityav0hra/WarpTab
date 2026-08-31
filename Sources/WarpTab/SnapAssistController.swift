import AppKit

final class SnapAssistController {
    private let panel: NSPanel
    private let previewCache: PreviewCache
    private let preferences: WarpPreferences
    private let effect = NSVisualEffectView()
    private let heading = NSTextField(labelWithString: "Choose a window for this space")
    private let scrollView = NSScrollView()
    private let documentView = FlippedSnapAssistView()
    private var visibleItems: [String: SnapAssistItemView] = [:]
    private var visibleWindows: [String: WarpWindow] = [:]
    private var selectionHandler: ((WarpWindow) -> Void)?
    private var dismissal: DispatchWorkItem?

    init(previewCache: PreviewCache, preferences: WarpPreferences) {
        self.previewCache = previewCache
        self.preferences = preferences
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = preferences.animationsEnabled ? .utilityWindow : .none

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .labelColor
        heading.lineBreakMode = .byTruncatingTail
        heading.autoresizingMask = [.width, .minYMargin]
        effect.addSubview(heading)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = documentView
        effect.addSubview(scrollView)
    }

    func show(
        in accessibilityRegion: CGRect,
        candidates: [WarpWindow],
        layout: SnapAssistLayout,
        onChoose: @escaping (WarpWindow) -> Void
    ) {
        panel.animationBehavior = preferences.animationsEnabled ? .utilityWindow : .none
        dismissal?.cancel()
        clearCandidates()
        selectionHandler = onChoose
        let usableCandidates = Array(candidates.filter {
            !$0.isWindowlessApplication && !$0.isFullscreen && $0.axWindow != nil && !$0.title.isEmpty
        }.prefix(8))
        guard !usableCandidates.isEmpty else {
            panel.orderOut(nil)
            return
        }

        let columns = layout == .thumbnails && accessibilityRegion.width >= 460 ? 2 : 1
        let rowCount = Int(ceil(Double(usableCandidates.count) / Double(columns)))
        let desiredWidth: CGFloat = layout == .thumbnails ? (columns == 2 ? 620 : 330) : 420
        let desiredHeight: CGFloat = layout == .thumbnails
            ? CGFloat(rowCount) * 155 + 46
            : CGFloat(usableCandidates.count) * 55 + 46
        let width = min(desiredWidth, max(260, accessibilityRegion.width - 28))
        let height = min(desiredHeight, max(110, accessibilityRegion.height - 28))
        let primaryTop = NSScreen.warpHardwareMain?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        let appKitRegion = ScreenGeometryService.accessibilityToAppKit(
            accessibilityRegion,
            primaryTop: primaryTop
        )
        let requestedFrame = CGRect(
                x: appKitRegion.midX - width / 2,
                y: appKitRegion.midY - height / 2,
                width: width,
                height: height
            )
        panel.setFrame(requestedFrame, display: false)
        effect.frame = CGRect(origin: .zero, size: requestedFrame.size)
        heading.frame = CGRect(x: 12, y: height - 34, width: width - 24, height: 20)
        scrollView.frame = CGRect(x: 8, y: 8, width: width - 16, height: height - 48)
        layoutCandidates(
            usableCandidates,
            layout: layout,
            columns: columns,
            width: scrollView.contentSize.width,
            onChoose: onChoose
        )
        panel.orderFrontRegardless()

        let item = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        dismissal = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: item)
    }

    func handleMouseDown(at accessibilityPoint: CGPoint) -> Bool {
        guard panel.isVisible else { return false }
        let primaryTop = NSScreen.warpHardwareMain?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        let appKitPoint = CGPoint(x: accessibilityPoint.x, y: primaryTop - accessibilityPoint.y)
        let windowPoint = panel.convertPoint(fromScreen: appKitPoint)
        for (identity, item) in visibleItems {
            let itemPoint = item.convert(windowPoint, from: nil)
            guard item.bounds.contains(itemPoint), let window = visibleWindows[identity] else { continue }
            panel.orderOut(nil)
            selectionHandler?(window)
            return true
        }
        return false
    }

    private func layoutCandidates(
        _ candidates: [WarpWindow],
        layout: SnapAssistLayout,
        columns: Int,
        width: CGFloat,
        onChoose: @escaping (WarpWindow) -> Void
    ) {
        let spacing: CGFloat = 7
        let itemHeight: CGFloat = layout == .thumbnails ? 148 : 48
        let rowHeight = itemHeight + spacing
        let rowCount = Int(ceil(Double(candidates.count) / Double(columns)))
        let contentHeight = max(scrollView.contentSize.height, CGFloat(rowCount) * rowHeight - spacing)
        documentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        let itemWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        for (index, candidate) in candidates.enumerated() {
            let row = index / columns
            let column = index % columns
            let style: SnapAssistItemView.Style = layout == .thumbnails ? .thumbnail : .list
            let item = makeItem(candidate, style: style, onChoose: onChoose)
            item.frame = CGRect(
                x: CGFloat(column) * (itemWidth + spacing),
                y: CGFloat(row) * rowHeight,
                width: itemWidth,
                height: itemHeight
            )
            documentView.addSubview(item)
        }
    }

    private func makeItem(
        _ candidate: WarpWindow,
        style: SnapAssistItemView.Style,
        onChoose: @escaping (WarpWindow) -> Void
    ) -> SnapAssistItemView {
        let item = SnapAssistItemView(window: candidate, style: style) { [weak self] window in
            self?.panel.orderOut(nil)
            onChoose(window)
        }
        visibleItems[candidate.identity] = item
        visibleWindows[candidate.identity] = candidate
        guard style == .thumbnail else { return item }
        let cached = previewCache.image(for: candidate) { [weak self] identity, image in
            guard self?.panel.isVisible == true else { return }
            self?.visibleItems[identity]?.updateThumbnail(image)
        }
        item.updateThumbnail(cached)
        return item
    }

    private func clearCandidates() {
        visibleItems.removeAll()
        visibleWindows.removeAll()
        selectionHandler = nil
        documentView.subviews.forEach { $0.removeFromSuperview() }
    }
}

private final class FlippedSnapAssistView: NSView {
    override var isFlipped: Bool { true }
}

private final class SnapAssistItemView: NSButton {
    enum Style {
        case list
        case thumbnail
    }

    private let candidateWindow: WarpWindow
    private let onChoose: (WarpWindow) -> Void
    private var previewImageView: NSImageView?
    private var placeholderImageView: NSImageView?
    private var tracking: NSTrackingArea?

    init(window: WarpWindow, style: Style, onChoose: @escaping (WarpWindow) -> Void) {
        candidateWindow = window
        self.onChoose = onChoose
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(choose)
        switch style {
        case .list: configureList(window)
        case .thumbnail: configureThumbnail(window)
        }
        setAccessibilityLabel("Fill remaining space with \(window.title) from \(window.appName)")
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        choose()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateThumbnail(_ image: NSImage?) {
        previewImageView?.image = image
        placeholderImageView?.isHidden = image != nil
    }

    private func configureList(_ window: WarpWindow) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        let icon = NSImageView(image: window.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = label(window.title, size: 12.5, weight: .medium, color: .labelColor)
        let subtitle = label(window.appName, size: 10, weight: .regular, color: .secondaryLabelColor)
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func configureThumbnail(_ window: WarpWindow) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        let preview = NSView()
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        preview.layer?.cornerRadius = 7
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        let previewImage = NSImageView()
        previewImageView = previewImage
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(previewImage)
        let placeholder = NSImageView(image: window.icon)
        placeholderImageView = placeholder
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(placeholder)
        let icon = NSImageView(image: window.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = label(window.title, size: 11.5, weight: .medium, color: .labelColor)
        addSubview(preview)
        addSubview(icon)
        addSubview(title)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            preview.heightAnchor.constraint(equalToConstant: 105),
            previewImage.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            previewImage.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            previewImage.topAnchor.constraint(equalTo: preview.topAnchor),
            previewImage.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: 44),
            placeholder.heightAnchor.constraint(equalToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 9),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor)
        ])
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    @objc private func choose() { onChoose(candidateWindow) }
}
