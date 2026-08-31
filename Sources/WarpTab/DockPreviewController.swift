import AppKit
import ApplicationServices
import CoreGraphics

final class DockPreviewController: NSWindowController {
    fileprivate struct PreviewMetrics {
        struct CardLayout {
            let cardWidth: CGFloat
            let cardHeight: CGFloat
            let imageHeight: CGFloat
            let fallbackIconSize: CGFloat
        }

        let cardWidth: CGFloat
        let cardHeight: CGFloat
        let imageHeight: CGFloat
        let panelHeight: CGFloat
        let fallbackIconSize: CGFloat

        func cardLayout(for window: WarpWindow) -> CardLayout {
            let maximumImageWidth = cardWidth - 16
            let maximumImageHeight = imageHeight
            let bounds = window.bounds
            guard bounds.width > 0, bounds.height > 0 else {
                return CardLayout(
                    cardWidth: cardWidth,
                    cardHeight: cardHeight,
                    imageHeight: imageHeight,
                    fallbackIconSize: fallbackIconSize
                )
            }
            let scale = min(maximumImageWidth / bounds.width, maximumImageHeight / bounds.height)
            let fittedWidth = max(1, floor(bounds.width * scale))
            let fittedHeight = max(1, floor(bounds.height * scale))
            return CardLayout(
                cardWidth: fittedWidth + 16,
                cardHeight: fittedHeight + (cardHeight - imageHeight),
                imageHeight: fittedHeight,
                fallbackIconSize: min(fallbackIconSize, fittedWidth * 0.55, fittedHeight * 0.55)
            )
        }

        static func forSize(_ size: DockPreviewSize) -> PreviewMetrics {
            switch size {
            case .small:
                return PreviewMetrics(
                    cardWidth: 190,
                    cardHeight: 136,
                    imageHeight: 94,
                    panelHeight: 156,
                    fallbackIconSize: 40
                )
            case .default:
                return PreviewMetrics(
                    cardWidth: 238,
                    cardHeight: 164,
                    imageHeight: 122,
                    panelHeight: 184,
                    fallbackIconSize: 48
                )
            }
        }
    }

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
    private var mouseEventTap: CFMachPort?
    private var mouseEventRunLoopSource: CFRunLoopSource?
    private var lastMouseEventTapInstallAttempt = Date.distantPast
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dockList: AXUIElement?
    private var candidateBundleIdentifier: String?
    private var currentBundleIdentifier: String?
    private var currentDockFrame = CGRect.zero
    private var visibleWindowSignatures: [String] = []
    private var lastRelevantMouseDate = Date.distantPast
    private var lastPanelRefresh = Date.distantPast
    private var lastDockListRefresh = Date.distantPast
    private var stackHeightConstraint: NSLayoutConstraint!
    private var suppressedBundleIdentifier: String?
    private var pendingMinimizeBundleIdentifier: String?
    private var pendingMinimizeDockFrame: CGRect?
    private var interceptedMultiWindowBundleIdentifier: String?
    private var interceptedPanelButton: DockPressButton?
    private var interceptedPanelButtonFrame: CGRect?

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
        store.onDockPreviewChange = { [weak self] in
            self?.handleStoreChange()
        }
    }

    required init?(coder: NSCoder) { nil }

    func start() {
        guard timer == nil else { return }
        previewCache.prepare()
        // Keep hover presentation inside a single display frame without doing
        // Dock Accessibility work while this optional feature is disabled.
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.trackPointer()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        ensureMouseEventTap()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.resetDockAccessibilityState() },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.resetDockAccessibilityState() }
        ]
    }

    func updateAnimationsEnabled(_ enabled: Bool) {
        window?.animationBehavior = enabled ? .utilityWindow : .none
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let mouseEventRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseEventRunLoopSource, .commonModes)
        }
        mouseEventRunLoopSource = nil
        mouseEventTap = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        dockList = nil
        hidePanel()
    }

    private func configurePanel(_ panel: NSPanel) {
        panel.title = "Dock Window Previews"
        // Dock previews must remain clickable above notifications and the
        // full-screen Space chrome, while the nonactivating style preserves
        // focus in the user's current application.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = preferences.animationsEnabled ? .utilityWindow : .none
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
        stackHeightConstraint = stack.heightAnchor.constraint(equalToConstant: 174)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: effect.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stackHeightConstraint
        ])
        panel.contentView = effect
    }

    private func trackPointer() {
        ensureMouseEventTap()
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
            suppressedBundleIdentifier = nil
            if Date().timeIntervalSince(lastRelevantMouseDate) > 0.28,
               window?.isVisible == true || currentBundleIdentifier != nil {
                hidePanel()
            }
            return
        }

        let mainTop = NSScreen.warpHardwareMain?.frame.maxY ?? 0
        let quartzPoint = CGPoint(x: appKitPoint.x, y: mainTop - appKitPoint.y)

        // In a full-screen Space the Dock may retract as soon as our auxiliary
        // panel appears. Its AX item can then disappear for a few frames even
        // though the pointer has not left the icon. Preserve the known hit so
        // the preview remains stable instead of flickering or closing.
        if let bundleIdentifier = currentBundleIdentifier ?? candidateBundleIdentifier,
           currentDockFrame.insetBy(dx: -4, dy: -4).contains(appKitPoint) {
            if suppressedBundleIdentifier == bundleIdentifier {
                hidePanel(clearCandidate: false)
                return
            }
            candidateBundleIdentifier = bundleIdentifier
            lastRelevantMouseDate = Date()
            if window?.isVisible == true {
                refreshVisiblePanelIfNeeded()
            } else {
                showPanel(for: bundleIdentifier, dockFrame: currentDockFrame)
            }
            return
        }

        if let hit = dockHit(at: quartzPoint) {
            if suppressedBundleIdentifier == hit.bundleIdentifier {
                hidePanel(clearCandidate: false)
                return
            }
            suppressedBundleIdentifier = nil
            lastRelevantMouseDate = Date()
            let previousDockFrame = currentDockFrame
            currentDockFrame = hit.appKitFrame
            if candidateBundleIdentifier != hit.bundleIdentifier {
                candidateBundleIdentifier = hit.bundleIdentifier
                store.requestRefresh(immediate: true)
                if currentBundleIdentifier != hit.bundleIdentifier { hidePanel(clearCandidate: false) }
            }
            if currentBundleIdentifier == hit.bundleIdentifier, window?.isVisible == true {
                if previousDockFrame != hit.appKitFrame { repositionPanel(for: hit.appKitFrame) }
                refreshVisiblePanelIfNeeded()
            } else {
                showPanel(for: hit.bundleIdentifier, dockFrame: hit.appKitFrame)
            }
            return
        }

        candidateBundleIdentifier = nil
        suppressedBundleIdentifier = nil
        if Date().timeIntervalSince(lastRelevantMouseDate) > 0.28 {
            hidePanel()
        }
    }

    private func ensureMouseEventTap() {
        if let mouseEventTap {
            if !CGEvent.tapIsEnabled(tap: mouseEventTap) {
                CGEvent.tapEnable(tap: mouseEventTap, enable: true)
            }
            return
        }
        guard Date().timeIntervalSince(lastMouseEventTapInstallAttempt) >= 1 else { return }
        lastMouseEventTapInstallAttempt = Date()
        let mouseMask = [
            CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown
        ].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mouseMask,
            callback: warpTabDockMouseEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        mouseEventTap = tap
        mouseEventRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let mouseEventRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), mouseEventRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func handleMouseEvent(_ eventType: CGEventType, event: CGEvent) -> Bool {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let mouseEventTap { CGEvent.tapEnable(tap: mouseEventTap, enable: true) }
            return false
        }

        let quartzPoint = event.location
        let mainTop = NSScreen.warpHardwareMain?.frame.maxY ?? 0
        let appKitPoint = CGPoint(x: quartzPoint.x, y: mainTop - quartzPoint.y)

        if eventType == .leftMouseUp, let pressedButton = interceptedPanelButton {
            let pressedFrame = interceptedPanelButtonFrame
            interceptedPanelButton = nil
            interceptedPanelButtonFrame = nil
            // Complete preview actions on mouse-up, like a native button. In
            // particular, do not try to activate another Space/application
            // while the physical Dock click is still held down; macOS can
            // silently reject that activation for real trackpad/mouse input.
            // Retain the original button through the whole gesture. An AX
            // refresh may otherwise rebuild the card hierarchy between down
            // and up and silently discard the user's chosen window.
            if pressedFrame?.contains(appKitPoint) == true {
                DispatchQueue.main.async { pressedButton.performPress() }
            }
            return true
        }

        // Dock Accessibility can report the icon below a point that is visibly
        // inside our panel. Resolve preview controls before any Dock action;
        // consuming the pair also avoids AppKit losing a release when this
        // nonactivating panel is above a background application.
        if window?.isVisible == true,
           window?.frame.contains(appKitPoint) == true {
            if eventType == .leftMouseDown,
               let button = panelButton(at: appKitPoint) {
                interceptedPanelButton = button
                interceptedPanelButtonFrame = buttonFrameOnScreen(button)
                return true
            }
            return false
        }

        if eventType == .leftMouseUp {
            if interceptedMultiWindowBundleIdentifier != nil {
                interceptedMultiWindowBundleIdentifier = nil
                return true
            }
            defer {
                pendingMinimizeBundleIdentifier = nil
                pendingMinimizeDockFrame = nil
            }
            let consumedMouseDown = pendingMinimizeBundleIdentifier != nil
            guard let pendingBundleIdentifier = pendingMinimizeBundleIdentifier,
                  let pendingDockFrame = pendingMinimizeDockFrame,
                  pendingDockFrame.insetBy(dx: -3, dy: -3).contains(appKitPoint) else {
                return consumedMouseDown
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.minimizeFrontmostWindow(bundleIdentifier: pendingBundleIdentifier)
            }
            return true
        }

        let cachedHit = candidateBundleIdentifier.flatMap { bundleIdentifier in
            currentDockFrame.insetBy(dx: -3, dy: -3).contains(appKitPoint)
                ? DockHit(bundleIdentifier: bundleIdentifier, appKitFrame: currentDockFrame)
                : nil
        }
        guard let hit = cachedHit ?? dockHit(at: quartzPoint),
              hit.appKitFrame.insetBy(dx: -3, dy: -3).contains(appKitPoint) else {
            pendingMinimizeBundleIdentifier = nil
            pendingMinimizeDockFrame = nil
            interceptedMultiWindowBundleIdentifier = nil
            return false
        }

        if eventType == .leftMouseDown,
           preferences.dockPreviewsEnabled,
           preferences.minimizeAllWindowsOnDockDoubleClick,
           event.getIntegerValueField(.mouseEventClickState) >= 2 {
            let windows = store.allWindows().filter {
                $0.bundleIdentifier == hit.bundleIdentifier && !$0.isWindowlessApplication
            }
            if windows.count > 1 {
                pendingMinimizeBundleIdentifier = nil
                pendingMinimizeDockFrame = nil
                interceptedMultiWindowBundleIdentifier = hit.bundleIdentifier
                suppressedBundleIdentifier = hit.bundleIdentifier
                hidePanel()
                let bundleIdentifier = hit.bundleIdentifier
                DispatchQueue.main.async { [weak self] in
                    self?.minimizeWindowsForDoubleClick(bundleIdentifier: bundleIdentifier)
                }
                return true
            }
        }

        if eventType == .leftMouseDown,
           preferences.dockPreviewsEnabled,
           preferences.chooseWindowOnMultiWindowDockClick {
            let windows = store.dockPreviewWindows(bundleIdentifier: hit.bundleIdentifier)
            let visibleChooserHasMultipleWindows = currentBundleIdentifier == hit.bundleIdentifier &&
                window?.isVisible == true && visibleWindowSignatures.count > 1
            if windows.count > 1 || visibleChooserHasMultipleWindows {
                pendingMinimizeBundleIdentifier = nil
                pendingMinimizeDockFrame = nil
                interceptedMultiWindowBundleIdentifier = hit.bundleIdentifier
                suppressedBundleIdentifier = nil
                candidateBundleIdentifier = hit.bundleIdentifier
                currentDockFrame = hit.appKitFrame
                lastRelevantMouseDate = Date()
                let bundleIdentifier = hit.bundleIdentifier
                let dockFrame = hit.appKitFrame
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          interceptedMultiWindowBundleIdentifier == bundleIdentifier else { return }
                    showPanel(for: bundleIdentifier, dockFrame: dockFrame)
                }
                return true
            }
        }

        interceptedMultiWindowBundleIdentifier = nil
        suppressedBundleIdentifier = hit.bundleIdentifier
        hidePanel(clearCandidate: false)

        guard eventType == .leftMouseDown,
              preferences.dockPreviewsEnabled,
              preferences.minimizeFrontmostWindowOnDockClick,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == hit.bundleIdentifier else {
            pendingMinimizeBundleIdentifier = nil
            pendingMinimizeDockFrame = nil
            return false
        }
        pendingMinimizeBundleIdentifier = hit.bundleIdentifier
        pendingMinimizeDockFrame = hit.appKitFrame
        return true
    }

    private func minimizeFrontmostWindow(bundleIdentifier: String) {
        guard preferences.minimizeFrontmostWindowOnDockClick,
              let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == bundleIdentifier else { return }
        let candidates = store.allWindows().filter {
            $0.application.processIdentifier == application.processIdentifier &&
                !$0.isMinimized && !$0.isWindowlessApplication
        }
        guard !candidates.isEmpty else { return }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let focusedElement = warpAXElement(attribute(applicationElement, kAXFocusedWindowAttribute))
        let target = focusedElement.flatMap { focused in
            candidates.first { candidate in
                candidate.axWindow.map { CFEqual($0, focused) } ?? false
            }
        } ?? candidates.first(where: \.isFocused) ?? candidates.max {
            ($0.lastFocusedAt ?? .distantPast) < ($1.lastFocusedAt ?? .distantPast)
        }
        guard let target else { return }
        store.activator.minimize(target)
        store.requestRefresh(immediate: true)
    }

    private func minimizeWindowsForDoubleClick(bundleIdentifier: String) {
        guard preferences.minimizeAllWindowsOnDockDoubleClick else { return }
        let candidates = store.allWindows().filter {
            $0.bundleIdentifier == bundleIdentifier && !$0.isMinimized && !$0.isWindowlessApplication
        }
        guard !candidates.isEmpty else { return }
        switch preferences.dockDoubleClickMinimizeScope {
        case .allWindows:
            candidates.forEach(store.activator.minimize)
        case .topWindow:
            guard let target = topWindow(in: candidates) else { return }
            store.activator.minimize(target)
        }
        store.requestRefresh(immediate: true)
    }

    private func topWindow(in candidates: [WarpWindow]) -> WarpWindow? {
        guard let application = candidates.first?.application else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let focusedElement = warpAXElement(attribute(applicationElement, kAXFocusedWindowAttribute))
        return focusedElement.flatMap { focused in
            candidates.first { candidate in
                candidate.axWindow.map { CFEqual($0, focused) } ?? false
            }
        } ?? candidates.first(where: \.isFocused) ?? candidates.max {
            ($0.lastFocusedAt ?? .distantPast) < ($1.lastFocusedAt ?? .distantPast)
        }
    }

    private func resetDockAccessibilityState() {
        dockList = nil
        lastDockListRefresh = .distantPast
        candidateBundleIdentifier = nil
        suppressedBundleIdentifier = nil
        hidePanel()
    }

    private func handleStoreChange() {
        guard currentBundleIdentifier != nil, window?.isVisible == true else { return }
        refreshVisiblePanelIfNeeded(forceRefresh: true)
    }

    private func refreshVisiblePanelIfNeeded(forceRefresh: Bool = false) {
        // Preserve an in-flight native click. Rebuilding the arranged views
        // here used to release the pressed card before mouse-up.
        guard interceptedPanelButton == nil else { return }
        guard let bundleIdentifier = currentBundleIdentifier,
              forceRefresh || Date().timeIntervalSince(lastPanelRefresh) >= 0.45 else { return }
        let windows = store.dockPreviewWindows(bundleIdentifier: bundleIdentifier)
        let application = windows.isEmpty && isKnownWindowless(bundleIdentifier: bundleIdentifier)
            ? runningApplication(bundleIdentifier: bundleIdentifier)
            : nil
        guard !windows.isEmpty || application != nil else {
            hidePanel()
            return
        }
        let signatures = windows.isEmpty
            ? ["empty:\(application?.processIdentifier ?? 0)"]
            : windows.map(windowSignature)
        if signatures != visibleWindowSignatures {
            showPanel(for: bundleIdentifier, dockFrame: currentDockFrame)
        } else {
            // Restoring focus after a background close can reorder windows from
            // another process above this nonactivating panel. Reassert its menu
            // level without activating WarpTab so the visible cards remain the
            // actual click target.
            window?.orderFrontRegardless()
            refreshPreviews(for: windows, forceRefresh: true)
            lastPanelRefresh = Date()
        }
    }

    private func refreshPreviews(for windows: [WarpWindow], forceRefresh: Bool) {
        // The stack can contain many windows, but the scroller displays only a
        // handful. Capture the visible cards plus one card of prefetch on each
        // side so large-window apps do not continuously allocate screenshots
        // that the user cannot see.
        let prefetchWidth = PreviewMetrics.forSize(preferences.dockPreviewSize).cardWidth + stack.spacing
        let captureRect = scrollView.documentVisibleRect.insetBy(dx: -prefetchWidth, dy: 0)
        for item in windows {
            guard let card = cards[item.identity], card.frame.intersects(captureRect) else { continue }
            let image = previewCache.image(for: item, forceRefresh: forceRefresh) { [weak self] identity, image in
                self?.cards[identity]?.updatePreview(image)
            }
            if let image { card.updatePreview(image) }
        }
    }

    private func showPanel(for bundleIdentifier: String, dockFrame: CGRect) {
        guard preferences.dockPreviewsEnabled else {
            hidePanel()
            return
        }
        let windows = store.dockPreviewWindows(bundleIdentifier: bundleIdentifier)
        let emptyApplication = windows.isEmpty && isKnownWindowless(bundleIdentifier: bundleIdentifier)
            ? runningApplication(bundleIdentifier: bundleIdentifier)
            : nil
        guard (!windows.isEmpty || emptyApplication != nil), let panel = window else {
            hidePanel(clearCandidate: false)
            return
        }

        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cards.removeAll()

        let metrics = PreviewMetrics.forSize(preferences.dockPreviewSize)
        let cardLayouts = windows.map(metrics.cardLayout)
        if let emptyApplication {
            let card = DockEmptyPreviewCard(application: emptyApplication) { [weak self, weak emptyApplication] in
                self?.hidePanel()
                emptyApplication?.activate(options: [.activateIgnoringOtherApps])
            }
            stack.addArrangedSubview(card)
        } else {
            for (item, layout) in zip(windows, cardLayouts) {
                let card = DockPreviewCard(
                    window: item,
                    layout: layout,
                    showsCloseButton: preferences.dockPreviewCloseEnabled,
                    onClick: { [weak self] in self?.activate(item) },
                    onClose: { [weak self] in self?.close(item) }
                )
                cards[item.identity] = card
                stack.addArrangedSubview(card)
            }
        }

        let screen = NSScreen.screens.first { $0.frame.intersects(dockFrame) }
            ?? NSScreen.warpHardwareMain
        guard let screen else { return }
        let naturalWidth = emptyApplication == nil
            ? cardLayouts.reduce(0) { $0 + $1.cardWidth }
                + CGFloat(max(0, windows.count - 1)) * stack.spacing + 20
            : 210
        let minimumWidth = emptyApplication == nil
            ? (cardLayouts.first?.cardWidth ?? metrics.cardWidth) + 20
            : 210
        let width = min(max(minimumWidth, naturalWidth), screen.visibleFrame.width - 24)
        let panelHeight = emptyApplication == nil ? metrics.panelHeight : CGFloat(112)
        stackHeightConstraint.constant = panelHeight - 10
        panel.setContentSize(NSSize(width: width, height: panelHeight))
        panel.setFrameOrigin(panelOrigin(size: panel.frame.size, dockFrame: dockFrame, screen: screen))
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        if !windows.isEmpty {
            refreshPreviews(for: windows, forceRefresh: true)
        }
        currentBundleIdentifier = bundleIdentifier
        currentDockFrame = dockFrame
        visibleWindowSignatures = windows.isEmpty
            ? ["empty:\(emptyApplication?.processIdentifier ?? 0)"]
            : windows.map(windowSignature)
        lastPanelRefresh = Date()
    }

    private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated && $0.activationPolicy == .regular }
    }

    private func isKnownWindowless(bundleIdentifier: String) -> Bool {
        store.allWindows().contains {
            $0.bundleIdentifier == bundleIdentifier && $0.isWindowlessApplication
        }
    }

    private func activate(_ item: WarpWindow) {
        let target = latestWindow(matching: item)
        hidePanel()
        store.commit(target)
    }

    private func close(_ item: WarpWindow) {
        let item = latestWindow(matching: item)
        let bundleIdentifier = item.bundleIdentifier
        let processIdentifier = item.application.processIdentifier
        let previousFocus = store.activator.captureFocus()
        let wasLastWindow = bundleIdentifier.map {
            store.dockPreviewWindows(bundleIdentifier: $0)
                .filter { $0.application.processIdentifier == processIdentifier }
                .count == 1
        } ?? false

        store.activator.close(item)
        store.requestRefresh(immediate: true)

        // Pressing a background window's AX close button can make that app's
        // next window key. Put the user back exactly where they were instead of
        // allowing the remaining sibling windows to come forward.
        if let previousFocus,
           previousFocus.application.processIdentifier != processIdentifier {
            for delay in [0.06, 0.24] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != previousFocus.application.processIdentifier || delay < 0.1 {
                        store.activator.restoreFocus(previousFocus)
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            store.requestRefresh(immediate: true)
            if currentBundleIdentifier == bundleIdentifier,
               bundleIdentifier != nil {
                // The observer-driven store refresh may already have rebuilt
                // the cards. Avoid replacing the view hierarchy between a
                // user's mouse-down and mouse-up on the next preview.
                refreshVisiblePanelIfNeeded(forceRefresh: true)
            }
        }

        guard wasLastWindow, preferences.quitAppWhenLastWindowClosed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self, application = item.application] in
            guard let self,
                  !application.isTerminated,
                  !hasOpenWindows(application) else { return }
            application.terminate()
            hidePanel()
        }
    }

    private func latestWindow(matching item: WarpWindow) -> WarpWindow {
        guard let bundleIdentifier = item.bundleIdentifier else { return item }
        let candidates = store.dockPreviewWindows(bundleIdentifier: bundleIdentifier)
            .filter { $0.application.processIdentifier == item.application.processIdentifier }
        if let exact = candidates.first(where: { $0.identity == item.identity }) { return exact }

        // A WindowServer id is stronger than a title. Browsers, Finder and
        // document apps routinely expose several blank or identical titles;
        // selecting the first title match can therefore open a sibling card.
        if let windowID = item.windowID {
            let matchingID = candidates.filter { $0.windowID == windowID }
            if matchingID.count == 1, let match = matchingID.first { return match }
        }
        let expectedTitle = item.rawTitle ?? ""
        let matchingTitles = candidates.filter {
            ($0.rawTitle ?? "") == expectedTitle && ($0.axTab != nil) == (item.axTab != nil)
        }
        if matchingTitles.count == 1, let match = matchingTitles.first { return match }
        return item
    }

    private func panelButton(at appKitPoint: CGPoint) -> DockPressButton? {
        guard let panel = window,
              panel.isVisible,
              panel.frame.contains(appKitPoint),
              let content = panel.contentView else { return nil }
        let windowPoint = panel.convertPoint(fromScreen: appKitPoint)
        let contentPoint = content.convert(windowPoint, from: nil)
        return content.hitTest(contentPoint) as? DockPressButton
    }

    private func buttonFrameOnScreen(_ button: DockPressButton) -> CGRect? {
        guard let panel = window, button.window === panel else { return nil }
        return panel.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func hasOpenWindows(_ application: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.contains { window in
            guard attribute(window, kAXRoleAttribute) as? String == kAXWindowRole else { return false }
            let subrole = attribute(window, kAXSubroleAttribute) as? String
            return subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        }
    }

    private func hidePanel(clearCandidate: Bool = true) {
        guard window?.isVisible == true || currentBundleIdentifier != nil || !cards.isEmpty else {
            if clearCandidate { candidateBundleIdentifier = nil }
            return
        }
        window?.orderOut(nil)
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        currentBundleIdentifier = nil
        visibleWindowSignatures = []
        cards.removeAll()
        if clearCandidate { candidateBundleIdentifier = nil }
    }

    private func repositionPanel(for dockFrame: CGRect) {
        guard let panel = window,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(dockFrame) })
                ?? NSScreen.warpHardwareMain else { return }
        panel.setFrameOrigin(panelOrigin(size: panel.frame.size, dockFrame: dockFrame, screen: screen))
    }

    private func windowSignature(_ window: WarpWindow) -> String {
        "\(window.identity)|\(window.title)|\(window.windowID ?? 0)|\(window.isMinimized)|\(window.isHidden)|\(window.isFullscreen)"
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
        if let list = dockListElement(), let hit = dockHit(at: point, in: list) { return hit }
        guard Date().timeIntervalSince(lastDockListRefresh) >= 0.5 else { return nil }
        dockList = nil
        lastDockListRefresh = Date()
        if let refreshedList = dockListElement(), let hit = dockHit(at: point, in: refreshedList) {
            return hit
        }

        // Full-screen and auto-hidden Dock layouts do not always expose the
        // application items as direct children of the first AXList. Use a
        // bounded hierarchy fallback only when the fast path misses.
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.08)
        return dockHit(at: point, inHierarchy: application, depth: 0)
    }

    private func dockHit(at point: CGPoint, inHierarchy element: AXUIElement, depth: Int) -> DockHit? {
        guard depth < 7 else { return nil }
        if attribute(element, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
           let frame = accessibilityFrame(of: element),
           frame.insetBy(dx: -3, dy: -3).contains(point),
           let bundleIdentifier = bundleIdentifier(for: element),
           bundleIdentifier != Bundle.main.bundleIdentifier {
            return DockHit(bundleIdentifier: bundleIdentifier, appKitFrame: appKitFrame(fromAccessibilityFrame: frame))
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let hit = dockHit(at: point, inHierarchy: child, depth: depth + 1) { return hit }
        }
        return nil
    }

    private func dockHit(at point: CGPoint, in list: AXUIElement) -> DockHit? {
        guard let items = attribute(list, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
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
        guard let positionValue = warpAXValue(attribute(element, kAXPositionAttribute)),
              let sizeValue = warpAXValue(attribute(element, kAXSizeAttribute)) else { return nil }
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

private final class DockEmptyPreviewCard: NSView {
    init(application: NSRunningApplication, onClick: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(application.localizedName ?? "application")")

        let clickButton = DockPressButton(action: onClick)
        clickButton.isBordered = false
        clickButton.title = ""
        clickButton.focusRingType = .none
        clickButton.translatesAutoresizingMaskIntoConstraints = false
        clickButton.setAccessibilityElement(false)

        let icon = DockDecorationImageView(image: application.icon ?? AppIcon.make())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = DockDecorationTextField(labelWithString: application.localizedName ?? "Application")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let message = DockDecorationTextField(labelWithString: "No window open")
        message.font = .systemFont(ofSize: 11, weight: .regular)
        message.textColor = .secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [title, message])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(clickButton)
        addSubview(icon)
        addSubview(labels)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 190),
            heightAnchor.constraint(equalToConstant: 92),
            clickButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickButton.topAnchor.constraint(equalTo: topAnchor),
            clickButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 42),
            icon.heightAnchor.constraint(equalToConstant: 42),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class DockPreviewCard: NSView {
    private let imageView = DockDecorationImageView()
    private let titleLabel = DockDecorationTextField(labelWithString: "")
    private let iconView = DockDecorationImageView()
    private let fallbackIcon = DockDecorationImageView()
    private var trackingArea: NSTrackingArea?

    init(
        window: WarpWindow,
        layout: DockPreviewController.PreviewMetrics.CardLayout,
        showsCloseButton: Bool,
        onClick: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
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
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
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

        let clickButton = DockPressButton(action: onClick)
        clickButton.isBordered = false
        clickButton.title = ""
        clickButton.focusRingType = .none
        clickButton.translatesAutoresizingMaskIntoConstraints = false
        clickButton.setAccessibilityElement(false)

        addSubview(clickButton)
        addSubview(imageView)
        addSubview(iconView)
        addSubview(titleLabel)
        let closeButton: NSButton? = showsCloseButton ? makeCloseButton(window: window, action: onClose) : nil
        if let closeButton { addSubview(closeButton) }
        translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            widthAnchor.constraint(equalToConstant: layout.cardWidth),
            heightAnchor.constraint(equalToConstant: layout.cardHeight),
            clickButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickButton.topAnchor.constraint(equalTo: topAnchor),
            clickButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.heightAnchor.constraint(equalToConstant: layout.imageHeight),
            fallbackIcon.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            fallbackIcon.widthAnchor.constraint(equalToConstant: layout.fallbackIconSize),
            fallbackIcon.heightAnchor.constraint(equalToConstant: layout.fallbackIconSize),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor)
        ]
        if let closeButton {
            constraints += [
                closeButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 7),
                closeButton.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -7),
                closeButton.widthAnchor.constraint(equalToConstant: 22),
                closeButton.heightAnchor.constraint(equalToConstant: 22)
            ]
        }
        NSLayoutConstraint.activate(constraints)
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

    private func makeCloseButton(window: WarpWindow, action: @escaping () -> Void) -> NSButton {
        let button = DockPressButton(action: action)
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close window")
        button.imageScaling = .scaleProportionallyUpOrDown
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel("Close \(window.title)")
        button.toolTip = "Close \(window.title)"
        return button
    }

    func updatePreview(_ image: NSImage?) {
        imageView.image = image
        fallbackIcon.isHidden = image != nil
    }
}

private final class DockDecorationImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DockDecorationTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DockPressButton: NSButton {
    private let callback: () -> Void

    init(action: @escaping () -> Void) {
        callback = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(invokeNativePress(_:))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func invokeNativePress(_ sender: Any?) { performPress() }
    func performPress() { callback() }
}

private func warpTabDockMouseEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<DockPreviewController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handleMouseEvent(type, event: event) ? nil : Unmanaged.passUnretained(event)
}
