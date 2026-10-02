import Foundation

// MARK: - Alignment

/// `w:jc`.
///
/// Justification is not one behaviour: Word has `both` (standard justify),
/// `distribute` (space every character evenly across the line), and three
/// Kashida/Thai variants used for Arabic and Thai text. Treating them all as
/// "justify" produces visibly wrong Arabic and Thai documents.
public enum ParagraphAlignment: String, Hashable, Sendable {
    case left = "left"
    case center = "center"
    case right = "right"
    case justify = "both"
    case distribute
    case mediumKashida
    case highKashida
    case lowKashida
    case thaiDistribute

    /// Word writes `start`/`end` in strict-conformance documents and
    /// `left`/`right` in transitional ones. Both must be understood.
    public init(ooxmlValue: String, isRightToLeft: Bool) {
        switch ooxmlValue {
        case "start":
            self = isRightToLeft ? .right : .left
        case "end":
            self = isRightToLeft ? .left : .right
        case "center", "centre":
            self = .center
        case "both":
            self = .justify
        case "distribute":
            self = .distribute
        case "mediumKashida":
            self = .mediumKashida
        case "highKashida":
            self = .highKashida
        case "lowKashida":
            self = .lowKashida
        case "thaiDistribute":
            self = .thaiDistribute
        case "right":
            self = .right
        default:
            self = .left
        }
    }

    /// The value Word 365 writes today.
    public var ooxmlValue: String {
        switch self {
        case .left:            return "left"
        case .center:          return "center"
        case .right:           return "right"
        case .justify:         return "both"
        case .distribute:      return "distribute"
        case .mediumKashida:   return "mediumKashida"
        case .highKashida:     return "highKashida"
        case .lowKashida:      return "lowKashida"
        case .thaiDistribute:  return "thaiDistribute"
        }
    }

    /// Whether this alignment stretches inter-word (or inter-character) space.
    public var stretchesToFillLine: Bool {
        switch self {
        case .justify, .distribute, .mediumKashida, .highKashida, .lowKashida, .thaiDistribute:
            return true
        case .left, .center, .right:
            return false
        }
    }
}

// MARK: - LineSpacing

/// `w:spacing w:line` plus `w:lineRule`.
///
/// The three rules behave very differently and conflating them is a classic
/// fidelity bug:
/// - `.multiple` — `line` is in 240ths of a line (240 == single, 360 == 1.5, 480 == double)
/// - `.atLeast` — `line` is twips; the line is at least that tall but grows for
///   taller content (this is why a large image inline does not get clipped)
/// - `.exactly` — `line` is twips; content taller than this is **clipped**
public enum LineSpacing: Hashable, Sendable {

    /// `w:lineRule="auto"` — a multiple of the natural line height.
    case multiple(twelfthsOfALine: Int32)
    /// `w:lineRule="atLeast"`.
    case atLeast(Twip)
    /// `w:lineRule="exact"`.
    case exactly(Twip)

    public static let single = LineSpacing.multiple(twelfthsOfALine: 240)
    public static let oneAndAHalf = LineSpacing.multiple(twelfthsOfALine: 360)
    public static let double = LineSpacing.multiple(twelfthsOfALine: 480)

    /// Word's own multiplier for "single": 1.08× with 8 pt after, which is what
    /// the default style actually produces. Kept separate from `.single` because
    /// it is a *style default*, not a spacing rule.
    public static let wordDefault = LineSpacing.multiple(twelfthsOfALine: 259)

    public var lineRule: String {
        switch self {
        case .multiple: return "auto"
        case .atLeast:  return "atLeast"
        case .exactly:  return "exact"
        }
    }

    /// The `w:line` value to write.
    public var lineValue: Int32 {
        switch self {
        case .multiple(let n): return n
        case .atLeast(let twip): return twip.rawValue
        case .exactly(let twip): return twip.rawValue
        }
    }

