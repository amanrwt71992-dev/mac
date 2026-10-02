import Foundation
import CoreKit

// MARK: - PaginationItem

/// One paragraph, tagged with the section it belongs to.
///
/// The section index travels with the paragraph rather than being inferred from
/// block order, because section boundaries in OOXML are marked by a `sectPr`
/// inside the *last paragraph* of the section — a shape that is easy to lose
/// track of once paragraphs have been filtered, reordered or lazily laid out.
public struct PaginationItem: Hashable, Sendable {
    public var paragraph: LaidOutParagraph
    public var sectionIndex: Int

    public init(paragraph: LaidOutParagraph, sectionIndex: Int) {
        self.paragraph = paragraph
        self.sectionIndex = sectionIndex
    }
}

// MARK: - Paginator

/// Places already-broken paragraphs onto pages and columns.
///
/// Pure and synchronous, like the line breaker. Everything it needs is in its
/// arguments, so it can run on any thread and its output can be compared for
/// equality in tests.
///
/// The rules implemented here are the ones that actually change page counts in
/// real documents:
///
/// - `w:spacing w:before` is suppressed at the top of a page. Word does this, and
///   not doing it shifts every heading down by its own space-before.
/// - `w:contextualSpacing` removes the gap between same-style paragraphs.
/// - `w:keepNext` keeps a heading with the paragraph that follows it.
/// - `w:keepLines` refuses to split a paragraph across a page.
/// - `w:widowControl` forbids a single line alone at the bottom of a page
///   (orphan) or alone at the top of the next (widow).
/// - `w:pageBreakBefore`, manual page breaks, and section starts of type
///   `nextPage`/`evenPage`/`oddPage`/`nextColumn`/`continuous`.
/// - Multi-column flow, including a paragraph that starts in one column and
///   finishes in another.
///
/// **Termination.** Every branch either places at least one line or advances the
/// column, and advancing always moves to a fresh column or a fresh page. The one
/// situation where a line cannot be placed — a line taller than an entire column,
/// which happens with a large inline image in an `exact`-spaced paragraph — is
/// detected by "the column is already empty" and the line is placed anyway,
/// overflowing. That escape is what makes an infinite loop structurally
/// impossible rather than merely unlikely.
public struct Paginator: Sendable {

    public init() {}

    /// Slack for floating-point comparisons against the column bottom.
    static let slack: Double = 0.01

    /// Lays the items out onto pages.
    public func paginate(
        items: [PaginationItem],
        sections: [SectionProperties],
        generation: UInt64 = 0
    ) -> LayoutSnapshot {
        var state = PaginationState(sections: sections)

        var index = 0
        while index < items.count {
            let item = items[index]
            state.handleSectionChange(to: item.sectionIndex)
            state.ensurePage(reason: .natural)

            let paragraph = item.paragraph
            let next = index + 1 < items.count ? items[index + 1].paragraph : nil

            // `w:pageBreakBefore`, or a manual page break ending the previous
            // paragraph, starts a new page — but only if this page is not
            // already empty, so two consecutive breaks do not emit a blank page.
            if paragraph.pageBreakBefore || state.previousEndedWithPageBreak {
                if !state.currentPageIsEmpty {
                    state.beginPage(reason: paragraph.pageBreakBefore ? .pageBreakBefore : .manualBreak)
                }
            }

            // Spacing is resolved *after* the page-break decision, because the
            // answer depends on whether we ended up at the top of a page.
            let leading = state.leadingSpace(paragraph)

            place(
                paragraph: paragraph,
                leadingSpace: leading,
                nextParagraph: next,
                state: &state
            )

            state.finishParagraph(paragraph)
            index += 1
        }

        state.flushPage()
        state.renumberPages()
        state.indexParagraphs()

        return LayoutSnapshot(
            pages: state.pages,
            firstPageOfParagraph: state.firstPageOfParagraph,
            paragraphPositions: state.paragraphPositions,
            contentHeight: state.contentHeight,
            generation: generation
        )
    }

