import AppKit
import Carbon.HIToolbox

enum SwitcherNavigation { case previous, next, left, right, up, down }
enum SelectedWindowAction { case close, minimize, hideApplication }

enum ScreenToolsHarnessFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let value): return value }
    }
}

private var passed = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ScreenToolsHarnessFailure.assertion(message) }
    passed += 1
}

private func approximately(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.6) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func testPreferences() throws {
    let suite = "com.warptab.screen-tools-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = WarpPreferences(defaults: defaults)

    try expect(preferences.screenTextCaptureShortcutStorageValue == nil, "Text Capture shortcut defaults to unassigned")
    try expect(!preferences.detectScreenQRCodes, "QR detection defaults off")
    try expect(preferences.screenColorPickerShortcutStorageValue == nil, "Color Picker shortcut defaults to unassigned")
    try expect(preferences.screenColorCopyFormat == .hex, "Color format defaults to HEX")
    try expect(!preferences.screenColorAutomaticallyCopies, "Color auto-copy defaults off")
    try expect(!defaults.bool(forKey: "showScreenTextInWarpTabMenu"), "Text Capture menu item defaults off")
    try expect(!defaults.bool(forKey: "showColorPickerInWarpTabMenu"), "Color Picker menu item defaults off")
    try expect(defaults.bool(forKey: "showWarpTabStatusItem"), "WarpTab main menu-bar icon defaults on")

    preferences.screenTextCaptureShortcutStorageValue = "17,6144,T"
    preferences.detectScreenQRCodes = true
    preferences.screenColorPickerShortcutStorageValue = "8,6144,C"
    preferences.screenColorCopyFormat = .hsl
    preferences.screenColorAutomaticallyCopies = true

    try expect(preferences.screenTextCaptureShortcutStorageValue == "17,6144,T", "Text Capture shortcut persists")
    try expect(preferences.detectScreenQRCodes, "QR toggle persists")
    try expect(preferences.screenColorPickerShortcutStorageValue == "8,6144,C", "Color Picker shortcut persists")
    try expect(preferences.screenColorCopyFormat == .hsl, "Color format persists")
    try expect(preferences.screenColorAutomaticallyCopies, "Color auto-copy persists")
}

private func testShortcutModifierIsolation() throws {
    let optionT = SwitcherShortcut(
        keyCode: UInt32(kVK_ANSI_T),
        carbonModifiers: UInt32(optionKey),
        keyLabel: "T"
    )
    try expect(optionT.matchesEventModifiers([.maskAlternate]), "Exact Option shortcut matches")
    try expect(
        optionT.matchesEventModifiers([.maskAlternate, .maskShift]),
        "Shift remains available for reverse switching"
    )
    try expect(
        !optionT.matchesEventModifiers([.maskControl, .maskAlternate]),
        "Control-Option screen tools do not invoke an Option-only switcher"
    )
    try expect(
        !optionT.matchesEventModifiers([.maskCommand, .maskAlternate]),
        "Command-Option does not invoke an Option-only switcher"
    )
}

private func testColorFormatting() throws {
    let red = ScreenColor(red: 1, green: 0, blue: 0)
    let green = ScreenColor(red: 0, green: 1, blue: 0)
    let blue = ScreenColor(red: 0, green: 0, blue: 1)
    let white = ScreenColor(red: 1, green: 1, blue: 1)
    let black = ScreenColor(red: 0, green: 0, blue: 0)
    let grey = ScreenColor(red: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255)

    try expect(red.formatHex() == "#FF0000" && red.formatRGB() == "rgb(255, 0, 0)", "Red HEX and RGB")
    try expect(approximately(red.hslComponents.hue, 0), "Red HSL hue")
    try expect(approximately(green.hslComponents.hue, 120), "Green HSL hue")
    try expect(approximately(blue.hslComponents.hue, 240), "Blue HSL hue")
    try expect(white.formatHSL() == "hsl(0, 0%, 100%)", "White HSL")
    try expect(black.formatHSL() == "hsl(0, 0%, 0%)", "Black HSL")
    try expect(grey.formatHex() == "#808080" && grey.formatHSL() == "hsl(0, 0%, 50%)", "Grey conversion")
    try expect(
        ScreenColor(red: 52.0 / 255, green: 168.0 / 255, blue: 235.0 / 255).formatSwiftUI() ==
            "Color(red: 0.204, green: 0.659, blue: 0.922)",
        "SwiftUI normalized channels"
    )
}

private func testGeometry() throws {
    let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let selection = CGRect(x: -1800, y: 100, width: 300, height: 200)
    try expect(
        ScreenToolsGeometry.displayLocalSourceRect(selection: selection, screenFrame: leftScreen) ==
            CGRect(x: 120, y: 780, width: 300, height: 200),
        "Negative global coordinates convert to display-local top-left coordinates"
    )
    try expect(
        ScreenToolsGeometry.standardizedRect(from: CGPoint(x: 40, y: 80), to: CGPoint(x: -20, y: 10)) ==
            CGRect(x: -20, y: 10, width: 60, height: 70),
        "Reverse drags standardize"
    )
    try expect(
        ScreenToolsGeometry.compositeTargetRect(
            intersection: CGRect(x: -200, y: 50, width: 100, height: 75),
            selection: CGRect(x: -300, y: 0, width: 500, height: 300),
            outputScale: 2
        ) == CGRect(x: 200, y: 100, width: 200, height: 150),
        "Mixed-display pieces preserve scaled placement"
    )
}

do {
    try testPreferences()
    try testShortcutModifierIsolation()
    try testColorFormatting()
    try testGeometry()
    print("WarpTab Screen Tools tests passed: \(passed) assertions")
} catch {
    fputs("WarpTab Screen Tools tests failed: \(error)\n", stderr)
    exit(1)
}
