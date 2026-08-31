import AppKit
import Carbon.HIToolbox
import Combine

enum MouseSideWheelDirection: String, Codable, CaseIterable {
    case left
    case right
}

enum MouseInput: Hashable, Codable, Identifiable {
    case button(Int64)
    case sideWheel(MouseSideWheelDirection)

    var id: String {
        switch self {
        case .button(let number): return "button-\(number)"
        case .sideWheel(let direction): return "side-wheel-\(direction.rawValue)"
        }
    }

    var displayName: String {
        switch self {
        case .button(3): return "Back Button"
        case .button(4): return "Forward Button"
        case .button(let number): return "Mouse Button \(number + 1)"
        case .sideWheel(.left): return "Side Wheel Left"
        case .sideWheel(.right): return "Side Wheel Right"
        }
    }
}

struct MouseKeyboardShortcut: Hashable, Codable {
    let keyCode: UInt16
    let carbonModifiers: UInt32
    let keyLabel: String

    init(keyCode: UInt16, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        keyCode = event.keyCode
        carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
        keyLabel = Self.keyLabel(for: event)
    }

    var displayName: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return "\(symbols)\(keyLabel)"
    }

    var hasModifiers: Bool { carbonModifiers != 0 }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String {
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
}

enum MouseSystemAction: String, Hashable, Codable {
    case missionControl
    case showDesktop
    case previousDesktop
    case nextDesktop
}

enum MouseWarpTabAction: String, Hashable, Codable {
    case windowSwitcher
    case clipboardHistory
    case keepMacAwake
    case screenCopyText = "screen.copyText"
    case screenPickColor = "screen.pickColor"
}

enum MouseAction: Hashable, Codable {
    case keyboardShortcut(MouseKeyboardShortcut)
    case back
    case forward
    case system(MouseSystemAction)
    case warpTab(MouseWarpTabAction)
    case none

    var displayName: String {
        switch self {
        case .keyboardShortcut(let shortcut): return shortcut.displayName
        case .back: return "Back"
        case .forward: return "Forward"
        case .system(let action):
            switch action {
            case .missionControl: return "Mission Control"
            case .showDesktop: return "Show Desktop"
            case .previousDesktop: return "Previous Desktop"
            case .nextDesktop: return "Next Desktop"
            }
        case .warpTab(let action):
            switch action {
            case .windowSwitcher: return "WarpTab Window Switcher"
            case .clipboardHistory: return "Clipboard History"
            case .keepMacAwake: return "Keep Mac Awake"
            case .screenCopyText: return "Copy Text from Screen"
            case .screenPickColor: return "Pick Color from Screen"
            }
        case .none: return "None"
        }
    }
}

struct MouseShortcutMapping: Hashable, Codable, Identifiable {
    let input: MouseInput
    var action: MouseAction

    var id: String { input.id }
}

final class MouseSettings: ObservableObject {
    static let backInput = MouseInput.button(3)
    static let forwardInput = MouseInput.button(4)

    private enum Key {
        static let enabled = "mouseFeaturesEnabled"
        static let reverseVertical = "mouseReverseVerticalScrolling"
        static let reverseHorizontal = "mouseReverseHorizontalScrolling"
        static let backAction = "mouseBackButtonAction"
        static let forwardAction = "mouseForwardButtonAction"
        static let mappings = "mouseShortcutMappings"
    }

    private let defaults: UserDefaults
    var onEnabledChange: ((Bool) -> Void)?

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.enabled)
            onEnabledChange?(isEnabled)
        }
    }

    @Published var reverseVerticalScrolling: Bool {
        didSet {
            defaults.set(reverseVerticalScrolling, forKey: Key.reverseVertical)
        }
    }

    @Published var reverseHorizontalScrolling: Bool {
        didSet {
            defaults.set(reverseHorizontalScrolling, forKey: Key.reverseHorizontal)
        }
    }

    @Published private(set) var backButtonAction: MouseAction {
        didSet { persist(backButtonAction, forKey: Key.backAction) }
    }

    @Published private(set) var forwardButtonAction: MouseAction {
        didSet { persist(forwardButtonAction, forKey: Key.forwardAction) }
    }

    @Published private(set) var customMappings: [MouseShortcutMapping] {
        didSet {
            if let data = try? JSONEncoder().encode(customMappings) {
                defaults.set(data, forKey: Key.mappings)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enabled: false,
            Key.reverseVertical: false,
            Key.reverseHorizontal: false
        ])
        isEnabled = defaults.bool(forKey: Key.enabled)
        reverseVerticalScrolling = defaults.bool(forKey: Key.reverseVertical)
        reverseHorizontalScrolling = defaults.bool(forKey: Key.reverseHorizontal)
        backButtonAction = Self.decodeAction(defaults.data(forKey: Key.backAction)) ?? .back
        forwardButtonAction = Self.decodeAction(defaults.data(forKey: Key.forwardAction)) ?? .forward
        customMappings = Self.decodeMappings(defaults.data(forKey: Key.mappings))
    }

    func action(for input: MouseInput) -> MouseAction? {
        switch input {
        case Self.backInput: return backButtonAction
        case Self.forwardInput: return forwardButtonAction
        default: return customMappings.first(where: { $0.input == input })?.action
        }
    }

    func setAction(_ action: MouseAction, for input: MouseInput) {
        switch input {
        case Self.backInput:
            backButtonAction = action
        case Self.forwardInput:
            forwardButtonAction = action
        default:
            if let index = customMappings.firstIndex(where: { $0.input == input }) {
                customMappings[index].action = action
            } else {
                customMappings.append(MouseShortcutMapping(input: input, action: action))
            }
            customMappings.sort { $0.input.displayName.localizedStandardCompare($1.input.displayName) == .orderedAscending }
        }
    }

    func removeMapping(for input: MouseInput) {
        guard input != Self.backInput, input != Self.forwardInput else { return }
        customMappings.removeAll { $0.input == input }
    }

    private func persist(_ action: MouseAction, forKey key: String) {
        if let data = try? JSONEncoder().encode(action) {
            defaults.set(data, forKey: key)
        }
    }

    private static func decodeAction(_ data: Data?) -> MouseAction? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(MouseAction.self, from: data)
    }

    private static func decodeMappings(_ data: Data?) -> [MouseShortcutMapping] {
        guard let data,
              let mappings = try? JSONDecoder().decode([MouseShortcutMapping].self, from: data) else { return [] }
        var seen = Set<MouseInput>()
        return mappings.filter { mapping in
            guard mapping.input != backInput, mapping.input != forwardInput else { return false }
            return seen.insert(mapping.input).inserted
        }
    }
}
