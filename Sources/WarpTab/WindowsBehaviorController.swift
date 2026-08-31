import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

private let warpTabSyntheticEventMarker: Int64 = 0x5752_5054
private let systemDefinedEventType = CGEventType(rawValue: 14)!

struct ClipboardHistoryEntry: Identifiable {
    let id = UUID()
    let items: [[NSPasteboard.PasteboardType: Data]]
    let plainText: String?
    let preview: String
    let fingerprint: Int

    static func capture(from pasteboard: NSPasteboard) -> ClipboardHistoryEntry? {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else { return nil }
        var captured: [[NSPasteboard.PasteboardType: Data]] = []
        var hasher = Hasher()

        for source in pasteboardItems {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in source.types {
                guard let data = source.data(forType: type) else { continue }
                representations[type] = data
                hasher.combine(type.rawValue)
                hasher.combine(data)
            }
            if !representations.isEmpty { captured.append(representations) }
        }
        guard !captured.isEmpty else { return nil }

        let text = plainText(from: pasteboardItems)
        let preview = displayPreview(text: text, pasteboardItems: pasteboardItems)
        return ClipboardHistoryEntry(
            items: captured,
            plainText: text,
            preview: preview,
            fingerprint: hasher.finalize()
        )
    }

    func restore(to pasteboard: NSPasteboard, withoutFormatting: Bool) {
        pasteboard.clearContents()
        if withoutFormatting, let plainText {
            pasteboard.setString(plainText, forType: .string)
            return
        }

        let pasteboardItems = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }

    private static func plainText(from items: [NSPasteboardItem]) -> String? {
        let strings = items.compactMap { item -> String? in
            if let value = item.string(forType: .string) { return value }
            if let data = item.data(forType: .html),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.html],
                   documentAttributes: nil
               ) {
                return attributed.string
            }
            if let value = item.string(forType: .fileURL), let url = URL(string: value) {
                return url.path
            }
            return nil
        }
        return strings.isEmpty ? nil : strings.joined(separator: "\n")
    }

    private static func displayPreview(text: String?, pasteboardItems: [NSPasteboardItem]) -> String {
        if let text {
            let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !compact.isEmpty { return String(compact.prefix(180)) }
        }
        if pasteboardItems.contains(where: { $0.types.contains(.tiff) || $0.types.contains(.png) }) {
            return "Image"
        }
        return "Clipboard item"
    }
}

final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var entries: [ClipboardHistoryEntry] = []
    private let pasteboard = NSPasteboard.general
    private let limit = 30
    private var observedChangeCount: Int

    init() {
        observedChangeCount = pasteboard.changeCount
    }

    func poll(enabled: Bool) {
        guard enabled, pasteboard.changeCount != observedChangeCount else { return }
        observedChangeCount = pasteboard.changeCount
        guard let entry = ClipboardHistoryEntry.capture(from: pasteboard) else { return }
        entries.removeAll { $0.fingerprint == entry.fingerprint }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func select(_ entry: ClipboardHistoryEntry, withoutFormatting: Bool) {
        entry.restore(to: pasteboard, withoutFormatting: withoutFormatting)
        observedChangeCount = pasteboard.changeCount
    }

    func clear() {
        entries.removeAll()
        pasteboard.clearContents()
        observedChangeCount = pasteboard.changeCount
    }
}

private final class ClipboardHistoryPanelController: NSWindowController, NSWindowDelegate {
    private let store: ClipboardHistoryStore
    private let plainTextOnClick: () -> Bool
    private let animationsEnabled: () -> Bool