    /// Resolves to a concrete line height in points.
    ///
    /// For `.multiple`, `naturalHeight` is the font's ascent + descent + leading,
    /// which is exactly what Word multiplies.
    public func height(naturalHeight: Double) -> Double {
        switch self {
        case .multiple(let n):
            return naturalHeight * Double(n) / 240.0
        case .atLeast(let twip):
            return max(twip.points, naturalHeight)
        case .exactly(let twip):
            return twip.points
        }
    }

    /// Resolves to a line height that never clips inline content taller than the
    /// text — used for images and other inline objects.
    public func height(naturalHeight: Double, contentHeight: Double) -> Double {
        switch self {
        case .exactly:
            return height(naturalHeight: naturalHeight)
        case .atLeast:
            return max(height(naturalHeight: naturalHeight), contentHeight)
        case .multiple:
            return max(height(naturalHeight: naturalHeight), contentHeight)
        }
    }
}

// MARK: - Indentation

/// `w:ind`.
///
/// Word distinguishes first-line indent from hanging indent by *sign
/// convention*: `w:firstLine` is positive and `w:hanging` is positive, and only
/// one of them may be present. It also has `Chars` variants
/// (`w:firstLineChars`, `w:hangingChars`, `w:leftChars`, `w:rightChars`) which
/// express the indent in hundredths of a character — used by CJK documents where
/// indenting by two characters must track the font size.
public struct ParagraphIndentation: Hashable, Sendable {

    public enum FirstLineKind: Hashable, Sendable {
        case none
        case indented(Twip)
        case hanging(Twip)
    }

    public var start: Twip?
    public var end: Twip?
    public var firstLine: FirstLineKind

    /// The `Chars` variants, in hundredths of a character. `nil` means unset.
    public var startChars: Int32?
    public var endChars: Int32?
    public var firstLineChars: Int32?
    public var hangingChars: Int32?

    public init(
        start: Twip? = nil,
        end: Twip? = nil,
        firstLine: FirstLineKind = .none,
        startChars: Int32? = nil,
        endChars: Int32? = nil,
        firstLineChars: Int32? = nil,
        hangingChars: Int32? = nil
    ) {
        self.start = start
        self.end = end
        self.firstLine = firstLine
        self.startChars = startChars
        self.endChars = endChars
        self.firstLineChars = firstLineChars
        self.hangingChars = hangingChars
    }

    public static let none = ParagraphIndentation()

    public var isEmpty: Bool { self == ParagraphIndentation.none }

    /// Left indent, which for a right-to-left paragraph is `w:right`.
    public func leadingIndent(isRightToLeft: Bool) -> Twip? {
        return isRightToLeft ? end : start
    }

    public func trailingIndent(isRightToLeft: Bool) -> Twip? {
        return isRightToLeft ? start : end
    }

    /// Resolves the first-line offset in points, taking the `Chars` variants into
    /// account when present. `characterWidth` is the grid/character width Word
    /// uses for the `Chars` forms — in practice the font size in points.
    public func firstLineOffsetPoints(characterWidth: Double) -> Double {
        if let chars = firstLineChars {
            return Double(chars) / 100.0 * characterWidth
        }
        if let chars = hangingChars {
            return -Double(chars) / 100.0 * characterWidth
        }
        switch firstLine {
        case .none:              return 0
        case .indented(let twip): return twip.points
        case .hanging(let twip):  return -twip.points
        }
    }

    public func merging(_ other: ParagraphIndentation) -> ParagraphIndentation {
        var result = self
        if let value = other.start { result.start = value }
        if let value = other.end { result.end = value }
        if other.firstLine != .none { result.firstLine = other.firstLine }
        if let value = other.startChars { result.startChars = value }
        if let value = other.endChars { result.endChars = value }
        if let value = other.firstLineChars { result.firstLineChars = value }
        if let value = other.hangingChars { result.hangingChars = value }
        return result
    }
}

// MARK: - TabStop

/// `w:tabs/w:tab`.
///
/// `clear` and `bar` are not positions: `clear` removes an inherited tab stop
/// from the style chain, and `bar` draws a vertical rule without affecting text.
/// Both must survive the cascade or documents that clear an inherited stop will
/// snap back to it.
public struct TabStop: Hashable, Sendable {

