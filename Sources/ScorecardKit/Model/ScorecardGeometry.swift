import Foundation

/// A rectangle in *normalized card space*: origin top-left, x to the right, y **down**, both in `0...1`.
///
/// Vision reports normalized rects with a bottom-left origin. `TextObservation` converts once, at the
/// boundary, so every algorithm in ScorecardKit can reason in ordinary reading order (smaller `y` == higher
/// on the card). Mixing the two conventions is the single easiest way to write a scorecard parser that
/// silently reads the card upside down, so the conversion lives in exactly one place.
public struct CardRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// Builds a rect from a Vision-style normalized rect (bottom-left origin).
    public static func fromBottomLeftOrigin(x: Double, y: Double, width: Double, height: Double) -> CardRect {
        CardRect(x: x, y: 1.0 - y - height, width: width, height: height)
    }

    public func union(_ other: CardRect) -> CardRect {
        let minX = Swift.min(self.minX, other.minX)
        let minY = Swift.min(self.minY, other.minY)
        let maxX = Swift.max(self.maxX, other.maxX)
        let maxY = Swift.max(self.maxY, other.maxY)
        return CardRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func insetBy(dx: Double, dy: Double) -> CardRect {
        CardRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    public func contains(x pointX: Double) -> Bool {
        pointX >= minX && pointX <= maxX
    }

    /// Fraction of `self`'s height that overlaps `other`'s vertical span.
    public func verticalOverlapRatio(with other: CardRect) -> Double {
        let overlap = Swift.min(maxY, other.maxY) - Swift.max(minY, other.minY)
        guard overlap > 0 else { return 0 }
        let smaller = Swift.min(height, other.height)
        guard smaller > 0 else { return 0 }
        return overlap / smaller
    }

    /// Fraction of `self`'s width that overlaps `other`'s horizontal span.
    public func horizontalOverlapRatio(with other: CardRect) -> Double {
        let overlap = Swift.min(maxX, other.maxX) - Swift.max(minX, other.minX)
        guard overlap > 0 else { return 0 }
        let smaller = Swift.min(width, other.width)
        guard smaller > 0 else { return 0 }
        return overlap / smaller
    }

    public func intersectionOverUnion(_ other: CardRect) -> Double {
        let interW = Swift.min(maxX, other.maxX) - Swift.max(minX, other.minX)
        let interH = Swift.min(maxY, other.maxY) - Swift.max(minY, other.minY)
        guard interW > 0, interH > 0 else { return 0 }
        let inter = interW * interH
        let union = width * height + other.width * other.height - inter
        guard union > 0 else { return 0 }
        return inter / union
    }

    /// Rotates the rect's centre by `radians` about `pivot` and keeps the original extent.
    ///
    /// Deskewing a scorecard only needs cell *centres* to line up into rows; re-deriving an axis-aligned
    /// bounding box for the rotated corners would inflate every box and blur the row bands we are trying
    /// to sharpen, so the extent is deliberately preserved.
    public func rotatingCenter(by radians: Double, around pivot: (x: Double, y: Double)) -> CardRect {
        let cosA = cos(radians)
        let sinA = sin(radians)
        let dx = midX - pivot.x
        let dy = midY - pivot.y
        let rx = dx * cosA - dy * sinA + pivot.x
        let ry = dx * sinA + dy * cosA + pivot.y
        return CardRect(x: rx - width / 2, y: ry - height / 2, width: width, height: height)
    }
}
