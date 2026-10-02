import Foundation
import CoreKit

// MARK: - EditorState

/// The complete editing state of one open document.
///
/// A value type: the document, the selection and the undo stack travel together
/// because an edit invalidates all three at once, and keeping them apart is how
/// an editor ends up with a caret on a page that no longer exists.
///
/// It deliberately holds **no** layout snapshot, and EditorKit does not import
/// LayoutKit. The layout is derived state: the document controller owns it,
/// re-runs the pipeline when the model changes, and swaps the result in. Storing
/// a snapshot here would mean the editor has to know that every mutation stales
/// it — which is what the three `layout = .empty` writes in an earlier revision
/// of this file were doing, spreading layout bookkeeping through every editing
/// path. Knowing less is what keeps the editing layer testable against CoreKit
/// alone, and CI enforces the boundary.
public struct EditorState: Hashable, Sendable {

    public var document: DocumentModel
    public var selection: TextSelection
    public var undoStack: UndoStack

    /// Which revisions are currently visible. Changing this re-lays out the
    /// document, because the final text and the marked-up text have different
    /// page counts.
    public var markup: RevisionMarkup

    /// The author name written into `w:ins`/`w:del` and into `docProps/core.xml`.
    public var authorName: String

    /// `w:trackChanges`. When on, edits are recorded as revisions rather than
    /// applied silently.
    public var trackChanges: Bool

    /// Formatting applied to the next character typed at a collapsed caret.
    ///
    /// This is the "sticky" formatting Word has: type a bold word, press space,
    /// and the space is still bold. It is state, not a property of the paragraph,
    /// which is why it lives on the editor rather than in the model.
    public var pendingRunProperties: RunProperties?

    public init(
        document: DocumentModel,
        selection: TextSelection? = nil,
        undoStack: UndoStack = UndoStack(),
        markup: RevisionMarkup = .allMarkup,
        authorName: String = "",
        trackChanges: Bool = false,
        pendingRunProperties: RunProperties? = nil
    ) {
        self.document = document
        self.undoStack = undoStack
        self.markup = markup
        self.authorName = authorName
        self.trackChanges = trackChanges
        self.pendingRunProperties = pendingRunProperties

        if let selection {
            self.selection = selection
        } else {
            // Caret at the very start of the first paragraph, or a synthetic
            // position if the document somehow has none.
            let first = document.paragraphIDsInOrder.first ?? NodeID(0)
            self.selection = TextSelection(caret: TextPosition(paragraphID: first, characterOffset: 0))
        }
    }

    /// A blank document with the caret at the start.
    public static func blank(authorName: String = "") -> EditorState {
        EditorState(document: DocumentModel.blank(), authorName: authorName)
    }

    public var author: MutationAuthor { .user(name: authorName) }

    /// `w:id` on `w:ins`/`w:del`. A separate counter from node ids: revision
    /// ids are document-scoped and Int32 in the schema, node ids are tree-scoped
    /// and UInt64 in ours, and reusing one for the other would eventually collide.
    public var nextRevisionID: Int32 = 1

    /// The revision mark to attach to an edit, or `nil` when tracking is off.
    private mutating func currentRevision(kind: RevisionKind, at date: Date) -> RevisionMark? {
        guard trackChanges else { return nil }
        let id = nextRevisionID
        nextRevisionID += 1
        return RevisionMark(id: id, author: authorName, date: date, kind: kind)
    }

    // MARK: Applying mutations

    /// Applies a mutation, records undo, and returns it.
    ///
    /// The single funnel. Every editing entry point below goes through here, so
    /// undo bookkeeping, the redo-branch invalidation and the dirty flag cannot
    /// be forgotten by a new feature.
    @discardableResult
    public mutating func apply(
        _ mutation: DocumentMutation,
        name: String,
        coalescingKey: CoalescingKey? = nil,
        timestamp: Date
    ) -> DocumentMutation {
        guard !mutation.isEmpty else { return .empty }
        let inverse = mutation.applied(to: &document)
        undoStack.record(
            undo: inverse,
            redo: mutation,
            name: name,
            coalescingKey: coalescingKey,
            timestamp: timestamp
        )
        return mutation
    }

