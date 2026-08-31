import AppKit
import Combine

enum WarpTabAction: String {
    case copyTextFromScreen = "screen.copyText"
    case pickColorFromScreen = "screen.pickColor"
}

@MainActor
final class ScreenToolsController: ObservableObject {
    @Published private(set) var textCaptureShortcut: SwitcherShortcut?
    @Published private(set) var colorPickerShortcut: SwitcherShortcut?

    private let preferences: WarpPreferences
    private let selector = ScreenSelectionController()
    private let captureService = ScreenCaptureService()
    private let textRecognizer = ScreenTextRecognizer()
    private let qrDetector = QRCodeDetector()
    private let resultPanel: ScreenToolsResultPanelController
    private var shortcutMonitor: GlobalShortcutMonitor?
    private var colorSampler: NSColorSampler?

    init(preferences: WarpPreferences) {
        self.preferences = preferences
        resultPanel = ScreenToolsResultPanelController(preferences: preferences)
        textCaptureShortcut = preferences.screenTextCaptureShortcutStorageValue.flatMap(SwitcherShortcut.init(storageValue:))
        colorPickerShortcut = preferences.screenColorPickerShortcutStorageValue.flatMap(SwitcherShortcut.init(storageValue:))
    }

    func start() {
        _ = installShortcutMonitor(
            textShortcut: textCaptureShortcut,
            colorShortcut: colorPickerShortcut
        )
    }

    func stop() {
        selector.cancel()
        shortcutMonitor?.stop()
        shortcutMonitor = nil
        resultPanel.dismiss()
        colorSampler = nil
    }

    @discardableResult
    func setTextCaptureShortcut(_ shortcut: SwitcherShortcut?) -> Bool {
        changeShortcut(text: shortcut, color: colorPickerShortcut) {
            preferences.screenTextCaptureShortcutStorageValue = shortcut?.storageValue
            textCaptureShortcut = shortcut
        }
    }

    @discardableResult
    func setColorPickerShortcut(_ shortcut: SwitcherShortcut?) -> Bool {
        changeShortcut(text: textCaptureShortcut, color: shortcut) {
            preferences.screenColorPickerShortcutStorageValue = shortcut?.storageValue
            colorPickerShortcut = shortcut
        }
    }

    func perform(_ action: WarpTabAction) {
        switch action {
        case .copyTextFromScreen: copyTextFromScreen()
        case .pickColorFromScreen: pickColorFromScreen()
        }
    }