    // MARK: - Paragraph placement

    /// Places one paragraph, possibly splitting it across columns and pages.
    private func place(
        paragraph: LaidOutParagraph,
        leadingSpace: Double,
        nextParagraph: LaidOutParagraph?,
        state: inout PaginationState
    ) {
        let lines = paragraph.lines
        guard !lines.isEmpty else {
            // An empty paragraph still occupies vertical space — the paragraph
            // mark is a character with a height, and dropping it would change
            // the page count of every document containing a blank line.
            state.recordEmptyParagraph(paragraph, leadingSpace: leadingSpace)
            return
        }

        // The gap above the paragraph is consumed *before* its first line is
        // placed. Adding it afterwards — as `consume` used to — draws the line at
        // the previous paragraph's baseline and leaves the gap below it. The
        // total advance is the same either way, which is why this survived a
        // single-paragraph fixture and only shows up once two paragraphs meet.
        state.consume(height: leadingSpace)

        var chunk = state.makeChunk(of: paragraph, spaceBefore: leadingSpace)
        var placed = 0

        while placed < lines.count {
            let remaining = lines.count - placed
            // `leadingSpace` is already consumed, so the remaining height is the
            // space this chunk actually has.
            let available = state.remainingHeightInColumn
            let fitting = Self.countLines(lines[placed...], thatFitIn: available)

            var limit = fitting

            if placed == 0 {
                // `w:keepLines`: the whole paragraph must stay together, unless
                // it cannot fit in an empty column at all — in which case Word
                // gives up and splits it, and so do we.
                if paragraph.keepLinesTogether, remaining > fitting, !state.columnIsEmpty {
                    state.advanceColumn()
                    continue
                }

                // `w:widowControl`, orphan side: never leave one line alone at
                // the bottom of a column.
                if paragraph.widowControl, remaining >= 2, fitting <= 1, !state.columnIsEmpty {
                    state.advanceColumn()
                    continue
                }

                // `w:widowControl`, widow side: if placing all that fits would
                // leave exactly one line for the next column, hold one back so
                // two remain.
                if paragraph.widowControl, remaining >= 3, fitting >= 2, fitting == remaining - 1 {
                    limit = fitting - 1
                }
            }

            // `w:keepNext`, decided once, before the first line is placed.
            //
            // Holding a line back cannot work here: a heading is usually a single
            // line, so there is nothing to hold back. The rule that actually
            // matches Word is "if this paragraph fits in a column on its own,
            // but this paragraph and the next one's first line do not fit in the
            // space left, move the whole thing down". A paragraph too long to fit
            // in any column is left to split normally, which is also what Word
            // does — otherwise a long keepNext paragraph would push itself to a
            // blank page forever.
            if let next = nextParagraph, paragraph.keepWithNext, placed == 0 {
                let selfHeight = lines.reduce(0.0) { $0 + $1.frame.height }
                let nextNeeds = next.spaceBefore + (next.lines.first?.frame.height ?? 0)
                let fitsAlone = selfHeight <= state.textAreaRect.height + Self.slack
                let fitsTogether = selfHeight + paragraph.spaceAfter + nextNeeds <= available + Self.slack
                if fitsAlone, !fitsTogether, !state.columnIsEmpty {
                    state.advanceColumn()
                    continue
                }
            }

            // Never place past a manual break.
            //
            // A line carrying `w:br w:type="page"` ends its page, so the lines
            // after it belong somewhere else. Without this cap a paragraph that
            // fits entirely in the remaining space is placed in one chunk and the
            // break inside it is never seen — which silently deletes every manual
            // page break in a short document.
            if limit > 0 {
                let upper = placed + limit
                if let breakIndex = lines[placed..<upper].firstIndex(where: {
                    $0.pendingBreak == .page || $0.pendingBreak == .column
                }) {
                    limit = breakIndex - placed + 1
                }
            }

            // Nothing fits. Either the column is full — advance — or the column
            // is already empty and this single line is taller than a whole
            // column, in which case it must be placed anyway. This is the
            // termination escape.
            if limit <= 0 {
                if state.columnIsEmpty {
                    limit = 1
                } else {
                    if !chunk.lines.isEmpty {
                        state.append(chunk: chunk, isFinal: false)
                        chunk = state.makeChunk(of: paragraph, spaceBefore: 0)
                    }
                    state.advanceColumn()
                    continue
                }
            }

            let slice = lines[placed..<(placed + limit)]
            for line in slice {
                chunk.lines.append(state.position(line: line))
            }
            state.consume(height: slice.reduce(0.0) { $0 + $1.frame.height })
            placed += limit

            guard placed < lines.count else { break }

            // The paragraph continues: flush this chunk and move on.
            state.append(chunk: chunk, isFinal: false)
            chunk = state.makeChunk(of: paragraph, spaceBefore: 0)

            if let breakKind = lines[placed - 1].pendingBreak {
                switch breakKind {
                case .page:   state.beginPage(reason: .manualBreak)
                case .column: state.advanceColumn()
                case .line:   break
                }
            } else {
                state.advanceColumn()
            }
        }

        state.append(chunk: chunk, isFinal: true)
    }

