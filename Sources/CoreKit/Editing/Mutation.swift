import Foundation

// MARK: - MutationOp

/// A single structural change to a document.
///
/// Every input path in the app — keyboard, mouse, ribbon, menu, undo, Apple
/// Writing Tools, AppleScript, and the AI assistant — funnels through this one
/// type. That is a deliberate architectural choice rather than tidiness: it is
/// what makes "AI edits land as reviewable tracked changes" and "⌘Z undoes
/// exactly one user-visible action" fall out for free instead of being bolted
/// on per feature.
///
/// There is deliberately no `replaceWholeDocument` case. An agent that wants to
/// rewrite a chapter must decompose into block operations, so that every change
/// is individually reviewable in the Review pane and individually acceptable as
/// a tracked change.
public enum MutationOp: Hashable, Sendable {

    /// Inserts text into a paragraph at a character offset.
    ///
    /// Run merging (append to an adjacent run when properties match rather than
    /// creating a new one) happens in `Paragraph.insert(text:…)`. Without it a
    /// document fragments into one run per keystroke, which bloats the file and
    /// slows every consumer of it.
    case insertText(
        paragraph: NodeID,
        characterOffset: Int,
        text: String,
        properties: RunProperties,
        revision: RevisionMark?
    )

    /// Deletes `length` characters starting at `characterOffset`.
    ///
    /// The characters are **removed**. This is what a normal edit does and what
    /// accepting a tracked deletion does.
    case deleteText(
        paragraph: NodeID,
        characterOffset: Int,
        length: Int
    )

    /// Marks `length` characters at `characterOffset` as deleted, keeping them.
    ///
    /// The tracked-changes counterpart to `deleteText`, and the only correct way
    /// to express a *proposed* deletion. Word writes this as `w:del` wrapping the
    /// runs with `w:delText` in place of `w:text`, so the characters stay in the
    /// file and the user can still reject the change. Removing them instead would
    /// leave nothing to reject and nothing for the Review pane to show.
    case markTextDeleted(
        paragraph: NodeID,
        characterOffset: Int,
        length: Int,
        revision: RevisionMark
    )

    /// Splits a paragraph at a character offset — the Return key.
    ///
    /// `newParagraphProperties` carries Word's "style for following paragraph"
    /// behaviour (`w:next`): Return inside a Heading 1 yields a Normal
    /// paragraph, Return inside a List Paragraph yields another List Paragraph.
    case splitParagraph(
        paragraph: NodeID,
        characterOffset: Int,
        newParagraphProperties: ParagraphProperties,
        newParagraphID: NodeID
    )

    /// Joins a paragraph with the one that follows it — Backspace at offset 0.
    case joinParagraphWithNext(paragraph: NodeID)

    /// Replaces a whole paragraph.
    ///
    /// Coarse but always exactly right, which is why every formatting command
    /// uses it. Applying bold to a selection is fiddly at run level, and getting
    /// undo wrong for formatting is far worse than a slightly larger inverse.
    case replaceParagraph(Paragraph)

    /// Inserts blocks at a position in a section.
    case insertBlocks(sectionIndex: Int, blockIndex: Int, blocks: [Block])

    /// Removes blocks by id, wherever they are in the tree.
    case removeBlocks(ids: [NodeID])

    /// Replaces a section's properties (page setup, margins, columns).
    case replaceSectionProperties(sectionIndex: Int, properties: SectionProperties)

    /// Replaces document-level settings.
    case replaceSettings(DocumentSettings)

    /// Records the assistant's rationale so the Review pane can show it.
    /// Carries no document effect and is deliberately absent from inverses —
    /// undoing a change should not re-narrate it.
    case annotate(rationale: String)
}

// MARK: - MutationAuthor

/// Who produced a mutation. Persisted as the OOXML revision author.
public enum MutationAuthor: Hashable, Sendable {
    /// A human, editing normally.
    case user(name: String)
    /// Apple Writing Tools. Distinct from `.assistant` because the adapter set
    /// and the privacy story are Apple's, not ours.
    case writingTools
    /// Our assistant, naming the provider so the user can see where text went.
    case assistant(provider: String)
    /// A macro, AppleScript, Shortcut or Siri intent.
    case automation(source: String)

    /// The `w:author` string OOXML stores.
    public var revisionAuthor: String {
        switch self {
        case .user(let name):            return name
        case .writingTools:              return "Writing Tools"
        case .assistant(let provider):   return "Assistant (\(provider))"
        case .automation(let source):    return source
        }
    }

