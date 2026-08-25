import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum ShortcutEvent {
    case cycle(backwards: Bool, scope: SwitcherWindowScope)
    case navigate(SwitcherNavigation)
    case searchCharacter(String)
    case deleteSearchCharacter
    case action(SelectedWindowAction)
    case commit
    case cancel
}

struct SwitcherShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = SwitcherShortcut(
        keyCode: UInt32(kVK_Tab),
        carbonModifiers: UInt32(optionKey),
        keyLabel: "Tab"
    )

    static let sameApplicationShortcut = SwitcherShortcut(
        keyCode: UInt32(kVK_ANSI_Grave),
        carbonModifiers: UInt32(optionKey),
        keyLabel: "`"
    )

    var displayName: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return "\(symbols) \(keyLabel)"
    }

    var eventModifierFlag: CGEventFlags {
        var flags: CGEventFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        return flags
    }

    var storageValue: String { "\(keyCode),\(carbonModifiers),\(keyLabel)" }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let keyCode = UInt32(parts[0]),
              let modifiers = UInt32(parts[1]),
              !parts[2].isEmpty else { return nil }
        self.init(keyCode: keyCode, carbonModifiers: modifiers, keyLabel: String(parts[2]))
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static func keyLabel(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            let value = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
            return value.isEmpty ? "Key \(event.keyCode)" : value
        }
    }

    var isReserved: Bool {
        (keyCode == UInt32(kVK_Tab) && carbonModifiers == UInt32(cmdKey)) ||
            self == Self.sameApplicationShortcut
    }
}

