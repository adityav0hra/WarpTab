import Carbon.HIToolbox
import Foundation

final class GlobalShortcutMonitor {
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef?] = []
    private let onCycleOutput: () -> Void
    private let onToggleMicrophones: () -> Void

    private static let signature: OSType = 0x534E_4442 // SNDB
    private static let cycleOutputID: UInt32 = 1
    private static let toggleMicrophonesID: UInt32 = 2

    init(onCycleOutput: @escaping () -> Void, onToggleMicrophones: @escaping () -> Void) {
        self.onCycleOutput = onCycleOutput
        self.onToggleMicrophones = onToggleMicrophones
        installHandler()
        register(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey), id: Self.cycleOutputID)
        register(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), id: Self.toggleMicrophonesID)
    }

    deinit {
        hotKeys.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalShortcutMonitor.signature else { return status }
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case GlobalShortcutMonitor.cycleOutputID: monitor.onCycleOutput()
                    case GlobalShortcutMonitor.toggleMicrophonesID: monitor.onToggleMicrophones()
                    default: break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &handler
        )
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: id)
        RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        hotKeys.append(reference)
    }
}
