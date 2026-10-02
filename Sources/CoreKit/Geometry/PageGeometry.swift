import Foundation

// MARK: - PageOrientation

public enum PageOrientation: String, Hashable, Sendable, CaseIterable {
    case portrait
    case landscape
}

// MARK: - PageSize

/// The physical page, as `w:pgSz`.
///
/// Note that OOXML stores the *effective* width and height — for landscape, Word
/// writes the two values swapped and sets `w:orient="landscape"`. We follow the
/// same convention so that a round trip is stable.
public struct PageSize: Hashable, Sendable {

    public var width: Twip
    public var height: Twip
    public var orientation: PageOrientation

    public init(width: Twip, height: Twip, orientation: PageOrientation = .portrait) {
        self.width = width
        self.height = height
        self.orientation = orientation
    }

    /// A portrait preset rotated into landscape, with the stored values swapped
    /// the way Word swaps them.
    public var landscape: PageSize {
        return PageSize(width: height, height: width, orientation: .landscape)
    }

    public var portrait: PageSize {
        return PageSize(width: min(width, height), height: max(width, height), orientation: .portrait)
    }

    public var widthPoints: Double { width.points }
    public var heightPoints: Double { height.points }

    // Word's Page Size gallery. Values are the twip counts Word itself writes.
    public static let letter = PageSize(width: Twip(12240), height: Twip(15840))        // 8.5 × 11 in
    public static let letterSmall = PageSize(width: Twip(12240), height: Twip(13680))    // 8.5 × 9.5 in
    public static let tabloid = PageSize(width: Twip(15840), height: Twip(24480))        // 11 × 17 in
    public static let ledger = PageSize(width: Twip(24480), height: Twip(15840))         // 17 × 11 in
    public static let legal = PageSize(width: Twip(12240), height: Twip(20160))          // 8.5 × 14 in
    public static let statement = PageSize(width: Twip(7920), height: Twip(12240))       // 5.5 × 8.5 in
    public static let executive = PageSize(width: Twip(10440), height: Twip(15120))      // 7.25 × 10.5 in
    public static let a3 = PageSize(width: Twip(16838), height: Twip(23811))             // 297 × 420 mm
    public static let a4 = PageSize(width: Twip(11906), height: Twip(16838))             // 210 × 297 mm
    public static let a4Small = PageSize(width: Twip(11906), height: Twip(15109))        // 210 × 267 mm
    public static let a5 = PageSize(width: Twip(8391), height: Twip(11906))              // 148 × 210 mm
    public static let b4JIS = PageSize(width: Twip(14570), height: Twip(20636))          // 257 × 364 mm
    public static let b5JIS = PageSize(width: Twip(10319), height: Twip(14570))          // 182 × 257 mm
    public static let envelopeDL = PageSize(width: Twip(6237), height: Twip(12472))      // 110 × 220 mm

    /// The locale-appropriate default. Word ships Letter for the US/Canada and
    /// A4 nearly everywhere else; getting this wrong is immediately visible to
    /// every non-American user on the first blank document they create.
    public static func systemDefault(regionUsesLetter: Bool) -> PageSize {
        return regionUsesLetter ? .letter : .a4
    }
}

// MARK: - PageMargins

/// `w:pgMar`. All seven attributes, in twips.
///
/// `header` and `footer` are distances from the page *edge*, not from the text
/// area — a subtlety that produces visibly wrong output when got backwards.
public struct PageMargins: Hashable, Sendable {

    public var top: Twip
    public var right: Twip
    public var bottom: Twip
    public var left: Twip
    public var header: Twip
    public var footer: Twip
    public var gutter: Twip

    public init(
        top: Twip,
        right: Twip,
        bottom: Twip,
        left: Twip,
        header: Twip = Twip(720),
        footer: Twip = Twip(720),
        gutter: Twip = .zero
    ) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.header = header
        self.footer = footer
        self.gutter = gutter
    }

    /// Word's "Normal": 1″ all round, header and footer at 0.5″.
    public static let normal = PageMargins(
        top: Twip(1440), right: Twip(1440), bottom: Twip(1440), left: Twip(1440),
        header: Twip(720), footer: Twip(720)
    )

    /// Word's "Narrow": 0.5″ all round.
    public static let narrow = PageMargins(
        top: Twip(720), right: Twip(720), bottom: Twip(720), left: Twip(720),
        header: Twip(720), footer: Twip(720)
    )

    /// Word's "Moderate": 1″ top and bottom, 0.75″ left and right.
    public static let moderate = PageMargins(
        top: Twip(1440), right: Twip(1080), bottom: Twip(1440), left: Twip(1080),
        header: Twip(720), footer: Twip(720)
    )

    /// Word's "Wide": 1″ top and bottom, 2″ left and right.
    public static let wide = PageMargins(
        top: Twip(1440), right: Twip(2880), bottom: Twip(1440), left: Twip(2880),
        header: Twip(720), footer: Twip(720)
    )

    /// Mirrored margins for duplex printing: left becomes "inside", right "outside".
    public func mirrored(isRecto: Bool) -> PageMargins {
        guard !isRecto else { return self }
        var copy = self
        copy.left = right
        copy.right = self.left
        return copy
    }
}