    public enum Alignment: String, Hashable, Sendable {
        case left
        case center
        case right
        case decimal
        case bar
        case clear
        case num
        /// `start`/`end` in strict-conformance documents.
        case start
        case end
    }

    public enum Leader: String, Hashable, Sendable {
        case none
        case dot
        case hyphen
        case underscore
        case middleDot = "middleDot"
        case heavy
    }

    public var position: Twip
    public var alignment: Alignment
    public var leader: Leader

    public init(position: Twip, alignment: Alignment = .left, leader: Leader = .none) {
        self.position = position
        self.alignment = alignment
        self.leader = leader
    }
}

// MARK: - ParagraphProperties

/// `w:pPr`, with the same all-optional / `nil`-means-inherit contract as
/// `RunProperties`.
public struct ParagraphProperties: Hashable, Sendable {

    /// `w:pStyle` — the style id, not the style object.
    public var styleID: String?

    /// `w:numPr`
    public var numbering: NumberingReference?

    public var alignment: ParagraphAlignment?
    public var indentation: ParagraphIndentation?
    public var spacingBefore: Twip?
    public var spacingAfter: Twip?
    public var lineSpacing: LineSpacing?
    /// `w:contextualSpacing` — suppress spacing between paragraphs of the same style.
    public var contextualSpacing: Bool?

    public var tabs: [TabStop]?
    public var defaultTabStopBehaviour: DefaultTabBehaviour?

    // Pagination controls.
    public var keepLinesTogether: Bool?     // w:keepLines
    public var keepWithNext: Bool?          // w:keepNext
    public var pageBreakBefore: Bool?       // w:pageBreakBefore
    public var widowControl: Bool?          // w:widowControl

    // Direction and script.
    public var bidirectional: Bool?         // w:bidi
    public var mirrorIndents: Bool?         // w:mirrorIndents
    public var suppressAutoHyphens: Bool?   // w:suppressAutoHyphens
    public var adjustRightIndents: Bool?    // w:adjustRightInd

    // Outline and structure.
    /// `w:outlineLvl`, 0–8. Level 9 (`w:val="9"`) means body text and is
    /// what Word writes to *remove* an inherited outline level.
    public var outlineLevel: OutlineLevel?

    // Appearance.
    public var shading: Shading?
    public var borders: ParagraphBorders?
    public var verticalAlignmentInCell: TableCellVerticalAlignment?

    // Frame and positioning (`w:framePr`) — used by drop caps and framed text.
    public var frame: FrameProperties?

    /// `w:rPr` inside `w:pPr` — the properties applied to the paragraph mark
    /// itself. Not cosmetic: the paragraph mark's font size determines the
    /// height of an empty paragraph, which is one of the most common sources of
    /// "why is there a big gap here" round-trip differences.
    public var paragraphMarkRunProperties: RunProperties?

    /// `w:pPrChange` — the pre-change properties, present when this paragraph's
    /// formatting is a tracked revision.
    public var propertyRevision: PropertyRevision?

