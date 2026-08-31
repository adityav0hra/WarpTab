import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class MouseSettingsPageModel: ObservableObject {
    let settings: MouseSettings
    let eventManager: MouseEventManager
    @Published var editor: MouseAssignmentViewModel?

    init(settings: MouseSettings, eventManager: MouseEventManager) {
        self.settings = settings
        self.eventManager = eventManager
    }

    func addMapping() {
        editor = MouseAssignmentViewModel(settings: settings, eventManager: eventManager)
    }

    func edit(input: MouseInput, action: MouseAction) {
        editor = MouseAssignmentViewModel(
            input: input,
            action: action,
            settings: settings,
            eventManager: eventManager
        )
    }

    func assignKeyboardShortcut(input: MouseInput, currentAction: MouseAction) {
        let initialAction: MouseAction?
        if case .keyboardShortcut = currentAction {
            initialAction = currentAction
        } else {
            initialAction = nil
        }
        editor = MouseAssignmentViewModel(
            input: input,
            action: initialAction,
            settings: settings,
            eventManager: eventManager
        )
    }

    func dismissEditor() {
        editor?.cancelDetection()
        editor = nil
    }

    func saveEditor() {
        guard let editor, let input = editor.detectedInput, let action = editor.selectedAction else { return }
        settings.setAction(action, for: input)
        dismissEditor()
    }
}

private enum MouseAssignmentKind: String, CaseIterable, Identifiable {
    case keyboardShortcut
    case back
    case forward
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keyboardShortcut: return "Keyboard Shortcut"
        case .back: return "Back"
        case .forward: return "Forward"
        case .none: return "None"
        }
    }
}

final class MouseAssignmentViewModel: ObservableObject, Identifiable {
    let id = UUID()
    let isNewAssignment: Bool
    private let settings: MouseSettings
    private let eventManager: MouseEventManager

    @Published var detectedInput: MouseInput?
    @Published fileprivate var kind: MouseAssignmentKind
    @Published var shortcut: MouseKeyboardShortcut?
    @Published var detectionError: String?

    init(
        input: MouseInput? = nil,
        action: MouseAction? = nil,
        settings: MouseSettings,
        eventManager: MouseEventManager
    ) {
        isNewAssignment = input == nil
        detectedInput = input
        self.settings = settings
        self.eventManager = eventManager
        let initial = Self.assignmentState(for: action)
        kind = initial.kind
        shortcut = initial.shortcut
    }

    var selectedAction: MouseAction? {
        switch kind {
        case .keyboardShortcut: return shortcut.map(MouseAction.keyboardShortcut)
        case .back: return .back
        case .forward: return .forward
        case .none: return MouseAction.none
        }
    }

    var replacesExistingAssignment: Bool {
        guard isNewAssignment, let detectedInput else { return false }
        return settings.action(for: detectedInput) != nil
    }

    func startDetection() {
        detectionError = nil
        if !eventManager.isRunning, !eventManager.start() {
            detectionError = "Mouse monitoring is unavailable. Grant WarpTab Accessibility access, then retry."
            return
        }
        eventManager.beginCapture { [weak self] input in
            guard let self else { return }
            self.detectedInput = input
            self.detectionError = nil
            if let existing = self.settings.action(for: input) {
                let state = Self.assignmentState(for: existing)
                self.kind = state.kind
                self.shortcut = state.shortcut
            } else {
                self.kind = .keyboardShortcut
                self.shortcut = nil
            }
        }
    }

    func retryDetection() {
        detectedInput = nil
        shortcut = nil
        startDetection()
    }

    func cancelDetection() {
        eventManager.cancelCapture()
        if !settings.isEnabled { eventManager.stop() }
    }

    private static func assignmentState(
        for action: MouseAction?
    ) -> (kind: MouseAssignmentKind, shortcut: MouseKeyboardShortcut?) {
        switch action {
        case .keyboardShortcut(let shortcut): return (.keyboardShortcut, shortcut)
        case .back: return (.back, nil)
        case .forward: return (.forward, nil)
        case .some(.none): return (.none, nil)
        case .system, .warpTab, nil: return (.keyboardShortcut, nil)
        }
    }
}

struct MouseSettingsView: View {
    @ObservedObject var pageModel: MouseSettingsPageModel
    @ObservedObject private var settings: MouseSettings

    init(pageModel: MouseSettingsPageModel) {
        self.pageModel = pageModel
        settings = pageModel.settings
    }