    // MARK: Typing

    /// Inserts text at the caret, replacing any selection.
    ///
    /// When something is selected, the deletion and the insertion are composed
    /// into **one** mutation and applied once. Doing them as two steps makes
    /// replacing a selection by typing two undo actions, and the user who presses
    /// ⌘Z expecting their text back gets the half-state instead.
    public mutating func insertText(_ text: String, timestamp: Date) {
        guard !text.isEmpty else { return }

        let ordered = selection.ordered(in: document)
        // The formatting to apply is read *before* anything is deleted: it is the
        // formatting in effect at the point the user was looking at.
        let properties = pendingRunProperties ?? runPropertiesAtCaret()

        var operations: [MutationOp] = []
        var caretParagraph = selection.focus.paragraphID
        var caretOffset = selection.focus.characterOffset

        if !selection.isCollapsed {
            operations.append(contentsOf: operationsDeletingRange(selection, timestamp: timestamp))
            caretParagraph = ordered.start.paragraphID
            caretOffset = ordered.start.characterOffset
        }

        guard document.paragraph(withID: caretParagraph) != nil else { return }
        let revision = currentRevision(kind: .insertion, at: timestamp)
        operations.append(.insertText(
            paragraph: caretParagraph,
            characterOffset: caretOffset,
            text: text,
            properties: properties,
            revision: revision
        ))

        // Replacing a selection does not coalesce with the keystrokes around it:
        // the caret does not move contiguously, and Word treats it as its own
        // action too.
        let key = selection.isCollapsed ? CoalescingKey(
            kind: .insertForward(paragraph: caretParagraph),
            startOffset: caretOffset,
            endOffset: caretOffset + text.count
        ) : nil

        apply(DocumentMutation(operations: operations, author: author),
              name: "Typing",
              coalescingKey: key,
              timestamp: timestamp)

        selection = TextSelection(caret: TextPosition(
            paragraphID: caretParagraph,
            characterOffset: caretOffset + text.count
        ))
    }

    /// The op that removes text, respecting `w:trackChanges`.
    ///
    /// With tracking on the text is marked deleted and kept; with it off the text
    /// is removed. Using physical deletion while tracking is on would destroy the
    /// user's ability to reject their own edit, which is the entire point of
    /// tracked changes.
    private mutating func deletionOperation(
        paragraph: NodeID,
        characterOffset: Int,
        length: Int,
        timestamp: Date
    ) -> MutationOp {
        guard trackChanges else {
            return .deleteText(paragraph: paragraph, characterOffset: characterOffset, length: length)
        }
        guard let revision = currentRevision(kind: .deletion, at: timestamp) else {
            return .deleteText(paragraph: paragraph, characterOffset: characterOffset, length: length)
        }
        return .markTextDeleted(
            paragraph: paragraph,
            characterOffset: characterOffset,
            length: length,
            revision: revision
        )
    }

    /// Backspace: deletes the selection, or one character before the caret, or
    /// joins with the previous paragraph when the caret is at offset 0.
    public mutating func deleteBackward(timestamp: Date) {
        if !selection.isCollapsed {
            deleteSelectionIfNeeded(timestamp: timestamp, undoName: "Delete")
            return
        }
        let caret = selection.focus
        guard document.paragraph(withID: caret.paragraphID) != nil else { return }

        if caret.characterOffset > 0 {
            let mutation = DocumentMutation(
                operations: [deletionOperation(
                    paragraph: caret.paragraphID,
                    characterOffset: caret.characterOffset - 1,
                    length: 1,
                    timestamp: timestamp
                )],
                author: author
            )
            apply(mutation, name: "Delete", coalescingKey: CoalescingKey(
                kind: .deleteBackward(paragraph: caret.paragraphID),
                startOffset: caret.characterOffset,
                endOffset: caret.characterOffset - 1
            ), timestamp: timestamp)
            selection = TextSelection(caret: caret.advanced(by: -1))
            return
        }

        // Offset 0: join with the previous paragraph. If there is none — the
        // caret is at the very start of the document — Backspace does nothing,
        // which is Word's behaviour and the one users expect.
        guard let previousID = document.paragraphID(before: caret.paragraphID) else { return }
        guard let previous = document.paragraph(withID: previousID) else { return }

        // The caret lands where the two paragraphs joined, i.e. at the old end
        // of the previous paragraph.
        let boundary = previous.characterCount
        let mutation = DocumentMutation(
            operations: [.joinParagraphWithNext(paragraph: previousID)],
            author: author
        )
        apply(mutation, name: "Delete", timestamp: timestamp)
        selection = TextSelection(caret: TextPosition(paragraphID: previousID, characterOffset: boundary))
    }

