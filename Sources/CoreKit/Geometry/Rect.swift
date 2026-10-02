import Foundation

// MARK: - Rect

/// A rectangle in the layout coordinate space, in **points**, origin at the
/// top-left of the page (the same convention Word uses and the opposite of
/// AppKit's default flipped-ness).
///
/// Deliberately built on `Double` rather than `CGFloat`/`CGRect` so that
/// `CoreKit` and the pure parts of `LayoutKit` compile and unit-test on Linux.
/// Only `LayoutKit/CoreText` converts to CoreGraphics types, at the boundary.
public struct Rect: Hashable, Sendable, CustomStringConvertible {

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: Point, size: Size) {
        self.x = origin.x
        self.y = origin.y
        self.width = size.width
        self.height = size.height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var origin: Point { Point(x: x, y: y) }
    public var size: Size { Size(width: width, height: height) }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func inset(dx: Double, dy: Double) -> Rect {
        return Rect(
            x: x + dx,
            y: y + dy,
            width: max(0, width - 2 * dx),
            height: max(0, height - 2 * dy)
        )
    }

    public func offsetBy(dx: Double, dy: Double) -> Rect {
        return Rect(x: x + dx, y: y + dy, width: width, height: height)
    }

    public func contains(_ point: Point) -> Bool {
        return point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func intersects(_ other: Rect) -> Bool {
        return maxX > other.minX && other.maxX > minX
            && maxY > other.minY && other.maxY > minY
    }

    public func intersection(_ other: Rect) -> Rect {
        let nx = max(minX, other.minX)
        let ny = max(minY, other.minY)
        let nMaxX = min(maxX, other.maxX)
        let nMaxY = min(maxY, other.maxY)
        return Rect(x: nx, y: ny, width: max(0, nMaxX - nx), height: max(0, nMaxY - ny))
    }

    public func union(_ other: Rect) -> Rect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let nx = min(minX, other.minX)
        let ny = min(minY, other.minY)
        let nMaxX = max(maxX, other.maxX)
        let nMaxY = max(maxY, other.maxY)
        return Rect(x: nx, y: ny, width: nMaxX - nx, height: nMaxY - ny)
    }

    /// The horizontal overlap between two rects, used when deciding whether a
    /// float's exclusion zone actually intersects a given line.
    public func horizontalOverlap(with other: Rect) -> Double {
        let start = max(minX, other.minX)
        let end = min(maxX, other.maxX)
        return max(0, end - start)
    }

    public var description: String {
        return String(format: "(%.1f, %.1f, %.1f × %.1f)", x, y, width, height)
    }
}

// MARK: - Point

public struct Point: Hashable, Sendable, CustomStringConvertible {

    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)

    public func offsetBy(dx: Double, dy: Double) -> Point {
        return Point(x: x + dx, y: y + dy)
    }

    public func distance(to other: Point) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }

    public var description: String { String(format: "(%.1f, %.1f)", x, y) }
}

// MARK: - Size

public struct Size: Hashable, Sendable, CustomStringConvertible {

    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public var description: String {
        return String(format: "%.1f × %.1f", width, height)
    }
}
