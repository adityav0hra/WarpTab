import AppKit
import ApplicationServices
import CoreGraphics

final class WindowRestoreStore {
    private var frames: [String: CGRect] = [:]

    func remember(_ frame: CGRect, for identity: String) {
        frames[identity] = frame
        if frames.count > 256, let first = frames.keys.first { frames.removeValue(forKey: first) }
    }

    func rememberIfAbsent(_ frame: CGRect, for identity: String) {
        if frames[identity] == nil { remember(frame, for: identity) }
    }

    func frame(for identity: String) -> CGRect? { frames[identity] }

    func forget(_ identity: String) { frames.removeValue(forKey: identity) }
}

private struct SnapDisplay {
    let snapshot: DisplaySnapshot
    let workArea: CGRect
}

final class ScreenGeometryService {
    func displays() -> [DisplaySnapshot] {
        let primaryTop = NSScreen.warpHardwareMain?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { screen in
            DisplaySnapshot(
                identifier: screen.warpIdentifier,
                frame: Self.appKitToAccessibility(screen.frame, primaryTop: primaryTop),
                visibleFrame: Self.appKitToAccessibility(screen.visibleFrame, primaryTop: primaryTop),
                scale: screen.backingScaleFactor
            )
        }
    }

    func display(containingLargestAreaOf windowFrame: CGRect) -> DisplaySnapshot? {
        ScreenSpatialGeometry.screenContainingLargestArea(of: windowFrame, screens: displays())
    }

    func adjacentDisplay(
        to display: DisplaySnapshot,
        direction: SnapDirection
    ) -> DisplaySnapshot? {
        ScreenSpatialGeometry.adjacentScreen(to: display, direction: direction, screens: displays())
    }

    static func appKitToAccessibility(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        ScreenCoordinateGeometry.appKitToAccessibility(frame, primaryTop: primaryTop)
    }

    static func accessibilityToAppKit(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        ScreenCoordinateGeometry.accessibilityToAppKit(frame, primaryTop: primaryTop)
    }
}

final class WindowSnapManager {
    private struct PendingMinimizedWindow {
        let window: WarpWindow
        let element: AXUIElement
    }

    private let store: WindowStore
    private let restoreStore: WindowRestoreStore
    private let screenGeometry: ScreenGeometryService
    private let snapAssist: SnapAssistController
    private var pendingMinimizedWindow: PendingMinimizedWindow?

    init(
        store: WindowStore,
        previewCache: PreviewCache = PreviewCache(),
        restoreStore: WindowRestoreStore = WindowRestoreStore(),
        screenGeometry: ScreenGeometryService = ScreenGeometryService()
    ) {
        self.store = store
        self.snapAssist = SnapAssistController(previewCache: previewCache)
        self.restoreStore = restoreStore
        self.screenGeometry = screenGeometry
    }

    @discardableResult
    func move(_ direction: SnapDirection) -> Bool {
        if direction == .up,
           store.preferences.snapUpAfterMinimizeBehavior == .restoreMinimizedWindow,
           restorePendingMinimizedWindow() {
            return true
        }
        if direction == .up, store.preferences.snapUpAfterMinimizeBehavior == .controlActiveWindow {
            pendingMinimizedWindow = nil
        }
        if direction != .up { pendingMinimizedWindow = nil }

        guard AXIsProcessTrusted(),
              let window = store.focusedWindow(),
              let element = window.axWindow,
              isEligible(element),
              let currentFrame = frame(of: element),
              let currentDisplay = screenGeometry.display(containingLargestAreaOf: currentFrame) else {
            return false
        }

        let identity = windowIdentity(element)
        let minimized = (attribute(element, kAXMinimizedAttribute) as? NSNumber)?.boolValue ?? false
        let currentState = minimized
            ? SnapState.minimized
            : SnapGeometry.recognizedState(for: currentFrame, in: currentDisplay.visibleFrame)
        if currentState == .floating { restoreStore.remember(currentFrame, for: identity) }

        let adjacent = store.preferences.windowSnapMoveAcrossDisplays
            ? screenGeometry.adjacentDisplay(to: currentDisplay, direction: direction)
            : nil
        let transition = SnapStateMachine.transition(
            from: currentState,
            direction: direction,
            hasAdjacentDisplay: adjacent != nil
        )
        if transition.action == .place(.maximized) {
            restoreStore.rememberIfAbsent(currentFrame, for: identity)
        }
        let targetDisplay = transition.movesToAdjacentDisplay ? (adjacent ?? currentDisplay) : currentDisplay

        switch transition.action {
        case .place(let state):
            guard let target = SnapGeometry.frame(for: state, in: targetDisplay.visibleFrame) else { return false }
            _ = setBoolean(false, attribute: kAXMinimizedAttribute, on: element)
            _ = setBoolean(false, attribute: "AXZoomed", on: element)
            let placed = setFrame(target, on: element)
            if placed { showSnapAssist(afterPlacing: state, currentWindow: window, display: targetDisplay) }
            return placed
        case .restore:
            if let restoreFrame = restoreStore.frame(for: identity) {
                _ = setBoolean(false, attribute: "AXZoomed", on: element)
                let restored = setFrame(restoreFrame, on: element)
                if restored { restoreStore.forget(identity) }
                return restored
            }
            // A window maximized outside WarpTab has no frame in our per-window
            // restore store. AXZoomed is the only API macOS exposes for asking the
            // owning application to recover its own previous frame.
            return setBoolean(false, attribute: "AXZoomed", on: element)
        case .minimize:
            return minimize(window, element: element)
        }
    }