    /// fn-Delete: deletes one character after the caret, or joins with the next
    /// paragraph at the end of one.
    public mutating func deleteForward(timestamp: Date) {
        if !selection.isCollapsed {
            deleteSelectionIfNeeded(timestamp: timestamp, undoName: "Delete")
            return
        }
        let caret = selection.focus
        guard let paragraph = document.paragraph(withID: caret.paragraphID) else { return }

        if caret.characterOffset < paragraph.characterCount {
            let mutation = DocumentMutation(
                operations: [deletionOperation(
                    paragraph: caret.paragraphID,
                    characterOffset: caret.characterOffset,
                    length: 1,
                    timestamp: timestamp
                )],
                author: author
            )
            // fn-Delete leaves the caret where it was, so start and end are the
            // same offset and every following fn-Delete continues the run.
            apply(mutation, name: "Delete", coalescingKey: CoalescingKey(
                kind: .deleteForward(paragraph: caret.paragraphID),
                startOffset: caret.characterOffset,
                endOffset: caret.characterOffset
            ), timestamp: timestamp)
            return
        }

        // Only the existence of a next paragraph matters here; `joinParagraph
        // WithNext` finds it itself.
        guard document.paragraphID(after: caret.paragraphID) != nil else { return }
        let mutation = DocumentMutation(
            operations: [.joinParagraphWithNext(paragraph: caret.paragraphID)],
            author: author
        )
        apply(mutation, name: "Delete", timestamp: timestamp)
    }

    /// Return: splits the paragraph at the caret.
    public mutating func insertParagraphBreak(timestamp: Date) {
        deleteSelectionIfNeeded(timestamp: timestamp, undoName: nil)

        let caret = selection.focus
        guard let paragraph = document.paragraph(withID: caret.paragraphID) else { return }

        let newID = document.nodeIDs.makeID()
        let newProperties = document.followingParagraphProperties(for: paragraph)
        let mutation = DocumentMutation(
            operations: [.splitParagraph(
                paragraph: caret.paragraphID,
                characterOffset: caret.characterOffset,
                newParagraphProperties: newProperties,
                newParagraphID: newID
            )],
            author: author
        )
        apply(mutation, name: "Paragraph Break", timestamp: timestamp)
        // Pending formatting does not survive Return: Word clears it, which is
        // why typing a bold word then pressing Return gives normal text.
        pendingRunProperties = nil
        selection = TextSelection(caret: TextPosition(paragraphID: newID, characterOffset: 0))
    }

    /// Tab: inserts a tab character.
    public mutating func insertTab(timestamp: Date) {
        insertText("\t", timestamp: timestamp)
    }

    // MARK: Selection deletion

    /// Deletes the current selection if it is not collapsed.
    ///
    /// `undoName` is `nil` when the deletion is a prelude to an insertion, in
    /// which case it must not become its own undo step — replacing a selection by
    /// typing is one action, not two.
    @discardableResult
    private mutating func deleteSelectionIfNeeded(timestamp: Date, undoName: String?) -> Bool {
        guard !selection.isCollapsed else { return false }
        let operations = operationsDeletingRange(selection, timestamp: timestamp)
        guard !operations.isEmpty else { return false }

        let ordered = selection.ordered(in: document)
        apply(DocumentMutation(operations: operations, author: author),
              name: undoName ?? "Delete",
              timestamp: timestamp)
        selection = TextSelection(caret: ordered.start)
        return true
    }