    init(
        store: ClipboardHistoryStore,
        plainTextOnClick: @escaping () -> Bool,
        animationsEnabled: @escaping () -> Bool
    ) {
        self.store = store
        self.plainTextOnClick = plainTextOnClick
        self.animationsEnabled = animationsEnabled
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        panel.title = "Clipboard History"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.insert(.fullSizeContentView)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = animationsEnabled() ? .utilityWindow : .none
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ClipboardHistoryView(
            store: store,
            onSelect: { [weak panel] entry in
                let shiftPressed = NSEvent.modifierFlags.contains(.shift)
                store.select(entry, withoutFormatting: plainTextOnClick() != shiftPressed)
                panel?.orderOut(nil)
            }
        ))
    }

    required init?(coder: NSCoder) { nil }

    func windowDidResignKey(_ notification: Notification) {
        window?.orderOut(nil)
    }

    func show() {
        guard let window else { return }
        window.animationBehavior = animationsEnabled() ? .utilityWindow : .none
        let rowCount = min(store.entries.count, 16)
        let contentHeight = store.entries.isEmpty
            ? CGFloat(139)
            : min(CGFloat(561), CGFloat(72 + rowCount * 27))
        window.setContentSize(NSSize(width: 340, height: contentHeight))
        if let screen = NSScreen.main {
            let frame = window.frame
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.maxX - frame.width - 18,
                y: visible.maxY - frame.height - 4
            ))
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardHistoryStore
    let onSelect: (ClipboardHistoryEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Clipboard history")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 30)
            Divider()

            if store.entries.isEmpty {
                VStack(spacing: 5) {
                    Text("No clipboard history yet")
                        .font(.system(size: 13, weight: .regular))
                    Text("Copy something to see it here.")
                        .font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.entries) { entry in
                            clipboardRow(entry)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }

            Divider()
            Button {
                store.clear()
            } label: {
                Text("Delete All History")
                    .font(.system(size: 13, weight: .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.entries.isEmpty)
            .opacity(store.entries.isEmpty ? 0.45 : 1)
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func clipboardRow(_ entry: ClipboardHistoryEntry) -> some View {
        Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 10) {
                Text(entry.preview)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy; hold Shift to use the alternate formatting mode")
    }
}

private final class AccentChooserPanelController: NSWindowController {
    private var onChoose: ((String) -> Void)?
    private let animationsEnabled: () -> Bool

    init(animationsEnabled: @escaping () -> Bool) {
        self.animationsEnabled = animationsEnabled
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 52),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = animationsEnabled() ? .utilityWindow : .none
    }

    required init?(coder: NSCoder) { nil }

    func show(characters: [String], onChoose: @escaping (String) -> Void) {
        guard let panel = window else { return }
        panel.animationBehavior = animationsEnabled() ? .utilityWindow : .none
        self.onChoose = onChoose
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 4
        for character in characters {
            let button = AccentButton(title: character, target: self, action: #selector(chooseAccent(_:)))
            button.character = character
            button.isBordered = false
            button.font = .systemFont(ofSize: 22)
            stack.addArrangedSubview(button)
        }
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -7)
        ])
        let width = max(90, CGFloat(characters.count) * 38 + 16)
        panel.setContentSize(NSSize(width: width, height: 52))
        panel.contentView = effect
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x - width / 2, y: mouse.y + 12))
        panel.orderFrontRegardless()
    }

    @objc private func chooseAccent(_ sender: AccentButton) {
        window?.orderOut(nil)
        onChoose?(sender.character)
    }
}

private final class AccentButton: NSButton {
    var character = ""
}

final class WindowsBehaviorController {
    private enum WindowButtonKind {
        case zoom
        case close
    }

    private let preferences: WarpPreferences
    private let windowSnapManager: WindowSnapManager
    private let dockAppShortcuts = DockAppShortcutController()
    private let clipboardStore = ClipboardHistoryStore()
    private lazy var clipboardPanel = ClipboardHistoryPanelController(
        store: clipboardStore,
        plainTextOnClick: { [weak self] in self?.preferences.clipboardPlainTextOnClick ?? true },
        animationsEnabled: { [weak self] in self?.preferences.animationsEnabled ?? false }
    )
    private lazy var accentPanel = AccentChooserPanelController(
        animationsEnabled: { [weak self] in self?.preferences.animationsEnabled ?? false }
    )
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clipboardTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var consumedKeyCodes: Set<UInt32> = []
    private var finderCutPending = false
    private var appliedRepeatPreference: Bool?
    private var optionizeGreenMouseUp = false
    private var consumeCloseMouseUp = false
    private var windowsMinimizedByCommandM: [pid_t: [AXUIElement]] = [:]
    private var lastCommandMProcessIdentifier: pid_t?
    private var started = false

