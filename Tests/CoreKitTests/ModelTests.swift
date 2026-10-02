import XCTest
import CoreKit

/// Model-layer tests.
///
/// These cover the invariants that are expensive to discover later: the style
/// cascade order, the difference between "inherit" and "explicitly off", the
/// exactness of mutation inverses, and the identifiers Word reserves for itself.
final class ModelTests: XCTestCase {

    // MARK: Node ids

    func testNodeIDStateNeverReissuesAnID() {
        var state = NodeIDState()
        var seen = Set<NodeID>()
        for _ in 0..<1000 {
            let id = state.makeID()
            XCTAssertFalse(seen.contains(id), "node ids must be unique")
            seen.insert(id)
        }
        XCTAssertEqual(state.highWaterMark, 1000)
    }

    func testReserveRaisesTheFloorAboveRestoredIDs() {
        var state = NodeIDState()
        state.reserve(upTo: 500)
        XCTAssertEqual(state.makeID(), NodeID(501))
        // Reserving below the floor must not rewind it.
        state.reserve(upTo: 10)
        XCTAssertEqual(state.makeID(), NodeID(502))
    }

    func testBuilderProducesUniqueIDsAcrossTheWholeTree() {
        var builder = DocumentBuilder()
        builder.heading("Title", level: 1)
        for index in 0..<20 {
            builder.paragraph("Paragraph \(index) with some text in it.")
        }
        let document = builder.build()

        var ids: [NodeID] = []
        for section in document.sections {
            ids.append(section.id)
            for block in section.blocks {
                ids.append(block.id)
                guard let paragraph = block.paragraph else { continue }
                ids.append(paragraph.id)
                ids.append(contentsOf: paragraph.runIDs)
            }
        }
        XCTAssertEqual(Set(ids).count, ids.count, "a duplicate node id corrupts every edit that targets one")
        XCTAssertGreaterThan(ids.count, 40)
    }

    // MARK: Style cascade

    func testStyleChainResolvesBaseFirst() {
        let table = StyleTable.wordDefaults
        XCTAssertEqual(
            table.resolveChain(styleID: "Heading3").map { $0.styleID },
            ["Normal", "Heading1", "Heading2", "Heading3"]
        )
    }

    func testBasedOnCycleTerminates() {
        // A malformed file can contain A basedOn B basedOn A. Word tolerates it,
        // so a hang on open would be strictly worse than slightly wrong formatting.
        var table = StyleTable.wordDefaults
        table.insert(Style(styleID: "Loop1", kind: .paragraph, name: "Loop 1", basedOn: "Loop2"))
        table.insert(Style(styleID: "Loop2", kind: .paragraph, name: "Loop 2", basedOn: "Loop1"))
        XCTAssertEqual(table.resolveChain(styleID: "Loop1").count, 2)
    }

    func testHeadingOneCarriesWordFormatting() {
        let table = StyleTable.wordDefaults
        var runProperties = table.defaultRunProperties
        var paragraphProperties = table.defaultParagraphProperties
        for style in table.resolveChain(styleID: "Heading1") {
            paragraphProperties = paragraphProperties.merging(style.paragraphProperties)
            runProperties = runProperties.merging(style.runProperties)
        }
        XCTAssertEqual(paragraphProperties.keepWithNext, true, "w:keepNext stops a heading ending a page")
        XCTAssertEqual(paragraphProperties.keepLinesTogether, true)
        XCTAssertEqual(runProperties.size, HalfPoint(32), "Heading 1 is 16 pt")
        XCTAssertEqual(runProperties.fonts?.primaryFamily, "Calibri Light")
        XCTAssertEqual(paragraphProperties.outlineLevel, .level1)
    }

    func testExplicitOffIsNotTheSameAsInheritance() {
        // `nil` means inherit, `false` means explicitly off. Conflating the two
        // is how bold disappears when a file is round-tripped.
        let inherited = RunProperties(bold: true, italic: true)
        let merged = inherited.merging(RunProperties(bold: false))
        XCTAssertEqual(merged.bold, false, "an explicit false overrides an inherited true")
        XCTAssertEqual(merged.italic, true, "an absent property inherits")
    }