    /// How many of the given lines fit in `height`.
    private static func countLines(_ lines: ArraySlice<LayoutLine>, thatFitIn height: Double) -> Int {
        guard height > 0 else { return 0 }
        var used = 0.0
        var count = 0
        for line in lines {
            if used + line.frame.height > height + slack { break }
            used += line.frame.height
            count += 1
        }
        return count
    }

    /// Resolves column geometry for a section.
    ///
    /// Column x origins are absolute in page coordinates; the line breaker works
    /// in text-area coordinates, so lines are shifted when they are placed.
    public static func columnFrames(for properties: SectionProperties, textArea: Rect) -> [Rect] {
        let widths = properties.columns.resolveWidths(availableWidth: textArea.width)
        guard widths.count > 1 else {
            return [Rect(x: textArea.x, y: textArea.y, width: textArea.width, height: textArea.height)]
        }
        let gaps = properties.columns.columns
        let rightToLeft = properties.columns.rightToLeft

        var frames: [Rect] = []
        if rightToLeft {
            var x = textArea.maxX
            for (index, width) in widths.enumerated() {
                x -= width
                frames.append(Rect(x: x, y: textArea.y, width: width, height: textArea.height))
                if index + 1 < gaps.count { x -= gaps[index].space.points }
            }
        } else {
            var x = textArea.x
            for (index, width) in widths.enumerated() {
                frames.append(Rect(x: x, y: textArea.y, width: width, height: textArea.height))
                x += width
                if index + 1 < gaps.count { x += gaps[index].space.points }
            }
        }
        return frames
    }
}

// MARK: - PaginationState

/// Mutable cursor state for one pagination run.
///
/// Kept out of `Paginator` so the paginator itself stays a value type with no
/// hidden state, and so the invariants (never place past the column bottom,
/// always make progress) live in one small auditable place.
private struct PaginationState {

    let sections: [SectionProperties]
    let fallback = SectionProperties()

    var pages: [PageLayout] = []
    var page: PageLayout?

    var currentSection = -1
    var properties = SectionProperties()
    var textArea = Rect.zero
    var columnFrames: [Rect] = []

    var columnIndex = 0
    /// Absolute y of the next line's top edge, in page coordinates.
    var y = 0.0

    /// The number Word would display, driven by `w:pgNumType w:start`.
    var displayedCounter = 0
    var sectionStartPage: [Int: Int] = [:]

    var previousStyleID: String?
    var previousContextualSpacing = false
    var previousSpaceAfter = 0.0
    var previousKeepWithNext = false
    var previousEndedWithPageBreak = false

