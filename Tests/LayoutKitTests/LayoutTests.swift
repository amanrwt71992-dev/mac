import XCTest
import CoreKit
import LayoutKit

/// Layout tests.
///
/// Every measurement here assumes `FixedWidthMeasurer.tenPoint`: 6 pt per grapheme
/// cluster, 6 pt per space, ascent 9 + descent 3 = a 12 pt single-spaced line.
/// So a 60 pt column holds exactly 10 clusters and a 36 pt text area holds
/// exactly 3 lines. Synthetic metrics are the point: an assertion whose expected
/// number a reader can derive by hand is one that cannot be silently "fixed" by
/// editing the assertion when a system font changes.
final class LayoutTests: XCTestCase {

    /// A style table with no spacing and exactly single line height.
    ///
    /// Word's real defaults (8 pt after, 1.08× line height) are right for a
    /// document and unusable for arithmetic.
    static let flatStyles = StyleTable(
        defaultRunProperties: .empty,
        defaultParagraphProperties: ParagraphProperties(spacingAfter: Twip(0), lineSpacing: .single),
        styles: [:],
        declarationOrder: []
    )

    private let measurer = FixedWidthMeasurer.tenPoint

    /// A document whose text area is exactly `width` × `height` points.
    private func document(
        width: Double = 60,
        height: Double = 400,
        build: (inout DocumentBuilder) -> Void
    ) -> DocumentModel {
        var builder = DocumentBuilder(author: "test", styles: Self.flatStyles)
        builder.setPageSize(
            PageSize(width: Twip(points: width + 144), height: Twip(points: height + 144)),
            margins: PageMargins(top: Twip(1440), right: Twip(1440), bottom: Twip(1440), left: Twip(1440))
        )
        build(&builder)
        return builder.build()
    }

    /// `count` groups of 10 clusters separated by single spaces.
    private func text(lines count: Int) -> String {
        Array(repeating: String(repeating: "x", count: 10), count: count).joined(separator: " ")
    }

    private func linesPerPage(_ snapshot: LayoutSnapshot) -> [Int] {
        snapshot.pages.map { $0.lines.count }
    }

    private func layout(_ model: DocumentModel) -> LayoutSnapshot {
        LayoutEngine(measurer: measurer).layout(document: model)
    }

    // MARK: Line breaking

    func testLinesRespectTheColumnWidth() {
        let snapshot = layout(document { builder in
            builder.paragraph(self.text(lines: 3))
        })
        XCTAssertEqual(snapshot.pageCount, 1)
        XCTAssertEqual(snapshot.pages[0].lines.count, 3, "ten clusters per 60 pt line")
        for line in snapshot.pages[0].lines {
            XCTAssertEqual(line.contentWidth, 60, accuracy: 0.001)
        }
    }

    func testAnEmptyParagraphStillOccupiesALine() {
        // The paragraph mark is a character with a height. Skipping empty
        // paragraphs changes the page count of every document with a blank line.
        let snapshot = layout(document { builder in
            builder.paragraph("aaa")
            builder.emptyParagraph()
            builder.paragraph("bbb")
        })
        XCTAssertEqual(snapshot.pages[0].lines.count, 3)
    }