    func testTabClearRemovesTheInheritedStop() {
        let inherited = ParagraphProperties(tabs: [
            TabStop(position: Twip(720)),
            TabStop(position: Twip(1440), alignment: .center),
        ])
        let direct = ParagraphProperties(tabs: [TabStop(position: Twip(720), alignment: .clear)])
        let merged = inherited.merging(direct)
        let positions = (merged.tabs ?? []).map { $0.position }
        XCTAssertFalse(positions.contains(Twip(720)), "w:tab w:val=clear removes the inherited stop")
        XCTAssertTrue(positions.contains(Twip(1440)), "stops that were not cleared survive")
    }

    func testNumberingCancellationIsDistinctFromAbsence() {
        // `w:numId w:val="0"` cancels inherited numbering. Treating 0 as "unset"
        // puts bullets on every paragraph under List Paragraph.
        let inherited = ParagraphProperties(numbering: NumberingReference(numberID: 3, level: 0))
        let cancelled = inherited.merging(ParagraphProperties(numbering: NumberingReference(numberID: 0, level: 0)))
        XCTAssertEqual(cancelled.numbering?.numberID, 0)
        XCTAssertFalse(cancelled.numbering?.isNumbered ?? true, "numId 0 means no numbering")
    }

    func testOutlineLevelNineIsBodyText() {
        XCTAssertEqual(OutlineLevel.bodyText.rawValue, 9)
        XCTAssertNotEqual(OutlineLevel.bodyText, .level1)
        XCTAssertTrue(ParagraphProperties().isEmpty)
    }

    // MARK: Page numbering

    func testPageNumberFormatsMatchWord() {
        XCTAssertEqual(PageNumbering(format: .decimal).format(pageNumber: 42), "42")
        XCTAssertEqual(PageNumbering(format: .lowerRoman).format(pageNumber: 4), "iv")
        XCTAssertEqual(PageNumbering(format: .upperRoman).format(pageNumber: 1994), "MCMXCIV")
        XCTAssertEqual(PageNumbering(format: .lowerLetter).format(pageNumber: 26), "z")
        // Bijective base-26: there is no zero, so 27 is "aa" rather than "ba".
        XCTAssertEqual(PageNumbering(format: .lowerLetter).format(pageNumber: 27), "aa")
        XCTAssertEqual(PageNumbering(format: .upperLetter).format(pageNumber: 28), "AB")
        XCTAssertEqual(PageNumbering(format: .none).format(pageNumber: 7), "")
        XCTAssertEqual(PageNumbering(format: .lowerRoman).format(pageNumber: 0), "", "Word prints nothing for 0")
    }

    // MARK: Notes

    func testWordReservedNoteIDsAreNotUserContent() {
        let separator = Note.separator(id: NodeID(1))
        let continuation = Note.continuationSeparator(id: NodeID(2))
        let user = Note(footnoteIndex: 1, id: NodeID(3), blocks: [.paragraph(.plain(id: NodeID(4), text: "note"))])

        XCTAssertTrue(separator.isSeparator)
        XCTAssertTrue(continuation.isSeparator, "id 0 is the continuation separator, not the first footnote")
        XCTAssertFalse(user.isSeparator)

        let collection = NoteCollection(notes: [separator, continuation, user])
        XCTAssertEqual(collection.userNotes.count, 1, "separators must never reach the notes pane or word count")
    }

    // MARK: Paragraph editing

    func testInsertingMatchingTextMergesIntoOneRun() {
        var paragraph = Paragraph.plain(id: NodeID(1), text: "Hello")
        var pool = [NodeID(10), NodeID(11), NodeID(12)]
        for character in " world" {
            paragraph.insert(
                text: String(character),
                atCharacterOffset: paragraph.characterCount,
                properties: .empty,
                idPool: &pool
            )
        }
        XCTAssertEqual(paragraph.plainText(), "Hello world")
        XCTAssertEqual(paragraph.runs.count, 1, "typing must not fragment the file into one run per keystroke")
    }

    func testInsertingDifferentlyFormattedTextSplitsTheRun() {
        var paragraph = Paragraph.plain(id: NodeID(1), text: "abcdef")
        var pool = [NodeID(10), NodeID(11), NodeID(12)]
        paragraph.insert(
            text: "XY",
            atCharacterOffset: 3,
            properties: RunProperties(bold: true),
            idPool: &pool
        )
        XCTAssertEqual(paragraph.plainText(), "abcXYdef")
        XCTAssertEqual(paragraph.runs.count, 3)
        XCTAssertEqual(paragraph.runs[1].properties.bold, true)
        XCTAssertEqual(paragraph.runs[0].properties.bold, nil)
        XCTAssertEqual(Set(paragraph.runIDs).count, 3, "each split piece needs its own id")
    }

