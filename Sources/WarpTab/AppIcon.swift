import AppKit

enum AppIcon {
    static func make() -> NSImage {
        if let url = Bundle.main.url(forResource: "WarpTab", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }
}