    var firstPageOfParagraph: [NodeID: Int] = [:]
    var paragraphPositions: [NodeID: ParagraphPosition] = [:]

    init(sections: [SectionProperties]) {
        self.sections = sections
        self.properties = SectionProperties()
    }

    // MARK: Geometry

    /// The section's text area, in page coordinates.
    var textAreaRect: Rect { textArea }

    var columnTop: Double { textArea.y }
    var columnBottom: Double { textArea.y + textArea.height }
    var remainingHeightInColumn: Double { max(0, columnBottom - y) }
    var columnIsEmpty: Bool { y <= columnTop + Paginator.slack }
    var currentPageIsEmpty: Bool { page?.paragraphs.isEmpty ?? true }

    var currentColumn: Rect {
        guard !columnFrames.isEmpty else { return textArea }
        return columnFrames[max(0, min(columnIndex, columnFrames.count - 1))]
    }

    /// Shifts a line from text-area coordinates into page coordinates for the
    /// current column.
    func position(line: LayoutLine) -> LayoutLine {
        let column = currentColumn
        var copy = line
        copy.frame = Rect(x: column.x, y: y, width: column.width, height: line.frame.height)
        copy.segments = line.segments.map { segment in
            var shifted = segment
            // The breaker emits segment x relative to the *column*, starting at
            // the indent — it has no idea where the column sits on the page, and
            // must not, or a line-break cache would be invalidated by a margin
            // change. So the shift is the column's origin plus the segment's own
            // offset, not a difference of two page-coordinate origins.
            shifted.x = column.x + segment.x
            return shifted
        }
        return copy
    }

    /// Advances the baseline cursor by a placed line's height.
    ///
    /// `mutating` because it moves the cursor: everything downstream — how much
    /// room is left in the column, whether the column is empty, where the next
    /// line goes — reads `y`, so a caller that could not commit the advance would
    /// place every subsequent line on top of the previous one.
    mutating func consume(height: Double) {
        y += height
    }

    // MARK: Page and column lifecycle

    mutating func flushPage() {
        guard var finished = page else { return }
        finished = applyVerticalAlignment(finished)
        pages.append(finished)
        page = nil
    }

    mutating func beginPage(reason: PageBreakReason) {
        flushPage()
        displayedCounter += 1
        page = PageLayout(
            index: pages.count,
            sectionIndex: max(0, currentSection),
            pageWithinSection: 1,
            displayedPageNumber: displayedCounter,
            pageSize: properties.pageSize,
            margins: properties.margins,
            textArea: textArea,
            columns: columnFrames.enumerated().map { ColumnLayout(index: $0.offset, frame: $0.element) },
            paragraphs: [],
            breakReason: reason
        )
        columnIndex = 0
        y = columnTop
        previousSpaceAfter = 0
        previousStyleID = nil
        previousEndedWithPageBreak = false
    }

    mutating func advanceColumn() {
        if columnIndex + 1 < columnFrames.count {
            columnIndex += 1
            y = columnTop
            previousSpaceAfter = 0
            previousStyleID = nil
        } else {
            beginPage(reason: .columnOverflow)
        }
    }

    mutating func ensurePage(reason: PageBreakReason) {
        guard page == nil else { return }
        if currentSection < 0 { adoptSection(0) }
        beginPage(reason: reason)
    }

    mutating func adoptSection(_ index: Int) {
        currentSection = index
        properties = index >= 0 && index < sections.count ? sections[index] : fallback
        textArea = properties.textAreaRect
        columnFrames = Paginator.columnFrames(for: properties, textArea: textArea)
    }

