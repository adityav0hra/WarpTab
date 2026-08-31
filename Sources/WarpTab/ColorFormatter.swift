import AppKit
import CoreGraphics

enum ScreenColorCopyFormat: String, CaseIterable, Identifiable {
    case hex
    case rgb
    case hsl
    case swiftUI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        case .swiftUI: return "SwiftUI"
        }
    }
}

struct ScreenColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
        self.alpha = min(1, max(0, alpha))
    }

    init?(nsColor: NSColor) {
        guard let color = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
    }

    init?(image: CGImage) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let alpha = Double(pixel[3]) / 255
        let divisor = alpha > 0 ? alpha : 1
        self.init(
            red: Double(pixel[0]) / 255 / divisor,
            green: Double(pixel[1]) / 255 / divisor,
            blue: Double(pixel[2]) / 255 / divisor,
            alpha: alpha
        )
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    func formatted(as format: ScreenColorCopyFormat) -> String {
        switch format {
        case .hex: return formatHex()
        case .rgb: return formatRGB()
        case .hsl: return formatHSL()
        case .swiftUI: return formatSwiftUI()
        }
    }

    func formatHex() -> String {
        String(format: "#%02X%02X%02X", red8, green8, blue8)
    }

    func formatRGB() -> String {
        "rgb(\(red8), \(green8), \(blue8))"
    }

    func formatHSL() -> String {
        let hsl = hslComponents
        return "hsl(\(Int(hsl.hue.rounded())), \(Int((hsl.saturation * 100).rounded()))%, \(Int((hsl.lightness * 100).rounded()))%)"
    }

    func formatSwiftUI() -> String {
        String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", red, green, blue)
    }

    var hslComponents: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        guard delta > 0 else { return (0, 0, lightness) }

        let saturation = delta / (1 - abs(2 * lightness - 1))
        let rawHue: Double
        if maximum == red {
            rawHue = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6))
        } else if maximum == green {
            rawHue = 60 * (((blue - red) / delta) + 2)
        } else {
            rawHue = 60 * (((red - green) / delta) + 4)
        }
        return (rawHue < 0 ? rawHue + 360 : rawHue, saturation, lightness)
    }

    private var red8: Int { Int((red * 255).rounded()) }
    private var green8: Int { Int((green * 255).rounded()) }
    private var blue8: Int { Int((blue * 255).rounded()) }
}
