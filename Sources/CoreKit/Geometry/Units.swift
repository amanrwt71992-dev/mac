import Foundation

// MARK: - Twip

/// Word's fundamental unit of length: one twentieth of a point.
///
/// Every distance in `w:sectPr`, `w:pgMar`, `w:pgSz`, `w:ind`, `w:spacing`,
/// `w:tabs` and `w:tcMar` is expressed in twips. 1 inch = 1440 twips,
/// 1 cm = 567 twips (rounded), 1 point = 20 twips.
///
/// Keeping this a distinct type rather than a bare `Int` prevents an entire
/// category of unit bug, which is the single most common source of layout
/// drift in OOXML implementations.
public struct Twip: Hashable, Sendable, Comparable, CustomStringConvertible {

    /// The raw OOXML value, in twentieths of a point.
    public let rawValue: Int32

    public init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Creates a twip length from a value in points (1 point = 20 twips).
    public init(points: Double) {
        self.rawValue = Int32((points * 20.0).rounded())
    }

    /// Creates a twip length from a value in inches (1 inch = 1440 twips).
    public init(inches: Double) {
        self.rawValue = Int32((inches * 1440.0).rounded())
    }

    /// Creates a twip length from a value in millimetres.
    public init(millimetres: Double) {
        self.rawValue = Int32((millimetres / 25.4 * 1440.0).rounded())
    }

    public static let zero = Twip(0)

    /// One inch.
    public static let inch = Twip(1440)

    /// One point.
    public static let point = Twip(20)

    public var points: Double { Double(rawValue) / 20.0 }

    public var inches: Double { Double(rawValue) / 1440.0 }

    public var millimetres: Double { Double(rawValue) / 1440.0 * 25.4 }

    public static func < (lhs: Twip, rhs: Twip) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    public static func + (lhs: Twip, rhs: Twip) -> Twip {
        return Twip(lhs.rawValue + rhs.rawValue)
    }

    public static func - (lhs: Twip, rhs: Twip) -> Twip {
        return Twip(lhs.rawValue - rhs.rawValue)
    }

    public var description: String { "\(rawValue)tw" }
}

// MARK: - HalfPoint

/// Font sizes in OOXML are stored in half-points: `w:sz w:val="24"` means 12 pt.
///
/// Word's size picker offers quarter-point steps in some places, but the file
/// format itself is half-point, so that is the unit we model.
public struct HalfPoint: Hashable, Sendable, Comparable, CustomStringConvertible {

    /// The raw OOXML value, in half-points.
    public let rawValue: Int32

    public init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    public init(points: Double) {
        self.rawValue = Int32((points * 2.0).rounded())
    }

    public var points: Double { Double(rawValue) / 2.0 }

    public static func < (lhs: HalfPoint, rhs: HalfPoint) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    public var description: String { "\(rawValue)hp" }
}

// MARK: - EMU

/// English Metric Units — the coordinate space of DrawingML (`a:` namespace),
/// used for shape and picture geometry, positions and extents.
///
/// 914,400 EMU = 1 inch; 12,700 EMU = 1 point.
public struct EMU: Hashable, Sendable, Comparable, CustomStringConvertible {

    /// The raw OOXML value.
    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Creates a length from a value in points (1 point = 12,700 EMU).
    public init(points: Double) {
        self.rawValue = Int64((points * 12_700.0).rounded())
    }

    public static let perInch: Int64 = 914_400
    public static let perPoint: Int64 = 12_700

    public var points: Double { Double(rawValue) / 12_700.0 }

    public static let zero = EMU(0)

    public static func < (lhs: EMU, rhs: EMU) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    public var description: String { "\(rawValue)emu" }
}

// MARK: - Percentage

/// Word expresses several quantities as fiftieths of a percent: `w:tblW
/// w:type="pct" w:w="5000"` means exactly 100%. Table widths, cell widths and
/// character scaling (`w:w`) all use this scale.
public struct FiftiethsOfAPercent: Hashable, Sendable, CustomStringConvertible {

    public let rawValue: Int32

    public init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// 100%.
    public static let whole = FiftiethsOfAPercent(5000)

    public init(fraction: Double) {
        self.rawValue = Int32((fraction * 5000.0).rounded())
    }

    /// The value as a fraction, where 1.0 == 100%.
    public var fraction: Double { Double(rawValue) / 5000.0 }

    public var description: String { String(format: "%.2f%%", fraction * 100.0) }
}