    /// Handles a section boundary.
    ///
    /// `w:type="continuous"` is the case that trips implementations up most
    /// often: it must *not* start a new page. Starting a page there is the single
    /// most common cause of "our page count differs from Word's".
    mutating func handleSectionChange(to index: Int) {
        guard index != currentSection else { return }
        let nextStart = index >= 0 && index < sections.count ? sections[index].start : .nextPage
        adoptSection(index)

        if page == nil {
            beginPage(reason: .sectionBreak(nextStart))
        } else {
            switch nextStart {
            case .continuous:
                if columnIndex + 1 < columnFrames.count {
                    columnIndex += 1
                    y = columnTop
                    previousSpaceAfter = 0
                    previousStyleID = nil
                }
            case .nextColumn:
                advanceColumn()
            case .nextPage:
                beginPage(reason: .sectionBreak(nextStart))
            case .evenPage, .oddPage:
                beginPage(reason: .sectionBreak(nextStart))
                let wantEven = nextStart == .evenPage
                // Bounded: a malformed document cannot spin here.
                var attempts = 0
                while (displayedCounter % 2 == 0) != wantEven, attempts < 2 {
                    beginPage(reason: .sectionBreak(nextStart))
                    attempts += 1
                }
            }
        }

        if let start = properties.pageNumbering.start {
            displayedCounter = Int(start)
            page?.displayedPageNumber = displayedCounter
        }
        page?.pageWithinSection = 1
    }

    // MARK: Spacing

    /// The whole vertical gap above this paragraph: the previous paragraph's
    /// `w:after` plus this one's `w:before`.
    ///
    /// Resolved as one number rather than added in two places, because both
    /// halves are suppressed by the same two rules and getting only one of them
    /// right is a classic source of "our page count is off by one".
    ///
    /// - At the top of a page or column, Word drops the gap entirely.
    /// - `w:contextualSpacing` on either paragraph removes the gap when the two
    ///   share a style — this is what makes a run of List Paragraphs sit tight.
    func leadingSpace(_ paragraph: LaidOutParagraph) -> Double {
        if columnIsEmpty { return 0 }
        if paragraph.contextualSpacing || previousContextualSpacing,
           let style = paragraph.styleID, style == previousStyleID {
            return 0
        }
        return previousSpaceAfter + paragraph.spaceBefore
    }

    mutating func finishParagraph(_ paragraph: LaidOutParagraph) {
        previousStyleID = paragraph.styleID
        previousContextualSpacing = paragraph.contextualSpacing
        // `spaceAfter` is *not* added to `y` here: `leadingSpace` adds it to the
        // next paragraph, so that the suppression rules can see both halves.
        previousSpaceAfter = paragraph.spaceAfter
        previousKeepWithNext = paragraph.keepWithNext
        previousEndedWithPageBreak = paragraph.lines.last?.pendingBreak == .page
        if paragraph.lines.last?.pendingBreak == .column {
            advanceColumn()
        }
    }

    // MARK: Chunking

    /// Starts a new `LaidOutParagraph` carrying the given paragraph's page rules.
    ///
    /// A paragraph split across pages appears on both pages as separate chunks,
    /// each holding only its own lines. That is why chunks are created per page
    /// rather than per paragraph.
    func makeChunk(of paragraph: LaidOutParagraph, spaceBefore: Double) -> LaidOutParagraph {
        var chunk = LaidOutParagraph(paragraphID: paragraph.paragraphID)
        chunk.spaceBefore = spaceBefore
        chunk.spaceAfter = paragraph.spaceAfter
        chunk.keepLinesTogether = paragraph.keepLinesTogether
        chunk.keepWithNext = paragraph.keepWithNext
        chunk.pageBreakBefore = paragraph.pageBreakBefore
        chunk.widowControl = paragraph.widowControl
        chunk.lineSpacing = paragraph.lineSpacing
        chunk.contextualSpacing = paragraph.contextualSpacing
        chunk.styleID = paragraph.styleID
        chunk.startsNewPage = currentPageIsEmpty
        return chunk
    }