    public init(
        styleID: String? = nil,
        numbering: NumberingReference? = nil,
        alignment: ParagraphAlignment? = nil,
        indentation: ParagraphIndentation? = nil,
        spacingBefore: Twip? = nil,
        spacingAfter: Twip? = nil,
        lineSpacing: LineSpacing? = nil,
        contextualSpacing: Bool? = nil,
        tabs: [TabStop]? = nil,
        defaultTabStopBehaviour: DefaultTabBehaviour? = nil,
        keepLinesTogether: Bool? = nil,
        keepWithNext: Bool? = nil,
        pageBreakBefore: Bool? = nil,
        widowControl: Bool? = nil,
        bidirectional: Bool? = nil,
        mirrorIndents: Bool? = nil,
        suppressAutoHyphens: Bool? = nil,
        adjustRightIndents: Bool? = nil,
        outlineLevel: OutlineLevel? = nil,
        shading: Shading? = nil,
        borders: ParagraphBorders? = nil,
        verticalAlignmentInCell: TableCellVerticalAlignment? = nil,
        frame: FrameProperties? = nil,
        paragraphMarkRunProperties: RunProperties? = nil,
        propertyRevision: PropertyRevision? = nil
    ) {
        self.styleID = styleID
        self.numbering = numbering
        self.alignment = alignment
        self.indentation = indentation
        self.spacingBefore = spacingBefore
        self.spacingAfter = spacingAfter
        self.lineSpacing = lineSpacing
        self.contextualSpacing = contextualSpacing
        self.tabs = tabs
        self.defaultTabStopBehaviour = defaultTabStopBehaviour
        self.keepLinesTogether = keepLinesTogether
        self.keepWithNext = keepWithNext
        self.pageBreakBefore = pageBreakBefore
        self.widowControl = widowControl
        self.bidirectional = bidirectional
        self.mirrorIndents = mirrorIndents
        self.suppressAutoHyphens = suppressAutoHyphens
        self.adjustRightIndents = adjustRightIndents
        self.outlineLevel = outlineLevel
        self.shading = shading
        self.borders = borders
        self.verticalAlignmentInCell = verticalAlignmentInCell
        self.frame = frame
        self.paragraphMarkRunProperties = paragraphMarkRunProperties
        self.propertyRevision = propertyRevision
    }

    public static let empty = ParagraphProperties()

    public var isEmpty: Bool {
        return self == ParagraphProperties.empty
    }

    /// Overlays `other`; non-`nil` fields win. Tab stops merge by position so a
    /// `clear` entry in `other` removes the matching inherited stop.
    public func merging(_ other: ParagraphProperties) -> ParagraphProperties {
        var result = self
        if let value = other.styleID { result.styleID = value }
        if let value = other.numbering { result.numbering = result.numbering.map { $0.merging(value) } ?? value }
        if let value = other.alignment { result.alignment = value }
        if let value = other.indentation { result.indentation = result.indentation.map { $0.merging(value) } ?? value }
        if let value = other.spacingBefore { result.spacingBefore = value }
        if let value = other.spacingAfter { result.spacingAfter = value }
        if let value = other.lineSpacing { result.lineSpacing = value }
        if let value = other.contextualSpacing { result.contextualSpacing = value }
        if let value = other.tabs { result.tabs = Self.mergeTabs(base: result.tabs, overlay: value) }
        if let value = other.defaultTabStopBehaviour { result.defaultTabStopBehaviour = value }
        if let value = other.keepLinesTogether { result.keepLinesTogether = value }
        if let value = other.keepWithNext { result.keepWithNext = value }
        if let value = other.pageBreakBefore { result.pageBreakBefore = value }
        if let value = other.widowControl { result.widowControl = value }
        if let value = other.bidirectional { result.bidirectional = value }
        if let value = other.mirrorIndents { result.mirrorIndents = value }
        if let value = other.suppressAutoHyphens { result.suppressAutoHyphens = value }
        if let value = other.adjustRightIndents { result.adjustRightIndents = value }
        if let value = other.outlineLevel { result.outlineLevel = value }
        if let value = other.shading { result.shading = value }
        if let value = other.borders { result.borders = result.borders.map { $0.merging(value) } ?? value }
        if let value = other.verticalAlignmentInCell { result.verticalAlignmentInCell = value }
        if let value = other.frame { result.frame = value }
        if let value = other.paragraphMarkRunProperties {
            result.paragraphMarkRunProperties = result.paragraphMarkRunProperties.map { $0.merging(value) } ?? value
        }
        if let value = other.propertyRevision { result.propertyRevision = value }
        return result
    }

    private static func mergeTabs(base: [TabStop]?, overlay: [TabStop]) -> [TabStop] {
        guard let base, !base.isEmpty else { return overlay.filter { $0.alignment != .clear } }
        var result: [TabStop] = []
        for tab in base {
            guard let replacement = overlay.first(where: { $0.position == tab.position }) else {
                result.append(tab)
                continue
            }
            // A `clear` entry removes the inherited stop rather than replacing it.
            if replacement.alignment != .clear {
                result.append(replacement)
            }
        }
        for tab in overlay where tab.alignment != .clear {
            if !result.contains(where: { $0.position == tab.position }) {
                result.append(tab)
            }
        }
        return result.sorted { $0.position < $1.position }
    }
}

