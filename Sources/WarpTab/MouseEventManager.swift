import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum MouseScrollClassifier {
    /// Public CGEvents do not include a source-device identifier. Line-based
    /// wheel events are the only conservative signal that excludes trackpads.
    static func isPhysicalMouseScroll(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
    }
}

final class MouseEventManager {
    private let settings: MouseSettings
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var captureHandler: ((MouseInput) -> Void)?
    private var suppressedButtonUps = Set<Int64>()
    private var lastSideWheelExecution: (input: MouseInput, timestamp: CFTimeInterval)?
    private var hasLoggedStartFailure = false

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    var isCapturingInput: Bool { captureHandler != nil }

    init(settings: MouseSettings) {
        self.settings = settings
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = [CGEventType.scrollWheel, .otherMouseDown, .otherMouseUp].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseEventCallback,
            userInfo: pointer
        )
        guard let eventTap else {
            if !hasLoggedStartFailure {
                NSLog("WarpTab Mouse: event tap unavailable; normal mouse behavior is unchanged")
                hasLoggedStartFailure = true
            }
            return false
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource else {
            self.eventTap = nil
            if !hasLoggedStartFailure {
                NSLog("WarpTab Mouse: could not create event-tap run-loop source")
                hasLoggedStartFailure = true
            }
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        hasLoggedStartFailure = false
        return isRunning
    }

    func stop() {
        cancelCapture()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        suppressedButtonUps.removeAll()
        lastSideWheelExecution = nil
    }

    func beginCapture(_ handler: @escaping (MouseInput) -> Void) {
        captureHandler = handler
    }

    func cancelCapture() {
        captureHandler = nil
    }

    fileprivate func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            NSLog("WarpTab Mouse: event tap was disabled and has been re-enabled")
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .otherMouseDown:
            return processButtonDown(event)
        case .otherMouseUp:
            return processButtonUp(event)
        case .scrollWheel:
            return processScroll(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func processButtonDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        guard buttonNumber >= 3 else { return Unmanaged.passUnretained(event) }
        let input = MouseInput.button(buttonNumber)

        if let captureHandler {
            self.captureHandler = nil
            suppressedButtonUps.insert(buttonNumber)
            DispatchQueue.main.async { captureHandler(input) }
            return nil
        }

        guard let action = settings.action(for: input) else {
            return Unmanaged.passUnretained(event)
        }
        suppressedButtonUps.insert(buttonNumber)
        execute(action)
        return nil
    }

    private func processButtonUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        return suppressedButtonUps.remove(buttonNumber) != nil ? nil : Unmanaged.passUnretained(event)
    }

    private func processScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard MouseScrollClassifier.isPhysicalMouseScroll(event) else {
            return Unmanaged.passUnretained(event)
        }

        let horizontalDelta = scrollDelta(event, axis: 2)
        if horizontalDelta != 0 {
            let input = MouseInput.sideWheel(horizontalDelta > 0 ? .right : .left)
            if let captureHandler {
                self.captureHandler = nil
                DispatchQueue.main.async { captureHandler(input) }
                return nil
            }
            if let action = settings.action(for: input) {
                executeSideWheelAction(action, input: input)
                return nil
            }
        }

        if settings.reverseVerticalScrolling { reverseScrollAxis(1, in: event) }
        if settings.reverseHorizontalScrolling { reverseScrollAxis(2, in: event) }
        return Unmanaged.passUnretained(event)
    }

    private func executeSideWheelAction(_ action: MouseAction, input: MouseInput) {
        let now = CFAbsoluteTimeGetCurrent()
        if let previous = lastSideWheelExecution,
           previous.input == input,
           now - previous.timestamp < 0.08 {
            return
        }
        lastSideWheelExecution = (input, now)
        execute(action)
    }

    private func execute(_ action: MouseAction) {
        switch action {
        case .keyboardShortcut(let shortcut):
            postKeyboardShortcut(shortcut)
        case .back:
            postKeyboardShortcut(MouseKeyboardShortcut(
                keyCode: UInt16(kVK_ANSI_LeftBracket),
                carbonModifiers: UInt32(cmdKey),
                keyLabel: "["
            ))
        case .forward:
            postKeyboardShortcut(MouseKeyboardShortcut(
                keyCode: UInt16(kVK_ANSI_RightBracket),
                carbonModifiers: UInt32(cmdKey),
                keyLabel: "]"
            ))
        case .none:
            break
        case .system, .warpTab:
            // These cases make the persisted action model extensible. They are
            // not exposed by the UI until an executor exists for each action.
            NSLog("WarpTab Mouse: unsupported stored mouse action ignored")
        }
    }

    private func postKeyboardShortcut(_ shortcut: MouseKeyboardShortcut) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(shortcut.keyCode),
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(shortcut.keyCode),
                keyDown: false
              ) else {
            NSLog("WarpTab Mouse: could not create keyboard shortcut events")
            return
        }
        let flags = eventFlags(from: shortcut.carbonModifiers)
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func eventFlags(from modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        return flags
    }

    private func scrollDelta(_ event: CGEvent, axis: Int) -> Int64 {
        let rawField: CGEventField = axis == 1 ? .scrollWheelEventRawDeltaAxis1 : .scrollWheelEventRawDeltaAxis2
        let standardField: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        let raw = event.getIntegerValueField(rawField)
        return raw != 0 ? raw : event.getIntegerValueField(standardField)
    }

    private func reverseScrollAxis(_ axis: Int, in event: CGEvent) {
        let fields: [CGEventField]
        if axis == 1 {
            fields = [
                .scrollWheelEventDeltaAxis1,
                .scrollWheelEventFixedPtDeltaAxis1,
                .scrollWheelEventPointDeltaAxis1,
                .scrollWheelEventAcceleratedDeltaAxis1,
                .scrollWheelEventRawDeltaAxis1
            ]
        } else {
            fields = [
                .scrollWheelEventDeltaAxis2,
                .scrollWheelEventFixedPtDeltaAxis2,
                .scrollWheelEventPointDeltaAxis2,
                .scrollWheelEventAcceleratedDeltaAxis2,
                .scrollWheelEventRawDeltaAxis2
            ]
        }
        for field in fields {
            let value = event.getIntegerValueField(field)
            event.setIntegerValueField(field, value: value == .min ? .max : -value)
        }
    }
}

private func mouseEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<MouseEventManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.process(type: type, event: event)
}
