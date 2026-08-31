import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCaptureFailure: Error {
    case permissionDenied
    case noDisplay
    case captureFailed
}

struct ScreenCaptureGeometry {
    static func sourceRect(selection: CGRect, on screen: NSScreen) -> CGRect {
        ScreenToolsGeometry.displayLocalSourceRect(selection: selection, screenFrame: screen.frame)
    }

    static func quartzGlobalRect(appKitRect: CGRect, primaryTop: CGFloat) -> CGRect {
        ScreenCoordinateGeometry.appKitToAccessibility(appKitRect, primaryTop: primaryTop)
    }

    static func pixelScale(for screen: NSScreen) -> CGFloat {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.backingScaleFactor
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let pointWidth = CGDisplayBounds(displayID).width
        guard pointWidth > 0 else { return screen.backingScaleFactor }
        return CGFloat(CGDisplayPixelsWide(displayID)) / pointWidth
    }
}

final class ScreenCaptureService {
    func capture(rectangle: CGRect) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureFailure.permissionDenied }
        let intersections = NSScreen.screens.compactMap { screen -> (NSScreen, CGRect)? in
            let intersection = screen.frame.intersection(rectangle)
            return intersection.isEmpty ? nil : (screen, intersection)
        }
        guard !intersections.isEmpty else { throw ScreenCaptureFailure.noDisplay }

        if #available(macOS 14.0, *) {
            return try await captureModern(rectangle: rectangle, intersections: intersections)
        }
        let primaryTop = NSScreen.warpHardwareMain?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        let quartzRect = ScreenCaptureGeometry.quartzGlobalRect(appKitRect: rectangle, primaryTop: primaryTop)
        guard let image = CGWindowListCreateImage(
            quartzRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else { throw ScreenCaptureFailure.captureFailed }
        return image
    }

    func capture(point: CGPoint) async throws -> CGImage {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            throw ScreenCaptureFailure.noDisplay
        }
        let scale = ScreenCaptureGeometry.pixelScale(for: screen)
        let unit = 1 / max(1, scale)
        let rect = CGRect(x: point.x - unit / 2, y: point.y - unit / 2, width: unit, height: unit)
        return try await capture(rectangle: rect)
    }

    @available(macOS 14.0, *)
    private func captureModern(
        rectangle: CGRect,
        intersections: [(NSScreen, CGRect)]
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var pieces: [(image: CGImage, frame: CGRect)] = []
        var outputScale: CGFloat = 1

        for (screen, intersection) in intersections {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let scale = ScreenCaptureGeometry.pixelScale(for: screen)
            outputScale = max(outputScale, scale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = ScreenCaptureGeometry.sourceRect(selection: intersection, on: screen)
            configuration.width = max(1, Int((intersection.width * scale).rounded(.up)))
            configuration.height = max(1, Int((intersection.height * scale).rounded(.up)))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            pieces.append((image, intersection))
        }

        guard !pieces.isEmpty,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: max(1, Int((rectangle.width * outputScale).rounded(.up))),
                height: max(1, Int((rectangle.height * outputScale).rounded(.up))),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw ScreenCaptureFailure.captureFailed }

        context.interpolationQuality = .none
        for piece in pieces {
            let target = ScreenToolsGeometry.compositeTargetRect(
                intersection: piece.frame,
                selection: rectangle,
                outputScale: outputScale
            )
            context.draw(piece.image, in: target)
        }
        guard let image = context.makeImage() else { throw ScreenCaptureFailure.captureFailed }
        return image
    }
}

enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
