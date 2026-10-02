import Foundation
import CoreKit

// MARK: - LayoutEngine

/// Runs the layout pipeline over a document.
///
/// The stages, in order:
///
/// 1. **Resolve** — collapse the style cascade into concrete numbers
///    (`StyleResolver`).
/// 2. **Flatten** — turn each paragraph into styled segments plus forced breaks.
/// 3. **Break** — greedy line breaking against a measured width (`LineBreaker`).
/// 4. **Paginate** — place lines onto pages and columns (`Paginator`).
///
/// Stages 3 and 4 are separated because they have different invalidation
/// triggers. Changing the window width re-breaks lines but does not change which
/// paragraph is which; changing a page margin changes both. Keeping them apart is
/// what lets a width change reuse the resolved styles, and it is why a
/// keystroke only has to re-break one paragraph rather than re-resolve the
/// document.
public struct LayoutEngine: Sendable {

    public var measurer: any TextMeasurer

    public init(measurer: any TextMeasurer) {
        self.measurer = measurer
    }

    /// The default measurer for this platform.
    ///
    /// `nil` on platforms without CoreText, which is why the executable target
    /// falls back to a fixed-width measurer when it is built for CI on Linux:
    /// the pipeline must be exercisable everywhere even though the shipped
    /// product is macOS-only.
    public static func defaultMeasurer() -> (any TextMeasurer)? {
        #if canImport(CoreText)
        return CoreTextMeasurer()
        #else
        return nil
        #endif
    }

    /// Lays out a whole document.
    ///
    /// - Parameters:
    ///   - markup: which revisions are visible. `.noMarkup` lays out the final
    ///     text, `.allMarkup` lays out insertions and deletions inline, and
    ///     `.original` lays out the pre-change text. Each produces a different
    ///     page count, which is why this is a layout input rather than a
    ///     rendering decoration.
    ///   - generation: echoed onto the snapshot so a stale result can be
    ///     discarded when it lands after a newer one.
    public func layout(
        document: DocumentModel,
        markup: RevisionMarkup = .allMarkup,
        generation: UInt64 = 0
    ) -> LayoutSnapshot {
        let resolver = StyleResolver(document: document)
        let breaker = LineBreaker(measurer: measurer)

        var items: [PaginationItem] = []
        var sections: [SectionProperties] = []

        for (sectionIndex, section) in document.sections.enumerated() {
            sections.append(section.properties)

            let textArea = section.properties.textAreaRect
            let columnWidth = Paginator.columnFrames(
                for: section.properties,
                textArea: textArea
            ).first?.width ?? textArea.width

            for block in section.blocks {
                switch block {
                case .paragraph(let paragraph):
                    items.append(PaginationItem(
                        paragraph: layoutParagraph(
                            paragraph,
                            resolver: resolver,
                            breaker: breaker,
                            availableWidth: columnWidth,
                            markup: markup
                        ),
                        sectionIndex: sectionIndex
                    ))

                case .table, .math, .contentControl, .preserved:
                    // Tables, equations, content controls and unmodelled
                    // elements are M1 work — they need cell-level layout, math
                    // typesetting and, for preserved elements, no layout at all
                    // beyond their measured height.
                    //
                    // They are deliberately *not* silently dropped from the
                    // model: they remain in `document.sections` and are still
                    // written back on save. Skipping them here affects only
                    // what M0 can draw, never what is preserved.
                    continue
                }
            }
        }

        return Paginator().paginate(items: items, sections: sections, generation: generation)
    }

    /// Resolves, flattens and breaks one paragraph.
    public func layoutParagraph(
        _ paragraph: Paragraph,
        resolver: StyleResolver,
        breaker: LineBreaker,
        availableWidth: Double,
        markup: RevisionMarkup = .allMarkup
    ) -> LaidOutParagraph {
        let resolved = resolver.resolveParagraph(paragraph.properties)
        let input = resolver.flatten(
            paragraph: paragraph,
            resolved: resolved,
            availableWidth: availableWidth,
            markup: markup
        )
        let lines = breaker.breakParagraph(input)

        var laid = LaidOutParagraph(paragraphID: paragraph.id, lines: lines)
        laid.spaceBefore = resolved.spaceBefore
        laid.spaceAfter = resolved.spaceAfter
        laid.keepLinesTogether = resolved.keepLinesTogether
        laid.keepWithNext = resolved.keepWithNext
        laid.pageBreakBefore = resolved.pageBreakBefore
        laid.widowControl = resolved.widowControl
        laid.lineSpacing = resolved.lineSpacing
        laid.contextualSpacing = resolved.contextualSpacing
        laid.styleID = resolved.styleID
        return laid
    }
}

