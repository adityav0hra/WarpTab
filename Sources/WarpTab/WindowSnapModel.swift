import CoreGraphics
import Foundation

enum SnapDirection: CaseIterable {
    case left
    case right
    case up
    case down
}

enum SnapState: Equatable {
    case floating
    case leftHalf
    case rightHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case maximized
    case minimized
}

enum SnapTransitionAction: Equatable {
    case place(SnapState)
    case restore
    case minimize
}

struct SnapTransitionResult: Equatable {
    let action: SnapTransitionAction
    let movesToAdjacentDisplay: Bool
}

enum SnapStateMachine {
    static func transition(
        from state: SnapState,
        direction: SnapDirection,
        hasAdjacentDisplay: Bool
    ) -> SnapTransitionResult {
        switch direction {
        case .left:
            return horizontalTransition(
                from: state,
                towardLeft: true,
                hasAdjacentDisplay: hasAdjacentDisplay
            )
        case .right:
            return horizontalTransition(
                from: state,
                towardLeft: false,
                hasAdjacentDisplay: hasAdjacentDisplay
            )
        case .up:
            return upTransition(from: state, hasAdjacentDisplay: hasAdjacentDisplay)
        case .down:
            return downTransition(from: state, hasAdjacentDisplay: hasAdjacentDisplay)
        }
    }

    private static func horizontalTransition(
        from state: SnapState,
        towardLeft: Bool,
        hasAdjacentDisplay: Bool
    ) -> SnapTransitionResult {
        let result: (SnapState, Bool)
        if towardLeft {
            result = switch state {
            case .floating, .rightHalf, .maximized, .minimized: (.leftHalf, false)
            case .leftHalf: hasAdjacentDisplay ? (.rightHalf, true) : (.leftHalf, false)
            case .topRight: (.topLeft, false)
            case .topLeft: hasAdjacentDisplay ? (.topRight, true) : (.topLeft, false)
            case .bottomRight: (.bottomLeft, false)
            case .bottomLeft: hasAdjacentDisplay ? (.bottomRight, true) : (.bottomLeft, false)
            }
        } else {
            result = switch state {
            case .floating, .leftHalf, .maximized, .minimized: (.rightHalf, false)
            case .rightHalf: hasAdjacentDisplay ? (.leftHalf, true) : (.rightHalf, false)
            case .topLeft: (.topRight, false)
            case .topRight: hasAdjacentDisplay ? (.topLeft, true) : (.topRight, false)
            case .bottomLeft: (.bottomRight, false)
            case .bottomRight: hasAdjacentDisplay ? (.bottomLeft, true) : (.bottomRight, false)
            }
        }
        return SnapTransitionResult(action: .place(result.0), movesToAdjacentDisplay: result.1)
    }

    private static func upTransition(
        from state: SnapState,
        hasAdjacentDisplay: Bool
    ) -> SnapTransitionResult {
        let result: (SnapState, Bool) = switch state {
        case .floating, .minimized: (.maximized, false)
        case .leftHalf, .bottomLeft: (.topLeft, false)
        case .rightHalf, .bottomRight: (.topRight, false)
        case .topLeft, .topRight: (.maximized, false)
        case .maximized:
            hasAdjacentDisplay ? (.maximized, true) : (.maximized, false)
        }
        return SnapTransitionResult(action: .place(result.0), movesToAdjacentDisplay: result.1)
    }

    private static func downTransition(
        from state: SnapState,
        hasAdjacentDisplay: Bool
    ) -> SnapTransitionResult {
        switch state {
        case .floating, .minimized:
            return SnapTransitionResult(action: .minimize, movesToAdjacentDisplay: false)
        case .maximized:
            return SnapTransitionResult(action: .restore, movesToAdjacentDisplay: false)
        case .leftHalf, .topLeft:
            return SnapTransitionResult(action: .place(.bottomLeft), movesToAdjacentDisplay: false)
        case .rightHalf, .topRight:
            return SnapTransitionResult(action: .place(.bottomRight), movesToAdjacentDisplay: false)
        case .bottomLeft:
            if hasAdjacentDisplay {
                return SnapTransitionResult(action: .place(.topLeft), movesToAdjacentDisplay: true)
            }
            return SnapTransitionResult(action: .minimize, movesToAdjacentDisplay: false)
        case .bottomRight:
            if hasAdjacentDisplay {
                return SnapTransitionResult(action: .place(.topRight), movesToAdjacentDisplay: true)
            }
            return SnapTransitionResult(action: .minimize, movesToAdjacentDisplay: false)
        }
    }
}

