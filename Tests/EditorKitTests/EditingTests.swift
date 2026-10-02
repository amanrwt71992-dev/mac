import XCTest
import CoreKit
import EditorKit
import IntelligenceKit

/// Editing tests.
///
/// The properties that matter here are the ones a user notices immediately and
/// that are easy to get subtly wrong: one ⌘Z per user-visible action, undo that
/// restores formatting rather than just characters, and assistant edits that
/// arrive as reviewable tracked changes.
final class EditingTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func editor(with paragraphs: [String]) -> (EditorState, [NodeID]) {
        var builder = DocumentBuilder(styles: StyleTable(
            defaultRunProperties: .empty,
            defaultParagraphProperties: ParagraphProperties(spacingAfter: Twip(0), lineSpacing: .single),
            styles: [:],
            declarationOrder: []
        ))
        var ids: [NodeID] = []
        for text in paragraphs {
            ids.append(builder.paragraph(text))
        }
        let state = EditorState(document: builder.build(), authorName: "Tester")
        return (state, ids)
    }

    private func caret(_ id: NodeID, _ offset: Int) -> TextRange {
        TextRange(caret: TextPosition(paragraphID: id, characterOffset: offset))
    }

    private func span(_ from: (NodeID, Int), _ to: (NodeID, Int)) -> TextRange {
        TextRange(
            anchor: TextPosition(paragraphID: from.0, characterOffset: from.1),
            focus: TextPosition(paragraphID: to.0, characterOffset: to.1)
        )
    }

    // MARK: Typing

    func testContiguousTypingIsOneUndoStepAndOneRun() {
        var state = EditorState.blank(authorName: "Tester")
        let id = state.selection.focus.paragraphID

        for (index, character) in "Hello".enumerated() {
            state.insertText(String(character), timestamp: start.addingTimeInterval(Double(index) * 0.05))
        }

        XCTAssertEqual(state.document.paragraph(withID: id)?.plainText(), "Hello")
        XCTAssertEqual(state.document.paragraph(withID: id)?.runs.count, 1,
                       "typing must not fragment the file into one run per keystroke")
        XCTAssertEqual(state.undoStack.depth, 1, "five keystrokes of one word are one ⌘Z")

        state.undo(timestamp: start.addingTimeInterval(5))
        XCTAssertEqual(state.document.paragraph(withID: id)?.plainText(), "")
        XCTAssertTrue(state.undoStack.canRedo)

        state.redo(timestamp: start.addingTimeInterval(6))
        XCTAssertEqual(state.document.paragraph(withID: id)?.plainText(), "Hello")
    }

    func testAPauseBreaksTheCoalescingRun() {
        var state = EditorState.blank(authorName: "Tester")
        state.insertText("Hi", timestamp: start)
        state.insertText(" there", timestamp: start.addingTimeInterval(2))
        XCTAssertEqual(state.undoStack.depth, 2, "a two-second pause is a different thought")
    }

    func testChangingDirectionBreaksTheCoalescingRun() {
        var state = EditorState.blank(authorName: "Tester")
        let id = state.selection.focus.paragraphID
        state.insertText("abc", timestamp: start)
        state.deleteBackward(timestamp: start.addingTimeInterval(0.1))
        XCTAssertEqual(state.undoStack.depth, 2, "typing forwards then backspacing is two actions")
        XCTAssertEqual(state.document.paragraph(withID: id)?.plainText(), "ab")

        state.deleteBackward(timestamp: start.addingTimeInterval(0.2))
        state.deleteBackward(timestamp: start.addingTimeInterval(0.3))
        XCTAssertEqual(state.undoStack.depth, 3, "the two backspaces coalesce with each other")
        XCTAssertEqual(state.document.paragraph(withID: id)?.plainText(), "")
    }

    func testAnyOtherActionInvalidatesTheRedoBranch() {
        var state = EditorState.blank(authorName: "Tester")
        state.insertText("one", timestamp: start)
        state.undo(timestamp: start.addingTimeInterval(1))
        XCTAssertTrue(state.undoStack.canRedo)
        state.insertText("two", timestamp: start.addingTimeInterval(2))
        XCTAssertFalse(state.undoStack.canRedo, "a new edit discards the redo future, as in every other editor")
    }

    func testUndoStackIsBounded() {
        var stack = UndoStack(maximumSteps: 3)
        for index in 0..<10 {
            stack.record(
                undo: .empty,
                redo: .empty,
                name: "step \(index)",
                timestamp: start.addingTimeInterval(Double(index) * 10)
            )
        }
        XCTAssertEqual(stack.depth, 3, "an unbounded undo history on a 300-page document is a memory leak")
        XCTAssertEqual(stack.undoName, "step 9", "and it keeps the most recent steps")
    }

    // MARK: Structure

    func testReturnSplitsAndUndoJoins() {
        var state = EditorState.blank(authorName: "Tester")
        let id = state.selection.focus.paragraphID
        state.insertText("abcdef", timestamp: start)
        state.selection = caret(id, 3)
        state.insertParagraphBreak(timestamp: start.addingTimeInterval(1))

        let ids = state.document.paragraphIDsInOrder
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "abc")
        XCTAssertEqual(state.document.paragraph(withID: ids[1])?.plainText(), "def")
        XCTAssertEqual(state.selection.focus.paragraphID, ids[1], "the caret follows the split")
        XCTAssertEqual(state.selection.focus.characterOffset, 0)
        XCTAssertEqual(Set(state.document.paragraphs.flatMap { $0.runIDs }).count,
                       state.document.paragraphs.flatMap { $0.runIDs }.count,
                       "the two halves of a split run must not share an id")

        state.undo(timestamp: start.addingTimeInterval(2))
        XCTAssertEqual(state.document.paragraphIDsInOrder.count, 1)
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "abcdef")
    }

    func testBackspaceAtOffsetZeroJoinsParagraphs() {
        var (state, ids) = editor(with: ["one", "two"])
        state.selection = caret(ids[1], 0)
        state.deleteBackward(timestamp: start)

        XCTAssertEqual(state.document.paragraphIDsInOrder, [ids[0]])
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "onetwo")
        XCTAssertEqual(state.selection.focus.paragraphID, ids[0])
        XCTAssertEqual(state.selection.focus.characterOffset, 3, "the caret lands on the join")

        state.undo(timestamp: start.addingTimeInterval(1))
        XCTAssertEqual(state.document.paragraphIDsInOrder, ids)
        XCTAssertEqual(state.document.paragraph(withID: ids[1])?.plainText(), "two")
    }

    func testBackspaceAtTheStartOfTheDocumentDoesNothing() {
        var (state, ids) = editor(with: ["only"])
        state.selection = caret(ids[0], 0)
        let before = state.document
        state.deleteBackward(timestamp: start)
        XCTAssertEqual(state.document.sections, before.sections, "there is nothing to join with")
        XCTAssertEqual(state.undoStack.depth, 0, "and nothing to undo")
    }

    func testDeletingAcrossParagraphsMergesTheSurvivingEdges() {
        var (state, ids) = editor(with: ["aaa", "bbb", "ccc"])
        state.selection = span((ids[0], 1), (ids[2], 2))
        state.deleteBackward(timestamp: start)

        XCTAssertEqual(state.document.paragraphIDsInOrder, [ids[0]])
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "ac")

        state.undo(timestamp: start.addingTimeInterval(1))
        XCTAssertEqual(state.document.paragraphIDsInOrder, ids, "undo restores all three paragraphs")
        XCTAssertEqual(state.document.paragraphs.map { $0.plainText() }, ["aaa", "bbb", "ccc"],
                       "and their exact original contents")
    }

    func testReplacingASelectionIsOneAction() {
        var (state, ids) = editor(with: ["Hello world"])
        state.selection = span((ids[0], 6), (ids[0], 11))
        state.insertText("there", timestamp: start)

        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "Hello there")
        XCTAssertEqual(state.undoStack.depth, 1, "not a delete followed by an insert")

        state.undo(timestamp: start.addingTimeInterval(1))
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "Hello world")
    }

    func testDeletingForwardsAtTheEndOfAParagraphJoinsWithTheNext() {
        var (state, ids) = editor(with: ["one", "two"])
        state.selection = caret(ids[0], 3)
        state.deleteForward(timestamp: start)
        XCTAssertEqual(state.document.paragraphIDsInOrder, [ids[0]])
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "onetwo")
        XCTAssertEqual(state.selection.focus.characterOffset, 3, "fn-Delete does not move the caret")
    }

    // MARK: Formatting

    func testBoldSplitsTheSelectionAndUndoRestoresTheOriginalRun() {
        var (state, ids) = editor(with: ["Hello world"])
        state.selection = span((ids[0], 0), (ids[0], 5))
        state.toggleBold(timestamp: start)

        let paragraph = state.document.paragraph(withID: ids[0])
        XCTAssertEqual(paragraph?.runs.count, 2, "the selection starts at 0, so there is no leading piece")
        XCTAssertEqual(paragraph?.runs[0].properties.bold, true)
        XCTAssertEqual(paragraph?.runs[1].properties.bold, nil)
        XCTAssertEqual(paragraph?.plainText(), "Hello world", "formatting never changes the characters")

        state.undo(timestamp: start.addingTimeInterval(1))
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.runs.count, 1,
                       "undo restores the single original run, not an approximation of it")
    }

    func testBoldToggleMakesAMixedSelectionUniformlyBold() {
        var (state, ids) = editor(with: ["Hello world"])
        state.selection = span((ids[0], 0), (ids[0], 5))
        state.toggleBold(timestamp: start)

        state.selection = span((ids[0], 0), (ids[0], 11))
        XCTAssertFalse(state.selectionIsUniformlyBold())
        state.toggleBold(timestamp: start.addingTimeInterval(1))
        XCTAssertTrue(state.selectionIsUniformlyBold(),
                      "Word's rule: if any of it is not bold, make all of it bold")
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "Hello world")
    }

    func testBoldToggleRemovesBoldOnlyWhenEverythingIsAlreadyBold() {
        var (state, ids) = editor(with: ["Hello"])
        state.selection = span((ids[0], 0), (ids[0], 5))
        state.toggleBold(timestamp: start)
        XCTAssertTrue(state.selectionIsUniformlyBold())
        state.toggleBold(timestamp: start.addingTimeInterval(1))
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.runs[0].properties.bold, false)
    }

    func testFormattingAtACollapsedCaretIsStickyAndDoesNotEditTheDocument() {
        var (state, ids) = editor(with: ["abc"])
        state.selection = caret(ids[0], 3)
        let before = state.document.sections
        state.toggleBold(timestamp: start)

        XCTAssertEqual(state.document.sections, before, "nothing is selected, so nothing is formatted")
        XCTAssertEqual(state.pendingRunProperties?.bold, true)
        XCTAssertEqual(state.undoStack.depth, 0)

        state.insertText("X", timestamp: start.addingTimeInterval(0.1))
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "abcX")
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.runs.last?.properties.bold, true,
                       "the next character typed picks up the pending formatting")
    }

    func testReturnClearsPendingFormatting() {
        var state = EditorState.blank(authorName: "Tester")
        state.toggleBold(timestamp: start)
        state.insertText("bold", timestamp: start.addingTimeInterval(0.1))
        state.insertParagraphBreak(timestamp: start.addingTimeInterval(0.2))
        XCTAssertNil(state.pendingRunProperties, "Word clears sticky formatting at a paragraph break")
        state.insertText("plain", timestamp: start.addingTimeInterval(0.3))
        let ids = state.document.paragraphIDsInOrder
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(state.document.paragraph(withID: ids[1])?.runs.first?.properties.bold, nil)
    }

    func testApplyingAStyleTouchesEveryParagraphInTheSelection() {
        var (state, ids) = editor(with: ["one", "two", "three"])
        state.selection = span((ids[0], 0), (ids[2], 5))
        state.applyParagraphStyle("Heading1", timestamp: start)
        for id in ids {
            XCTAssertEqual(state.document.paragraph(withID: id)?.properties.styleID, "Heading1")
        }
        XCTAssertEqual(state.undoStack.depth, 1, "one command, one undo step")
    }

    func testASelectionEndingAtOffsetZeroDoesNotRestyleTheNextParagraph() {
        var (state, ids) = editor(with: ["one", "two"])
        state.selection = span((ids[0], 0), (ids[1], 0))
        state.applyParagraphStyle("Heading1", timestamp: start)
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.properties.styleID, "Heading1")
        XCTAssertNotEqual(state.document.paragraph(withID: ids[1])?.properties.styleID, "Heading1",
                          "the selection only touches the start of the second paragraph")
    }

    // MARK: Tracked changes and the assistant

    func testTrackChangesRecordsTheEditInsteadOfApplyingIt() {
        var (state, ids) = editor(with: ["Original"])
        state.trackChanges = true
        state.selection = span((ids[0], 0), (ids[0], 8))
        state.insertText("Replacement", timestamp: start)

        let paragraph = state.document.paragraph(withID: ids[0])
        let marks = (paragraph?.runs ?? []).compactMap { $0.revision }
        XCTAssertFalse(marks.isEmpty, "with tracking on the edit is a revision, not a silent change")
        XCTAssertTrue(marks.allSatisfy { $0.author == "Tester" })
        XCTAssertEqual(paragraph?.plainText(markup: .allMarkup).contains("Original"), true,
                       "the original text is still in the document and still rejectable")
    }

    func testAssistantEditsAreTrackedAndAttributeTheProvider() {
        var (state, ids) = editor(with: ["Original"])
        let mutation = AssistantMutationBuilder.replaceText(
            in: ids[0],
            characterRange: 0..<8,
            originalText: "Original",
            with: "Replacement",
            author: .assistant(provider: "Ollama"),
            revisionID: 1,
            date: start
        )
        state.apply(mutation, name: "Assistant rewrite", timestamp: start)

        let paragraph = state.document.paragraph(withID: ids[0])
        let marks = (paragraph?.runs ?? []).compactMap { $0.revision }
        XCTAssertFalse(marks.isEmpty)
        XCTAssertTrue(marks.allSatisfy { $0.author == "Assistant (Ollama)" },
                      "the author string names the provider, so the user can see where text went")
        XCTAssertTrue((paragraph?.runs ?? []).contains { $0.revision?.kind == .deletion },
                      "the original is marked deleted, not removed")
        XCTAssertTrue((paragraph?.runs ?? []).contains { $0.revision?.kind == .insertion })
        XCTAssertEqual(paragraph?.plainText(markup: .allMarkup), "ReplacementOriginal")
        XCTAssertEqual(paragraph?.plainText(markup: .noMarkup), "Replacement",
                       "No Markup shows the result the author would get by accepting")
        XCTAssertEqual(paragraph?.plainText(markup: .original), "Original",
                       "Original shows what was there before the assistant")

        state.undo(timestamp: start.addingTimeInterval(1))
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(), "Original",
                       "one ⌘Z undoes the whole assistant operation")
    }

    func testEachAssistantChangeIsIndividuallyRejectable() {
        // There is deliberately no whole-document mutation op: an agent has to
        // decompose, so each change stays a separate undo step and a separate
        // accept/reject unit in the Review pane.
        var (state, ids) = editor(with: ["alpha", "beta"])
        let first = AssistantMutationBuilder.replaceText(
            in: ids[0], characterRange: 0..<5, originalText: "alpha", with: "ALPHA",
            author: .assistant(provider: "Ollama"), revisionID: 1, date: start
        )
        let second = AssistantMutationBuilder.replaceText(
            in: ids[1], characterRange: 0..<4, originalText: "beta", with: "BETA",
            author: .assistant(provider: "Ollama"), revisionID: 3, date: start.addingTimeInterval(0.01)
        )
        state.apply(first, name: "Assistant", timestamp: start)
        state.apply(second, name: "Assistant", timestamp: start.addingTimeInterval(0.01))

        XCTAssertEqual(state.undoStack.depth, 2,
                       "no coalescing key, so two changes stay two reviewable units")
        state.undo(timestamp: start.addingTimeInterval(1))
        XCTAssertEqual(state.document.paragraph(withID: ids[1])?.plainText(markup: .noMarkup), "beta",
                       "rejecting the second change restores it exactly")
        XCTAssertEqual(state.document.paragraph(withID: ids[0])?.plainText(markup: .noMarkup), "ALPHA",
                       "and the first change is untouched")
    }

    // MARK: Selection model

    func testABackwardsSelectionExtendsLeftwardsFromTheAnchor() {
        var (state, ids) = editor(with: ["hello world"])
        state.selection = span((ids[0], 5), (ids[0], 0))
        XCTAssertEqual(state.selection.anchor.characterOffset, 5, "the anchor stays where the user pressed down")
        XCTAssertEqual(state.selection.focus.characterOffset, 0)
        let ordered = state.selection.ordered(in: state.document)
        XCTAssertTrue(ordered.isBackward)
        XCTAssertEqual(ordered.start.characterOffset, 0)
        XCTAssertEqual(ordered.end.characterOffset, 5)

        state.selection = state.selection.extending(to: TextPosition(paragraphID: ids[0], characterOffset: 3))
        XCTAssertEqual(state.selection.anchor.characterOffset, 5, "extending moves the focus, never the anchor")
    }

    func testNodeIDOrderIsNotDocumentOrder() {
        // This is why `TextPosition` is deliberately not `Comparable`: a
        // synthesised `<` would compile, and it would be wrong.
        var builder = DocumentBuilder()
        let first = builder.paragraph("first")
        let second = builder.paragraph("second")
        var document = builder.build()

        // Insert between them using the model's own generator, so the new
        // paragraph necessarily carries a *larger* id than the one after it.
        let paragraphID = document.nodeIDs.makeID()
        let runID = document.nodeIDs.makeID()
        let inserted = Paragraph(
            id: paragraphID,
            properties: ParagraphProperties(styleID: "Normal"),
            runs: [Run(id: runID, content: .text("inserted"))]
        )
        guard let location = document.location(ofBlock: first) else {
            return XCTFail("the anchor paragraph must be findable")
        }
        document.sections[location.sectionIndex].blocks.insert(.paragraph(inserted), at: location.blockIndex + 1)

        XCTAssertGreaterThan(paragraphID.rawValue, second.rawValue,
                             "a paragraph inserted earlier in the file carries a later id")
        XCTAssertEqual(document.paragraphIDsInOrder, [first, paragraphID, second],
                       "reading order comes from the tree, not from the ids")
        let ordering = ParagraphOrdering(document: document)
        XCTAssertLessThan(ordering.index(of: paragraphID), ordering.index(of: second))
        XCTAssertTrue(ordering.ordered(
            TextPosition(paragraphID: paragraphID, characterOffset: 0),
            before: TextPosition(paragraphID: second, characterOffset: 0)
        ))
    }

    func testParagraphIDNeighboursFollowReadingOrder() {
        var (state, ids) = editor(with: ["a", "b", "c"])
        XCTAssertEqual(state.document.paragraphID(before: ids[1]), ids[0])
        XCTAssertEqual(state.document.paragraphID(after: ids[1]), ids[2])
        XCTAssertNil(state.document.paragraphID(before: ids[0]))
        XCTAssertNil(state.document.paragraphID(after: ids[2]))
    }

    func testCaretIsClampedWhenUndoShortensTheParagraph() {
        var (state, ids) = editor(with: ["long paragraph"])
        state.selection = caret(ids[0], 14)
        state.deleteBackward(timestamp: start)
        state.selection = caret(ids[0], 13)
        state.insertText("XXXXXXXX", timestamp: start.addingTimeInterval(1))
        XCTAssertEqual(state.selection.focus.characterOffset, 21)

        state.undo(timestamp: start.addingTimeInterval(2))
        guard let paragraph = state.document.paragraph(withID: ids[0]) else {
            return XCTFail("the paragraph must still exist")
        }
        XCTAssertEqual(paragraph.plainText(), "long paragrap")
        XCTAssertLessThanOrEqual(state.selection.focus.characterOffset, paragraph.characterCount,
                                 "a caret cannot sit past the end of its paragraph")
    }

    // MARK: Provider surface

    func testEveryCataloguedProviderReportsItsStatus() {
        for provider in ProviderCatalogue.builtIn {
            XCTAssertFalse(provider.id.isEmpty)
            XCTAssertFalse(provider.displayName.isEmpty)
            let status = provider.availability()
            XCTAssertFalse(status.userMessage.isEmpty, "the picker needs a sentence to show")
            if provider.runsOnDevice {
                XCTAssertTrue(ProviderCatalogue.onDevice.contains { $0.id == provider.id })
            }
        }
    }

    func testTasksWithoutAnAppleAdapterAreNotPretendedToHaveOne() {
        XCTAssertNil(AITask.expand.writingToolsEquivalent)
        XCTAssertNil(AITask.translate.writingToolsEquivalent)
        XCTAssertEqual(AITask.proofread.writingToolsEquivalent, "proofread")
        XCTAssertEqual(AITask.shorten.writingToolsEquivalent, "concise")
        XCTAssertEqual(AITask.tabulate.writingToolsEquivalent, "table")
    }

    func testRedactionPolicyIsStrictForAnythingOffDevice() {
        XCTAssertTrue(RedactionPolicy.strict.removesEmailAddresses)
        XCTAssertTrue(RedactionPolicy.strict.removesPersonalNames)
        XCTAssertFalse(RedactionPolicy.none.redactsAnything,
                       "text that never leaves the Mac needs no redaction")
        XCTAssertTrue(RedactionPolicy.strict.redactsAnything)
    }
}

