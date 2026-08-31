import AppKit
import SwiftUI

@MainActor
final class ScreenToolsResultPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let preferences: WarpPreferences

    init(preferences: WarpPreferences) {
        self.preferences = preferences
    }

    func showMessage(_ message: String, symbol: String = "checkmark.circle") {
        show(
            AnyView(
                HStack(spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(Color.accentColor)
                    Text(message).font(.callout)
                }
                .padding(16)
            ),
            size: NSSize(width: 270, height: 70)
        )
    }

    func showQRCodes(_ codes: [DetectedQRCode], notice: String? = nil) {
        show(
            AnyView(QRCodeResultView(codes: Array(codes.prefix(5)), notice: notice)),
            size: NSSize(width: 410, height: min(350, 112 + codes.count * 62 + (notice == nil ? 0 : 34)))
        )
    }

    func showColor(_ color: ScreenColor, preferredFormat: ScreenColorCopyFormat) {
        show(
            AnyView(ColorResultView(
                color: color,
                preferredFormat: preferredFormat,
                copy: { Self.copy($0) }
            )),
            size: NSSize(width: 430, height: 300)
        )
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) { dismiss() }

    private func show(_ content: AnyView, size: NSSize) {
        dismiss()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.animationBehavior = preferences.animationsEnabled ? .utilityWindow : .none
        panel.contentView = NSHostingView(rootView: content)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            let origin = CGPoint(
                x: min(max(mouse.x - size.width / 2, visibleFrame.minX + 12), visibleFrame.maxX - size.width - 12),
                y: min(max(mouse.y - size.height - 22, visibleFrame.minY + 12), visibleFrame.maxY - size.height - 12)
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        self.panel = panel
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

private struct QRCodeResultView: View {
    let codes: [DetectedQRCode]
    let notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("QR Code", systemImage: "qrcode")
                .font(.headline)
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(codes) { code in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(code.value)
                                .font(.callout)
                                .textSelection(.enabled)
                                .lineLimit(3)
                            HStack(spacing: 8) {
                                Button("Copy") { ScreenToolsResultPanelController.copy(code.value) }
                                    .accessibilityLabel("Copy QR code contents")
                                if let url = code.url {
                                    Button("Open Link") { NSWorkspace.shared.open(url) }
                                        .accessibilityLabel("Open QR code link")
                                }
                            }
                            .controlSize(.small)
                        }
                        if code.id != codes.last?.id { Divider() }
                    }
                }
            }
        }
        .padding(16)
    }
}

private struct ColorResultView: View {
    let color: ScreenColor
    let preferredFormat: ScreenColorCopyFormat
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: color.nsColor))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
                    .frame(width: 54, height: 54)
                    .accessibilityLabel("Selected colour preview")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selected Colour").font(.headline)
                    Text(color.formatted(as: preferredFormat))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
                }
            }
            Divider()
            ForEach(ScreenColorCopyFormat.allCases) { format in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(format.displayName)
                        .font(.caption.weight(format == preferredFormat ? .semibold : .regular))
                        .foregroundStyle(format == preferredFormat ? Color.accentColor : Color.secondary)
                        .frame(width: 54, alignment: .leading)
                    Text(color.formatted(as: format))
                        .font(.system(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Copy") { copy(color.formatted(as: preferredFormat)) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Copy selected colour")
            }
        }
        .padding(16)
    }
}