    /// Builds the mutation that deletes a range, spanning paragraphs if needed.
    ///
    /// Cross-paragraph deletion is the case implementations get wrong: deleting
    /// the middle of a document must merge the two boundary paragraphs, drop
    /// everything between them, and keep the boundary paragraphs' own
    /// properties — the merged paragraph keeps the *first* one's, which is why
    /// selecting from a body paragraph into a heading and deleting leaves body
    /// formatting behind.
    private mutating func operationsDeletingRange(_ range: TextSelection, timestamp: Date) -> [MutationOp] {
        let ordered = range.ordered(in: document)
        let start = ordered.start
        let end = ordered.end

        if start.paragraphID == end.paragraphID {
            let length = end.characterOffset - start.characterOffset
            guard length > 0 else { return [] }
            return [deletionOperation(
                paragraph: start.paragraphID,
                characterOffset: start.characterOffset,
                length: length,
                timestamp: timestamp
            )]
        }

        let ordering = ParagraphOrdering(document: document)
        let startIndex = ordering.index(of: start.paragraphID)
        let endIndex = ordering.index(of: end.paragraphID)
        guard startIndex < endIndex else { return [] }
        let all = document.paragraphIDsInOrder

        // With tracking on, Word marks the text deleted and marks the paragraph
        // marks deleted, so the paragraphs stay in the file until the change is
        // accepted. Merging them here would remove content the user is supposed
        // to be able to reject. Joining the paragraph marks is M1 work; until
        // then a tracked cross-paragraph delete marks the text and leaves the
        // paragraph structure alone, which is reversible and never loses data.
        if trackChanges {
            var operations: [MutationOp] = []
            if let first = document.paragraph(withID: start.paragraphID) {
                operations.append(deletionOperation(
                    paragraph: start.paragraphID,
                    characterOffset: start.characterOffset,
                    length: max(0, first.characterCount - start.characterOffset),
                    timestamp: timestamp
                ))
            }
            for id in all[(startIndex + 1)..<endIndex] {
                guard let middle = document.paragraph(withID: id) else { continue }
                operations.append(deletionOperation(
                    paragraph: id,
                    characterOffset: 0,
                    length: middle.characterCount,
                    timestamp: timestamp
                ))
            }
            if document.paragraph(withID: end.paragraphID) != nil {
                operations.append(deletionOperation(
                    paragraph: end.paragraphID,
                    characterOffset: 0,
                    length: end.characterOffset,
                    timestamp: timestamp
                ))
            }
            return operations
        }

        guard var startParagraph = document.paragraph(withID: start.paragraphID),
              var endParagraph = document.paragraph(withID: end.paragraphID) else { return [] }

        startParagraph.deleteText(
            atCharacterOffset: start.characterOffset,
            length: max(0, startParagraph.characterCount - start.characterOffset)
        )
        endParagraph.deleteText(atCharacterOffset: 0, length: end.characterOffset)
        startParagraph.appendRuns(from: endParagraph)

        // Everything strictly between the two ends goes, plus the end paragraph
        // itself, whose remaining runs were just folded into the start.
        var removed = Array(all[(startIndex + 1)..<endIndex])
        removed.append(end.paragraphID)

        return [
            .replaceParagraph(startParagraph),
            .removeBlocks(ids: removed),
        ]
    }

    // MARK: Undo and redo

    public mutating func undo(timestamp: Date) {
        guard var step = undoStack.popUndo() else { return }
        let inverse = step.undo.applied(to: &document)
        step.redo = inverse
        undoStack.pushRedo(step)
        restoreSelectionAfterUndo()
    }

