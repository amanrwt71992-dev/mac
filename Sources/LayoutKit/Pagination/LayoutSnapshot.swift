import Foundation
import CoreKit

// MARK: - LineSegment

/// A run of consecutive text on a laid-out line, in one resolved style.
///
/// This is the unit the renderer paints. It carries its own x origin and its own
/// style so the paint stage never has to walk back into the model, and it carries
/// the mapping from character offsets to x positions so hit-testing and caret
/// placement are arithmetic rather than a re-measurement.
public struct LineSegment: Hashable, Sendable {

    /// The text actually drawn on this line.
    ///
    /// A substring of the model's text — never a transformed copy. If the model
    /// says "colour" the segment says "colour", even when the UI is displaying it
    /// as "color" for a US spelling preference.
    public var text: String

    /// Character offset of `text`'s first character within the paragraph.
    public var characterOffset: Int

    public var style: ResolvedRunStyle

    /// X origin of this segment, in text-area coordinates (left edge of the
    /// line's content box).
    public var x: Double

    /// Total advance width.
    public var width: Double

    /// Per-cluster advances, parallel to `clusterOffsets`.
    public var advances: [Double]
    /// Character offsets (paragraph-relative) of each cluster in this segment.
    public var clusterOffsets: [Int]

    /// Set when this segment ends at a manual tab rather than running to its
    /// natural width, which is how the renderer knows to paint tab leaders.
    public var tabLeader: TabStop.Leader?
    public var tabLeaderWidth: Double

    public init(
        text: String,
        characterOffset: Int,
        style: ResolvedRunStyle,
        x: Double,
        width: Double,
        advances: [Double] = [],
        clusterOffsets: [Int] = [],
        tabLeader: TabStop.Leader? = nil,
        tabLeaderWidth: Double = 0
    ) {
        self.text = text
        self.characterOffset = characterOffset
        self.style = style
        self.x = x
        self.width = width
        self.advances = advances
        self.clusterOffsets = clusterOffsets
        self.tabLeader = tabLeader
        self.tabLeaderWidth = tabLeaderWidth
    }

    /// X position of a character offset within this segment.
    public func xOffset(forCharacterOffset offset: Int) -> Double {
        guard !clusterOffsets.isEmpty else { return x }
        var index = 0
        while index < clusterOffsets.count, clusterOffsets[index] < offset { index += 1 }
        guard index > 0 else { return x }
        return x + advances[0..<min(index, advances.count)].reduce(0, +)
    }

    /// The character offset nearest to an x position — used for click-to-place-caret.
    public func characterOffset(nearestX targetX: Double) -> Int {
        guard !clusterOffsets.isEmpty else { return characterOffset }
        let relative = targetX - x
        var accumulated = 0.0
        for index in advances.indices {
            let midpoint = accumulated + advances[index] / 2
            if relative < midpoint { return clusterOffsets[index] }
            accumulated += advances[index]
        }
        // Past the end: the offset just after the last cluster.
        let last = clusterOffsets[clusterOffsets.count - 1]
        return last + (text.count - (last - characterOffset))
    }
}

// MARK: - LayoutLine

/// One laid-out line.
public struct LayoutLine: Hashable, Sendable {

    public var segments: [LineSegment]

    /// The line's box, in text-area coordinates (origin at the top-left of the
    /// page's text area). `height` is the full line height including spacing.
    public var frame: Rect

    /// Distance from `frame.origin.y` to the baseline.
    public var baselineOffset: Double

    /// Ascent and descent of the tallest segment on the line. Kept separately
    /// from `frame` because `frame.height` includes `w:spacing`, while these
    /// describe where glyphs actually sit.
    public var ascent: Double
    public var descent: Double

    public var paragraphID: NodeID

    /// Character range within the paragraph. `lowerBound` is the first character
    /// on the line; `upperBound` is one past the last, **excluding** a trailing
    /// space that hangs into the margin.
    public var characterRange: Range<Int>

    public var isFirstLineOfParagraph: Bool
    public var isLastLineOfParagraph: Bool

    /// Width of the content, excluding any hanging trailing whitespace.
    public var contentWidth: Double

    /// Width of trailing whitespace that hangs past `contentWidth`.
    public var hangingTrailingWhitespace: Double

    /// Extra space added per inter-cluster gap to achieve justification.
    ///
    /// Stored as a single number rather than baked into the advances, so the
    /// renderer can apply it as a tracking adjustment and so that a later
    /// re-layout at a different width starts from unmodified measurements.
    public var justificationExtraPerGap: Double
    public var justificationGapCount: Int

    /// Non-nil when the line was hyphenated; the hyphen is not part of the model
    /// text and must be drawn by the renderer.
    public var hyphenInsertedAt: Int?

    /// A manual break (`w:br`) that terminates this line.
    ///
    /// Carried on the line rather than returned alongside it because the
    /// paginator needs it to decide whether to start a new page or column, and
    /// because a paragraph can end with a page break that produces no further
    /// lines — in which case the break has to ride on the last one that exists.
    public var pendingBreak: ForcedBreak?