    func testDeletingAcrossRunsKeepsTheSurvivingFormatting() {
        var paragraph = Paragraph(
            id: NodeID(1),
            runs: [
                Run(id: NodeID(2), content: .text("bold"), properties: RunProperties(bold: true)),
                Run(id: NodeID(3), content: .text("plain"), properties: .empty),
            ]
        )
        let removed = paragraph.deleteText(atCharacterOffset: 2, length: 4)
        XCTAssertEqual(removed, "ldpl")
        XCTAssertEqual(paragraph.plainText(), "boain")
        XCTAssertEqual(paragraph.runs.count, 2)
        XCTAssertEqual(paragraph.runs[0].properties.bold, true, "the surviving bold text stays bold")
    }

    func testMarkingDeletedKeepsTheTextInTheFile() {
        var paragraph = Paragraph.plain(id: NodeID(1), text: "Hello world")
        var pool = [NodeID(50), NodeID(51), NodeID(52)]
        let mark = RevisionMark(
            id: 7, author: "Assistant (Ollama)",
            date: Date(timeIntervalSince1970: 0), kind: .deletion
        )
        XCTAssertTrue(paragraph.markDeleted(atCharacterOffset: 0, length: 5, revision: mark, idPool: &pool))
        // The characters stay: that is what makes the change rejectable.
        XCTAssertEqual(paragraph.plainText(markup: .allMarkup), "Hello world")
        XCTAssertEqual(paragraph.plainText(markup: .noMarkup), " world")
        XCTAssertEqual(paragraph.runs.first?.revision?.author, "Assistant (Ollama)")
        XCTAssertEqual(paragraph.runs.first?.revision?.kind, .deletion)
    }

    func testSplittingMovesTheParagraphMarkFormattingToTheNewParagraph() {
        var paragraph = Paragraph(
            id: NodeID(1),
            properties: ParagraphProperties(
                styleID: "Normal",
                paragraphMarkRunProperties: RunProperties(bold: true)
            ),
            runs: [Run(id: NodeID(2), content: .text("abcdef"), properties: RunProperties(italic: true))]
        )
        var pool = [NodeID(20), NodeID(21)]
        let tail = paragraph.split(
            atCharacterOffset: 3,
            newID: NodeID(10),
            newProperties: ParagraphProperties(styleID: "Normal"),
            idPool: &pool
        )
        XCTAssertEqual(paragraph.plainText(), "abc")
        XCTAssertEqual(tail?.plainText(), "def")
        XCTAssertEqual(tail?.properties.paragraphMarkRunProperties?.bold, true,
                       "the paragraph mark travels with the caret")
        XCTAssertEqual(tail?.runs.first?.properties.italic, true, "the split tail keeps its formatting")
        XCTAssertNotEqual(paragraph.runs.first?.id, tail?.runs.first?.id,
                          "the two halves of a split run must not share an id")
    }

    // MARK: Mutations and inverses

    func testEveryMutationInverseRestoresTheText() {
        var builder = DocumentBuilder()
        builder.heading("Title", level: 1)
        builder.paragraph("The quick brown fox jumps over the lazy dog.")
        builder.paragraph("Second paragraph with more text.")
        let original = builder.build()
        let originalText = original.paragraphs.map { $0.plainText() }

        let cases: [[MutationOp]] = [
            [.insertText(paragraph: original.paragraphIDsInOrder[1], characterOffset: 4,
                         text: "INSERTED", properties: .empty, revision: nil)],
            [.deleteText(paragraph: original.paragraphIDsInOrder[1], characterOffset: 0, length: 10)],
            [.replaceParagraph({
                var p = original.paragraphs[2]
                p.properties.alignment = .center
                return p
            }())],
            [.splitParagraph(paragraph: original.paragraphIDsInOrder[1], characterOffset: 9,
                             newParagraphProperties: .empty, newParagraphID: NodeID(9999))],
            [.removeBlocks(ids: [original.paragraphIDsInOrder[2]])],
        ]

        for (index, operations) in cases.enumerated() {
            var document = original
            let mutation = DocumentMutation(operations: operations, author: .user(name: "Test"))
            let inverse = mutation.applied(to: &document)
            XCTAssertFalse(inverse.isEmpty, "case \(index) produced no inverse")
            inverse.applied(to: &document)
            XCTAssertEqual(
                document.paragraphs.map { $0.plainText() },
                originalText,
                "case \(index): undo did not restore the original text"
            )
        }
    }

