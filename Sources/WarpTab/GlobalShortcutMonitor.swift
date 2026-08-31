import Carbon.HIToolbox
import Foundation

final class GlobalShortcutMonitor {
    struct Registration {
        let shortcut: SwitcherShortcut
        let action: () -> Void
    }

    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private let signature: OSType
    private let registrations: [Registration]
    private(set) var isRunning = false

    init(signature: OSType, registrations: [Registration], startsImmediately: Bool = true) {
        self.signature = signature
        self.registrations = registrations
        if startsImmediately { _ = start() }
    }

    convenience init(onCycleOutput: @escaping () -> Void, onToggleMicrophones: @escaping () -> Void) {
        self.init(
            signature: 0x534E_4442, // SNDB
            registrations: [
                Registration(
                    shortcut: SwitcherShortcut(
                        keyCode: UInt32(kVK_ANSI_O),
                        carbonModifiers: UInt32(controlKey | optionKey),
                        keyLabel: "O"
                    ),
                    action: onCycleOutput
                ),
                Registration(
                    shortcut: SwitcherShortcut(
                        keyCode: UInt32(kVK_ANSI_M),
                        carbonModifiers: UInt32(controlKey | optionKey),
                        keyLabel: "M"
                    ),
                    action: onToggleMicrophones
                )
            ]
        )
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        stop()
        guard !registrations.isEmpty else {
            isRunning = true
            return true
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalShortcutEventHandler,
            1,
            &eventType,
            context,
            &handler
        )
        guard status == noErr else { stop(); return false }

        for (index, registration) in registrations.enumerated() {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            let registrationStatus = RegisterEventHotKey(
                registration.shortcut.keyCode,
                registration.shortcut.carbonModifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            guard registrationStatus == noErr, let reference else {
                stop()
                return false
            }
            hotKeys.append(reference)
        }
        isRunning = true
        return true
    }

    func stop() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        isRunning = false
    }

    fileprivate func invoke(identifier: EventHotKeyID) -> OSStatus {
        guard identifier.signature == signature,
              identifier.id > 0,
              Int(identifier.id) <= registrations.count else { return OSStatus(eventNotHandledErr) }
        let action = registrations[Int(identifier.id - 1)].action
        DispatchQueue.main.async(execute: action)
        return noErr
    }
}

private func globalShortcutEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
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
    return monitor.invoke(identifier: identifier)
}