// MARK: - Supporting types

public enum OutlineLevel: Int32, Hashable, Sendable, CaseIterable {
    case level1 = 0
    case level2 = 1
    case level3 = 2
    case level4 = 3
    case level5 = 4
    case level6 = 5
    case level7 = 6
    case level8 = 7
    case level9 = 8
    /// `w:val="9"` — body text. Distinct from `nil` (inherit).
    case bodyText = 9

    public init?(ooxmlValue: Int32) {
        guard let level = OutlineLevel(rawValue: ooxmlValue) else { return nil }
        self = level
    }

    /// Whether this level appears in the Navigation pane and the default TOC.
    public var isHeading: Bool { self != .bodyText }
}

public enum DefaultTabBehaviour: String, Hashable, Sendable {
    /// Word's default: advance to the next half-inch multiple.
    case halfInch
    case left
    case center
    case right
    case decimal
}

public enum TableCellVerticalAlignment: String, Hashable, Sendable {
    case top
    case center
    case bottom
    case both
}

/// `w:numPr`.
public struct NumberingReference: Hashable, Sendable {

    /// `w:numId`. A value of 0 means "no numbering", which is how a paragraph
    /// *cancels* numbering inherited from its style — it is not the same as
    /// the property being absent.
    public var numberID: Int32?
    /// `w:ilvl`, 0-based.
    public var level: Int32?

    public init(numberID: Int32? = nil, level: Int32? = nil) {
        self.numberID = numberID
        self.level = level
    }

    public static let none = NumberingReference()

    public var isNumbered: Bool {
        guard let numberID else { return false }
        return numberID != 0
    }

    public func merging(_ other: NumberingReference) -> NumberingReference {
        var result = self
        if let value = other.numberID { result.numberID = value }
        if let value = other.level { result.level = value }
        return result
    }
}

/// `w:pBdr` — up to six borders around a paragraph.
public struct ParagraphBorders: Hashable, Sendable {

    public var top: BorderDefinition?
    public var left: BorderDefinition?
    public var bottom: BorderDefinition?
    public var right: BorderDefinition?
    public var between: BorderDefinition?
    public var bar: BorderDefinition?

    public init(
        top: BorderDefinition? = nil,
        left: BorderDefinition? = nil,
        bottom: BorderDefinition? = nil,
        right: BorderDefinition? = nil,
        between: BorderDefinition? = nil,
        bar: BorderDefinition? = nil
    ) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
        self.between = between
        self.bar = bar
    }

    public static let none = ParagraphBorders()

    /// The AutoFormat-As-You-Type border keys produce exactly these.
    public static func box(style: BorderStyle = .single, width: EighthOfAPoint = EighthOfAPoint(6), color: DocumentColor = .automatic) -> ParagraphBorders {
        let edge = BorderDefinition(style: style, width: width, color: color)
        return ParagraphBorders(top: edge, left: edge, bottom: edge, right: edge)
    }

    public func merging(_ other: ParagraphBorders) -> ParagraphBorders {
        var result = self
        if let value = other.top { result.top = value }
        if let value = other.left { result.left = value }
        if let value = other.bottom { result.bottom = value }
        if let value = other.right { result.right = value }
        if let value = other.between { result.between = value }
        if let value = other.bar { result.bar = value }
        return result
    }
}

public struct BorderDefinition: Hashable, Sendable {

    public var style: BorderStyle
    /// `w:sz`, in eighths of a point.
    public var width: EighthOfAPoint
    public var color: DocumentColor
    /// `w:space`, distance from the text in points.
    public var spacePoints: Double

    public init(
        style: BorderStyle = .single,
        width: EighthOfAPoint = EighthOfAPoint(6),
        color: DocumentColor = .automatic,
        spacePoints: Double = 0
    ) {
        self.style = style
        self.width = width
        self.color = color
        self.spacePoints = spacePoints
    }
}