    public mutating func redo(timestamp: Date) {
        guard var step = undoStack.popRedo() else { return }
        let inverse = step.redo.applied(to: &document)
        step.undo = inverse
        undoStack.pushUndo(step)
        restoreSelectionAfterUndo()
    }

    /// Best-effort caret restoration.
    ///
    /// Word restores the selection you had when you performed the action. Doing
    /// that properly needs the selection stored on the undo step; until then the
    /// caret is moved to the first paragraph the mutation touched, which is
    /// close enough that it never lands somewhere unrelated.
    private mutating func restoreSelectionAfterUndo() {
        guard selection.focus.paragraphOrNil(in: document) != nil else {
            let first = document.paragraphIDsInOrder.first ?? NodeID(0)
            selection = TextSelection(caret: TextPosition(paragraphID: first, characterOffset: 0))
            return
        }
        // Clamp the offset: the paragraph may be shorter than it was.
        guard let paragraph = document.paragraph(withID: selection.focus.paragraphID) else { return }
        let clamped = min(selection.focus.characterOffset, paragraph.characterCount)
        selection = TextSelection(caret: TextPosition(paragraphID: paragraph.id, characterOffset: clamped))
    }

    // MARK: Formatting

    /// The run properties in effect at the caret.
    ///
    /// At a collapsed caret inside a run, that run's properties. At the boundary
    /// between two runs, the *following* run's — which is why typing at the end
    /// of a bold word continues bold, but typing at the start of the word after
    /// it does not.
    public func runPropertiesAtCaret() -> RunProperties {
        guard let paragraph = document.paragraph(withID: selection.focus.paragraphID) else {
            return document.styles.defaultRunProperties
        }
        let offset = selection.focus.characterOffset
        guard let location = paragraph.locate(characterOffset: offset, markup: markup) else {
            return paragraph.properties.paragraphMarkRunProperties ?? document.styles.defaultRunProperties
        }
        guard location.runIndex < paragraph.runs.count else { return document.styles.defaultRunProperties }
        return paragraph.runs[location.runIndex].properties
    }

    /// Applies direct character formatting to the selection, or sets the pending
    /// formatting when the selection is collapsed.
    ///
    /// Replaces the whole paragraph, which makes undo exact at the cost of a
    /// larger inverse. For a formatting command — one per ⌘B — that trade is
    /// obviously right.
    public mutating func applyRunFormatting(_ transform: (inout RunProperties) -> Void, timestamp: Date) {
        if selection.isCollapsed {
            var properties = pendingRunProperties ?? runPropertiesAtCaret()
            transform(&properties)
            pendingRunProperties = properties
            return
        }

        let ordered = selection.ordered(in: document)
        guard ordered.start.paragraphID == ordered.end.paragraphID else {
            // Cross-paragraph character formatting is M1: it needs per-run
            // splitting across several paragraphs, and doing it by replacing
            // whole paragraphs would destroy the paragraph boundaries.
            return
        }
        guard var paragraph = document.paragraph(withID: ordered.start.paragraphID) else { return }

        let from = ordered.start.characterOffset
        let to = ordered.end.characterOffset
        guard to > from else { return }

        var rebuilt: [Run] = []
        var consumed = 0
        for run in paragraph.runs {
            let text = run.content.plainText
            let runStart = consumed
            let runEnd = consumed + text.count
            consumed = runEnd

            guard case .text(let original) = run.content else {
                // Non-text runs are preserved untouched.
                rebuilt.append(run)
                continue
            }
            if runEnd <= from || runStart >= to {
                rebuilt.append(run)
                continue
            }

            let lower = max(0, from - runStart)
            let upper = min(text.count, to - runStart)
            let before = String(original[..<original.index(original.startIndex, offsetBy: lower)])
            let middle = String(original[original.index(original.startIndex, offsetBy: lower)..<original.index(original.startIndex, offsetBy: upper)])
            let after = String(original[original.index(original.startIndex, offsetBy: upper)...])

            if !before.isEmpty {
                rebuilt.append(Run(id: run.id, content: .text(before), properties: run.properties, revision: run.revision))
            }
            var middleProperties = run.properties
            transform(&middleProperties)
            rebuilt.append(Run(
                id: document.nodeIDs.makeID(),
                content: .text(middle),
                properties: middleProperties,
                revision: run.revision
            ))
            if !after.isEmpty {
                rebuilt.append(Run(
                    id: document.nodeIDs.makeID(),
                    content: .text(after),
                    properties: run.properties,
                    revision: run.revision
                ))
            }
        }

        paragraph.runs = rebuilt
        apply(DocumentMutation(operations: [.replaceParagraph(paragraph)], author: author),
              name: "Formatting",
              timestamp: timestamp)
    }