    public var isAssistant: Bool {
        if case .assistant = self { return true }
        return false
    }
}

// MARK: - DocumentMutation

/// An ordered list of operations, applied atomically.
///
/// Atomicity matters for two reasons: a Find & Replace All must be one undo
/// step, and an AI operation must be one accept/reject unit.
public struct DocumentMutation: Hashable, Sendable {

    public var operations: [MutationOp]
    public var author: MutationAuthor

    public init(operations: [MutationOp], author: MutationAuthor = .user(name: "")) {
        self.operations = operations
        self.author = author
    }

    public static let empty = DocumentMutation(operations: [])

    public var isEmpty: Bool { operations.isEmpty }

    public mutating func append(_ op: MutationOp) {
        operations.append(op)
    }

    /// Applies the mutation and returns the mutation that reverses it.
    ///
    /// Inverses are built from the pre-change state, captured before each
    /// operation runs. That is what makes undo exact rather than approximate —
    /// including for deletions that span runs with different formatting, where
    /// reconstructing from the characters alone would lose the bold.
    ///
    /// Operations whose target does not exist are skipped rather than trapping:
    /// an AI proposal can name a node that a concurrent edit removed, and a
    /// crash is never the right response to a stale node id.
    @discardableResult
    public func applied(to document: inout DocumentModel) -> DocumentMutation {
        var inverse: [MutationOp] = []

        for op in operations {
            switch op {

            case .insertText(let paragraphID, let offset, let text, let properties, let revision):
                guard !text.isEmpty else { continue }
                guard var paragraph = document.paragraph(withID: paragraphID) else { continue }
                // Ids are allocated as a batch before the edit runs, because a
                // closure that allocated them would have to capture the `inout`
                // document, which Swift forbids.
                var pool = document.makeNodeIDPool(size: nodeIDPoolSize(for: paragraph))
                paragraph.insert(
                    text: text,
                    atCharacterOffset: offset,
                    properties: properties,
                    revision: revision,
                    idPool: &pool
                )
                guard document.replaceParagraph(paragraph) else { continue }
                inverse.append(.deleteText(
                    paragraph: paragraphID,
                    characterOffset: offset,
                    length: text.count
                ))

            case .deleteText(let paragraphID, let offset, let length):
                guard length > 0 else { continue }
                guard let original = document.paragraph(withID: paragraphID) else { continue }
                var paragraph = original
                let removed = paragraph.deleteText(atCharacterOffset: offset, length: length)
                guard !removed.isEmpty else { continue }
                guard document.replaceParagraph(paragraph) else { continue }
                // Restoring the whole paragraph is exact: it brings back the
                // runs that were deleted, with their formatting and revisions.
                inverse.append(.replaceParagraph(original))

            case .markTextDeleted(let paragraphID, let offset, let length, let revision):
                guard length > 0 else { continue }
                guard let original = document.paragraph(withID: paragraphID) else { continue }
                var paragraph = original
                var pool = document.makeNodeIDPool(size: nodeIDPoolSize(for: paragraph))
                guard paragraph.markDeleted(
                    atCharacterOffset: offset,
                    length: length,
                    revision: revision,
                    idPool: &pool
                ) else { continue }
                guard document.replaceParagraph(paragraph) else { continue }
                // Restoring the whole paragraph is exact: it puts back the runs
                // as they were, without their deletion marks.
                inverse.append(.replaceParagraph(original))

            case .splitParagraph(let paragraphID, let offset, let newProperties, let newID):
                guard var paragraph = document.paragraph(withID: paragraphID) else { continue }
                var pool = document.makeNodeIDPool(size: nodeIDPoolSize(for: paragraph))
                guard let tail = paragraph.split(
                    atCharacterOffset: offset,
                    newID: newID,
                    newProperties: newProperties,
                    idPool: &pool
                ) else { continue }
                guard document.replaceParagraph(paragraph) else { continue }
                guard let location = document.location(ofBlock: paragraphID) else { continue }
                document.sections[location.sectionIndex].blocks.insert(.paragraph(tail), at: location.blockIndex + 1)
                inverse.append(.joinParagraphWithNext(paragraph: paragraphID))

            case .joinParagraphWithNext(let paragraphID):
                guard let location = document.location(ofBlock: paragraphID) else { continue }
                let blocks = document.sections[location.sectionIndex].blocks
                guard location.blockIndex + 1 < blocks.count else { continue }
                guard let current = blocks[location.blockIndex].paragraph else { continue }
                guard let next = blocks[location.blockIndex + 1].paragraph else { continue }

                let boundary = current.characterCount
                var merged = current
                merged.appendRuns(from: next)
                document.sections[location.sectionIndex].blocks[location.blockIndex] = .paragraph(merged)
                document.sections[location.sectionIndex].blocks.remove(at: location.blockIndex + 1)

                inverse.append(.splitParagraph(
                    paragraph: paragraphID,
                    characterOffset: boundary,
                    newParagraphProperties: next.properties,
                    newParagraphID: next.id
                ))

            case .replaceParagraph(let replacement):
                guard let original = document.paragraph(withID: replacement.id) else { continue }
                guard document.replaceParagraph(replacement) else { continue }
                inverse.append(.replaceParagraph(original))

            case .insertBlocks(let sectionIndex, let blockIndex, let blocks):
                guard sectionIndex >= 0, sectionIndex < document.sections.count else { continue }
                guard !blocks.isEmpty else { continue }
                let clamped = max(0, min(blockIndex, document.sections[sectionIndex].blocks.count))
                document.sections[sectionIndex].blocks.insert(contentsOf: blocks, at: clamped)
                inverse.append(.removeBlocks(ids: blocks.map { $0.id }))

            case .removeBlocks(let ids):
                guard !ids.isEmpty else { continue }
                // Collect in reverse document order, so re-inserting in that
                // same order restores every index correctly.
                var removed: [(sectionIndex: Int, blockIndex: Int, block: Block)] = []
                for sectionIndex in document.sections.indices.reversed() {
                    for blockIndex in document.sections[sectionIndex].blocks.indices.reversed() {
                        let block = document.sections[sectionIndex].blocks[blockIndex]
                        guard ids.contains(block.id) else { continue }
                        removed.append((sectionIndex, blockIndex, block))
                        document.sections[sectionIndex].blocks.remove(at: blockIndex)
                    }
                }
                for entry in removed {
                    inverse.append(.insertBlocks(
                        sectionIndex: entry.sectionIndex,
                        blockIndex: entry.blockIndex,
                        blocks: [entry.block]
                    ))
                }

            case .replaceSectionProperties(let sectionIndex, let properties):
                guard sectionIndex >= 0, sectionIndex < document.sections.count else { continue }
                let original = document.sections[sectionIndex].properties
                document.sections[sectionIndex].properties = properties
                inverse.append(.replaceSectionProperties(sectionIndex: sectionIndex, properties: original))

            case .replaceSettings(let settings):
                let original = document.settings
                document.settings = settings
                inverse.append(.replaceSettings(original))

            case .annotate:
                continue
            }
        }

        return DocumentMutation(operations: inverse, author: author)
    }
}