// MARK: - FixedWidthMeasurer

/// A measurer with synthetic, predictable metrics.
///
/// Two uses, both important:
///
/// - **Testing.** A measurer whose numbers are known exactly makes line-break
///   assertions arithmetic instead of guesswork. A test that says "with a 6 pt
///   monospace font, 10 characters fit in 60 points" is a test that cannot
///   silently pass because a system font changed.
/// - **Non-macOS CI.** The pipeline is pure Swift and runs on Linux, where there
///   is no CoreText. Exercising it there on every push is what keeps the
///   algorithms honest between macOS runs.
public struct FixedWidthMeasurer: TextMeasurer, Sendable {

    /// Advance of one grapheme cluster, in points.
    public var advancePerCharacter: Double
    /// Width of a space, in points.
    public var spaceAdvance: Double
    public var ascent: Double
    public var descent: Double
    public var leading: Double
    /// Width of a tab stop grid, in points.
    public var tabGrid: Double
    public var hyphenAdvance: Double

    /// Character offsets that may begin a break, on top of the structural rules.
    /// Lets a test assert kinsoku-like behaviour without a dictionary.
    public var extraBreakOpportunities: Set<Int>

    /// Hyphenation candidates per word, for tests that exercise hyphenation.
    /// Named apart from the protocol method it feeds, which Swift will not let
    /// share an identifier with a stored property.
    public var hyphenationTable: [String: [Int]]

    public init(
        advancePerCharacter: Double = 6,
        spaceAdvance: Double = 6,
        ascent: Double = 9,
        descent: Double = 3,
        leading: Double = 0,
        tabGrid: Double = 36,
        hyphenAdvance: Double = 6,
        extraBreakOpportunities: Set<Int> = [],
        hyphenationTable: [String: [Int]] = [:]
    ) {
        self.advancePerCharacter = advancePerCharacter
        self.spaceAdvance = spaceAdvance
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.tabGrid = tabGrid
        self.hyphenAdvance = hyphenAdvance
        self.extraBreakOpportunities = extraBreakOpportunities
        self.hyphenationTable = hyphenationTable
    }

    /// 10 pt text on a 36 pt grid: the arithmetic stays in whole numbers.
    public static let tenPoint = FixedWidthMeasurer()

    public func measure(_ text: String, style: ResolvedRunStyle) -> MeasuredRun {
        guard !text.isEmpty else { return MeasuredRun() }
        var offsets: [Int] = []
        var advances: [Double] = []
        for (index, character) in text.enumerated() {
            offsets.append(index)
            advances.append(character == " " ? spaceAdvance : advancePerCharacter)
        }
        return MeasuredRun(clusterOffsets: offsets, advances: advances)
    }

    public func lineMetrics(for style: ResolvedRunStyle) -> FontLineMetrics {
        FontLineMetrics(
            ascent: ascent,
            descent: descent,
            leading: leading,
            capHeight: ascent * 0.7,
            xHeight: ascent * 0.5,
            underlinePosition: -descent / 2,
            underlineThickness: 1,
            strikeoutPosition: ascent * 0.3,
            strikeoutThickness: 1
        )
    }

    public func breakOpportunities(in text: String, style: ResolvedRunStyle) -> [Int] {
        var result: [Int] = []
        for (index, character) in text.enumerated() {
            if character == " " || character == "-" { result.append(index + 1) }
        }
        for extra in extraBreakOpportunities where extra > 0 && extra < text.count {
            result.append(extra)
        }
        return result
    }

    public func hyphenationCandidates(in word: String, style: ResolvedRunStyle) -> [Int] {
        hyphenationTable[word] ?? []
    }

    public func hyphenWidth(style: ResolvedRunStyle) -> Double {
        hyphenAdvance
    }
}