    mutating func append(chunk: LaidOutParagraph, isFinal: Bool) {
        guard !chunk.lines.isEmpty || (isFinal && chunk.spaceBefore > 0) else { return }
        var copy = chunk
        if !isFinal { copy.spaceAfter = 0 }
        page?.paragraphs.append(copy)
    }

    /// An empty paragraph: advance y by its spacing so following content moves
    /// down as it would in Word.
    mutating func recordEmptyParagraph(_ paragraph: LaidOutParagraph, leadingSpace: Double) {
        y += leadingSpace
        previousStyleID = paragraph.styleID
        previousContextualSpacing = paragraph.contextualSpacing
        previousSpaceAfter = paragraph.spaceAfter
        previousKeepWithNext = paragraph.keepWithNext
        // No lines means no chunk to record, but the paragraph still occupies
        // space and still ends a page if it carries a manual break.
        previousEndedWithPageBreak = false
    }

    // MARK: Post-passes

    /// Records which page each paragraph starts on, and where.
    ///
    /// A post-pass rather than a note taken during placement: while placing, a
    /// paragraph that is about to be pushed to the next column still reports the
    /// column it was in when the decision was made. Walking the finished pages is
    /// exact by construction, and it is also the only place that knows the
    /// paragraph's index within its page, which `ParagraphPosition` needs.
    mutating func indexParagraphs() {
        for pageIndex in pages.indices {
            for paragraphIndex in pages[pageIndex].paragraphs.indices {
                let laid = pages[pageIndex].paragraphs[paragraphIndex]
                if firstPageOfParagraph[laid.paragraphID] == nil {
                    firstPageOfParagraph[laid.paragraphID] = pageIndex
                }
                if paragraphPositions[laid.paragraphID] == nil, let firstLine = laid.lines.first {
                    paragraphPositions[laid.paragraphID] = ParagraphPosition(
                        pageIndex: pageIndex,
                        lineIndexWithinPage: paragraphIndex,
                        frame: firstLine.frame
                    )
                }
            }
        }
    }

    /// Fills in `index` and `pageWithinSection` now that every page exists.
    mutating func renumberPages() {
        var starts: [Int: Int] = [:]
        for pageIndex in pages.indices {
            let section = pages[pageIndex].sectionIndex
            if starts[section] == nil { starts[section] = pageIndex }
            pages[pageIndex].index = pageIndex
            pages[pageIndex].pageWithinSection = pageIndex - (starts[section] ?? pageIndex) + 1
        }
    }

    var contentHeight: Double {
        pages.reduce(0.0) { $0 + $1.pageSize.height.points }
    }

    /// Applies `w:vAlign`, which shifts the whole text block within the page.
    ///
    /// A post-pass because a page's final content height is not known until
    /// every paragraph has been placed on it.
    private func applyVerticalAlignment(_ page: PageLayout) -> PageLayout {
        switch properties.verticalAlignment {
        case .top:
            return page
        case .center, .bottom, .both:
            break
        }
        guard let firstLine = page.paragraphs.first?.lines.first,
              let lastLine = page.paragraphs.last?.lines.last else { return page }

        let used = lastLine.frame.maxY - firstLine.frame.minY
        let free = max(0, page.textArea.height - used)
        let offset: Double
        switch properties.verticalAlignment {
        case .top:    offset = 0
        case .center: offset = free / 2
        case .bottom: offset = free
        // `both` distributes the free space between paragraphs, which needs the
        // paragraph boundaries; M0 treats it as top-aligned rather than guessing.
        case .both:   offset = 0
        }
        guard offset > Paginator.slack else { return page }

        var shifted = page
        shifted.paragraphs = page.paragraphs.map { paragraph in
            var copy = paragraph
            copy.lines = paragraph.lines.map { line in
                var moved = line
                moved.frame = Rect(x: line.frame.x, y: line.frame.y + offset, width: line.frame.width, height: line.frame.height)
                return moved
            }
            return copy
        }
        return shifted
    }
}