// MARK: - UndoStack

/// Undo and redo, with Word-matching coalescing.
///
/// Coalescing is not a nicety; it is what makes ⌘Z feel correct. Word does not
/// undo one character at a time, and it does not make you press ⌘Z two hundred
/// times to reverse a Replace All. The rules:
///
/// | Action | Coalescing |
/// |---|---|
/// | Typing | coalesce contiguous inserts; break on a pause, on any other action, or on losing focus |
/// | Delete / Backspace | coalesce the same way; deleting a selection is one unit |
/// | Formatting change | one unit, never coalesced with typing |
/// | Find & Replace All | one unit |
/// | Insert table / picture / footnote | one unit |
/// | AI edit | one unit, so "undo the assistant" is a single ⌘Z |
/// | Writing Tools result | one unit |
public struct UndoStack: Hashable, Sendable {

    /// One undoable step: the mutation to apply, and the key that decides
    /// whether the next mutation merges into it.
    public struct Step: Hashable, Sendable {
        public var undo: DocumentMutation
        public var redo: DocumentMutation
        public var name: String
        public var coalescingKey: CoalescingKey?
        public var timestamp: Date

        public init(
            undo: DocumentMutation,
            redo: DocumentMutation,
            name: String,
            coalescingKey: CoalescingKey? = nil,
            timestamp: Date = Date(timeIntervalSince1970: 0)
        ) {
            self.undo = undo
            self.redo = redo
            self.name = name
            self.coalescingKey = coalescingKey
            self.timestamp = timestamp
        }
    }

    private var undoSteps: [Step]
    private var redoSteps: [Step]

    /// Consecutive edits within this window merge. Word's behaviour is
    /// approximately "until you stop typing"; 500 ms is the conventional choice.
    public var coalescingWindow: TimeInterval