    public init(
        segments: [LineSegment] = [],
        frame: Rect = .zero,
        baselineOffset: Double = 0,
        ascent: Double = 0,
        descent: Double = 0,
        // Spelled out: `NodeID` wraps a UInt64 and is deliberately *not*
        // ExpressibleByIntegerLiteral, so a bare 0 will not convert. Letting
        // literals in would defeat the point of the wrapper — a node id and a
        // count would become interchangeable at every call site.
        paragraphID: NodeID = NodeID(0),
        characterRange: Range<Int> = 0..<0,
        isFirstLineOfParagraph: Bool = true,
        isLastLineOfParagraph: Bool = true,
        contentWidth: Double = 0,
        hangingTrailingWhitespace: Double = 0,
        justificationExtraPerGap: Double = 0,
        justificationGapCount: Int = 0,
        hyphenInsertedAt: Int? = nil,
        pendingBreak: ForcedBreak? = nil
    ) {
        self.segments = segments
        self.frame = frame
        self.baselineOffset = baselineOffset
        self.ascent = ascent
        self.descent = descent
        self.paragraphID = paragraphID
        self.characterRange = characterRange
        self.isFirstLineOfParagraph = isFirstLineOfParagraph
        self.isLastLineOfParagraph = isLastLineOfParagraph
        self.contentWidth = contentWidth
        self.hangingTrailingWhitespace = hangingTrailingWhitespace
        self.justificationExtraPerGap = justificationExtraPerGap
        self.justificationGapCount = justificationGapCount
        self.hyphenInsertedAt = hyphenInsertedAt
        self.pendingBreak = pendingBreak
    }

    /// Y of the baseline, in text-area coordinates.
    public var baselineY: Double { frame.origin.y + baselineOffset }

    /// X position of a character offset on this line.
    public func xOffset(forCharacterOffset offset: Int) -> Double {
        for segment in segments where offset >= segment.characterOffset && offset <= segment.characterOffset + segment.text.count {
            return segment.xOffset(forCharacterOffset: offset)
        }
        guard let last = segments.last else { return frame.origin.x }
        return last.x + last.width
    }

    /// The character offset nearest an x position on this line.
    public func characterOffset(nearestX targetX: Double) -> Int {
        guard !segments.isEmpty else { return characterRange.lowerBound }
        for segment in segments where targetX <= segment.x + segment.width {
            return segment.characterOffset(nearestX: targetX)
        }
        return segments[segments.count - 1].characterOffset(nearestX: targetX)
    }
}

// MARK: - LaidOutParagraph

/// All the lines of one paragraph, with the paragraph's own spacing applied.
public struct LaidOutParagraph: Hashable, Sendable {

    public var paragraphID: NodeID
    public var lines: [LayoutLine]

    /// Space above the first line, in points (`w:spacing w:before`).
    public var spaceBefore: Double
    /// Space below the last line, in points (`w:spacing w:after`).
    public var spaceAfter: Double

    /// Set when `w:keepLines` is on: this paragraph's lines may not be split
    /// across a page boundary.
    public var keepLinesTogether: Bool
    /// Set when `w:keepNext` is on: this paragraph must stay with the next one.
    public var keepWithNext: Bool
    /// Set when `w:pageBreakBefore` is on.
    public var pageBreakBefore: Bool
    /// `w:widowControl`: at least two lines must remain together at a page edge.
    public var widowControl: Bool

    /// The line spacing rule, needed by the paginator to decide whether
    /// `w:spacing w:before` is suppressed at the top of a page.
    public var lineSpacing: LineSpacing
    /// `w:contextualSpacing`: suppress space between paragraphs of the same style.
    public var contextualSpacing: Bool
    public var styleID: String?

    /// Non-nil when this paragraph begins a new page because of an explicit
    /// page break inside it (as opposed to `pageBreakBefore`).
    public var startsNewPage: Bool

    public init(
        paragraphID: NodeID,
        lines: [LayoutLine] = [],
        spaceBefore: Double = 0,
        spaceAfter: Double = 0,
        keepLinesTogether: Bool = false,
        keepWithNext: Bool = false,
        pageBreakBefore: Bool = false,
        widowControl: Bool = true,
        lineSpacing: LineSpacing = .single,
        contextualSpacing: Bool = false,
        styleID: String? = nil,
        startsNewPage: Bool = false
    ) {
        self.paragraphID = paragraphID
        self.lines = lines
        self.spaceBefore = spaceBefore
        self.spaceAfter = spaceAfter
        self.keepLinesTogether = keepLinesTogether
        self.keepWithNext = keepWithNext
        self.pageBreakBefore = pageBreakBefore
        self.widowControl = widowControl
        self.lineSpacing = lineSpacing
        self.contextualSpacing = contextualSpacing
        self.styleID = styleID
        self.startsNewPage = startsNewPage
    }

    /// Total height this paragraph occupies, including spacing.
    public var totalHeight: Double {
        spaceBefore + lines.reduce(0.0) { $0 + $1.frame.height } + spaceAfter
    }
}

// MARK: - PageLayout

/// One laid-out page.
public struct PageLayout: Hashable, Sendable {

