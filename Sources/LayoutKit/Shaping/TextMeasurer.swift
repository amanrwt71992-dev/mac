import Foundation
import CoreKit

// MARK: - Measurement types

/// Vertical metrics for a resolved font at a resolved size.
///
/// These come from the font's own tables, via CoreText on macOS. Everything
/// downstream is arithmetic on these numbers, which is why the line breaker and
/// paginator can be tested on Linux against a mock.
public struct FontLineMetrics: Hashable, Sendable {

    /// Distance from the baseline to the top of the tallest ascender.
    public var ascent: Double
    /// Distance from the baseline to the bottom of the deepest descender, positive.
    public var descent: Double
    /// Recommended extra interline spacing.
    public var leading: Double

    public var capHeight: Double
    public var xHeight: Double

    /// Negative means below the baseline, which is the convention.
    public var underlinePosition: Double
    public var underlineThickness: Double
    public var strikeoutPosition: Double
    public var strikeoutThickness: Double

    public init(
        ascent: Double,
        descent: Double,
        leading: Double,
        capHeight: Double = 0,
        xHeight: Double = 0,
        underlinePosition: Double = 0,
        underlineThickness: Double = 0,
        strikeoutPosition: Double = 0,
        strikeoutThickness: Double = 0
    ) {
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.capHeight = capHeight
        self.xHeight = xHeight
        self.underlinePosition = underlinePosition
        self.underlineThickness = underlineThickness
        self.strikeoutPosition = strikeoutPosition
        self.strikeoutThickness = strikeoutThickness
    }

    /// What Word calls "single" spacing: ascent + descent + line gap.
    ///
    /// CoreText's `CTFontGetAscent + CTFontGetDescent + CTFontGetLeading` is
    /// exactly the quantity Word multiplies for `w:lineRule="auto"`, so the two
    /// agree without adjustment. This is a small thing that buys a lot of
    /// fidelity, and it is the reason we measure through the font rather than
    /// approximating from the point size.
    public var naturalLineHeight: Double { ascent + descent + leading }
}

/// The measured result for one run of text in one style.
///
/// Cluster-granular rather than character-granular: `advances[i]` is the width of
/// the grapheme cluster starting at `clusterOffsets[i]`. Breaking on cluster
/// boundaries is what makes Indic, Thai and emoji text survive layout — splitting
/// inside a cluster corrupts the text, which is precisely the class of bug
/// TextKit 1's glyph-based APIs are known for.
public struct MeasuredRun: Hashable, Sendable {

    /// Character offset of each grapheme cluster, in the measured string.
    public var clusterOffsets: [Int]
    /// Advance width of each cluster, in points.
    public var advances: [Double]

    public init(clusterOffsets: [Int] = [], advances: [Double] = []) {
        self.clusterOffsets = clusterOffsets
        self.advances = advances
    }

    public var width: Double { advances.reduce(0, +) }

    public var clusterCount: Int { clusterOffsets.count }

    /// Width of the clusters in `[fromCluster, toCluster)`.
    public func width(fromCluster from: Int, toCluster to: Int) -> Double {
        guard to > from else { return 0 }
        let lower = max(0, min(from, advances.count))
        let upper = max(lower, min(to, advances.count))
        return advances[lower..<upper].reduce(0, +)
    }

    /// Index of the cluster containing a character offset.
    public func clusterIndex(forCharacterOffset offset: Int) -> Int {
        var index = 0
        while index < clusterOffsets.count, clusterOffsets[index] <= offset {
            if index + 1 >= clusterOffsets.count || clusterOffsets[index + 1] > offset {
                return index
            }
            index += 1
        }
        return max(0, clusterOffsets.count - 1)
    }

    /// X offset of a character within the run.
    public func xOffset(forCharacterOffset offset: Int) -> Double {
        let index = clusterIndex(forCharacterOffset: offset)
        guard index > 0 else { return 0 }
        return advances[0..<index].reduce(0, +)
    }
}