    /// Toggles bold across the selection.
    ///
    /// Word's rule: if *any* of the selection is not bold, make it all bold;
    /// only if all of it is already bold does the command remove bold. Users read
    /// the opposite behaviour as the button not working.
    public mutating func toggleBold(timestamp: Date) {
        let shouldBold = !selectionIsUniformlyBold()
        applyRunFormatting({ properties in
            properties.bold = shouldBold
        }, timestamp: timestamp)
    }

    public func selectionIsUniformlyBold() -> Bool {
        guard !selection.isCollapsed else {
            return runPropertiesAtCaret().bold == true
        }
        let ordered = selection.ordered(in: document)
        guard ordered.start.paragraphID == ordered.end.paragraphID,
              let paragraph = document.paragraph(withID: ordered.start.paragraphID) else { return false }
        let text = paragraph.plainText(markup: markup)
        let lower = text.index(text.startIndex, offsetBy: min(ordered.start.characterOffset, text.count))
        let upper = text.index(text.startIndex, offsetBy: min(ordered.end.characterOffset, text.count))
        guard lower < upper else { return false }

        var consumed = 0
        for run in paragraph.runs {
            let length = run.content.plainText.count
            let runStart = consumed
            let runEnd = consumed + length
            consumed = runEnd
            guard runEnd > ordered.start.characterOffset, runStart < ordered.end.characterOffset else { continue }
            if run.properties.bold != true { return false }
        }
        return true
    }

    /// Applies a paragraph style by id.
    public mutating func applyParagraphStyle(_ styleID: String, timestamp: Date) {
        let ordered = selection.ordered(in: document)
        let ordering = ParagraphOrdering(document: document)
        let all = document.paragraphIDsInOrder
        let startIndex = ordering.index(of: ordered.start.paragraphID)
        var endIndex = ordering.index(of: ordered.end.paragraphID)
        // Word excludes a paragraph the selection merely touches at offset 0:
        // selecting to the very start of the next heading should not restyle it.
        if endIndex > startIndex, ordered.end.characterOffset == 0 { endIndex -= 1 }
        guard startIndex <= endIndex, endIndex < all.count else { return }

        var operations: [MutationOp] = []
        for id in all[startIndex...endIndex] {
            guard var paragraph = document.paragraph(withID: id) else { continue }
            paragraph.properties.styleID = styleID
            operations.append(.replaceParagraph(paragraph))
        }
        guard !operations.isEmpty else { return }
        apply(DocumentMutation(operations: operations, author: author), name: "Style", timestamp: timestamp)
    }
}

// MARK: - Navigation helpers

extension TextPosition {
    /// The paragraph id if it still exists in the document.
    func paragraphOrNil(in document: DocumentModel) -> NodeID? {
        document.paragraph(withID: paragraphID) == nil ? nil : paragraphID
    }
}

extension DocumentModel {

    /// The paragraph immediately before this one in reading order.
    public func paragraphID(before id: NodeID) -> NodeID? {
        let all = paragraphIDsInOrder
        guard let index = all.firstIndex(of: id), index > 0 else { return nil }
        return all[index - 1]
    }

    /// The paragraph immediately after this one in reading order.
    public func paragraphID(after id: NodeID) -> NodeID? {
        let all = paragraphIDsInOrder
        guard let index = all.firstIndex(of: id), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}
