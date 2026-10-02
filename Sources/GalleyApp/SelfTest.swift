import Foundation
import CoreKit
import LayoutKit
import EditorKit
import IntelligenceKit

// MARK: - Assertions

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Assertions that throw rather than trap.
///
/// A harness that calls `precondition` cannot report which check failed after
/// the first one, and a crash in CI produces a stack trace instead of a sentence.
/// Throwing means every check reports its own failure and the run continues.
func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw CheckFailure(message: message()) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String) throws {
    guard actual == expected else {
        throw CheckFailure(message: "\(message()) — expected \(expected), got \(actual)")
    }
}

func expectClose(
    _ actual: Double,
    _ expected: Double,
    tolerance: Double = 0.01,
    _ message: @autoclosure () -> String
) throws {
    guard abs(actual - expected) <= tolerance else {
        throw CheckFailure(message: "\(message()) — expected \(expected) ±\(tolerance), got \(actual)")
    }
}

// MARK: - SelfTest

struct SelfTestContext {
    let width: Double
    let measurer: any TextMeasurer
    let verbose: Bool
}

struct SelfTest {

    let name: String

    /// Whether the check's expected numbers were derived from
    /// `FixedWidthMeasurer.tenPoint`.
    ///
    /// A check that says "three lines fit in a 36 pt text area" is only true
    /// because a line is exactly 12 pt under the synthetic measurer. Running it
    /// against CoreText would measure the same assertions against real Carlito
    /// metrics and fail for a reason that has nothing to do with the layout
    /// algorithms — so those checks declare the dependency and skip themselves,
    /// while the structural ones (page counts, break reasons, model invariants,
    /// editing behaviour) run against both backends.
    let requiresFixedMetrics: Bool

    let body: (SelfTestContext) throws -> Void

    init(
        name: String,
        requiresFixedMetrics: Bool = false,
        body: @escaping (SelfTestContext) throws -> Void
    ) {
        self.name = name
        self.requiresFixedMetrics = requiresFixedMetrics
        self.body = body
    }

    func run(width: Double, measurer: any TextMeasurer, verbose: Bool) throws {
        try body(SelfTestContext(width: width, measurer: measurer, verbose: verbose))
    }

    static func layout(_ document: DocumentModel, measurer: any TextMeasurer) -> LayoutSnapshot {
        LayoutEngine(measurer: measurer).layout(document: document)
    }

    static func linesPerPage(_ snapshot: LayoutSnapshot) -> [Int] {
        snapshot.pages.map { $0.lines.count }
    }