/// A run of text with fully resolved properties — the unit the measurer accepts.
public struct StyledText: Hashable, Sendable {
    public var text: String
    public var style: ResolvedRunStyle

    public init(text: String, style: ResolvedRunStyle) {
        self.text = text
        self.style = style
    }
}

// MARK: - TextMeasurer

/// The boundary between the pure layout algorithms and the platform text stack.
///
/// Two implementations exist: `CoreTextMeasurer` on macOS, and a mock in the
/// test target. That is the whole point of the protocol — the line breaker and
/// paginator contain the genuinely difficult logic, and they can be exercised on
/// a Linux CI runner in seconds without a font system.
public protocol TextMeasurer: Sendable {

    /// Measures a run of text.
    func measure(_ text: String, style: ResolvedRunStyle) -> MeasuredRun

    /// The vertical metrics for a style.
    func lineMetrics(for style: ResolvedRunStyle) -> FontLineMetrics

    /// Character offsets at which a line may legally end.
    ///
    /// Platform-provided rather than hard-coded because correct break
    /// opportunities require a real line-break implementation: UAX #14 for most
    /// scripts, dictionary-based word breaking for Thai and Lao (which have no
    /// spaces at all), and kinsoku rules for CJK. CoreText and ICU both do this
    /// properly; a hand-rolled "break on spaces" does not.
    func breakOpportunities(in text: String, style: ResolvedRunStyle) -> [Int]

    /// Offsets inside a word at which it may be hyphenated, most-preferred first.
    ///
    /// Empty when hyphenation is off or no dictionary is available for the
    /// language. On macOS this is backed by `NSHyphenation`/CoreText.
    func hyphenationCandidates(in word: String, style: ResolvedRunStyle) -> [Int]

    /// Width of a hyphen glyph in this style, needed to reserve room before
    /// deciding to hyphenate.
    func hyphenWidth(style: ResolvedRunStyle) -> Double
}

// MARK: - ParagraphLayoutInput

/// Everything the line breaker needs to lay out one paragraph.
///
/// Deliberately flat and pre-resolved: the style cascade has already run, the
/// section geometry is already known, and the available width is already a
/// number. Pushing all of that resolution *upstream* is what keeps the breaker
/// itself a pure function.
public struct ParagraphLayoutInput: Hashable, Sendable {

    public var paragraphID: NodeID
    public var segments: [StyledText]

    /// Forced breaks, addressed by character offset within the paragraph.
    ///
    /// Kept out of the segment text on purpose. A manual line break, a page
    /// break and a column break all need different treatment from the breaker,
    /// and `RunContent.plainText` collapses page and column breaks into the same
    /// form-feed character — so the distinction is carried here instead, where it
    /// survives.
    public var breaks: [BreakMarker]

    public var alignment: ParagraphAlignment
    public var lineSpacing: LineSpacing

    /// Available text width in points, per line index.
    ///
    /// A closure rather than a constant because floating objects make the
    /// available width vary by vertical position, and columns make it vary by
    /// column. M0 supplies a constant; the float resolver in M2 supplies the
    /// real function. The shape is decided now so that adding floats does not
    /// mean rewriting the breaker.
    public var widthAtLine: LineWidthProvider

    /// Left indent in points, already resolved for direction.
    public var indentStart: Double
    /// Right indent in points.
    public var indentEnd: Double
    /// Extra indent applied to the first line only (negative for hanging).
    public var firstLineIndent: Double

    public var tabStops: [TabStop]
    public var defaultTabStop: Double

    public var rightToLeft: Bool

    /// `w:compat/w:wrapTrailingSpaces` — when false (Word's default), a space at
    /// a line break hangs into the margin instead of being counted against the
    /// line width. Getting this wrong makes justified text visibly ragged.
    public var wrapsTrailingSpaces: Bool