    /// A hard cap, because an unbounded undo history on a 300-page document is
    /// an unbounded memory leak. Word does not offer infinite undo either.
    public var maximumSteps: Int

    public init(coalescingWindow: TimeInterval = 0.5, maximumSteps: Int = 1000) {
        self.undoSteps = []
        self.redoSteps = []
        self.coalescingWindow = coalescingWindow
        self.maximumSteps = maximumSteps
    }

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }

    public var undoName: String? { undoSteps.last?.name }
    public var redoName: String? { redoSteps.last?.name }

    public var depth: Int { undoSteps.count }

    /// Records a completed edit.
    ///
    /// `undo` is the mutation produced by `DocumentMutation.applied(to:)`;
    /// `redo` is the mutation that was just applied.
    public mutating func record(
        undo: DocumentMutation,
        redo: DocumentMutation,
        name: String,
        coalescingKey: CoalescingKey? = nil,
        timestamp: Date
    ) {
        // Any new user action invalidates the redo branch, exactly as in every
        // other editor. Doing otherwise loses the user's future.
        redoSteps.removeAll()

        if let key = coalescingKey, var last = undoSteps.last,
           let lastKey = last.coalescingKey,
           lastKey.continues(into: key),
           timestamp.timeIntervalSince(last.timestamp) <= coalescingWindow {
            // Merge: the combined undo runs the older inverse *after* the newer
            // one, and the combined redo runs the newer after the older.
            let mergedUndo = DocumentMutation(
                operations: undo.operations + last.undo.operations,
                author: undo.author
            )
            let mergedRedo = DocumentMutation(
                operations: last.redo.operations + redo.operations,
                author: redo.author
            )
            last.undo = mergedUndo
            last.redo = mergedRedo
            last.timestamp = timestamp
            undoSteps[undoSteps.count - 1] = last
            return
        }

        undoSteps.append(Step(
            undo: undo,
            redo: redo,
            name: name,
            coalescingKey: coalescingKey,
            timestamp: timestamp
        ))

        if undoSteps.count > maximumSteps {
            undoSteps.removeFirst(undoSteps.count - maximumSteps)
        }
    }

    /// Pops the next undo step. The caller applies `step.undo` and then passes
    /// the resulting inverse back through `pushRedo`.
    public mutating func popUndo() -> Step? {
        guard let step = undoSteps.popLast() else { return nil }
        return step
    }

    public mutating func popRedo() -> Step? {
        guard let step = redoSteps.popLast() else { return nil }
        return step
    }

    public mutating func pushRedo(_ step: Step) {
        redoSteps.append(step)
        if redoSteps.count > maximumSteps {
            redoSteps.removeFirst(redoSteps.count - maximumSteps)
        }
    }

    public mutating func pushUndo(_ step: Step) {
        undoSteps.append(step)
        if undoSteps.count > maximumSteps {
            undoSteps.removeFirst(undoSteps.count - maximumSteps)
        }
    }

    public mutating func clear() {
        undoSteps.removeAll()
        redoSteps.removeAll()
    }
}

/// Decides which consecutive edits merge into one undo step.
///
/// Two edits merge only when they are the same *kind* of edit in the same
/// paragraph and the second starts exactly where the first ended. That is what
/// makes "hello" typed in five keystrokes one ⌘Z, while "hello" typed then
/// backspaced twice is three separate steps — the direction changed, so the run
/// of contiguous edits ended.
///
/// Comparing whole keys for equality would not work: consecutive inserts have
/// different start offsets by definition. The comparison has to be
/// `previous.endOffset == next.startOffset`, which is what `continues(into:)`
/// expresses.
public struct CoalescingKey: Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        /// Typing forwards at a contiguous position.
        case insertForward(paragraph: NodeID)
        /// Backspacing at a contiguous position.
        case deleteBackward(paragraph: NodeID)
        /// Deleting forwards (fn-Delete).
        case deleteForward(paragraph: NodeID)
    }

    public var kind: Kind
    /// The caret offset this edit started at.
    public var startOffset: Int
    /// The caret offset this edit left behind, i.e. where a contiguous
    /// continuation must start.
    public var endOffset: Int

    public init(kind: Kind, startOffset: Int, endOffset: Int) {
        self.kind = kind
        self.startOffset = startOffset
        self.endOffset = endOffset
    }

    /// Whether `next` continues this run of edits.
    public func continues(into next: CoalescingKey) -> Bool {
        kind == next.kind && endOffset == next.startOffset
    }
}
