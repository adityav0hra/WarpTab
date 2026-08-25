import AppKit
import CoreGraphics
import Vision

private func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

private func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

private func press(_ keyCode: CGKeyCode) {
    postKey(keyCode, down: true, flags: [.maskAlternate])
    postKey(keyCode, down: false, flags: [.maskAlternate])
    wait(0.025)
}

private func overlayWindow() -> CGWindowID? {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return windows.compactMap { info -> (CGWindowID, CGFloat)? in
        guard (info[kCGWindowOwnerName as String] as? String) == "WarpTab",
              let number = info[kCGWindowNumber as String] as? NSNumber,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              bounds.width > 200, bounds.height > 40 else { return nil }
        return (CGWindowID(number.uint32Value), bounds.width * bounds.height)
    }.max(by: { $0.1 < $1.1 })?.0
}

private func captureText(windowID: CGWindowID) throws -> String {
    guard let image = CGWindowListCreateImage(
        .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]
    ) else { throw NSError(domain: "WarpTabStress", code: 1) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

private let keyCodes: [Character: CGKeyCode] = [
    "s": 1, "t": 17, "r": 15, "e": 14, " ": 49,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
    "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
]

guard CommandLine.arguments.count == 2, let count = Int(CommandLine.arguments[1]) else {
    fputs("usage: stress-harness <window-count>\n", stderr)
    exit(2)
}

postKey(58, down: true, flags: [.maskAlternate])
let start = CFAbsoluteTimeGetCurrent()
press(48)
var windowID: CGWindowID?
while CFAbsoluteTimeGetCurrent() - start < 2 {
    if let current = overlayWindow() {
        windowID = current
        break
    }
    wait(0.01)
}
guard windowID != nil else {
    postKey(58, down: false, flags: [])
    fputs("overlay did not appear for \(count) windows\n", stderr)
    exit(1)
}
let latency = CFAbsoluteTimeGetCurrent() - start
// The panel becomes visible before AppKit finishes laying out a very large row
// set. Let that first layout drain so synthetic search keystrokes are not queued
// against a still-busy test process (physical keyboard input is naturally slower).
wait(0.2)

let query = "stress \(String(format: "%03d", count))"
for character in query {
    guard let keyCode = keyCodes[character] else { continue }
    press(keyCode)
}
wait(0.35)
guard let filteredWindow = overlayWindow() else {
    postKey(58, down: false, flags: [])
    fputs("overlay disappeared during search for \(count) windows\n", stderr)
    exit(1)
}
let text = try captureText(windowID: filteredWindow)
press(53)
wait(0.15)
postKey(58, down: false, flags: [])

guard text.contains(String(format: "%03d", count)) else {
    fputs("last window was not searchable for \(count) windows; OCR=\(text)\n", stderr)
    exit(1)
}
guard latency < 1 else {
    fputs("overlay latency \(latency)s exceeded 1s for \(count) windows\n", stderr)
    exit(1)
}
print(String(format: "%d windows: %.3fs overlay latency, last window searchable", count, latency))