    // Every measurement below assumes `FixedWidthMeasurer.tenPoint`: 6 pt per
    // cluster, 6 pt per space, 12 pt per single-spaced line. A 60 pt column holds
    // exactly 10 clusters; a page whose text area is 36 pt holds exactly 3 lines.
    static let all: [SelfTest] = [

        // MARK: Model

        SelfTest(name: "blank-document-is-one-page") { ctx in
            let snapshot = SelfTest.layout(DocumentModel.blank(), measurer: ctx.measurer)
            try expectEqual(snapshot.pageCount, 1, "a blank document is one page")
            try expectEqual(snapshot.pages[0].lines.count, 1, "a blank document is one empty line")
            try expectEqual(
                snapshot.pages[0].displayedPageNumber, 1,
                "the first page of the first section is page 1"
            )
        },

        SelfTest(name: "empty-paragraph-occupies-a-line") { ctx in
            // The paragraph mark is a character with a height. An engine that
            // skips empty paragraphs produces a different page count from Word's
            // on any document containing a blank line.
            let document = SampleDocument.sized(widthPoints: 60, heightPoints: 400) { builder in
                builder.paragraph("aaa")
                builder.emptyParagraph()
                builder.paragraph("bbb")
            }
            let snapshot = SelfTest.layout(document, measurer: ctx.measurer)
            try expectEqual(snapshot.pageCount, 1, "three short lines fit on one page")
            try expectEqual(snapshot.pages[0].lines.count, 3, "the empty paragraph still takes a line")
        },

        SelfTest(name: "node-ids-are-unique") { _ in
            let document = SampleDocument.make()
            var ids: [NodeID] = []
            for section in document.sections {
                ids.append(section.id)
                for block in section.blocks {
                    // `block.id` is the paragraph's own id for a `.paragraph`
                    // block; counting both would report a false duplicate.
                    if let paragraph = block.paragraph {
                        ids.append(paragraph.id)
                        ids.append(contentsOf: paragraph.runs.map { $0.id })
                    } else {
                        ids.append(block.id)
                    }
                }
            }
            try expectEqual(Set(ids).count, ids.count, "every node in the tree has a distinct id")
            try expect(ids.count > 20, "the fixture is large enough to be worth checking")
        },

        SelfTest(name: "word-count-excludes-separators") { _ in
            let document = DocumentModel.blank()
            // Word's own separator stories (ids -1 and 0) must never reach the
            // word count or the notes pane.
            let separator = Note(
                footnoteIndex: -1, id: NodeID(900),
                blocks: [.paragraph(.plain(id: NodeID(910), text: "junk"))]
            )
            let continuation = Note(
                footnoteIndex: 0, id: NodeID(901),
                blocks: [.paragraph(.plain(id: NodeID(911), text: "more junk"))]
            )
            let real = Note(
                footnoteIndex: 1, id: NodeID(902),
                blocks: [.paragraph(.plain(id: NodeID(912), text: "genuine note"))]
            )
            var model = document
            model.footnotes = NoteCollection(notes: [separator, continuation, real])
            try expect(separator.isSeparator, "id -1 is Word's separator")
            try expect(continuation.isSeparator, "id 0 is Word's continuation separator")
            try expect(!real.isSeparator, "id 1 is a user footnote")
            let counted = model.footnotes.notes.filter { !$0.isSeparator }
            try expectEqual(counted.count, 1, "only user notes are counted")
        },

        // MARK: Style cascade

        SelfTest(name: "style-cascade-resolves-heading-one") { _ in
            let resolver = StyleResolver(document: DocumentModel.blank())
            let resolved = resolver.resolveParagraph(ParagraphProperties(styleID: "Heading1"))
            try expect(resolved.keepWithNext, "Heading 1 sets w:keepNext so a heading never ends a page")
            try expect(resolved.keepLinesTogether, "Heading 1 sets w:keepLines")
            try expectClose(resolved.markStyle.font.sizePoints, 16, tolerance: 0.001,
                            "Heading 1 is 32 half-points = 16 pt")
            try expectEqual(resolved.markStyle.font.family, "Calibri Light",
                            "Heading 1 uses Calibri Light in the Office theme")
            try expectClose(resolved.spaceBefore, 24, tolerance: 0.001,
                            "Heading 1 sets w:before=480 twips = 24 pt")
        },

        SelfTest(name: "style-chain-inherits-through-based-on") { _ in
            let table = StyleTable.wordDefaults
            // HeadingChar is basedOn Heading1; Heading1 is basedOn Normal. The
            // chain must resolve base-first, and a cycle must not hang.
            var cyclic = table
            cyclic.insert(Style(styleID: "A", kind: .paragraph, name: "A", basedOn: "B"))
            cyclic.insert(Style(styleID: "B", kind: .paragraph, name: "B", basedOn: "A"))
            try expectEqual(cyclic.resolveChain(styleID: "A").count, 2,
                            "a basedOn cycle terminates rather than hanging")
            try expectEqual(table.resolveChain(styleID: "Heading3").map { $0.styleID },
                            ["Normal", "Heading1", "Heading2", "Heading3"],
                            "the chain resolves base-first")
        },

        SelfTest(name: "explicit-off-is-not-inheritance") { _ in
            // `nil` means inherit; `false` means explicitly off. Conflating the
            // two is how bold disappears when a file is saved.
            let inherited = RunProperties(bold: true)
            let directOff = RunProperties(bold: false)
            let merged = inherited.merging(directOff)
            try expectEqual(merged.bold, false, "an explicit false overrides an inherited true")
            let mergedInherit = inherited.merging(RunProperties())
            try expectEqual(mergedInherit.bold, true, "an absent property inherits")
        },

        SelfTest(name: "tab-clear-removes-inherited-stops") { _ in
            let inherited = ParagraphProperties(tabs: [
                TabStop(position: Twip(720), alignment: .left),
                TabStop(position: Twip(1440), alignment: .center),
            ])
            let direct = ParagraphProperties(tabs: [TabStop(position: Twip(720), alignment: .clear)])
            let merged = inherited.merging(direct)
            let positions = (merged.tabs ?? []).map { $0.position }
            try expect(!positions.contains(Twip(720)), "a w:tab w:val=clear entry removes the inherited stop")
            try expect(positions.contains(Twip(1440)), "stops that were not cleared survive")
        },

        // MARK: Line breaking

        SelfTest(name: "line-breaks-respect-column-width", requiresFixedMetrics: true) { ctx in
            let document = SampleDocument.sized(widthPoints: 60, heightPoints: 400) { builder in
                builder.paragraph(SampleDocument.text(lines: 3))
            }
            let snapshot = SelfTest.layout(document, measurer: ctx.measurer)
            try expectEqual(snapshot.pageCount, 1, "three lines fit on a 400 pt page")
            try expectEqual(snapshot.pages[0].lines.count, 3, "10 clusters per 60 pt line, three lines")
            for (index, line) in snapshot.pages[0].lines.enumerated() {
                try expectClose(line.contentWidth, 60, tolerance: 0.001,
                                "line \(index + 1) fills the column exactly")
            }
        },

        SelfTest(name: "trailing-whitespace-hangs-into-margin", requiresFixedMetrics: true) { ctx in
            // Word's default (`w:wrapTrailingSpaces` absent) lets the space at a
            // break hang. Counting it against the line makes justified text
            // visibly ragged compared with Word.
            let input = ParagraphLayoutInput(
                paragraphID: NodeID(1),
                segments: [StyledText(text: "aaaa bbbb cccc", style: .documentDefault)],
                widthAtLine: .constant(60),
                wrapsTrailingSpaces: false
            )
            let lines = LineBreaker(measurer: ctx.measurer).breakParagraph(input)
            try expectEqual(lines.count, 2, "ten clusters fit per line")
            try expectClose(lines[0].contentWidth, 54, tolerance: 0.001,
                            "the trailing space hangs rather than counting")
            try expectClose(lines[0].hangingTrailingWhitespace, 6, tolerance: 0.001,
                            "one space width is recorded as hanging")

            let wrapping = ParagraphLayoutInput(
                paragraphID: NodeID(1),
                segments: [StyledText(text: "aaaa bbbb cccc", style: .documentDefault)],
                widthAtLine: .constant(60),
                wrapsTrailingSpaces: true
            )
            let wrapped = LineBreaker(measurer: ctx.measurer).breakParagraph(wrapping)
            try expectClose(wrapped[0].contentWidth, 60, tolerance: 0.001,
                            "with w:wrapTrailingSpaces the space counts")
        },

        SelfTest(name: "manual-line-break-produces-two-lines", requiresFixedMetrics: true) { ctx in
            let document = SampleDocument.sized(widthPoints: 60, heightPoints: 400) { builder in
                builder.paragraphWithLineBreak("abc")
            }
            let snapshot = SelfTest.layout(document, measurer: ctx.measurer)
            try expectEqual(snapshot.pageCount, 1, "a line break does not start a page")
            try expectEqual(snapshot.pages[0].lines.count, 2,
                            "text plus a manual break leaves the paragraph mark on its own line")
        },

        SelfTest(name: "manual-page-break-starts-a-new-page") { ctx in
            let document = SampleDocument.sized(widthPoints: 60, heightPoints: 400) { builder in
                builder.paragraph("one")
                builder.pageBreak()
                builder.paragraph("two")
            }
            let snapshot = SelfTest.layout(document, measurer: ctx.measurer)
            try expectEqual(snapshot.pageCount, 2, "an explicit page break starts page 2")
            let text = snapshot.pages.map { page in
                page.lines.flatMap { $0.segments.map { $0.text } }.joined()
            }
            try expect(text[0].contains("one"), "page 1 holds the text before the break")
            try expect(text[1].contains("two"), "page 2 holds the text after the break")
        },

        SelfTest(name: "tab-stops-are-absolute", requiresFixedMetrics: true) { ctx in
            let input = ParagraphLayoutInput(
                paragraphID: NodeID(1),
                segments: [StyledText(text: "a\tb", style: .documentDefault)],
                widthAtLine: .constant(200),
                defaultTabStop: 36
            )
            let lines = LineBreaker(measurer: ctx.measurer).breakParagraph(input)
            try expectEqual(lines.count, 1, "the line is far from full")
            try expectEqual(lines[0].segments.count, 3, "text, tab, text")
            try expectClose(lines[0].segments[1].width, 30, tolerance: 0.001,
                            "the tab runs from x=6 to the 36 pt default stop")
            try expectClose(lines[0].segments[2].x, 36, tolerance: 0.001,
                            "the following text starts at the stop")
        },

        SelfTest(name: "justification-distributes-extra-space", requiresFixedMetrics: true) { ctx in
            let input = ParagraphLayoutInput(
                paragraphID: NodeID(1),
                segments: [StyledText(text: "aa bb cc dd ee ff", style: .documentDefault)],
                alignment: .justify,
                widthAtLine: .constant(60)
            )
            let lines = LineBreaker(measurer: ctx.measurer).breakParagraph(input)
            try expectEqual(lines.count, 2, "17 clusters at 6 pt over a 60 pt column")
            try expect(lines[0].justificationGapCount > 0, "the first line has gaps to stretch")
            try expect(lines[0].justificationExtraPerGap > 0, "and they are stretched")
            try expectEqual(lines[1].justificationExtraPerGap, 0,
                            "Word never justifies the last line of a paragraph")
        },

        // MARK: Pagination

        SelfTest(name: "widow-control-holds-a-line-back", requiresFixedMetrics: true) { ctx in
            // A 36 pt text area holds exactly three 12 pt lines.
            let withControl = SampleDocument.sized(widthPoints: 60, heightPoints: 36) { builder in
                builder.paragraph(SampleDocument.text(lines: 4), paragraphProperties: ParagraphProperties(
                    widowControl: true
                ))
            }
            let controlled = SelfTest.layout(withControl, measurer: ctx.measurer)
            try expectEqual(SelfTest.linesPerPage(controlled), [2, 2],
                            "widow control leaves two lines on each page, not three and one")

            let withoutControl = SampleDocument.sized(widthPoints: 60, heightPoints: 36) { builder in
                builder.paragraph(SampleDocument.text(lines: 4), paragraphProperties: ParagraphProperties(
                    widowControl: false
                ))
            }
            let uncontrolled = SelfTest.layout(withoutControl, measurer: ctx.measurer)
            try expectEqual(SelfTest.linesPerPage(uncontrolled), [3, 1],
                            "without widow control the paragraph splits three and one")
        },

        SelfTest(name: "keep-with-next-moves-the-heading", requiresFixedMetrics: true) { ctx in
            // Page holds three lines: A takes two, leaving room for the one-line
            // heading B but not for C's first line as well.
            func document(keepNext: Bool) -> DocumentModel {
                SampleDocument.sized(widthPoints: 60, heightPoints: 36) { builder in
                    builder.paragraph(SampleDocument.text(lines: 2))
                    builder.paragraph("Heading", paragraphProperties: ParagraphProperties(
                        keepWithNext: keepNext
                    ))
                    builder.paragraph(SampleDocument.text(lines: 2))
                }
            }
            let kept = SelfTest.layout(document(keepNext: true), measurer: ctx.measurer)
            try expectEqual(SelfTest.linesPerPage(kept), [2, 3],
                            "keepNext moves the heading down so it sits with its paragraph")

            let notKept = SelfTest.layout(document(keepNext: false), measurer: ctx.measurer)
            try expectEqual(SelfTest.linesPerPage(notKept), [3, 2],
                            "without keepNext the heading is orphaned at the foot of page 1")
        },

        SelfTest(name: "keep-lines-together-refuses-to-split", requiresFixedMetrics: true) { ctx in
            func document(keepLines: Bool) -> DocumentModel {
                SampleDocument.sized(widthPoints: 60, heightPoints: 36) { builder in
                    builder.paragraph(SampleDocument.text(lines: 2))
                    builder.paragraph(SampleDocument.text(lines: 2), paragraphProperties: ParagraphProperties(
                        keepLinesTogether: keepLines,
                        widowControl: false
                    ))
                }
            }
            let kept = SelfTest.layout(document(keepLines: true), measurer: ctx.measurer)
            try expectEqual(SelfTest.linesPerPage(kept), [2, 2],
                            "keepLines moves the whole paragraph to page 2")

            let split = SelfTest.layout(document(keepLines: false), measurer: ctx.measurer)
            try expectEqual(SelfTest.linesPerPage(split), [3, 1],
                            "without keepLines the paragraph splits across the page")
        },

        SelfTest(name: "page-break-before-starts-a-page") { ctx in
            let document = SampleDocument.sized(widthPoints: 60, heightPoints: 400) { builder in
                builder.paragraph("first")
                builder.paragraph("second", paragraphProperties: ParagraphProperties(pageBreakBefore: true))
            }
            let snapshot = SelfTest.layout(document, measurer: ctx.measurer)
            try expectEqual(snapshot.pageCount, 2, "w:pageBreakBefore starts page 2")
            try expectEqual(snapshot.pages[1].breakReason, .pageBreakBefore,
                            "the page records why it was forced")
        },

        SelfTest(name: "continuous-section-break-does-not-start-a-page", requiresFixedMetrics: true) { ctx in
            // The single most common cause of "our page count differs from
            // Word's": treating w:type="continuous" as a page break.
            let pageSize = PageSize(width: Twip(points: 204), height: Twip(points: 544))
            let margins = PageMargins(top: Twip(1440), right: Twip(1440), bottom: Twip(1440), left: Twip(1440))
            var builder = DocumentBuilder(styles: SampleDocument.flatStyles)
            builder.setSectionProperties(SectionProperties(pageSize: pageSize, margins: margins))
            builder.paragraph("one")
            builder.section(
                properties: SectionProperties(
                    pageSize: pageSize,
                    margins: margins,
                    columns: .equal(count: 2, spacing: Twip(240)),
                    start: .continuous
                ),
                start: .continuous
            )
            builder.paragraph("two")
            let secondProperties = SectionProperties(
                pageSize: pageSize,
                margins: margins,
                columns: .equal(count: 2, spacing: Twip(240)),
                start: .continuous
            )
            let snapshot = SelfTest.layout(builder.build(), measurer: ctx.measurer)
            try expectEqual(snapshot.pageCount, 1, "a continuous section break stays on the same page")
            // Known M0 gap: `PageLayout` carries one `sectionIndex`, so a page
            // holding content from two sections after a continuous break reports
            // the first one's columns. The column geometry itself is right, which
            // is what this asserts. Tracked in docs/07-OPEN-QUESTIONS.md.
            let frames = Paginator.columnFrames(for: secondProperties, textArea: secondProperties.textAreaRect)
            try expectEqual(frames.count, 2, "the second section resolves to two columns")
            try expectClose(frames[0].width, 24, tolerance: 0.001,
                            "60 pt of text area minus a 12 pt gap, split in two")
        },

        SelfTest(name: "section-restarts-page-numbering") { ctx in
            let pageSize = PageSize(width: Twip(points: 204), height: Twip(points: 544))
            let margins = PageMargins(top: Twip(1440), right: Twip(1440), bottom: Twip(1440), left: Twip(1440))
            var builder = DocumentBuilder(styles: SampleDocument.flatStyles)
            builder.setSectionProperties(SectionProperties(pageSize: pageSize, margins: margins))
            builder.paragraph("front matter")
            builder.section(
                properties: SectionProperties(
                    pageSize: pageSize,
                    margins: margins,
                    pageNumbering: PageNumbering(format: .lowerRoman, start: 3),
                    start: .nextPage
                ),
                start: .nextPage
            )
            builder.paragraph("body")
            let snapshot = SelfTest.layout(builder.build(), measurer: ctx.measurer)
            try expectEqual(snapshot.pageCount, 2, "two sections, each starting a page")
            try expectEqual(snapshot.pages[0].displayedPageNumber, 1, "section 1 counts from 1")
            try expectEqual(snapshot.pages[1].displayedPageNumber, 3, "w:pgNumType w:start restarts at 3")
            try expectEqual(snapshot.pages[1].pageWithinSection, 1, "and it is the first page of its section")
        },

        SelfTest(name: "multi-column-flow", requiresFixedMetrics: true) { ctx in
            let pageSize = PageSize(width: Twip(points: 204), height: Twip(points: 288))
            let margins = PageMargins(top: Twip(1440), right: Twip(1440), bottom: Twip(1440), left: Twip(1440))
            // Text area is 60 × 144 pt. Two columns with no gap are 30 pt wide,
            // so a 10-cluster line no longer fits: 5 clusters per line, 12 lines
            // per column, 24 lines per page.
            var properties = SectionProperties(pageSize: pageSize, margins: margins)
            properties.columns = .equal(count: 2, spacing: Twip(0))
            var builder = DocumentBuilder(styles: SampleDocument.flatStyles)
            builder.setSectionProperties(properties)
            builder.paragraph(SampleDocument.text(lines: 6))
            let snapshot = SelfTest.layout(builder.build(), measurer: ctx.measurer)
            let columns = Paginator.columnFrames(for: properties, textArea: properties.textAreaRect)
            try expectEqual(columns.count, 2, "two columns are resolved")
            try expectClose(columns[0].width, 30, tolerance: 0.001, "the text area is split evenly")
            try expectClose(columns[1].x, columns[0].maxX, tolerance: 0.001, "and they are adjacent")
            try expectEqual(snapshot.pageCount, 1, "six lines of five clusters fit in one column pair")
        },

        // MARK: Determinism

        SelfTest(name: "layout-is-deterministic") { ctx in
            let document = SampleDocument.make(widthPoints: ctx.width)
            let engine = LayoutEngine(measurer: ctx.measurer)
            let first = engine.layout(document: document, generation: 7)
            let second = engine.layout(document: document, generation: 7)
            try expectEqual(first, second, "the same document must lay out identically every time")
            try expectEqual(first.generation, 7, "the generation is echoed onto the snapshot")
            try expect(first.pageCount >= 2, "the fixture spans more than one page")
        },

        // MARK: Editing

        SelfTest(name: "typing-coalesces-and-undoes-as-one") { _ in
            var editor = EditorState.blank(authorName: "Tester")
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let paragraphID = editor.selection.focus.paragraphID

            for (index, character) in "Hello".enumerated() {
                editor.insertText(String(character), timestamp: start.addingTimeInterval(Double(index) * 0.05))
            }

            try expectEqual(editor.document.paragraph(withID: paragraphID)?.plainText(), "Hello",
                            "five keystrokes produce the typed text")
            try expectEqual(editor.document.paragraph(withID: paragraphID)?.runs.count, 1,
                            "typing merges into one run rather than fragmenting the file")
            try expectEqual(editor.undoStack.depth, 1,
                            "contiguous typing is a single undo step, as in Word")

            editor.undo(timestamp: start.addingTimeInterval(5))
            try expectEqual(editor.document.paragraph(withID: paragraphID)?.plainText(), "",
                            "one ⌘Z removes the whole word")
            try expect(editor.undoStack.canRedo, "and leaves something to redo")

            editor.redo(timestamp: start.addingTimeInterval(6))
            try expectEqual(editor.document.paragraph(withID: paragraphID)?.plainText(), "Hello",
                            "⌘⇧Z restores it")
        },

        SelfTest(name: "a-pause-breaks-coalescing") { _ in
            var editor = EditorState.blank(authorName: "Tester")
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            editor.insertText("Hi", timestamp: start)
            // Two seconds later is a different thought, so a different undo step.
            editor.insertText(" there", timestamp: start.addingTimeInterval(2))
            try expectEqual(editor.undoStack.depth, 2, "typing separated by a pause is two undo steps")
        },

        SelfTest(name: "return-splits-and-undo-joins") { _ in
            var editor = EditorState.blank(authorName: "Tester")
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            editor.insertText("abcdef", timestamp: start)
            editor.selection = TextRange(caret: TextPosition(
                paragraphID: editor.selection.focus.paragraphID,
                characterOffset: 3
            ))
            editor.insertParagraphBreak(timestamp: start.addingTimeInterval(1))

            let ids = editor.document.paragraphIDsInOrder
            try expectEqual(ids.count, 2, "Return creates a second paragraph")
            try expectEqual(editor.document.paragraph(withID: ids[0])?.plainText(), "abc", "text before the caret stays")
            try expectEqual(editor.document.paragraph(withID: ids[1])?.plainText(), "def", "text after it moves")
            try expectEqual(editor.selection.focus.paragraphID, ids[1], "the caret follows the split")
            try expectEqual(editor.selection.focus.characterOffset, 0, "and lands at the start")

            editor.undo(timestamp: start.addingTimeInterval(2))
            try expectEqual(editor.document.paragraphIDsInOrder.count, 1, "⌘Z joins them again")
            try expectEqual(
                editor.document.paragraph(withID: ids[0])?.plainText(), "abcdef",
                "with the text intact and in order"
            )
        },

        SelfTest(name: "backspace-at-offset-zero-joins-paragraphs") { _ in
            var builder = DocumentBuilder(styles: SampleDocument.flatStyles)
            let first = builder.paragraph("one")
            let second = builder.paragraph("two")
            var editor = EditorState(document: builder.build(), authorName: "Tester")
            editor.selection = TextRange(caret: TextPosition(paragraphID: second, characterOffset: 0))

            editor.deleteBackward(timestamp: Date(timeIntervalSince1970: 1_700_000_000))
            try expectEqual(editor.document.paragraphIDsInOrder.count, 1, "the two paragraphs became one")
            try expectEqual(editor.document.paragraph(withID: first)?.plainText(), "onetwo", "in the right order")
            try expectEqual(editor.selection.focus.paragraphID, first, "the caret moves to the join")
            try expectEqual(editor.selection.focus.characterOffset, 3, "at the boundary")
        },

        SelfTest(name: "deleting-across-paragraphs-merges-them") { _ in
            var builder = DocumentBuilder(styles: SampleDocument.flatStyles)
            let first = builder.paragraph("aaa")
            _ = builder.paragraph("bbb")
            let third = builder.paragraph("ccc")
            var editor = EditorState(document: builder.build(), authorName: "Tester")
            editor.selection = TextRange(
                anchor: TextPosition(paragraphID: first, characterOffset: 1),
                focus: TextPosition(paragraphID: third, characterOffset: 2)
            )

            editor.deleteBackward(timestamp: Date(timeIntervalSince1970: 1_700_000_000))
            try expectEqual(editor.document.paragraphIDsInOrder.count, 1,
                            "the middle paragraph and the tail are gone")
            try expectEqual(editor.document.paragraph(withID: first)?.plainText(), "ac",
                            "the surviving edges of the boundary paragraphs are joined")
        },

        SelfTest(name: "replacing-a-selection-is-one-undo-step") { _ in
            var builder = DocumentBuilder(styles: SampleDocument.flatStyles)
            let id = builder.paragraph("Hello world")
            var editor = EditorState(document: builder.build(), authorName: "Tester")
            editor.selection = TextRange(
                anchor: TextPosition(paragraphID: id, characterOffset: 6),
                focus: TextPosition(paragraphID: id, characterOffset: 11)
            )
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            editor.insertText("there", timestamp: start)
            try expectEqual(editor.document.paragraph(withID: id)?.plainText(), "Hello there",
                            "typing replaces the selection")
            try expectEqual(editor.undoStack.depth, 1, "and it is one action, not a delete plus an insert")
            editor.undo(timestamp: start.addingTimeInterval(1))
            try expectEqual(editor.document.paragraph(withID: id)?.plainText(), "Hello world",
                            "one ⌘Z brings the deleted text back")
        },

        SelfTest(name: "bold-toggle-follows-word-rules") { _ in
            var builder = DocumentBuilder(styles: SampleDocument.flatStyles)
            let id = builder.paragraph("Hello world")
            var editor = EditorState(document: builder.build(), authorName: "Tester")
            let start = Date(timeIntervalSince1970: 1_700_000_000)

            editor.selection = TextRange(
                anchor: TextPosition(paragraphID: id, characterOffset: 0),
                focus: TextPosition(paragraphID: id, characterOffset: 5)
            )
            editor.toggleBold(timestamp: start)
            let paragraph = editor.document.paragraph(withID: id)
            // Two, not three: the selection starts at offset 0, so there is no
            // "before" piece — only the bold run and the untouched remainder.
            try expectEqual(paragraph?.runs.count, 2, "the selection splits off as its own bold run")
            try expectEqual(paragraph?.runs[0].properties.bold, true, "the selection became bold")
            try expectEqual(paragraph?.plainText(), "Hello world", "and the text is unchanged")

            editor.undo(timestamp: start.addingTimeInterval(1))
            try expectEqual(editor.document.paragraph(withID: id)?.runs.count, 1,
                            "undo restores the single original run exactly")

            // Mixed selection: part bold, part not. Word makes it all bold.
            editor.selection = TextRange(
                anchor: TextPosition(paragraphID: id, characterOffset: 0),
                focus: TextPosition(paragraphID: id, characterOffset: 5)
            )
            editor.toggleBold(timestamp: start.addingTimeInterval(2))
            editor.selection = TextRange(
                anchor: TextPosition(paragraphID: id, characterOffset: 0),
                focus: TextPosition(paragraphID: id, characterOffset: 11)
            )
            try expect(!editor.selectionIsUniformlyBold(), "a partly bold selection is not uniformly bold")
            editor.toggleBold(timestamp: start.addingTimeInterval(3))
            try expect(editor.selectionIsUniformlyBold(), "so toggling makes the whole thing bold")
        },

        SelfTest(name: "tracked-changes-are-individually-reviewable") { _ in
            var builder = DocumentBuilder(styles: SampleDocument.flatStyles)
            let id = builder.paragraph("Original")
            var editor = EditorState(document: builder.build(), authorName: "Reviewer")
            editor.trackChanges = true
            editor.selection = TextRange(
                anchor: TextPosition(paragraphID: id, characterOffset: 0),
                focus: TextPosition(paragraphID: id, characterOffset: 8)
            )
            let when = Date(timeIntervalSince1970: 1_700_000_000)
            let mutation = AssistantMutationBuilder.replaceText(
                in: id,
                characterRange: 0..<8,
                originalText: "Original",
                with: "Replacement",
                author: .assistant(provider: "Ollama"),
                revisionID: 1,
                date: when
            )
            editor.apply(mutation, name: "Assistant rewrite", timestamp: when)

            let paragraph = editor.document.paragraph(withID: id)
            let marks = (paragraph?.runs ?? []).compactMap { $0.revision }
            try expect(!marks.isEmpty, "the assistant's edit is recorded as tracked changes")
            try expect(
                marks.allSatisfy { $0.author == "Assistant (Ollama)" },
                "every mark names the provider, so the user can see where the text went"
            )
            try expect(
                (paragraph?.runs ?? []).contains { $0.revision?.kind == .deletion },
                "the original is marked deleted rather than silently replaced"
            )
            try expect(
                (paragraph?.runs ?? []).contains { $0.revision?.kind == .insertion },
                "and the replacement is marked inserted"
            )
            try expectEqual(
                paragraph?.plainText(markup: .noMarkup), "Replacement",
                "No Markup shows the final text"
            )
        },

        // MARK: AI plumbing

        SelfTest(name: "revision-author-names-the-provider") { _ in
            try expectEqual(MutationAuthor.assistant(provider: "Ollama").revisionAuthor, "Assistant (Ollama)",
                            "the author string names the provider")
            try expectEqual(MutationAuthor.writingTools.revisionAuthor, "Writing Tools",
                            "Apple's Writing Tools is attributed separately from our assistant")
            try expectEqual(MutationAuthor.user(name: "Ada").revisionAuthor, "Ada",
                            "a human edit is attributed to the human")
        },

        SelfTest(name: "on-device-providers-need-no-redaction") { _ in
            for provider in ProviderCatalogue.builtIn {
                let policy: RedactionPolicy = provider.runsOnDevice ? .none : .strict
                if provider.runsOnDevice {
                    try expect(!policy.redactsAnything,
                               "\(provider.id) runs on this Mac, so nothing needs redacting")
                } else if provider.id != "ollama" {
                    try expect(policy.redactsAnything,
                               "\(provider.id) sends text off this Mac, so redaction applies by default")
                }
            }
            try expect(ProviderCatalogue.onDevice.contains { $0.id == "apple-intelligence" },
                       "Apple Intelligence is offered as an on-device provider")
        },

        SelfTest(name: "unconfigured-provider-reports-missing-credentials") { _ in
            try expect(ProviderCatalogue.provider(id: "anthropic") != nil,
                       "a configured provider is reachable by id")
            // Concrete type, not `any AIProvider`: the endpoint is a property of
            // this provider, and the settings UI shows it verbatim so the user
            // can see exactly where their text would go.
            let provider = OpenAICompatibleProvider(
                id: "anthropic",
                displayName: "Anthropic",
                baseURL: URL(string: "https://api.anthropic.com/v1")!,
                model: "claude-sonnet-4-5"
            )
            try expectEqual(provider.availability(), .missingCredentials,
                            "a provider with no key says so rather than failing at request time")
            try expect(!provider.runsOnDevice, "a hosted API is not on-device")
            try expect(
                provider.completionEndpoint.absoluteString.contains("api.anthropic.com"),
                "the settings UI shows the exact destination URL"
            )
            let configured = OpenAICompatibleProvider(
                id: "anthropic",
                displayName: "Anthropic",
                baseURL: URL(string: "https://api.anthropic.com/v1")!,
                model: "claude-sonnet-4-5",
                apiKey: "sk-test"
            )
            try expectEqual(configured.availability(), .available, "and reports ready once a key is present")
        },

        SelfTest(name: "writing-tools-mapping-is-honest") { _ in
            // Tasks with no trained Apple adapter must route to the configured
            // provider. Claiming an equivalent that does not exist produces a
            // plausible-looking wrong answer.
            try expectEqual(AITask.proofread.writingToolsEquivalent, "proofread", "Apple has a proofreading adapter")
            try expectEqual(AITask.summarise.writingToolsEquivalent, "summarize", "Apple has a summary adapter")
            try expectEqual(AITask.expand.writingToolsEquivalent, nil, "Apple has no expand adapter")
            try expectEqual(AITask.translate.writingToolsEquivalent, nil, "Apple has no translate adapter")
            try expect(AITask.question.mutatesDocument == false, "a question is answered in a panel, not in the file")
            try expect(AITask.compose.mutatesDocument, "composed text lands in the document")
        },

        // MARK: Fonts and legal

        SelfTest(name: "no-microsoft-font-is-bundled") { _ in
            for family in FontSubstitution.bundled {
                try expect(FontSubstitution.mayBundle(family: family),
                           "\(family) is in the bundled list but is not redistributable")
                try expect(!FontSubstitution.neverBundle.contains(family),
                           "\(family) is on both the bundled and the forbidden list")
            }
            for family in FontSubstitution.neverBundle {
                try expect(!FontSubstitution.mayBundle(family: family),
                           "\(family) must never be shipped")
            }
            try expectEqual(FontSubstitution.metricCompatible["Calibri"], "Carlito",
                            "Calibri falls back to metric-compatible Carlito")
            try expectEqual(FontSubstitution.metricCompatible["Cambria"], "Caladea",
                            "Cambria falls back to metric-compatible Caladea")
        },

        // MARK: Page numbering

        SelfTest(name: "page-number-formats-match-word") { _ in
            try expectEqual(PageNumbering(format: .decimal).format(pageNumber: 42), "42", "decimal")
            try expectEqual(PageNumbering(format: .lowerRoman).format(pageNumber: 4), "iv", "lower roman")
            try expectEqual(PageNumbering(format: .upperRoman).format(pageNumber: 1994), "MCMXCIV", "upper roman")
            try expectEqual(PageNumbering(format: .lowerLetter).format(pageNumber: 26), "z", "letter 26 is z")
            try expectEqual(PageNumbering(format: .lowerLetter).format(pageNumber: 27), "aa",
                            "Word's letter numbering is bijective base-26, so 27 is aa, not ba")
            try expectEqual(PageNumbering(format: .upperLetter).format(pageNumber: 28), "AB", "28 is AB")
            try expectEqual(PageNumbering(format: .none).format(pageNumber: 7), "", "w:fmt=none prints nothing")
        },

        // MARK: Headers and footers

        SelfTest(name: "first-page-header-is-selected") { _ in
            // GenOffice #1685: removing a default header stripped the first-page
            // one too, because the kinds were conflated. They are distinct keys.
            var properties = SectionProperties()
            properties.differentFirstPage = true
            let section = Section(
                id: NodeID(1),
                properties: properties,
                headersAndFooters: [
                    .headerDefault: HeaderFooter(
                        kind: .headerDefault, relationshipID: "rId1",
                        blocks: [.paragraph(.plain(id: NodeID(10), text: "Default"))]
                    ),
                    .headerFirst: HeaderFooter(
                        kind: .headerFirst, relationshipID: "rId2",
                        blocks: [.paragraph(.plain(id: NodeID(11), text: "First"))]
                    ),
                ]
            )
            try expectEqual(
                section.headerFooter(isHeader: true, isFirstPageOfSection: true, isEvenPage: false)?.plainText(),
                "First", "the first page of the section uses its own header"
            )
            try expectEqual(
                section.headerFooter(isHeader: true, isFirstPageOfSection: false, isEvenPage: false)?.plainText(),
                "Default", "and later pages use the default"
            )
            try expectEqual(HeaderFooterKind.headerDefault.typeValue, HeaderFooterKind.footerDefault.typeValue,
                            "headers and footers share the same w:type strings, which is why the kind is not a raw String")
        },
    ]
}