// MARK: - ColumnSet

/// `w:cols` — newspaper-style columns within a section.
///
/// Word stores `w:num`, `w:space` (default spacing), `w:sep` (draw a line
/// between columns) and `w:equalWidth`. When widths are unequal, individual
/// `w:col` children carry `w:w` and `w:space`.
public struct ColumnSet: Hashable, Sendable {

    public struct Column: Hashable, Sendable {
        /// Column width. `nil` means "derived by dividing the text area equally".
        public var width: Twip?
        /// Space between this column and the next.
        public var space: Twip

        public init(width: Twip? = nil, space: Twip = Twip(720)) {
            self.width = width
            self.space = space
        }
    }

    public var columns: [Column]
    public var drawsSeparatorLine: Bool
    public var rightToLeft: Bool

    public init(
        columns: [Column],
        drawsSeparatorLine: Bool = false,
        rightToLeft: Bool = false
    ) {
        self.columns = columns.isEmpty ? [Column()] : columns
        self.drawsSeparatorLine = drawsSeparatorLine
        self.rightToLeft = rightToLeft
    }

    public static let single = ColumnSet(columns: [Column()])

    public static func equal(count: Int, spacing: Twip = Twip(720), separator: Bool = false) -> ColumnSet {
        let n = max(1, min(count, 13))
        return ColumnSet(
            columns: (0..<n).map { _ in Column(width: nil, space: spacing) },
            drawsSeparatorLine: separator
        )
    }

    public var count: Int { columns.count }

    /// Resolves possibly-`nil` widths against the available text width.
    ///
    /// When any width is unspecified Word divides the remaining space equally
    /// between the unspecified columns after subtracting the inter-column gaps.
    public func resolveWidths(availableWidth: Double) -> [Double] {
        let n = columns.count
        guard n > 0 else { return [] }
        guard n > 1 else { return [max(0, availableWidth)] }

        // There are n-1 gaps between n columns.
        let gaps = (0..<(n - 1)).reduce(0.0) { $0 + columns[$1].space.points }
        let remaining = max(0, availableWidth - gaps)

        let specified = columns.compactMap { $0.width }
        if specified.count == n {
            return columns.map { ($0.width ?? Twip(0)).points }
        }

        let knownTotal = specified.reduce(0.0) { $0 + $1.points }
        let unknownCount = n - specified.count
        let eachUnknown = unknownCount > 0 ? max(0, (remaining - knownTotal) / Double(unknownCount)) : 0

        return columns.map { column in
            return column.width?.points ?? eachUnknown
        }
    }
}

// MARK: - DocumentGrid

/// `w:docGrid`.
///
/// This is the setting that makes East Asian documents lay out differently from
/// Western ones: `lines` snaps every line to a fixed pitch, and `linesAndChars`
/// additionally snaps horizontally to a character grid. Ignoring it silently
/// changes the page count of CJK documents, which is why it is modelled from
/// day one rather than discovered later.
public struct DocumentGrid: Hashable, Sendable {

    public enum Kind: String, Hashable, Sendable {
        case `default`
        case lines
        case snapToChars
        case linesAndChars
    }

    public var kind: Kind
    /// `w:linePitch`, in twips. 0 means "use the font's natural line height".
    public var linePitch: Twip
    /// `w:charSpace`, in twips of *additional* character spacing.
    public var charSpace: Twip

    public init(kind: Kind = .default, linePitch: Twip = Twip(360), charSpace: Twip = .zero) {
        self.kind = kind
        self.linePitch = linePitch
        self.charSpace = charSpace
    }

    public static let none = DocumentGrid(kind: .default)

    public var snapsLines: Bool { kind == .lines || kind == .linesAndChars }
    public var snapsChars: Bool { kind == .snapToChars || kind == .linesAndChars }
}
