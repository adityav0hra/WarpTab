import AppKit
import Carbon.HIToolbox
import CoreGraphics

private var assertions = 0

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let suiteName = "com.warptab.tests.mouse.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suiteName) else {
    fatalError("Could not create isolated defaults suite")
}
defer { defaults.removePersistentDomain(forName: suiteName) }

let settings = MouseSettings(defaults: defaults)
require(!settings.isEnabled, "mouse features default off")
require(!settings.reverseVerticalScrolling, "vertical reversal defaults off")
require(!settings.reverseHorizontalScrolling, "horizontal reversal defaults off")
require(settings.action(for: .button(3)) == .back, "button 4 defaults to Back")
require(settings.action(for: .button(4)) == .forward, "button 5 defaults to Forward")
require(MouseInput.button(3).displayName == "Back Button", "back button has a friendly name")
require(MouseInput.button(5).displayName == "Mouse Button 6", "extra buttons use one-based display names")
require(MouseInput.sideWheel(.left).displayName == "Side Wheel Left", "side wheel has a friendly name")

let shortcut = MouseKeyboardShortcut(
    keyCode: UInt16(kVK_ANSI_T),
    carbonModifiers: UInt32(cmdKey | shiftKey),
    keyLabel: "T"
)
require(shortcut.displayName == "⇧⌘T", "shortcut displays standard modifier symbols")
settings.reverseVerticalScrolling = true
settings.isEnabled = true
settings.setAction(.keyboardShortcut(shortcut), for: .button(5))
settings.setAction(.forward, for: .button(5))
require(settings.customMappings.count == 1, "reassigning an input replaces rather than duplicates")
require(settings.action(for: .button(5)) == .forward, "replacement action is active")

let reloaded = MouseSettings(defaults: defaults)
require(reloaded.isEnabled, "mouse feature state survives reload")
require(reloaded.reverseVerticalScrolling, "scroll preference survives reload")
require(reloaded.customMappings.count == 1, "custom mapping survives reload")
require(reloaded.action(for: .button(5)) == .forward, "custom action survives reload")
reloaded.removeMapping(for: .button(5))
require(reloaded.action(for: .button(5)) == nil, "removing a custom mapping restores pass-through")

guard let lineEvent = CGEvent(
    scrollWheelEvent2Source: nil,
    units: .line,
    wheelCount: 2,
    wheel1: 1,
    wheel2: 1,
    wheel3: 0
), let pixelEvent = CGEvent(
    scrollWheelEvent2Source: nil,
    units: .pixel,
    wheelCount: 2,
    wheel1: 1,
    wheel2: 1,
    wheel3: 0
) else {
    fatalError("Could not create scroll events")
}
require(MouseScrollClassifier.isPhysicalMouseScroll(lineEvent), "line-based wheel event is classified as mouse")
require(!MouseScrollClassifier.isPhysicalMouseScroll(pixelEvent), "pixel-based scroll event is protected")

print("WarpTab mouse tests passed: \(assertions) assertions")