    func handleSnapAssistMouseDown(at point: CGPoint) -> Bool {
        snapAssist.handleMouseDown(at: point)
    }

    private func minimize(_ window: WarpWindow, element: AXUIElement) -> Bool {
        let nextWindow = store.preferences.snapMinimizeFocusBehavior == .activateWindowBehind
            ? windowBehind(excluding: element)
            : nil
        guard setBoolean(true, attribute: kAXMinimizedAttribute, on: element) else { return false }
        pendingMinimizedWindow = store.preferences.snapUpAfterMinimizeBehavior == .restoreMinimizedWindow
            ? PendingMinimizedWindow(window: window, element: element)
            : nil
        if let nextWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak store] in
                store?.activator.activate(nextWindow)
            }
        }
        return true
    }

    private func restorePendingMinimizedWindow() -> Bool {
        guard let pending = pendingMinimizedWindow else { return false }
        pendingMinimizedWindow = nil
        guard !pending.window.application.isTerminated,
              (attribute(pending.element, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true else {
            return false
        }
        store.activator.activate(pending.window)
        return true
    }

    private func windowBehind(excluding currentElement: AXUIElement) -> WarpWindow? {
        let candidates = store.allWindows().filter { candidate in
            guard let element = candidate.axWindow,
                  !CFEqual(element, currentElement),
                  !candidate.isWindowlessApplication,
                  !candidate.isMinimized,
                  !candidate.isHidden,
                  !candidate.isFullscreen,
                  candidate.isOnScreen,
                  !candidate.application.isTerminated else { return false }
            return true
        }
        return store.mru.ordered(candidates).first
    }

    private func showSnapAssist(
        afterPlacing state: SnapState,
        currentWindow: WarpWindow,
        display: DisplaySnapshot
    ) {
        guard store.preferences.windowSnapAssistEnabled else { return }
        let complementaryState: SnapState? = switch state {
        case .leftHalf, .topLeft, .bottomLeft: .rightHalf
        case .rightHalf, .topRight, .bottomRight: .leftHalf
        case .floating, .maximized, .minimized: nil
        }
        guard let complementaryState,
              let region = SnapGeometry.frame(for: complementaryState, in: display.visibleFrame) else { return }
        let currentElement = currentWindow.axWindow
        let candidates = store.allWindows().filter { candidate in
            guard let element = candidate.axWindow else { return false }
            return currentElement.map { !CFEqual($0, element) } ?? true
        }
        snapAssist.show(
            in: region,
            candidates: candidates,
            layout: store.preferences.snapAssistLayout
        ) { [weak self] candidate in
            guard let self, let element = candidate.axWindow else { return }
            self.store.activator.activate(candidate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                _ = self.setBoolean(false, attribute: kAXMinimizedAttribute, on: element)
                _ = self.setBoolean(false, attribute: "AXZoomed", on: element)
                _ = self.setFrame(region, on: element)
            }
        }
    }

    private func isEligible(_ element: AXUIElement) -> Bool {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier != ProcessInfo.processInfo.processIdentifier,
              attribute(element, kAXRoleAttribute) as? String == kAXWindowRole else { return false }
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        guard subrole == nil || subrole == kAXStandardWindowSubrole else { return false }
        return isSettable(kAXPositionAttribute, on: element) && isSettable(kAXSizeAttribute, on: element)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func setFrame(_ requestedFrame: CGRect, on element: AXUIElement) -> Bool {
        var size = requestedFrame.size
        var position = requestedFrame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else { return false }

        // Applications enforce their own min/max sizes. Applying size before
        // position and then anchoring again leaves constrained windows as close
        // as their AX implementation permits to the requested snap region.
        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let positionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        if sizeResult == .success {
            _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        }
        return sizeResult == .success || positionResult == .success
    }

    private func setBoolean(_ value: Bool, attribute: String, on element: AXUIElement) -> Bool {
        guard isSettable(attribute, on: element) else { return false }
        let raw = value ? kCFBooleanTrue! : kCFBooleanFalse!
        return AXUIElementSetAttributeValue(element, attribute as CFString, raw) == .success
    }

    private func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func windowIdentity(_ element: AXUIElement) -> String {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        return "\(processIdentifier):ax:\(CFHash(element))"
    }
}