    func testTrailingWhitespaceHangsByDefault() {
        let input = ParagraphLayoutInput(
            paragraphID: NodeID(1),
            segments: [StyledText(text: "aaaa bbbb cccc", style: .documentDefault)],
            widthAtLine: .constant(60)
        )
        let lines = LineBreaker(measurer: measurer).breakParagraph(input)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].contentWidth, 54, accuracy: 0.001)
        XCTAssertEqual(lines[0].hangingTrailingWhitespace, 6, accuracy: 0.001)

        var wrapping = input
        wrapping.wrapsTrailingSpaces = true
        let wrapped = LineBreaker(measurer: measurer).breakParagraph(wrapping)
        XCTAssertEqual(wrapped[0].contentWidth, 60, accuracy: 0.001,
                       "w:wrapTrailingSpaces counts the space against the line")
    }

    func testTabsLandOnTheDefaultGrid() {
        let input = ParagraphLayoutInput(
            paragraphID: NodeID(1),
            segments: [StyledText(text: "a\tb", style: .documentDefault)],
            widthAtLine: .constant(200),
            defaultTabStop: 36
        )
        let lines = LineBreaker(measurer: measurer).breakParagraph(input)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].segments.count, 3, "text, tab, text")
        XCTAssertEqual(lines[0].segments[1].width, 30, accuracy: 0.001, "from x=6 to the 36 pt stop")
        XCTAssertEqual(lines[0].segments[2].x, 36, accuracy: 0.001)
    }

    func testExplicitTabStopsBeatTheDefaultGrid() {
        let input = ParagraphLayoutInput(
            paragraphID: NodeID(1),
            segments: [StyledText(text: "a\tb", style: .documentDefault)],
            widthAtLine: .constant(400),
            tabStops: [TabStop(position: Twip(points: 100), alignment: .left, leader: .dot)],
            defaultTabStop: 36
        )
        let lines = LineBreaker(measurer: measurer).breakParagraph(input)
        XCTAssertEqual(lines[0].segments[1].width, 94, accuracy: 0.001)
        XCTAssertEqual(lines[0].segments[1].tabLeader, .dot, "the renderer needs to know to draw leaders")
    }

    func testJustificationStretchesGapsButNotTheLastLine() {
        let input = ParagraphLayoutInput(
            paragraphID: NodeID(1),
            segments: [StyledText(text: "aa bb cc dd ee ff", style: .documentDefault)],
            alignment: .justify,
            widthAtLine: .constant(60)
        )
        let lines = LineBreaker(measurer: measurer).breakParagraph(input)
        XCTAssertEqual(lines.count, 2)
        XCTAssertGreaterThan(lines[0].justificationExtraPerGap, 0)
        XCTAssertEqual(lines[0].justificationGapCount, 2, "the hanging trailing space is not a gap")
        XCTAssertEqual(lines[1].justificationExtraPerGap, 0, "Word never justifies a paragraph's last line")
    }

    func testAManualLineBreakEndsTheLineWithoutEndingTheParagraph() {
        let input = ParagraphLayoutInput(
            paragraphID: NodeID(1),
            segments: [StyledText(text: "abc", style: .documentDefault)],
            breaks: [BreakMarker(characterOffset: 3, kind: .line)],
            widthAtLine: .constant(200)
        )
        let lines = LineBreaker(measurer: measurer).breakParagraph(input)
        XCTAssertEqual(lines.count, 2, "the break leaves the paragraph mark on its own line")
        XCTAssertEqual(lines[0].pendingBreak, .line)
        XCTAssertFalse(lines[0].isLastLineOfParagraph)
        XCTAssertTrue(lines[1].isLastLineOfParagraph)
    }

    func testAWordLongerThanTheLineIsSplitRatherThanLooping() {
        let input = ParagraphLayoutInput(
            paragraphID: NodeID(1),
            segments: [StyledText(text: String(repeating: "x", count: 25), style: .documentDefault)],
            widthAtLine: .constant(60)
        )
        let lines = LineBreaker(measurer: measurer).breakParagraph(input)
        XCTAssertEqual(lines.count, 3, "25 clusters at 10 per line")
        XCTAssertEqual(lines.flatMap { $0.segments.map { $0.text } }.joined().count, 25,
                       "no character may be dropped by the overflow path")
    }

    func testANonBreakingSpaceNeverStartsALine() {
        let input = ParagraphLayoutInput(
            paragraphID: NodeID(1),
            segments: [StyledText(text: "aaaaa\u{00A0}bbbbb", style: .documentDefault)],
            widthAtLine: .constant(42)
        )
        let lines = LineBreaker(measurer: measurer).breakParagraph(input)
        for line in lines {
            for segment in line.segments {
                XCTAssertFalse(segment.text.hasPrefix("\u{00A0}"), "a line must not begin with a non-breaking space")
            }
        }
        XCTAssertEqual(lines.flatMap { $0.segments.map { $0.text } }.joined(), "aaaaa\u{00A0}bbbbb")
    }

    func testLineHeightComesFromTheLineSpacingRule() {
        let breaker = LineBreaker(measurer: measurer)
        let base = ParagraphLayoutInput(
            paragraphID: NodeID(1),
            segments: [StyledText(text: "x", style: .documentDefault)],
            widthAtLine: .constant(200)
        )
        var single = base
        XCTAssertEqual(breaker.breakParagraph(single)[0].frame.height, 12, accuracy: 0.001)

        single.lineSpacing = .double
        XCTAssertEqual(breaker.breakParagraph(single)[0].frame.height, 24, accuracy: 0.001)

        // `atLeast` grows to fit the font but never shrinks below it.
        single.lineSpacing = .atLeast(Twip(points: 40))
        XCTAssertEqual(breaker.breakParagraph(single)[0].frame.height, 40, accuracy: 0.001)
        single.lineSpacing = .atLeast(Twip(points: 4))
        XCTAssertEqual(breaker.breakParagraph(single)[0].frame.height, 12, accuracy: 0.001)

        // `exact` clips: that is what the author asked for.
        single.lineSpacing = .exactly(Twip(points: 6))
        XCTAssertEqual(breaker.breakParagraph(single)[0].frame.height, 6, accuracy: 0.001)
    }

    func testTheParagraphMarkGivesAnEmptyParagraphItsHeight() {
        // In Word an empty paragraph is as tall as its paragraph mark's font: the
        // mark contributes to the last line's height, and an empty paragraph is
        // all last line. `FixedWidthMeasurer` reports the same metrics for every
        // style, so what this can assert is that the mark contributes at all —
        // an engine that measured only the (absent) text would report height 0
        // and collapse every blank line in the document.
        let input = ParagraphLayoutInput(
            paragraphID: NodeID(1),
            segments: [],
            widthAtLine: .constant(200),
            markStyle: .documentDefault
        )
        let lines = LineBreaker(measurer: measurer).breakParagraph(input)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].frame.height, 12, accuracy: 0.001)
        XCTAssertGreaterThan(lines[0].ascent, 0, "an empty line still has a baseline")
    }

    // MARK: Pagination

    func testWidowControlHoldsALineBack() {
        let controlled = layout(document(height: 36) { builder in
            builder.paragraph(self.text(lines: 4), paragraphProperties: ParagraphProperties(widowControl: true))
        })
        XCTAssertEqual(linesPerPage(controlled), [2, 2], "three-and-one would leave a widow")

        let uncontrolled = layout(document(height: 36) { builder in
            builder.paragraph(self.text(lines: 4), paragraphProperties: ParagraphProperties(widowControl: false))
        })
        XCTAssertEqual(linesPerPage(uncontrolled), [3, 1])
    }

    func testKeepWithNextMovesTheHeadingDown() {
        func fixture(keepNext: Bool) -> DocumentModel {
            document(height: 36) { builder in
                builder.paragraph(self.text(lines: 2))
                builder.paragraph("Heading", paragraphProperties: ParagraphProperties(keepWithNext: keepNext))
                builder.paragraph(self.text(lines: 2))
            }
        }
        XCTAssertEqual(linesPerPage(layout(fixture(keepNext: true))), [2, 3],
                       "a heading must not be orphaned at the foot of a page")
        XCTAssertEqual(linesPerPage(layout(fixture(keepNext: false))), [3, 2])
    }

    func testKeepLinesTogetherRefusesToSplitAParagraph() {
        func fixture(keepLines: Bool) -> DocumentModel {
            document(height: 36) { builder in
                builder.paragraph(self.text(lines: 2))
                builder.paragraph(self.text(lines: 2), paragraphProperties: ParagraphProperties(
                    keepLinesTogether: keepLines,
                    widowControl: false
                ))
            }
        }
        XCTAssertEqual(linesPerPage(layout(fixture(keepLines: true))), [2, 2])
        XCTAssertEqual(linesPerPage(layout(fixture(keepLines: false))), [3, 1])
    }

    func testPageBreakBeforeStartsANewPage() {
        let snapshot = layout(document { builder in
            builder.paragraph("first")
            builder.paragraph("second", paragraphProperties: ParagraphProperties(pageBreakBefore: true))
        })
        XCTAssertEqual(snapshot.pageCount, 2)
        XCTAssertEqual(snapshot.pages[1].breakReason, .pageBreakBefore)
    }

    func testAManualPageBreakStartsANewPage() {
        let snapshot = layout(document { builder in
            builder.paragraph("one")
            builder.pageBreak()
            builder.paragraph("two")
        })
        XCTAssertEqual(snapshot.pageCount, 2)
        let text = snapshot.pages.map { page in
            page.lines.flatMap { $0.segments.map { $0.text } }.joined()
        }
        XCTAssertTrue(text[0].contains("one"))
        XCTAssertTrue(text[1].contains("two"))
    }

    func testPageBreakBeforeOnTheFirstParagraphIsANoOp() {
        // The guard that matters: a break onto a page that is already empty must
        // not emit a leading blank page, or every document that starts with a
        // title page gains one.
        let snapshot = layout(document { builder in
            builder.paragraph("first", paragraphProperties: ParagraphProperties(pageBreakBefore: true))
        })
        XCTAssertEqual(snapshot.pageCount, 1)
    }

    func testTwoConsecutivePageBreaksDoProduceABlankPage() {
        // This is Word's behaviour, not a bug to fix: each `w:br w:type="page"`
        // forces a break, so two of them in a row leave an empty page between.
        // Matching it is the point — a reader comparing page counts with Word
        // would notice a missing page immediately.
        let snapshot = layout(document { builder in
            builder.paragraph("one")
            builder.pageBreak()
            builder.pageBreak()
            builder.paragraph("two")
        })
        XCTAssertEqual(snapshot.pageCount, 3)
        XCTAssertTrue(snapshot.pages[1].lines.allSatisfy { line in
            line.segments.allSatisfy { $0.text.isEmpty }
        }, "the middle page is blank")
    }

    func testSpaceBeforeIsSuppressedAtTheTopOfAPage() {
        // Word drops `w:spacing w:before` at the top of a page. Not dropping it
        // shifts every heading down by its own space-before.
        let snapshot = layout(document(height: 36) { builder in
            builder.paragraph("first", paragraphProperties: ParagraphProperties(spacingBefore: Twip(points: 24)))
        })
        XCTAssertEqual(snapshot.pages[0].lines[0].frame.y, 72, accuracy: 0.001,
                       "the line starts at the top margin, not 24 pt below it")
    }

    func testContextualSpacingRemovesTheGapBetweenSameStyleParagraphs() {
        let properties = ParagraphProperties(spacingAfter: Twip(points: 24), contextualSpacing: true)
        let withSpacing = layout(document { builder in
            builder.paragraph("aaa", style: "ListParagraph", paragraphProperties: properties)
            builder.paragraph("bbb", style: "ListParagraph", paragraphProperties: properties)
        })
        XCTAssertEqual(withSpacing.pages[0].lines[1].frame.y, 72 + 12, accuracy: 0.001,
                       "no 24 pt gap between two List Paragraphs")

        var uncontextual = properties
        uncontextual.contextualSpacing = false
        let withoutSpacing = layout(document { builder in
            builder.paragraph("aaa", style: "ListParagraph", paragraphProperties: uncontextual)
            builder.paragraph("bbb", style: "ListParagraph", paragraphProperties: uncontextual)
        })
        XCTAssertEqual(withoutSpacing.pages[0].lines[1].frame.y, 72 + 12 + 24, accuracy: 0.001)
    }

    func testAContinuousSectionBreakDoesNotStartAPage() {
        let pageSize = PageSize(width: Twip(points: 204), height: Twip(points: 544))
        let margins = PageMargins(top: Twip(1440), right: Twip(1440), bottom: Twip(1440), left: Twip(1440))
        var builder = DocumentBuilder(styles: Self.flatStyles)
        builder.setSectionProperties(SectionProperties(pageSize: pageSize, margins: margins))
        builder.paragraph("one")
        let twoColumn = SectionProperties(
            pageSize: pageSize,
            margins: margins,
            columns: .equal(count: 2, spacing: Twip(240)),
            start: .continuous
        )
        builder.section(properties: twoColumn, start: .continuous)
        builder.paragraph("two")

        let snapshot = layout(builder.build())
        XCTAssertEqual(snapshot.pageCount, 1, "w:type=continuous stays on the same page")
        let frames = Paginator.columnFrames(for: twoColumn, textArea: twoColumn.textAreaRect)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].width, 24, accuracy: 0.001, "60 pt minus a 12 pt gap, split in two")
    }

    func testASectionCanRestartPageNumbering() {
        let pageSize = PageSize(width: Twip(points: 204), height: Twip(points: 544))
        let margins = PageMargins(top: Twip(1440), right: Twip(1440), bottom: Twip(1440), left: Twip(1440))
        var builder = DocumentBuilder(styles: Self.flatStyles)
        builder.setSectionProperties(SectionProperties(pageSize: pageSize, margins: margins))
        builder.paragraph("front matter")
        builder.section(
            properties: SectionProperties(
                pageSize: pageSize, margins: margins,
                pageNumbering: PageNumbering(format: .lowerRoman, start: 3),
                start: .nextPage
            ),
            start: .nextPage
        )
        builder.paragraph("body")

        let snapshot = layout(builder.build())
        XCTAssertEqual(snapshot.pageCount, 2)
        XCTAssertEqual(snapshot.pages[0].displayedPageNumber, 1)
        XCTAssertEqual(snapshot.pages[1].displayedPageNumber, 3, "w:pgNumType w:start restarts the count")
        XCTAssertEqual(snapshot.pages[1].pageWithinSection, 1)
    }

    func testColumnsFlow() {
        let pageSize = PageSize(width: Twip(points: 204), height: Twip(points: 288))
        let margins = PageMargins(top: Twip(1440), right: Twip(1440), bottom: Twip(1440), left: Twip(1440))
        var properties = SectionProperties(pageSize: pageSize, margins: margins)
        properties.columns = .equal(count: 2, spacing: Twip(0))
        var builder = DocumentBuilder(styles: Self.flatStyles)
        builder.setSectionProperties(properties)
        builder.paragraph(text(lines: 6))

        let snapshot = layout(builder.build())
        XCTAssertEqual(snapshot.pageCount, 1, "6 groups of 10 clusters become 12 lines of 5, and a column holds 12")
        XCTAssertEqual(snapshot.pages[0].columns.count, 2)
    }

    // MARK: Engine properties

    func testLayoutIsDeterministic() {
        let model = document(width: 468) { builder in
            builder.heading("Title", level: 1)
            for index in 0..<40 {
                builder.paragraph("Paragraph \(index): the quick brown fox jumps over the lazy dog again and again.")
            }
        }
        let engine = LayoutEngine(measurer: measurer)
        XCTAssertEqual(engine.layout(document: model, generation: 3), engine.layout(document: model, generation: 3),
                       "the same document must lay out identically every time")
    }

    func testTheSnapshotIndexFindsEveryParagraphsFirstPage() {
        let model = document(height: 36) { builder in
            builder.paragraph(self.text(lines: 3))
            builder.paragraph(self.text(lines: 3))
        }
        let snapshot = layout(model)
        XCTAssertEqual(snapshot.pageCount, 2)
        let ids = model.paragraphIDsInOrder
        XCTAssertEqual(snapshot.firstPageOfParagraph[ids[0]], 0)
        XCTAssertEqual(snapshot.firstPageOfParagraph[ids[1]], 1)
        XCTAssertNotNil(snapshot.paragraphPositions[ids[0]], "the navigation pane needs a frame per paragraph")
    }

    func testALineTallerThanAPageIsPlacedRatherThanLooping() {
        // A large inline image in an `exact`-spaced paragraph can exceed the
        // whole text area. The paginator must place it and overflow, never spin.
        let snapshot = layout(document(width: 60, height: 12) { builder in
            builder.paragraph("x", paragraphProperties: ParagraphProperties(
                lineSpacing: .exactly(Twip(points: 400))
            ))
        })
        XCTAssertEqual(snapshot.pageCount, 1)
        XCTAssertEqual(snapshot.pages[0].lines.count, 1)
    }

    func testLineSegmentsCarryCharacterOffsetsForHitTesting() {
        // 200 pt, so "hello world" stays on one line and the offsets below are
        // about characters rather than about a wrap.
        let snapshot = layout(document(width: 200) { builder in
            builder.paragraph("hello world")
        })
        let line = snapshot.pages[0].lines[0]
        XCTAssertEqual(line.characterRange.lowerBound, 0)
        XCTAssertEqual(line.characterRange.upperBound, 11)
        XCTAssertEqual(line.segments[0].characterOffset, 0)
        XCTAssertEqual(line.xOffset(forCharacterOffset: 0), line.frame.x, accuracy: 0.001)
        XCTAssertEqual(line.xOffset(forCharacterOffset: 5), line.frame.x + 30, accuracy: 0.001)
        XCTAssertEqual(line.characterOffset(nearestX: line.frame.x + 1), 0, "clicking the first cluster")
        XCTAssertEqual(line.characterOffset(nearestX: line.frame.x + 1000), 11, "clicking past the end")
    }

    func testRevisionMarkupChangesTheLayout() {
        // A deletion, not an insertion: No Markup shows the *final* text, which
        // includes insertions and excludes deletions. Testing an insertion here
        // would assert that two different markup modes lay out identically.
        var builder = DocumentBuilder(styles: Self.flatStyles)
        let deleted = RevisionMark(id: 1, author: "A", date: Date(timeIntervalSince1970: 0), kind: .deletion)
        builder.append(block: .paragraph(Paragraph(
            id: NodeID(500),
            properties: ParagraphProperties(styleID: "Normal"),
            runs: [
                Run(id: NodeID(501), content: .text("keep ")),
                Run(id: NodeID(502), content: .text("dropped"), properties: .empty, revision: deleted),
            ]
        )))
        let model = builder.build()
        let engine = LayoutEngine(measurer: measurer)

        let marked = engine.layout(document: model, markup: .allMarkup)
        let clean = engine.layout(document: model, markup: .noMarkup)
        let markedText = marked.pages[0].lines.flatMap { $0.segments.map { $0.text } }.joined()
        let cleanText = clean.pages[0].lines.flatMap { $0.segments.map { $0.text } }.joined()
        XCTAssertEqual(markedText, "keep dropped", "All Markup shows the struck-through text")
        XCTAssertEqual(cleanText, "keep ", "No Markup lays out the final text, which is narrower")
        XCTAssertNotEqual(marked, clean, "markup is a layout input, not a rendering decoration")
    }
}
