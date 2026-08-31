import AppKit

enum ScreenSelectionMode {
    case rectangle
    case point
}

enum ScreenSelectionResult {
    case rectangle(CGRect)
    case point(CGPoint)
}

@MainActor
final class ScreenSelectionController {
    private var overlays: [ScreenSelectionOverlayPanel] = []
    private var completion: ((ScreenSelectionResult?) -> Void)?
    private var mode: ScreenSelectionMode = .rectangle
    private var dragOrigin: CGPoint?
    private var selectionRect: CGRect?
    private var point: CGPoint?
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var cursorIsPushed = false

    var isSelecting: Bool { completion != nil }

    func begin(
        mode: ScreenSelectionMode,
        completion: @escaping (ScreenSelectionResult?) -> Void
    ) {
        cancel()
        self.mode = mode
        self.completion = completion

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            finish(nil)
            return
        }

        overlays = screens.map { screen in
            let panel = ScreenSelectionOverlayPanel(screen: screen)
            panel.selectionView.onMouseDown = { [weak self] point in self?.mouseDown(at: point) }
            panel.selectionView.onMouseDragged = { [weak self] point in self?.mouseDragged(to: point) }
            panel.selectionView.onMouseUp = { [weak self] point in self?.mouseUp(at: point) }
            panel.orderFrontRegardless()
            return panel
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }

        NSCursor.crosshair.push()
        cursorIsPushed = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        overlays.first?.makeKey()
    }

    func cancel() {
        guard completion != nil else { return }
        finish(nil)
    }

    private func mouseDown(at globalPoint: CGPoint) {
        dragOrigin = globalPoint
        point = globalPoint
        selectionRect = mode == .point ? nil : CGRect(origin: globalPoint, size: .zero)
        updateOverlays()
    }

    private func mouseDragged(to globalPoint: CGPoint) {
        point = globalPoint
        if mode == .rectangle, let dragOrigin {
            selectionRect = ScreenToolsGeometry.standardizedRect(from: dragOrigin, to: globalPoint)
        }
        updateOverlays()
    }

    private func mouseUp(at globalPoint: CGPoint) {
        point = globalPoint
        switch mode {
        case .point:
            finish(.point(globalPoint))
        case .rectangle:
            guard let dragOrigin else { finish(nil); return }
            let rectangle = ScreenToolsGeometry.standardizedRect(from: dragOrigin, to: globalPoint)
            finish(rectangle.width >= 2 && rectangle.height >= 2 ? .rectangle(rectangle) : nil)
        }
    }

    private func updateOverlays() {
        for overlay in overlays {
            overlay.selectionView.selectionRect = selectionRect
            overlay.selectionView.selectionPoint = point
            overlay.selectionView.mode = mode
            overlay.selectionView.needsDisplay = true
        }
    }

    private func finish(_ result: ScreenSelectionResult?) {
        let callback = completion
        completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        dragOrigin = nil
        selectionRect = nil
        point = nil
        if cursorIsPushed {
            NSCursor.pop()
            cursorIsPushed = false
        }
        callback?(result)
    }

}

private final class ScreenSelectionOverlayPanel: NSPanel {
    let selectionView = ScreenSelectionOverlayView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        contentView = selectionView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
}

private final class ScreenSelectionOverlayView: NSView {
    var mode: ScreenSelectionMode = .rectangle
    var selectionRect: CGRect?
    var selectionPoint: CGPoint?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let window else { return }
        if mode == .rectangle, let selectionRect {
            let windowRect = window.convertFromScreen(selectionRect)
            let localRect = convert(windowRect, from: nil).intersection(bounds)
            guard !localRect.isEmpty else { return }
            NSGraphicsContext.current?.cgContext.saveGState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            localRect.fill()
            NSGraphicsContext.current?.cgContext.restoreGState()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: localRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 2
            border.stroke()
        } else if mode == .point, let selectionPoint {
            let windowPoint = window.convertPoint(fromScreen: selectionPoint)
            let localPoint = convert(windowPoint, from: nil)
            guard bounds.insetBy(dx: -1, dy: -1).contains(localPoint) else { return }
            let clearRect = CGRect(x: localPoint.x - 9, y: localPoint.y - 9, width: 18, height: 18)
            NSGraphicsContext.current?.cgContext.saveGState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            NSBezierPath(ovalIn: clearRect).fill()
            NSGraphicsContext.current?.cgContext.restoreGState()
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: clearRect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(globalPoint(for: event)) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(globalPoint(for: event)) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(globalPoint(for: event)) }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
}
