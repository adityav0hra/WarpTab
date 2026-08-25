import AppKit
import ApplicationServices
import CoreGraphics

final class DockPreviewController: NSWindowController {
    private struct DockHit {
        let bundleIdentifier: String
        let appKitFrame: CGRect
    }

    private let store: WindowStore
    private let preferences: WarpPreferences
    private let previewCache: PreviewCache
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private var cards: [String: DockPreviewCard] = [:]
    private var timer: Timer?
    private var dockList: AXUIElement?
    private var candidateBundleIdentifier: String?
    private var candidateSince = Date.distantPast
    private var currentBundleIdentifier: String?
    private var currentDockFrame = CGRect.zero
    private var visibleWindowIdentities: [String] = []
    private var lastRelevantMouseDate = Date.distantPast
    private var lastPanelRefresh = Date.distantPast

    init(store: WindowStore, preferences: WarpPreferences, previewCache: PreviewCache) {
        self.store = store
        self.preferences = preferences
        self.previewCache = previewCache
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 184),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        configurePanel(panel)
    }

    required init?(coder: NSCoder) { nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.trackPointer()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        dockList = nil
        hidePanel()
    }

    private func configurePanel(_ panel: NSPanel) {
        panel.title = "Dock Window Previews"
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
        panel.setAccessibilityLabel("Dock window previews")

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stack
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: effect.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: 174)
        ])
        panel.contentView = effect
    }

    private func trackPointer() {
        guard preferences.dockPreviewsEnabled, AXIsProcessTrusted() else {
            hidePanel()
            return
        }

        let appKitPoint = NSEvent.mouseLocation
        if window?.isVisible == true, window?.frame.insetBy(dx: -4, dy: -4).contains(appKitPoint) == true {
            lastRelevantMouseDate = Date()
            refreshVisiblePanelIfNeeded()
            return
        }

        guard isNearDisplayEdge(appKitPoint) else {
            candidateBundleIdentifier = nil
            if Date().timeIntervalSince(lastRelevantMouseDate) > 0.28 { hidePanel() }
            return
        }

        let quartzPoint = CGEvent(source: nil)?.location ?? .zero
        if let hit = dockHit(at: quartzPoint) {
            lastRelevantMouseDate = Date()
            let previousDockFrame = currentDockFrame
            currentDockFrame = hit.appKitFrame
            if candidateBundleIdentifier != hit.bundleIdentifier {
                candidateBundleIdentifier = hit.bundleIdentifier
                candidateSince = Date()
                if currentBundleIdentifier != hit.bundleIdentifier { hidePanel(clearCandidate: false) }
            }
            if Date().timeIntervalSince(candidateSince) >= 0.4 {
                if currentBundleIdentifier == hit.bundleIdentifier, window?.isVisible == true {
                    if previousDockFrame != hit.appKitFrame { repositionPanel(for: hit.appKitFrame) }
                    refreshVisiblePanelIfNeeded()
                } else {
                    showPanel(for: hit.bundleIdentifier, dockFrame: hit.appKitFrame)
                }
            }
            return
        }

        candidateBundleIdentifier = nil
        if Date().timeIntervalSince(lastRelevantMouseDate) > 0.28 {
            hidePanel()
        }
    }

    private func refreshVisiblePanelIfNeeded() {
        guard let bundleIdentifier = currentBundleIdentifier,
              Date().timeIntervalSince(lastPanelRefresh) >= 0.75 else { return }
        let identities = store.dockPreviewWindows(bundleIdentifier: bundleIdentifier).map(\.identity)
        if identities != visibleWindowIdentities {
            showPanel(for: bundleIdentifier, dockFrame: currentDockFrame)
        }
    }

    private func showPanel(for bundleIdentifier: String, dockFrame: CGRect) {
        let windows = store.dockPreviewWindows(bundleIdentifier: bundleIdentifier)
        guard !windows.isEmpty, let panel = window else {
            hidePanel(clearCandidate: false)
            return
        }

        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cards.removeAll()

        for item in windows {
            let card = DockPreviewCard(window: item) { [weak self] in
                self?.activate(item)
            }
            cards[item.identity] = card
            stack.addArrangedSubview(card)
            let image = previewCache.image(for: item) { [weak self] identity, image in
                self?.cards[identity]?.updatePreview(image)
            }
            card.updatePreview(image)
        }

        let screen = NSScreen.screens.first { $0.frame.intersects(dockFrame) }
            ?? NSScreen.warpHardwareMain
        guard let screen else { return }
        let naturalWidth = CGFloat(windows.count * 238 + max(0, windows.count - 1) * 10 + 20)
        let width = min(max(258, naturalWidth), screen.visibleFrame.width - 24)
        panel.setContentSize(NSSize(width: width, height: 184))
        panel.setFrameOrigin(panelOrigin(size: panel.frame.size, dockFrame: dockFrame, screen: screen))
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        currentBundleIdentifier = bundleIdentifier
        currentDockFrame = dockFrame
        visibleWindowIdentities = windows.map(\.identity)
        lastPanelRefresh = Date()
    }

    private func activate(_ item: WarpWindow) {
        hidePanel()
        store.commit(item)
    }

    private func hidePanel(clearCandidate: Bool = true) {
        window?.orderOut(nil)
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        currentBundleIdentifier = nil
        visibleWindowIdentities = []
        cards.removeAll()
        if clearCandidate { candidateBundleIdentifier = nil }
    }

    private func repositionPanel(for dockFrame: CGRect) {
        guard let panel = window,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(dockFrame) })
                ?? NSScreen.warpHardwareMain else { return }
        panel.setFrameOrigin(panelOrigin(size: panel.frame.size, dockFrame: dockFrame, screen: screen))
    }

    private func isNearDisplayEdge(_ point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        let frame = screen.frame
        return min(
            abs(point.x - frame.minX),
            abs(frame.maxX - point.x),
            abs(point.y - frame.minY),
            abs(frame.maxY - point.y)
        ) <= 110
    }

    private func panelOrigin(size: CGSize, dockFrame: CGRect, screen: NSScreen) -> CGPoint {
        let frame = screen.visibleFrame
        let center = CGPoint(x: dockFrame.midX, y: dockFrame.midY)
        let distances: [(edge: CGRectEdge, value: CGFloat)] = [
            (.minXEdge, abs(center.x - screen.frame.minX)),
            (.maxXEdge, abs(screen.frame.maxX - center.x)),
            (.minYEdge, abs(center.y - screen.frame.minY)),
            (.maxYEdge, abs(screen.frame.maxY - center.y))
        ]
        let edge = distances.min(by: { $0.value < $1.value })?.edge ?? .minYEdge
        var origin: CGPoint
        switch edge {
        case .minXEdge:
            origin = CGPoint(x: dockFrame.maxX + 10, y: dockFrame.midY - size.height / 2)
        case .maxXEdge:
            origin = CGPoint(x: dockFrame.minX - size.width - 10, y: dockFrame.midY - size.height / 2)
        case .maxYEdge:
            origin = CGPoint(x: dockFrame.midX - size.width / 2, y: dockFrame.minY - size.height - 10)
        case .minYEdge:
            origin = CGPoint(x: dockFrame.midX - size.width / 2, y: dockFrame.maxY + 10)
        @unknown default:
            origin = CGPoint(x: dockFrame.midX - size.width / 2, y: dockFrame.maxY + 10)
        }
        origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
        origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        return origin
    }

    private func dockHit(at point: CGPoint) -> DockHit? {
        guard let list = dockListElement(),
              let items = attribute(list, kAXChildrenAttribute) as? [AXUIElement] else {
            dockList = nil
            return nil
        }
        for item in items {
            guard attribute(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
                  let frame = accessibilityFrame(of: item),
                  frame.insetBy(dx: -2, dy: -2).contains(point),
                  let bundleIdentifier = bundleIdentifier(for: item),
                  bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
            return DockHit(bundleIdentifier: bundleIdentifier, appKitFrame: appKitFrame(fromAccessibilityFrame: frame))
        }
        return nil
    }

    private func dockListElement() -> AXUIElement? {
        if let dockList { return dockList }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.08)
        let list = firstDescendant(of: application, role: kAXListRole, depth: 0)
        dockList = list
        return list
    }

    private func firstDescendant(of element: AXUIElement, role: String, depth: Int) -> AXUIElement? {
        guard depth < 4 else { return nil }
        if attribute(element, kAXRoleAttribute) as? String == role { return element }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let match = firstDescendant(of: child, role: role, depth: depth + 1) { return match }
        }
        return nil
    }

    private func bundleIdentifier(for item: AXUIElement) -> String? {
        if let url = attribute(item, kAXURLAttribute) as? URL,
           let identifier = Bundle(url: url)?.bundleIdentifier { return identifier }
        let title = attribute(item, kAXTitleAttribute) as? String
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.localizedName == title
        }
        return matches.count == 1 ? matches[0].bundleIdentifier : nil
    }

    private func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute).map({ $0 as! AXValue }),
              let sizeValue = attribute(element, kAXSizeAttribute).map({ $0 as! AXValue }) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func appKitFrame(fromAccessibilityFrame frame: CGRect) -> CGRect {
        let mainTop = NSScreen.warpHardwareMain?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: mainTop - frame.maxY, width: frame.width, height: frame.height)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

private final class DockPreviewCard: NSView {
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let fallbackIcon = NSImageView()
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(window: WarpWindow, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(window.title)")

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        imageView.layer?.cornerRadius = 7
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        fallbackIcon.image = window.icon
        fallbackIcon.imageScaling = .scaleProportionallyUpOrDown
        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(fallbackIcon)

        iconView.image = window.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = window.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(iconView)
        addSubview(titleLabel)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 238),
            heightAnchor.constraint(equalToConstant: 164),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.heightAnchor.constraint(equalToConstant: 122),
            fallbackIcon.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            fallbackIcon.widthAnchor.constraint(equalToConstant: 48),
            fallbackIcon.heightAnchor.constraint(equalToConstant: 48),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.32).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
    }

    override func mouseUp(with event: NSEvent) { onClick() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updatePreview(_ image: NSImage?) {
        imageView.image = image
        fallbackIcon.isHidden = image != nil
    }
}
