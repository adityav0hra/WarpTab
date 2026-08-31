import CoreGraphics

enum ScreenToolsGeometry {
    static func standardizedRect(from first: CGPoint, to second: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    /// Converts a global AppKit rectangle (bottom-left origin) into a
    /// ScreenCaptureKit display-local rectangle (top-left origin).
    static func displayLocalSourceRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: selection.minX - screenFrame.minX,
            y: screenFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }

    static func compositeTargetRect(
        intersection: CGRect,
        selection: CGRect,
        outputScale: CGFloat
    ) -> CGRect {
        CGRect(
            x: (intersection.minX - selection.minX) * outputScale,
            y: (intersection.minY - selection.minY) * outputScale,
            width: intersection.width * outputScale,
            height: intersection.height * outputScale
        )
    }
}