    init(preferences: WarpPreferences, store: WindowStore, previewCache: PreviewCache = PreviewCache()) {
        self.preferences = preferences
        self.windowSnapManager = WindowSnapManager(store: store, previewCache: previewCache)
        preferences.onWindowsBehaviorChange = { [weak self] in self?.refreshPreferences() }
    }

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func start() {
        started = true
        guard eventTap == nil else { refreshPreferences(); return }
        let mask = [CGEventType.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, systemDefinedEventType]
            .reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: windowsBehaviorEventCallback,
            userInfo: pointer
        )
        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        refreshPreferences()
    }

    func stop() {
        started = false
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        eventTap = nil
        consumedKeyCodes.removeAll()
        optionizeGreenMouseUp = false
        consumeCloseMouseUp = false
        windowsMinimizedByCommandM.removeAll()
        lastCommandMProcessIdentifier = nil
    }

    func clearClipboard() {
        clipboardStore.clear()
        finderCutPending = false
    }

    func showClipboardHistory() {
        clipboardStore.poll(enabled: preferences.clipboardHistoryEnabled)
        clipboardPanel.show()
    }

    fileprivate func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == warpTabSyntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseUp {
            if consumeCloseMouseUp {
                consumeCloseMouseUp = false
                return nil
            }
            if optionizeGreenMouseUp {
                optionizeGreenMouseUp = false
                event.flags = event.flags.union(.maskAlternate)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown,
           windowSnapManager.handleSnapAssistMouseDown(at: event.location) {
            return nil
        }

        if type == .leftMouseDown,
           let target = windowButton(at: event.location) {
            if target.kind == .zoom, preferences.greenButtonMaximizes {
                if event.flags.contains(.maskShift), preferences.shiftGreenUsesFullScreen {
                    return Unmanaged.passUnretained(event)
                }
                optionizeGreenMouseUp = true
                event.flags = event.flags.union(.maskAlternate)
                return Unmanaged.passUnretained(event)
            }
            if target.kind == .close,
               preferences.quitOnLastWindowClose,
               !(event.flags.contains(.maskShift) && preferences.shiftCloseKeepsAppRunning),
               let application = applicationToQuitAfterClosingLastWindow(processIdentifier: target.processIdentifier) {
                consumeCloseMouseUp = true
                DispatchQueue.main.async { application.terminate() }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let finderIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        if type == systemDefinedEventType,
           preferences.finderF2RenameEnabled,
           finderIsFrontmost,
           let systemEvent = NSEvent(cgEvent: event),
           systemEvent.subtype.rawValue == 8,
           (systemEvent.data1 >> 16) & 0xFFFF == 2 {
            // On Apple keyboards the unmodified F2 key arrives as the
            // brightness-up media event. Treat both its down and up halves as
            // F2 while Finder is active, and rename on the down half.
            let state = (systemEvent.data1 >> 8) & 0xFF
            if state == 0xA { postKey(UInt16(kVK_Return), flags: []) }
            return nil
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, consumedKeyCodes.remove(keyCode) != nil { return nil }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let option = flags.contains(.maskAlternate)
        let control = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)

        if preferences.commandMMinimizesAllWindows,
           keyCode == UInt32(kVK_ANSI_M), command, !option, !control, !shift {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                consumedKeyCodes.insert(keyCode)
                DispatchQueue.main.async { [weak self] in self?.toggleAllWindowsForFrontmostApplication() }
            }
            return nil
        }

        if preferences.windowSnappingEnabled,
           control, shift, !command, !option,
           let direction = snapDirection(for: keyCode) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat, consumedKeyCodes.contains(keyCode) { return nil }
            consumedKeyCodes.insert(keyCode)
            DispatchQueue.main.async { [weak self] in _ = self?.windowSnapManager.move(direction) }
            return nil
        }

        if preferences.dockAppShortcutsEnabled,
           !control, !shift,
           let dockIndex = Self.dockIndex(for: keyCode) {
            if command, !option {
                consumedKeyCodes.insert(keyCode)
                DispatchQueue.main.async { [weak self] in
                    self?.dockAppShortcuts.openApp(at: dockIndex)
                }
                return nil
            }
            if command, option {
                consumedKeyCodes.insert(keyCode)
                postKey(UInt16(keyCode), flags: .maskAlternate)
                return nil
            }
        }

        if preferences.clipboardHistoryEnabled,
           keyCode == UInt32(kVK_ANSI_V), option, !command, !control {
            consumedKeyCodes.insert(keyCode)
            DispatchQueue.main.async { [weak self] in self?.showClipboardHistory() }
            return nil
        }

        if finderIsFrontmost {
            if preferences.finderF2RenameEnabled,
               keyCode == UInt32(kVK_F2), !command, !option, !control {
                consumedKeyCodes.insert(keyCode)
                postKey(UInt16(kVK_Return), flags: [])
                return nil
            }
            if preferences.finderCutPasteEnabled,
               keyCode == UInt32(kVK_ANSI_X), command, !option, !control {
                finderCutPending = true
                consumedKeyCodes.insert(keyCode)
                postKey(UInt16(kVK_ANSI_C), flags: .maskCommand)
                return nil
            }
            if preferences.finderCutPasteEnabled,
               keyCode == UInt32(kVK_ANSI_C), command, !option, !control {
                finderCutPending = false
            }
            if preferences.finderCutPasteEnabled,
               keyCode == UInt32(kVK_ANSI_V), command, !option, !control, finderCutPending {
                finderCutPending = false
                consumedKeyCodes.insert(keyCode)
                postKey(UInt16(kVK_ANSI_V), flags: [.maskCommand, .maskAlternate])
                return nil
            }
            if !preferences.finderCutPasteEnabled { finderCutPending = false }
        } else if command && (keyCode == UInt32(kVK_ANSI_C) || keyCode == UInt32(kVK_ANSI_X)) {
            finderCutPending = false
        }

        if preferences.controlAccentChooserEnabled,
           control, !command, !option,
           let base = baseLetter(for: keyCode),
           let choices = Self.accentChoices[base] {
            consumedKeyCodes.insert(keyCode)
            let displayed = shift ? choices.map { $0.uppercased() } : choices
            DispatchQueue.main.async { [weak self] in
                self?.accentPanel.show(characters: displayed) { [weak self] value in self?.postUnicode(value) }
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func snapDirection(for keyCode: UInt32) -> SnapDirection? {
        switch Int(keyCode) {
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        default: return nil
        }
    }

    private func refreshPreferences() {
        if appliedRepeatPreference != preferences.repeatKeysOnHold {
            appliedRepeatPreference = preferences.repeatKeysOnHold
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = [
                "write", "NSGlobalDomain", "ApplePressAndHoldEnabled", "-bool",
                preferences.repeatKeysOnHold ? "false" : "true"
            ]
            try? process.run()
        }

        guard started else { return }
        if preferences.clipboardHistoryEnabled {
            if clipboardTimer == nil {
                let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    clipboardStore.poll(enabled: preferences.clipboardHistoryEnabled)
                }
                RunLoop.main.add(timer, forMode: .common)
                clipboardTimer = timer
            }
            clipboardStore.poll(enabled: true)
        } else {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        }

        if preferences.clearClipboardOnSleep {
            if sleepObserver == nil {
                sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.willSleepNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in self?.clearClipboard() }
            }
        } else if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
    }

    private func windowButton(at point: CGPoint) -> (kind: WindowButtonKind, processIdentifier: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
        let hitElement else { return nil }

        var current: AXUIElement? = hitElement
        for _ in 0..<5 {
            guard let element = current else { break }
            if axString(element, kAXRoleAttribute as String) == kAXButtonRole {
                let subrole = axString(element, kAXSubroleAttribute as String)
                let kind: WindowButtonKind?
                switch subrole {
                case "AXFullScreenButton", "AXZoomButton": kind = .zoom
                case "AXCloseButton": kind = .close
                default: kind = nil
                }
                if let kind {
                    var processIdentifier: pid_t = 0
                    guard AXUIElementGetPid(element, &processIdentifier) == .success else { return nil }
                    return (kind, processIdentifier)
                }
            }
            current = axElement(element, kAXParentAttribute as String)
        }
        return nil
    }

    private func applicationToQuitAfterClosingLastWindow(
        processIdentifier: pid_t
    ) -> NSRunningApplication? {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.bundleIdentifier != "com.apple.finder",
              application.activationPolicy == .regular else { return nil }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let windows = axElements(appElement, kAXWindowsAttribute as String).filter { window in
            guard axString(window, kAXRoleAttribute as String) == kAXWindowRole else { return false }
            let subrole = axString(window, kAXSubroleAttribute as String)
            return subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        }
        return windows.count == 1 ? application : nil
    }

    private func toggleAllWindowsForFrontmostApplication() {
        if let processIdentifier = lastCommandMProcessIdentifier,
           let remembered = windowsMinimizedByCommandM[processIdentifier],
           remembered.contains(where: { axBool($0, kAXMinimizedAttribute as String) == true }),
           let application = NSRunningApplication(processIdentifier: processIdentifier) {
            for window in remembered where axBool(window, kAXMinimizedAttribute as String) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            windowsMinimizedByCommandM.removeValue(forKey: processIdentifier)
            lastCommandMProcessIdentifier = nil
            application.activate()
            return
        }
        lastCommandMProcessIdentifier = nil

        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular else { return }

        let processIdentifier = application.processIdentifier
        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let windows = axElements(appElement, kAXWindowsAttribute as String).filter { window in
            guard axString(window, kAXRoleAttribute as String) == kAXWindowRole else { return false }
            let subrole = axString(window, kAXSubroleAttribute as String)
            return subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        }
        guard !windows.isEmpty else {
            windowsMinimizedByCommandM.removeValue(forKey: processIdentifier)
            lastCommandMProcessIdentifier = nil
            return
        }

        if let remembered = windowsMinimizedByCommandM[processIdentifier],
           remembered.contains(where: { axBool($0, kAXMinimizedAttribute as String) == true }) {
            for window in remembered where axBool(window, kAXMinimizedAttribute as String) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            windowsMinimizedByCommandM.removeValue(forKey: processIdentifier)
            application.activate()
            return
        }

        let visibleWindows = windows.filter { axBool($0, kAXMinimizedAttribute as String) != true }
        if visibleWindows.isEmpty {
            for window in windows {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            windowsMinimizedByCommandM.removeValue(forKey: processIdentifier)
            lastCommandMProcessIdentifier = nil
            application.activate()
        } else {
            windowsMinimizedByCommandM[processIdentifier] = visibleWindows
            lastCommandMProcessIdentifier = processIdentifier
            for window in visibleWindows {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    private func axValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        axValue(element, attribute) as? String
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        axValue(element, attribute) as? Bool
    }

    private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = axValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        axValue(element, attribute) as? [AXUIElement] ?? []
    }

    private func postKey(_ keyCode: UInt16, flags: CGEventFlags) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: warpTabSyntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private func postUnicode(_ value: String) {
        let units = Array(value.utf16)
        guard !units.isEmpty else { return }
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: warpTabSyntheticEventMarker)
            units.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func baseLetter(for keyCode: UInt32) -> String? {
        Self.letterKeyCodes[keyCode]
    }

    private static func dockIndex(for keyCode: UInt32) -> Int? {
        switch Int(keyCode) {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        case kVK_ANSI_0: return 9
        default: return nil
        }
    }

    private static let letterKeyCodes: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "a", UInt32(kVK_ANSI_C): "c", UInt32(kVK_ANSI_E): "e",
        UInt32(kVK_ANSI_I): "i", UInt32(kVK_ANSI_L): "l", UInt32(kVK_ANSI_N): "n",
        UInt32(kVK_ANSI_O): "o", UInt32(kVK_ANSI_S): "s", UInt32(kVK_ANSI_U): "u",
        UInt32(kVK_ANSI_Y): "y", UInt32(kVK_ANSI_Z): "z"
    ]

    private static let accentChoices: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["ì", "í", "î", "ï", "ī", "į"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ò", "ó", "ô", "ö", "œ", "õ", "ø", "ō"],
        "s": ["ß", "ś", "š"],
        "u": ["ù", "ú", "û", "ü", "ū"],
        "y": ["ý", "ÿ"],
        "z": ["ž", "ź", "ż"]
    ]
}

private func windowsBehaviorEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<WindowsBehaviorController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.process(type: type, event: event)
}