    func testOperationsTargetingMissingNodesAreSkippedNotFatal() {
        // An AI proposal can name a node a concurrent edit removed. A trap there
        // loses the document; skipping the operation does not.
        var document = DocumentModel.blank()
        let mutation = DocumentMutation(operations: [
            .deleteText(paragraph: NodeID(424242), characterOffset: 0, length: 5),
            .replaceParagraph(Paragraph(id: NodeID(424243), runs: [Run(id: NodeID(1), content: .text("x"))])),
            .removeBlocks(ids: [NodeID(424244)]),
            .insertBlocks(sectionIndex: 99, blockIndex: 0, blocks: []),
        ])
        let inverse = mutation.applied(to: &document)
        XCTAssertTrue(inverse.isEmpty, "nothing was applied, so there is nothing to undo")
        XCTAssertEqual(document.paragraphs.count, 1, "the document is unchanged")
    }

    func testAnnotateCarriesNoDocumentEffect() {
        var document = DocumentModel.blank()
        let before = document.sections
        let mutation = DocumentMutation(
            operations: [.annotate(rationale: "Made it shorter.")],
            author: .assistant(provider: "Test")
        )
        let inverse = mutation.applied(to: &document)
        XCTAssertEqual(document.sections, before)
        XCTAssertTrue(inverse.isEmpty, "undoing a change must not re-narrate it")
    }

    func testRemoveBlocksInverseRestoresPosition() {
        var builder = DocumentBuilder()
        let a = builder.paragraph("A")
        let b = builder.paragraph("B")
        let c = builder.paragraph("C")
        var document = builder.build()
        let before = document.paragraphIDsInOrder

        let mutation = DocumentMutation(operations: [.removeBlocks(ids: [b])])
        let inverse = mutation.applied(to: &document)
        XCTAssertEqual(document.paragraphIDsInOrder, [a, c])

        inverse.applied(to: &document)
        XCTAssertEqual(document.paragraphIDsInOrder, before, "the removed block returns to its original position")
        XCTAssertEqual(document.paragraph(withID: b)?.plainText(), "B")
    }

    // MARK: Sections, headers and footers

    func testFirstPageHeaderIsSelectedSeparatelyFromTheDefault() {
        var properties = SectionProperties()
        properties.differentFirstPage = true
        let section = Section(
            id: NodeID(1),
            properties: properties,
            headersAndFooters: [
                .headerDefault: HeaderFooter(kind: .headerDefault, relationshipID: "rId1",
                                             blocks: [.paragraph(.plain(id: NodeID(10), text: "Default"))]),
                .headerFirst: HeaderFooter(kind: .headerFirst, relationshipID: "rId2",
                                           blocks: [.paragraph(.plain(id: NodeID(11), text: "First"))]),
            ]
        )
        XCTAssertEqual(section.headerFooter(isHeader: true, isFirstPageOfSection: true, isEvenPage: false)?.plainText(), "First")
        XCTAssertEqual(section.headerFooter(isHeader: true, isFirstPageOfSection: false, isEvenPage: false)?.plainText(), "Default")
        XCTAssertEqual(section.headerFooter(isHeader: false, isFirstPageOfSection: true, isEvenPage: false), nil,
                       "an absent footer kind is absent, not the header's")
    }

    func testHeadersAndFootersShareTypeStringsSoTheKindIsNotARawString() {
        // `w:type` is "default" for both a header and a footer. Two enum cases
        // cannot share one String raw value, which is why HeaderFooterKind has a
        // computed `typeValue` instead.
        XCTAssertEqual(HeaderFooterKind.headerDefault.typeValue, "default")
        XCTAssertEqual(HeaderFooterKind.footerDefault.typeValue, "default")
        XCTAssertEqual(HeaderFooterKind.headerFirst.typeValue, "first")
        XCTAssertTrue(HeaderFooterKind.headerEven.isHeader)
        XCTAssertFalse(HeaderFooterKind.footerEven.isHeader)
        XCTAssertEqual(HeaderFooterKind.allCases.count, 6)
    }