enum SnapGeometry {
    static func frame(for state: SnapState, in workArea: CGRect) -> CGRect? {
        let halfWidth = workArea.width / 2
        let halfHeight = workArea.height / 2
        switch state {
        case .floating, .minimized:
            return nil
        case .leftHalf:
            return CGRect(x: workArea.minX, y: workArea.minY, width: halfWidth, height: workArea.height)
        case .rightHalf:
            return CGRect(x: workArea.minX + halfWidth, y: workArea.minY, width: workArea.width - halfWidth, height: workArea.height)
        case .topLeft:
            return CGRect(x: workArea.minX, y: workArea.minY, width: halfWidth, height: halfHeight)
        case .topRight:
            return CGRect(x: workArea.minX + halfWidth, y: workArea.minY, width: workArea.width - halfWidth, height: halfHeight)
        case .bottomLeft:
            return CGRect(x: workArea.minX, y: workArea.minY + halfHeight, width: halfWidth, height: workArea.height - halfHeight)
        case .bottomRight:
            return CGRect(x: workArea.minX + halfWidth, y: workArea.minY + halfHeight, width: workArea.width - halfWidth, height: workArea.height - halfHeight)
        case .maximized:
            return workArea
        }
    }

    static func recognizedState(
        for frame: CGRect,
        in workArea: CGRect,
        tolerance: CGFloat = 8
    ) -> SnapState {
        for state in [
            SnapState.maximized, .leftHalf, .rightHalf,
            .topLeft, .topRight, .bottomLeft, .bottomRight
        ] {
            guard let candidate = self.frame(for: state, in: workArea) else { continue }
            if frame.approximatelyEquals(candidate, tolerance: tolerance) { return state }
        }
        return .floating
    }
}

enum ScreenSpatialGeometry {
    static func screenContainingLargestArea(
        of window: CGRect,
        screens: [DisplaySnapshot]
    ) -> DisplaySnapshot? {
        screens.max { left, right in
            intersectionArea(left.frame, window) < intersectionArea(right.frame, window)
        }
    }

    static func adjacentScreen(
        to source: DisplaySnapshot,
        direction: SnapDirection,
        screens: [DisplaySnapshot]
    ) -> DisplaySnapshot? {
        let candidates = screens.filter { screen in
            guard screen.identifier != source.identifier else { return false }
            let deltaX = screen.frame.midX - source.frame.midX
            let deltaY = screen.frame.midY - source.frame.midY
            switch direction {
            case .left: return deltaX < 0 && abs(deltaX) >= abs(deltaY) * 0.25
            case .right: return deltaX > 0 && abs(deltaX) >= abs(deltaY) * 0.25
            case .up: return deltaY < 0 && abs(deltaY) >= abs(deltaX) * 0.25
            case .down: return deltaY > 0 && abs(deltaY) >= abs(deltaX) * 0.25
            }
        }
        return candidates.min { candidateScore($0, from: source, direction: direction) < candidateScore($1, from: source, direction: direction) }
    }

    private static func candidateScore(
        _ candidate: DisplaySnapshot,
        from source: DisplaySnapshot,
        direction: SnapDirection
    ) -> CGFloat {
        let primaryDistance: CGFloat
        let perpendicularDistance: CGFloat
        let overlapsPerpendicularAxis: Bool
        switch direction {
        case .left, .right:
            primaryDistance = abs(candidate.frame.midX - source.frame.midX)
            perpendicularDistance = abs(candidate.frame.midY - source.frame.midY)
            overlapsPerpendicularAxis = candidate.frame.minY < source.frame.maxY && candidate.frame.maxY > source.frame.minY
        case .up, .down:
            primaryDistance = abs(candidate.frame.midY - source.frame.midY)
            perpendicularDistance = abs(candidate.frame.midX - source.frame.midX)
            overlapsPerpendicularAxis = candidate.frame.minX < source.frame.maxX && candidate.frame.maxX > source.frame.minX
        }
        // Prefer a display that is actually in the same row/column, while still
        // supporting diagonal arrangements when no aligned display exists.
        return primaryDistance + perpendicularDistance * 1.5 + (overlapsPerpendicularAxis ? 0 : 10_000)
    }

    private static func intersectionArea(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

enum ScreenCoordinateGeometry {
    static func appKitToAccessibility(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func accessibilityToAppKit(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance &&
            abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }
}