    /// `w:suppressAutoHyphens` inverted, plus the hyphenation zone.
    public var hyphenation: HyphenationSettings

    /// The paragraph mark's own resolved style (`w:pPr/w:rPr`).
    ///
    /// Not decorative. Word includes the paragraph mark's font in the height of
    /// the paragraph's **last** line, which is why an empty paragraph formatted
    /// at 24 pt occupies a 24 pt line, and why setting a large font on the
    /// paragraph mark pushes following text down. A layout engine that ignores
    /// this gets the page count wrong on every document with a blank line in it.
    public var markStyle: ResolvedRunStyle

    public init(
        paragraphID: NodeID,
        segments: [StyledText],
        breaks: [BreakMarker] = [],
        alignment: ParagraphAlignment = .left,
        lineSpacing: LineSpacing = .single,
        widthAtLine: LineWidthProvider = .constant(0),
        indentStart: Double = 0,
        indentEnd: Double = 0,
        firstLineIndent: Double = 0,
        tabStops: [TabStop] = [],
        defaultTabStop: Double = 36,
        rightToLeft: Bool = false,
        wrapsTrailingSpaces: Bool = false,
        hyphenation: HyphenationSettings = .disabled,
        markStyle: ResolvedRunStyle = .documentDefault
    ) {
        self.paragraphID = paragraphID
        self.segments = segments
        self.breaks = breaks
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.widthAtLine = widthAtLine
        self.indentStart = indentStart
        self.indentEnd = indentEnd
        self.firstLineIndent = firstLineIndent
        self.tabStops = tabStops
        self.defaultTabStop = defaultTabStop
        self.rightToLeft = rightToLeft
        self.wrapsTrailingSpaces = wrapsTrailingSpaces
        self.hyphenation = hyphenation
        self.markStyle = markStyle
    }

    /// Total available width for a line, after indents.
    public func availableWidth(lineIndex: Int) -> Double {
        let total = widthAtLine.width(lineIndex: lineIndex)
        let firstLineExtra = lineIndex == 0 ? firstLineIndent : 0
        return max(0, total - indentStart - indentEnd - firstLineExtra)
    }
}

/// How wide the text area is for a given line.
///
/// An enum with a payload rather than a closure so the whole input stays
/// `Hashable` and `Sendable` — closures would break both, and we want layout
/// inputs to be cache keys.
public enum LineWidthProvider: Hashable, Sendable {

    /// A fixed width. Single-column documents with no floats.
    case constant(Double)

    /// Per-line widths supplied by the float resolver and the column placer.
    /// Indexed by absolute line number within the paragraph.
    case table([Double])

    public func width(lineIndex: Int) -> Double {
        switch self {
        case .constant(let value):
            return value
        case .table(let values):
            guard !values.isEmpty else { return 0 }
            guard lineIndex >= 0, lineIndex < values.count else { return values[values.count - 1] }
            return values[lineIndex]
        }
    }
}

public struct HyphenationSettings: Hashable, Sendable {
    public var enabled: Bool
    /// `w:hyphenationZone`, in points. Word will not hyphenate if the break
    /// would land further from the right margin than this.
    public var zonePoints: Double
    /// `w:consecutiveHyphenLimit`. `nil` means unlimited.
    public var consecutiveLimit: Int?

    public init(enabled: Bool = false, zonePoints: Double = 36, consecutiveLimit: Int? = nil) {
        self.enabled = enabled
        self.zonePoints = zonePoints
        self.consecutiveLimit = consecutiveLimit
    }

    public static let disabled = HyphenationSettings(enabled: false)
}

// MARK: - BreakMarker

/// A forced break at a character offset within a paragraph.
public struct BreakMarker: Hashable, Sendable {

    /// Character offset of the break within the paragraph's visible text.
    public var characterOffset: Int
    public var kind: ForcedBreak

    public init(characterOffset: Int, kind: ForcedBreak) {
        self.characterOffset = characterOffset
        self.kind = kind
    }
}