    func testSectionGeometryMatchesWordDefaults() {
        let properties = SectionProperties(pageSize: .letter, margins: .normal)
        XCTAssertEqual(properties.textAreaWidthPoints, 468, accuracy: 0.001, "8.5in minus two 1in margins")
        XCTAssertEqual(properties.textAreaHeightPoints, 648, accuracy: 0.001, "11in minus two 1in margins")
        XCTAssertEqual(properties.textAreaRect.x, 72, accuracy: 0.001)
        XCTAssertEqual(properties.textAreaRect.y, 72, accuracy: 0.001)
    }

    func testMirroredMarginsSwapForVerso() {
        let margins = PageMargins(top: Twip(1440), right: Twip(720), bottom: Twip(1440), left: Twip(1800))
        let mirrored = margins.mirrored(isRecto: false)
        XCTAssertEqual(mirrored.left, Twip(720), "inside and outside swap on a verso page")
        XCTAssertEqual(mirrored.right, Twip(1800))
        let recto = margins.mirrored(isRecto: true)
        XCTAssertEqual(recto.left, margins.left, "a recto page keeps its own margins")
    }

    // MARK: Units

    func testUnitConversionsAreExact() {
        XCTAssertEqual(Twip(1440).points, 72, accuracy: 0.0001)
        XCTAssertEqual(Twip(points: 72).rawValue, 1440)
        XCTAssertEqual(HalfPoint(22).points, 11, accuracy: 0.0001)
        XCTAssertEqual(EMU(points: 1).rawValue, 12700)
        XCTAssertEqual(EMU.perInch, 914_400)
        XCTAssertEqual(EMU.perPoint, 12_700)
        XCTAssertEqual(EighthOfAPoint(8).points, 1, accuracy: 0.0001)
        // Rounding, not truncation: 0.1 pt must not become 1 EMU short.
        XCTAssertEqual(EMU(points: 0.1).rawValue, 1270)
    }

    func testColumnWidthsResolveAgainstTheTextArea() {
        let columns = ColumnSet.equal(count: 3, spacing: Twip(240))
        let widths = columns.resolveWidths(availableWidth: 300)
        XCTAssertEqual(widths.count, 3)
        // Two 12 pt gaps come out first, then the remainder is split three ways.
        for width in widths {
            XCTAssertEqual(width, (300 - 24) / 3, accuracy: 0.001)
        }
        XCTAssertEqual(ColumnSet.single.resolveWidths(availableWidth: 468), [468])
    }

    // MARK: Font script selection

    func testFontSlotIsChosenByCharacterScript() {
        let reference = FontReference(
            ascii: "Calibri",
            hAnsi: "Calibri",
            eastAsia: "MS Gothic",
            complexScript: "Arial Unicode MS"
        )
        guard let latin = Unicode.Scalar("A"), let cjk = Unicode.Scalar(0x4E2D), let arabic = Unicode.Scalar(0x0627) else {
            return XCTFail("test scalars must be valid")
        }
        XCTAssertEqual(reference.family(for: latin), "Calibri")
        XCTAssertEqual(reference.family(for: cjk), "MS Gothic", "CJK text uses the eastAsia slot")
        XCTAssertEqual(reference.family(for: arabic), "Arial Unicode MS", "complex script uses the cs slot")
    }

    func testFontSubstitutionPolicyIsRedistributable() {
        for family in FontSubstitution.bundled {
            XCTAssertTrue(FontSubstitution.mayBundle(family: family), "\(family) must be redistributable")
            XCTAssertFalse(FontSubstitution.neverBundle.contains(family), "\(family) is on both lists")
        }
        for family in FontSubstitution.neverBundle {
            XCTAssertFalse(FontSubstitution.mayBundle(family: family), "\(family) must never ship with the app")
        }
        XCTAssertEqual(FontSubstitution.metricCompatible["Calibri"], "Carlito")
        XCTAssertEqual(FontSubstitution.metricCompatible["Cambria"], "Caladea")
        XCTAssertEqual(FontSubstitution.metricCompatible["Times New Roman"], "Liberation Serif")
    }
}