final class ShortcutMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var sameApplicationHotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var modifierEventTap: CFMachPort?
    private var modifierRunLoopSource: CFRunLoopSource?
    private var isCycling = false
    private var activeShortcut: SwitcherShortcut?
    private var activeScope: SwitcherWindowScope = .allWindows
    private var initialTabWasReleased = false
    private var consumedKeyCodes: Set<UInt32> = []
    private(set) var shortcut: SwitcherShortcut
    private let handler: (ShortcutEvent) -> Void

    var isRunning: Bool {
        guard let modifierEventTap else { return false }
        return hotKeyRef != nil && sameApplicationHotKeyRef != nil && CGEvent.tapIsEnabled(tap: modifierEventTap)
    }

    init(shortcut: SwitcherShortcut, handler: @escaping (ShortcutEvent) -> Void) {
        self.shortcut = shortcut
        self.handler = handler
    }

    @discardableResult
    func changeShortcut(to shortcut: SwitcherShortcut) -> Bool {
        guard self.shortcut != shortcut else { return true }
        let wasRunning = isRunning
        let previous = self.shortcut
        self.shortcut = shortcut
        guard wasRunning else { return true }
        if start() { return true }
        self.shortcut = previous
        _ = start()
        return false
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = eventTypes.withUnsafeBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(), warpTabEventHandler, buffer.count, buffer.baseAddress,
                pointer, &hotKeyHandlerRef
            )
        }
        guard handlerStatus == noErr else {
            recordBackend("unavailable")
            return false
        }

        let identifier = EventHotKeyID(signature: 0x57525054, id: 1) // "WRPT"
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, identifier,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let hotKeyHandlerRef { RemoveEventHandler(hotKeyHandlerRef) }
            hotKeyHandlerRef = nil
            hotKeyRef = nil
            recordBackend("unavailable")
            return false
        }

        let sameApplicationIdentifier = EventHotKeyID(signature: 0x57525054, id: 2)
        let sameApplicationStatus = RegisterEventHotKey(
            SwitcherShortcut.sameApplicationShortcut.keyCode,
            SwitcherShortcut.sameApplicationShortcut.carbonModifiers,
            sameApplicationIdentifier,
            GetApplicationEventTarget(), 0, &sameApplicationHotKeyRef
        )
        guard sameApplicationStatus == noErr else {
            stop()
            recordBackend("unavailable")
            return false
        }

        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        modifierEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: modifierEventCallback,
            userInfo: pointer
        )
        guard let modifierEventTap else {
            stop()
            recordBackend("unavailable")
            return false
        }
        modifierRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, modifierEventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), modifierRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: modifierEventTap, enable: true)

        recordBackend("carbon-custom-with-release")
        return isRunning
    }

    func stop() {
        if let modifierRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), modifierRunLoopSource, .commonModes)
        }
        modifierRunLoopSource = nil
        modifierEventTap = nil
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let sameApplicationHotKeyRef { UnregisterEventHotKey(sameApplicationHotKeyRef) }
        if let hotKeyHandlerRef { RemoveEventHandler(hotKeyHandlerRef) }
        hotKeyRef = nil
        sameApplicationHotKeyRef = nil
        hotKeyHandlerRef = nil
        isCycling = false
        activeShortcut = nil
        activeScope = .allWindows
        initialTabWasReleased = false
        consumedKeyCodes.removeAll()
    }

    fileprivate func processCarbonHotKey(scope: SwitcherWindowScope) {
        // Return from Carbon dispatch before asking WindowServer for its
        // window list; doing that synchronously here creates a circular wait.
        if !isCycling {
            isCycling = true
            activeScope = scope
            activeShortcut = scope == .allWindows ? shortcut : .sameApplicationShortcut
            initialTabWasReleased = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handler(.cycle(backwards: false, scope: self.activeScope))
            }
        }
    }

    fileprivate func processCarbonHotKeyReleased() {
        // Carbon reports the release before the combined keyboard state is
        // updated. Check on the next event-loop turn so an actual key lift is
        // distinguishable from Carbon's autorepeat press/release pairs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, self.isCycling else { return }
            guard let activeShortcut = self.activeShortcut else { return }
            let shortcutKeyIsPhysicallyDown = CGEventSource.keyState(
                .combinedSessionState,
                key: CGKeyCode(activeShortcut.keyCode)
            )
            if !shortcutKeyIsPhysicallyDown { self.initialTabWasReleased = true }
        }
    }

    fileprivate func processModifierEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let modifierEventTap { CGEvent.tapEnable(tap: modifierEventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyUp, consumedKeyCodes.remove(keyCode) != nil {
            return nil
        }

        let invokedShortcut: (shortcut: SwitcherShortcut, scope: SwitcherWindowScope)?
        if keyCode == shortcut.keyCode,
           event.flags.contains(shortcut.eventModifierFlag) {
            invokedShortcut = (shortcut, .allWindows)
        } else if keyCode == SwitcherShortcut.sameApplicationShortcut.keyCode,
                  event.flags.contains(SwitcherShortcut.sameApplicationShortcut.eventModifierFlag) {
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            invokedShortcut = pid.map { (SwitcherShortcut.sameApplicationShortcut, .application($0)) }
        } else {
            invokedShortcut = nil
        }

        if (type == .keyDown || type == .keyUp), let invokedShortcut {
            if !isCycling {
                // Begin on the first physical key-down. Waiting for Carbon's
                // application-event delivery can make the initial press only
                // arm the cycle, so the panel does not appear until the next
                // Tab press. Carbon remains registered as a fallback.
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                isCycling = true
                activeShortcut = invokedShortcut.shortcut
                activeScope = invokedShortcut.scope
                initialTabWasReleased = false
                let backwards = event.flags.contains(.maskShift) &&
                    !invokedShortcut.shortcut.eventModifierFlag.contains(.maskShift)
                DispatchQueue.main.async { [handler] in
                    handler(.cycle(backwards: backwards, scope: invokedShortcut.scope))
                }
            } else if keyCode != activeShortcut?.keyCode {
                return Unmanaged.passUnretained(event)
            } else if type == .keyUp {
                initialTabWasReleased = true
            } else if initialTabWasReleased || event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                let backwards = event.flags.contains(.maskShift) &&
                    !invokedShortcut.shortcut.eventModifierFlag.contains(.maskShift)
                let scope = activeScope
                DispatchQueue.main.async { [handler] in handler(.cycle(backwards: backwards, scope: scope)) }
            }
            // Carbon owns the first shortcut press. Once the switcher is open,
            // consume this key here so both discrete presses and macOS key
            // autorepeat advance exactly once without reaching the active app.
            return nil
        }

        if type == .keyDown, isCycling {
            let commandDown = event.flags.contains(.maskCommand)
            let controlDown = event.flags.contains(.maskControl)
            let dispatched: ShortcutEvent?
            switch Int(keyCode) {
            case kVK_Escape:
                dispatched = .cancel
            case kVK_Return, kVK_ANSI_KeypadEnter:
                dispatched = .commit
                isCycling = false
                activeShortcut = nil
                activeScope = .allWindows
                initialTabWasReleased = false
            case kVK_LeftArrow: dispatched = .navigate(.left)
            case kVK_RightArrow: dispatched = .navigate(.right)
            case kVK_UpArrow: dispatched = .navigate(.up)
            case kVK_DownArrow: dispatched = .navigate(.down)
            case kVK_Delete, kVK_ForwardDelete: dispatched = .deleteSearchCharacter
            case kVK_ANSI_W where commandDown: dispatched = .action(.close)
            case kVK_ANSI_M where commandDown: dispatched = .action(.minimize)
            case kVK_ANSI_H where commandDown: dispatched = .action(.hideApplication)
            default:
                if !commandDown, !controlDown,
                   let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
                   characters.count == 1,
                   let scalar = characters.unicodeScalars.first,
                   !CharacterSet.controlCharacters.contains(scalar) {
                    dispatched = .searchCharacter(characters)
                } else {
                    dispatched = nil
                }
            }
            if let dispatched {
                consumedKeyCodes.insert(keyCode)
                DispatchQueue.main.async { [handler] in handler(dispatched) }
                return nil
            }
        }

        if type == .flagsChanged,
           isCycling,
           let activeShortcut,
           !event.flags.contains(activeShortcut.eventModifierFlag) {
            isCycling = false
            self.activeShortcut = nil
            activeScope = .allWindows
            initialTabWasReleased = false
            consumedKeyCodes.removeAll()
            DispatchQueue.main.async { [handler] in handler(.commit) }
        }
        return Unmanaged.passUnretained(event)
    }

    private func recordBackend(_ name: String) {
        UserDefaults.standard.set(name, forKey: "monitorBackend")
    }
}

private func modifierEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.processModifierEvent(type: type, event: event)
}

private func warpTabEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }
    if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
        monitor.processCarbonHotKeyReleased()
    } else {
        let scope: SwitcherWindowScope
        if identifier.id == 2,
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            scope = .application(pid)
        } else {
            scope = .allWindows
        }
        monitor.processCarbonHotKey(scope: scope)
    }
    return noErr
}
