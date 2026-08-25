import AppKit
import CoreGraphics

private func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

private func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

private let keyCodes: [Character: CGKeyCode] = [
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
    "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
    "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
    "v": 9, "w": 13, "x": 7, "y": 16, "z": 6, " ": 49
]

guard CommandLine.arguments.count == 3 else { exit(2) }
let query = CommandLine.arguments[1].lowercased()
let expected = CommandLine.arguments[2].lowercased()

post(58, down: true, flags: [.maskAlternate])
post(48, down: true, flags: [.maskAlternate])
post(48, down: false, flags: [.maskAlternate])
wait(0.25)
for character in query {
    guard let key = keyCodes[character] else { continue }
    post(key, down: true, flags: [.maskAlternate])
    post(key, down: false, flags: [.maskAlternate])
    wait(0.025)
}
wait(0.2)
post(36, down: true, flags: [.maskAlternate])
post(36, down: false, flags: [.maskAlternate])
wait(0.9)
post(58, down: false, flags: [])
wait(0.15)

let active = (NSWorkspace.shared.frontmostApplication?.localizedName ?? "").lowercased()
guard active.contains(expected) else {
    fputs("query '\(query)' expected '\(expected)', activated '\(active)'\n", stderr)
    exit(1)
}
print("\(query): activated \(active)")