    var body: some View {
        SettingsPage(
            title: "Mouse",
            description: "Configure mouse-only scrolling, navigation buttons, and extra controls."
        ) {
            SettingsSection(title: "Mouse Features") {
                SettingRow(
                    "Enable Mouse Features",
                    description: "Enable WarpTab's mouse scrolling, navigation, and extra-button actions."
                ) {
                    Toggle("", isOn: $settings.isEnabled)
                        .labelsHidden()
                        .accessibilityLabel("Enable Mouse Features")
                }
            }

            Group {
            SettingsSection(title: "Scrolling") {
                SettingRow(
                    "Reverse Vertical Scrolling",
                    description: "Reverse vertical mouse-wheel scrolling without changing trackpad scrolling."
                ) {
                    Toggle("", isOn: $settings.reverseVerticalScrolling)
                        .labelsHidden()
                        .accessibilityLabel("Reverse Vertical Scrolling")
                }
                Divider()
                SettingRow(
                    "Reverse Horizontal Scrolling",
                    description: "Reverse horizontal mouse-wheel or tilt-wheel scrolling without changing trackpad scrolling."
                ) {
                    Toggle("", isOn: $settings.reverseHorizontalScrolling)
                        .labelsHidden()
                        .accessibilityLabel("Reverse Horizontal Scrolling")
                }
            }

            SettingsSection(title: "Navigation Buttons") {
                navigationRow("Back Button", input: MouseSettings.backInput, action: settings.backButtonAction)
                Divider()
                navigationRow("Forward Button", input: MouseSettings.forwardInput, action: settings.forwardButtonAction)
            }

            SettingsSection(title: "Mouse Button Shortcuts") {
                if settings.customMappings.isEmpty {
                    SettingRow(
                        "No custom shortcuts",
                        description: "Assign an extra mouse button or a side-wheel direction."
                    ) { EmptyView() }
                    Divider()
                } else {
                    ForEach(settings.customMappings) { mapping in
                        SettingRow(mapping.input.displayName, description: mapping.action.displayName) {
                            HStack(spacing: 6) {
                                Button {
                                    pageModel.edit(input: mapping.input, action: mapping.action)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Edit \(mapping.input.displayName)")
                                .accessibilityLabel("Edit \(mapping.input.displayName)")

                                Button {
                                    settings.removeMapping(for: mapping.input)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(mapping.input.displayName)")
                                .accessibilityLabel("Remove \(mapping.input.displayName)")
                            }
                        }
                        Divider()
                    }
                }

                HStack {
                    Spacer()
                    Button(action: pageModel.addMapping) {
                        Label("Add Shortcut", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            }
            .disabled(!settings.isEnabled)
        }
        .sheet(item: $pageModel.editor) { editor in
            MouseAssignmentSheet(
                editor: editor,
                onCancel: pageModel.dismissEditor,
                onSave: pageModel.saveEditor
            )
        }
    }

    private func navigationRow(_ title: String, input: MouseInput, action: MouseAction) -> some View {
        SettingRow(title, description: "Choose the command sent when this side button is pressed.") {
            Menu(action.displayName) {
                Button("Back") { settings.setAction(.back, for: input) }
                Button("Forward") { settings.setAction(.forward, for: input) }
                Button("Keyboard Shortcut…") {
                    pageModel.assignKeyboardShortcut(input: input, currentAction: action)
                }
                Divider()
                Button("None") { settings.setAction(.none, for: input) }
            }
            .frame(width: 150)
            .accessibilityLabel("\(title) action")
        }
    }
}

private struct MouseAssignmentSheet: View {
    @ObservedObject var editor: MouseAssignmentViewModel
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let input = editor.detectedInput {
                detectedContent(input)
            } else {
                detectionContent
            }

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.detectedInput == nil || editor.selectedAction == nil)
            }
        }
        .padding(24)
        .frame(width: 450)
        .onAppear {
            if editor.detectedInput == nil { editor.startDetection() }
        }
        .onDisappear { editor.cancelDetection() }
    }

    private var detectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Press a mouse button").font(.title2.weight(.semibold))
            Text("Press an extra mouse button or move the side wheel you want to assign. Left, right, and middle clicks are ignored.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let detectionError = editor.detectionError {
                Label(detectionError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Retry Detection", action: editor.startDetection)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Listening for mouse input…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detectedContent(_ input: MouseInput) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose action").font(.title2.weight(.semibold))

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Detected").font(.caption).foregroundStyle(.secondary)
                    Text(input.displayName).font(.body.weight(.medium))
                }
                Spacer()
                Button("Retry Detection", action: editor.retryDetection)
            }

            Picker("Action", selection: $editor.kind) {
                ForEach(MouseAssignmentKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if editor.kind == .keyboardShortcut {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Press a keyboard shortcut").font(.callout.weight(.medium))
                    Text("Use Command, Option, Control, or Shift with a non-modifier key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MouseKeyboardShortcutRecorder(shortcut: $editor.shortcut)
                }
            }

            if editor.replacesExistingAssignment {
                Label("Saving will replace the existing assignment for this control.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MouseKeyboardShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: MouseKeyboardShortcut?

    func makeNSView(context: Context) -> MouseKeyboardShortcutRecorderButton {
        let button = MouseKeyboardShortcutRecorderButton(shortcut: shortcut)
        button.onShortcut = { self.shortcut = $0 }
        return button
    }

    func updateNSView(_ button: MouseKeyboardShortcutRecorderButton, context: Context) {
        button.onShortcut = { self.shortcut = $0 }
        button.setShortcut(shortcut)
    }
}

private final class MouseKeyboardShortcutRecorderButton: NSButton {
    var onShortcut: ((MouseKeyboardShortcut) -> Void)?
    private var shortcut: MouseKeyboardShortcut?
    private var isRecording = false

    init(shortcut: MouseKeyboardShortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        title = shortcut?.displayName ?? "Record Shortcut…"
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("Mouse keyboard shortcut")
        setAccessibilityHelp("Press to record a keyboard shortcut")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func setShortcut(_ value: MouseKeyboardShortcut?) {
        guard !isRecording else { return }
        shortcut = value
        title = value?.displayName ?? "Record Shortcut…"
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording()
            return
        }
        let candidate = MouseKeyboardShortcut(event: event)
        guard candidate.hasModifiers else {
            NSSound.beep()
            showTemporaryMessage("Add a modifier")
            return
        }
        shortcut = candidate
        onShortcut?(candidate)
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { finishRecording() }
        return super.resignFirstResponder()
    }

    private func finishRecording() {
        isRecording = false
        title = shortcut?.displayName ?? "Record Shortcut…"
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    private func showTemporaryMessage(_ message: String) {
        title = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isRecording else { return }
            self.title = "Type shortcut…"
        }
    }
}
