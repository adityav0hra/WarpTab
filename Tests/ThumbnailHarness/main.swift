import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

private func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

guard CommandLine.arguments.count == 2 else { exit(2) }
post(58, down: true, flags: [.maskAlternate])
post(48, down: true, flags: [.maskAlternate])
post(48, down: false, flags: [.maskAlternate])
wait(1.5)

let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] ?? []
let candidate = windows.compactMap { info -> (CGWindowID, CGFloat)? in
    guard (info[kCGWindowOwnerName as String] as? String) == "WarpTab",
          let number = info[kCGWindowNumber as String] as? NSNumber,
          let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
          bounds.width > 400 else { return nil }
    return (CGWindowID(number.uint32Value), bounds.width * bounds.height)
}.max(by: { $0.1 < $1.1 })

guard let windowID = candidate?.0,
      let image = CGWindowListCreateImage(
        .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]
      ) else {
    post(58, down: false, flags: [])
    exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let destination = CGImageDestinationCreateWithURL(
    url, UTType.png.identifier as CFString, 1, nil
) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }

post(53, down: true, flags: [.maskAlternate])
post(53, down: false, flags: [.maskAlternate])
post(58, down: false, flags: [])
print("Thumbnail overlay captured to \(CommandLine.arguments[1])")