    func copyTextFromScreen() {
        guard ScreenRecordingPermission.isGranted else {
            showScreenRecordingExplanation()
            return
        }
        selector.begin(mode: .rectangle) { [weak self] result in
            guard case .rectangle(let rectangle) = result else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                Task { await self?.processTextSelection(rectangle) }
            }
        }
    }

    func pickColorFromScreen() {
        if ScreenRecordingPermission.isGranted {
            selector.begin(mode: .point) { [weak self] result in
                guard case .point(let point) = result else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    Task { await self?.processColorPoint(point) }
                }
            }
        } else {
            let sampler = NSColorSampler()
            colorSampler = sampler
            sampler.show { [weak self] color in
                DispatchQueue.main.async {
                    self?.colorSampler = nil
                    guard let color, let value = ScreenColor(nsColor: color) else { return }
                    self?.present(color: value)
                }
            }
        }
    }

    private func changeShortcut(
        text: SwitcherShortcut?,
        color: SwitcherShortcut?,
        commit: () -> Void
    ) -> Bool {
        if let text, let color, text == color { return false }
        let oldText = textCaptureShortcut
        let oldColor = colorPickerShortcut
        shortcutMonitor?.stop()
        shortcutMonitor = nil
        if installShortcutMonitor(textShortcut: text, colorShortcut: color) {
            commit()
            return true
        }
        _ = installShortcutMonitor(textShortcut: oldText, colorShortcut: oldColor)
        return false
    }

    private func installShortcutMonitor(
        textShortcut: SwitcherShortcut?,
        colorShortcut: SwitcherShortcut?
    ) -> Bool {
        var registrations: [GlobalShortcutMonitor.Registration] = []
        if let textShortcut {
            registrations.append(.init(shortcut: textShortcut) { [weak self] in
                self?.perform(.copyTextFromScreen)
            })
        }
        if let colorShortcut {
            registrations.append(.init(shortcut: colorShortcut) { [weak self] in
                self?.perform(.pickColorFromScreen)
            })
        }
        let monitor = GlobalShortcutMonitor(
            signature: 0x5343_524E, // SCRN
            registrations: registrations,
            startsImmediately: false
        )
        guard monitor.start() else { return false }
        shortcutMonitor = monitor
        return true
    }

    private func processTextSelection(_ rectangle: CGRect) async {
        do {
            let image = try await captureService.capture(rectangle: rectangle)
            let qrTask = Task { [qrDetector] in
                preferences.detectScreenQRCodes ? await qrDetector.detect(in: image) : []
            }
            let recognition: ScreenTextRecognition
            do {
                recognition = try await textRecognizer.recognize(in: image)
            } catch {
                let codes = await qrTask.value
                if !codes.isEmpty {
                    resultPanel.showQRCodes(codes, notice: "Text recognition failed.")
                } else {
                    resultPanel.showMessage("Text recognition failed.", symbol: "exclamationmark.triangle")
                }
                return
            }
            let codes = await qrTask.value
            let text = meaningfulText(recognition, qrCodes: codes)
            if !text.isEmpty { Self.copyToClipboard(text) }

            if !codes.isEmpty {
                resultPanel.showQRCodes(codes)
            } else if text.isEmpty {
                resultPanel.showMessage("No text found.", symbol: "text.magnifyingglass")
            } else {
                resultPanel.showMessage("Text copied.", symbol: "doc.on.clipboard")
            }
        } catch ScreenCaptureFailure.permissionDenied {
            showScreenRecordingExplanation()
        } catch {
            resultPanel.showMessage("Screen capture failed.", symbol: "exclamationmark.triangle")
        }
    }

    private func meaningfulText(_ recognition: ScreenTextRecognition, qrCodes: [DetectedQRCode]) -> String {
        let text = recognition.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        if qrCodes.contains(where: { $0.value == text || $0.value == normalized }) { return "" }
        let largeQR = qrCodes.contains { $0.boundingBox.width * $0.boundingBox.height > 0.35 }
        if largeQR && recognition.fragmentCount <= 2 { return "" }
        return text
    }

    private func processColorPoint(_ point: CGPoint) async {
        do {
            let image = try await captureService.capture(point: point)
            guard let color = ScreenColor(image: image) else {
                pickColorWithSystemSamplerAfterFailure()
                return
            }
            present(color: color)
        } catch {
            pickColorWithSystemSamplerAfterFailure()
        }
    }

    private func pickColorWithSystemSamplerAfterFailure() {
        resultPanel.showMessage("Using the macOS colour sampler.", symbol: "eyedropper")
        let sampler = NSColorSampler()
        colorSampler = sampler
        sampler.show { [weak self] color in
            DispatchQueue.main.async {
                self?.colorSampler = nil
                guard let color, let value = ScreenColor(nsColor: color) else { return }
                self?.present(color: value)
            }
        }
    }

    private func present(color: ScreenColor) {
        let format = preferences.screenColorCopyFormat
        if preferences.screenColorAutomaticallyCopies {
            Self.copyToClipboard(color.formatted(as: format))
        }
        resultPanel.showColor(color, preferredFormat: format)
    }

    private func showScreenRecordingExplanation() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Screen Recording Required"
        alert.informativeText = "WarpTab needs Screen Recording permission to capture text from the screen. Recognition stays entirely on this Mac."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { ScreenRecordingPermission.openSettings() }
    }

    private static func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