/// `w:sz` on a border is in eighths of a point, yet another unit.
public struct EighthOfAPoint: Hashable, Sendable {
    public let rawValue: UInt8
    public init(_ rawValue: UInt8) { self.rawValue = rawValue }
    public var points: Double { Double(rawValue) / 8.0 }
    public init(points: Double) { self.rawValue = UInt8(max(0, min(255, (points * 8.0).rounded()))) }
}

public enum BorderStyle: String, Hashable, Sendable {
    case none
    case single
    case thick
    case doubleLine = "double"
    case dotted
    case dashed
    case dotDash
    case dotDotDash
    case triple
    case thinThickSmallGap = "thinThickSmallGap"
    case thickThinSmallGap = "thickThinSmallGap"
    case thinThickThinSmallGap = "thinThickThinSmallGap"
    case thinThickMediumGap = "thinThickMediumGap"
    case thickThinMediumGap = "thickThinMediumGap"
    case thinThickThinMediumGap = "thinThickThinMediumGap"
    case thinThickLargeGap = "thinThickLargeGap"
    case thickThinLargeGap = "thickThinLargeGap"
    case thinThickThinLargeGap = "thinThickThinLargeGap"
    case wave
    case doubleWave = "doubleWave"
    case dashSmallGap = "dashSmallGap"
    case dashDotStroked = "dashDotStroked"
    case threeDEmboss = "threeDEmboss"
    case threeDEngrave = "threeDEngrave"
    case outset
    case inset
    case apples
    case archedScallops = "archedScallops"
    case babyPacifier = "babyPacifier"
    case babyRattle = "babyRattle"
    case balloons = "balloons"
    // The full `w:borderStyle` enumeration runs to ~150 "art" values used by
    // Word's border gallery. The functional ones are listed above; art borders
    // are parsed into `.custom` and re-emitted verbatim by OOXMLKit (M1) rather
    // than enumerated here, which keeps this type honest about what we render.
    case custom
}

/// `w:framePr` — framed text. Drop caps are implemented as a frame, which is
/// why this is modelled rather than special-cased.
public struct FrameProperties: Hashable, Sendable {

    public enum Wrap: String, Hashable, Sendable {
        case auto
        case notBeside
        case around
        case tight
        case through
        case none
    }

    public enum Anchor: String, Hashable, Sendable {
        case text
        case margin
        case page
    }

    public var dropCap: DropCapMode
    public var lines: Int32
    public var width: Twip?
    public var height: Twip?
    public var horizontalAnchor: Anchor
    public var horizontalSpace: Twip?
    public var verticalAnchor: Anchor
    public var verticalSpace: Twip?
    public var wrap: Wrap

    public init(
        dropCap: DropCapMode = .none,
        lines: Int32 = 0,
        width: Twip? = nil,
        height: Twip? = nil,
        horizontalAnchor: Anchor = .text,
        horizontalSpace: Twip? = nil,
        verticalAnchor: Anchor = .text,
        verticalSpace: Twip? = nil,
        wrap: Wrap = .auto
    ) {
        self.dropCap = dropCap
        self.lines = lines
        self.width = width
        self.height = height
        self.horizontalAnchor = horizontalAnchor
        self.horizontalSpace = horizontalSpace
        self.verticalAnchor = verticalAnchor
        self.verticalSpace = verticalSpace
        self.wrap = wrap
    }

    public static let none = FrameProperties()
}

public enum DropCapMode: String, Hashable, Sendable {
    case none
    /// Dropped into the body text.
    case dropped = "drop"
    /// Sitting in the margin.
    case margin
}

/// `w:pPrChange` / `w:rPrChange` — the "before" half of a tracked formatting change.
public struct PropertyRevision: Hashable, Sendable {
    public var author: String
    public var date: Date
    public var revisionID: Int32?

    public init(author: String, date: Date, revisionID: Int32? = nil) {
        self.author = author
        self.date = date
        self.revisionID = revisionID
    }
}