    /// Zero-based page index within the document.
    public var index: Int

    /// The section this page belongs to. Page setup, headers and footers all
    /// come from here, so a page cannot be rendered without it.
    public var sectionIndex: Int

    /// Which page of the section this is, one-based. Needed for "different first
    /// page" and "different odd and even" header selection.
    public var pageWithinSection: Int

    /// The number Word displays in a PAGE field. Differs from `index` whenever a
    /// section sets `w:pgNumType w:start`.
    public var displayedPageNumber: Int

    public var pageSize: PageSize
    public var margins: PageMargins

    /// The text area, in page coordinates.
    public var textArea: Rect

    /// The columns on this page, in page coordinates.
    public var columns: [ColumnLayout]

    /// Paragraphs whose lines appear on this page, in reading order.
    ///
    /// A paragraph split across pages appears on both, carrying only its lines
    /// for that page. This is why `LaidOutParagraph.lines` is per page rather
    /// than per document.
    public var paragraphs: [LaidOutParagraph]

    /// Non-nil when the page was forced by an explicit page break.
    public var breakReason: PageBreakReason

    public init(
        index: Int = 0,
        sectionIndex: Int = 0,
        pageWithinSection: Int = 1,
        displayedPageNumber: Int = 1,
        pageSize: PageSize = .letter,
        margins: PageMargins = .normal,
        textArea: Rect = .zero,
        columns: [ColumnLayout] = [],
        paragraphs: [LaidOutParagraph] = [],
        breakReason: PageBreakReason = .natural
    ) {
        self.index = index
        self.sectionIndex = sectionIndex
        self.pageWithinSection = pageWithinSection
        self.displayedPageNumber = displayedPageNumber
        self.pageSize = pageSize
        self.margins = margins
        self.textArea = textArea
        self.columns = columns
        self.paragraphs = paragraphs
        self.breakReason = breakReason
    }

    /// Every line on the page, flattened in reading order.
    public var lines: [LayoutLine] { paragraphs.flatMap { $0.lines } }

    public var isRecto: Bool { displayedPageNumber % 2 == 1 }
}

public struct ColumnLayout: Hashable, Sendable {
    public var index: Int
    public var frame: Rect

    public init(index: Int, frame: Rect) {
        self.index = index
        self.frame = frame
    }
}

public enum PageBreakReason: Hashable, Sendable {
    /// The previous page simply ran out of room.
    case natural
    /// `w:pageBreakBefore` on the first paragraph.
    case pageBreakBefore
    /// A manual page break (`w:br w:type="page"`) inside a paragraph.
    case manualBreak
    /// A section break of type `nextPage`, `evenPage` or `oddPage`.
    case sectionBreak(SectionStart)
    /// A column break filled the last column.
    case columnOverflow
}

// MARK: - LayoutSnapshot

/// The whole document's layout, produced by one pass of the pipeline.
///
/// Immutable and diffable. The render layer consumes a snapshot and the layout
/// engine produces a new one; because both are values, a background re-layout can
/// run to completion and be swapped in atomically without ever mutating what is
/// currently on screen. That is the property that makes the 120 Hz scroll target
/// achievable — the render thread never blocks on layout and never sees a
/// half-updated structure.
public struct LayoutSnapshot: Hashable, Sendable {

    public var pages: [PageLayout]

    /// Page index at which each paragraph's *first* line appears. Drives the
    /// Navigation pane, `w:instrText` PAGEREF fields, and the "Page X of Y"
    /// status bar item.
    public var firstPageOfParagraph: [NodeID: Int]

    /// Line index within its page at which each paragraph starts.
    public var paragraphPositions: [NodeID: ParagraphPosition]

    /// Total laid-out height, used to size the scroll view.
    public var contentHeight: Double

    /// Monotonically increasing; lets a stale layout result be discarded when it
    /// arrives after a newer one.
    public var generation: UInt64

    public init(
        pages: [PageLayout] = [],
        firstPageOfParagraph: [NodeID: Int] = [:],
        paragraphPositions: [NodeID: ParagraphPosition] = [:],
        contentHeight: Double = 0,
        generation: UInt64 = 0
    ) {
        self.pages = pages
        self.firstPageOfParagraph = firstPageOfParagraph
        self.paragraphPositions = paragraphPositions
        self.contentHeight = contentHeight
        self.generation = generation
    }

    public var pageCount: Int { pages.count }

    public func page(at index: Int) -> PageLayout? {
        guard index >= 0, index < pages.count else { return nil }
        return pages[index]
    }

    /// Which page contains a caret position, for scroll-to-selection.
    public func pageIndex(containingParagraph id: NodeID) -> Int? {
        firstPageOfParagraph[id]
    }

    public static let empty = LayoutSnapshot()
}

public struct ParagraphPosition: Hashable, Sendable {
    public var pageIndex: Int
    public var lineIndexWithinPage: Int
    public var frame: Rect

    public init(pageIndex: Int, lineIndexWithinPage: Int, frame: Rect) {
        self.pageIndex = pageIndex
        self.lineIndexWithinPage = lineIndexWithinPage
        self.frame = frame
    }
}
