import Foundation

// MARK: - Id allocation for splits

/// Takes an id from a pre-allocated pool.
///
/// A pool rather than a closure or a generator reference, because these methods
/// are called from `DocumentMutation.applied(to: inout DocumentModel)`, and Swift
/// will not let a closure capture an `inout` parameter — so there is no way to
/// hand a mutating method a callback that allocates from the document. Allocating
/// a batch up front is also cheaper: one contiguous bump instead of a call per
/// split.
///
/// `fallback` covers pool exhaustion, which cannot happen when the caller sizes
/// the pool from the run count. Reusing an existing id there is still better than
/// trapping, because a duplicate id degrades an edit while a trap loses the
/// document.
private func nextID(from pool: inout [NodeID], fallback: NodeID) -> NodeID {
    guard !pool.isEmpty else { return fallback }
    return pool.removeFirst()
}

/// How many ids a paragraph edit could possibly need.
///
/// Every run can be split into at most three pieces by one edit, and two of those
/// are new, so two ids per run plus a little slack is a hard upper bound.
func nodeIDPoolSize(for paragraph: Paragraph) -> Int {
    paragraph.runs.count * 2 + 2
}

// MARK: - Character-level paragraph editing

/// The character-level editing primitives.
///
/// Everything here works in **visible character offsets within the paragraph**,
/// which is the coordinate space the caret and the layout engine both use. Runs
/// that contribute no characters — field marks, proofing markers, preserved XML —
/// are transparent to the offset arithmetic but are never discarded, which is
/// what keeps fields and tracked-change markers intact while typing around them.
extension Paragraph {

    /// Inserts text at a character offset.
    ///
    /// Merges into an adjacent run when the properties and revision state match.
    /// This is the run-fragmentation guard: without it, a paragraph typed one
    /// character at a time becomes hundreds of runs, the file balloons, and every
    /// downstream consumer slows down.
    public mutating func insert(
        text: String,
        atCharacterOffset offset: Int,
        properties: RunProperties,
        revision: RevisionMark? = nil,
        idPool: inout [NodeID]
    ) {
        guard !text.isEmpty else { return }

        if runs.isEmpty {
            runs.append(Run(
                id: nextID(from: &idPool, fallback: id),
                content: .text(text),
                properties: properties,
                revision: revision
            ))
            return
        }

        let target = insertionPoint(forCharacterOffset: offset)
        let run = runs[target.runIndex]

        // Case 1: same formatting and same revision state — merge into the run.
        if case .text(let existing) = run.content, run.properties == properties, run.revision == revision {
            if target.characterOffset >= existing.count {
                runs[target.runIndex].content = .text(existing + text)
                return
            }
            if target.characterOffset == 0 {
                // Prefer extending the *previous* run, so typing at the start of
                // a bold run does not inherit the bold.
                if target.runIndex > 0 {
                    let previous = runs[target.runIndex - 1]
                    if case .text(let previousText) = previous.content,
                       previous.properties == properties,
                       previous.revision == revision {
                        runs[target.runIndex - 1].content = .text(previousText + text)
                        return
                    }
                }
                runs.insert(Run(
                    id: nextID(from: &idPool, fallback: run.id),
                    content: .text(text), properties: properties, revision: revision
                ), at: target.runIndex)
                return
            }
            // Mid-run: split, with the inserted text taking the middle slot.
            let splitIndex = existing.index(existing.startIndex, offsetBy: target.characterOffset)
            let head = String(existing[existing.startIndex..<splitIndex])
            let tail = String(existing[splitIndex...])
            runs[target.runIndex].content = .text(head)
            runs.insert(Run(
                id: nextID(from: &idPool, fallback: run.id),
                content: .text(text), properties: properties, revision: revision
            ), at: target.runIndex + 1)
            runs.insert(Run(
                id: nextID(from: &idPool, fallback: run.id),
                content: .text(tail), properties: run.properties, revision: run.revision
            ), at: target.runIndex + 2)
            return
        }

        // Case 2: different formatting, offset lands mid-run — still a split, so
        // the tail keeps its own properties.
        if case .text(let existing) = run.content,
           target.characterOffset > 0,
           target.characterOffset < existing.count {
            let splitIndex = existing.index(existing.startIndex, offsetBy: target.characterOffset)
            let head = String(existing[existing.startIndex..<splitIndex])
            let tail = String(existing[splitIndex...])
            runs[target.runIndex].content = .text(head)
            runs.insert(Run(
                id: nextID(from: &idPool, fallback: run.id),
                content: .text(text), properties: properties, revision: revision
            ), at: target.runIndex + 1)
            runs.insert(Run(
                id: nextID(from: &idPool, fallback: run.id),
                content: .text(tail), properties: run.properties, revision: run.revision
            ), at: target.runIndex + 2)
            return
        }

        // Case 3: at a run boundary — a run of its own.
        let insertionIndex = target.characterOffset == 0 ? target.runIndex : target.runIndex + 1
        runs.insert(Run(
            id: nextID(from: &idPool, fallback: run.id),
            content: .text(text), properties: properties, revision: revision
        ), at: insertionIndex)
    }

    /// Deletes `length` characters starting at `offset` and returns what was removed.
    ///
    /// Needs no ids: deleting only shrinks and removes runs.
    @discardableResult
    public mutating func deleteText(atCharacterOffset offset: Int, length: Int) -> String {
        guard length > 0, offset < characterCount else { return "" }

        let start = max(0, offset)
        let end = min(characterCount, offset + length)
        guard end > start else { return "" }

        var removed = ""
        var survivors: [Run] = []
        var consumed = 0

        for run in runs {
            let text = run.content.plainText
            let runStart = consumed
            let runEnd = consumed + text.count
            consumed = runEnd

            if runEnd <= start || runStart >= end {
                survivors.append(run)
                continue
            }

            let localStart = max(0, start - runStart)
            let localEnd = min(text.count, end - runStart)

            let lower = text.index(text.startIndex, offsetBy: localStart)
            let upper = text.index(text.startIndex, offsetBy: localEnd)
            removed += String(text[lower..<upper])

            guard case .text(let original) = run.content else {
                // A tab, line break or symbol fully inside the range: dropped.
                continue
            }
            // Recomputed against `original` rather than reused from `text`:
            // String indices are not guaranteed to transfer between instances.
            let headEnd = original.index(original.startIndex, offsetBy: localStart)
            let tailStart = original.index(original.startIndex, offsetBy: localEnd)
            let kept = String(original[..<headEnd]) + String(original[tailStart...])
            guard !kept.isEmpty else { continue }
            var copy = run
            copy.content = .text(kept)
            survivors.append(copy)
        }

        runs = survivors
        return removed
    }

    /// Marks `length` characters at `offset` as deleted **without removing them**.
    ///
    /// This is what tracked changes require. `deleteText` removes the runs, which
    /// is correct for an accepted edit and wrong for a proposed one: with the
    /// text gone there is nothing left to reject, and the Review pane has nothing
    /// to show. Word expresses this as `w:del` wrapping the runs, and `w:delText`
    /// replacing `w:text`, so the characters stay in the file.
    ///
    /// Returns whether anything was marked.
    @discardableResult
    public mutating func markDeleted(
        atCharacterOffset offset: Int,
        length: Int,
        revision: RevisionMark,
        idPool: inout [NodeID]
    ) -> Bool {
        guard length > 0, offset < characterCount else { return false }

        let start = max(0, offset)
        let end = min(characterCount, offset + length)
        guard end > start else { return false }

        var result: [Run] = []
        var consumed = 0
        var changed = false

        for run in runs {
            let text = run.content.plainText
            let runStart = consumed
            let runEnd = consumed + text.count
            consumed = runEnd

            // Untouched.
            if runEnd <= start || runStart >= end {
                result.append(run)
                continue
            }

            let localStart = max(0, start - runStart)
            let localEnd = min(text.count, end - runStart)

            // Wholly inside the deleted range.
            if localStart == 0 && localEnd == text.count {
                var copy = run
                copy.revision = revision
                result.append(copy)
                changed = true
                continue
            }

            guard case .text(let original) = run.content else {
                // Non-text content partially covered: mark the whole run. Losing
                // a fraction of a tab is better than losing the revision.
                var copy = run
                copy.revision = revision
                result.append(copy)
                changed = true
                continue
            }

            let splitLow = original.index(original.startIndex, offsetBy: localStart)
            let splitHigh = original.index(original.startIndex, offsetBy: localEnd)
            let head = String(original[..<splitLow])
            let middle = String(original[splitLow..<splitHigh])
            let tail = String(original[splitHigh...])

            if !head.isEmpty {
                result.append(Run(id: run.id, content: .text(head), properties: run.properties, revision: run.revision))
            }
            if !middle.isEmpty {
                result.append(Run(
                    id: nextID(from: &idPool, fallback: run.id),
                    content: .text(middle),
                    properties: run.properties,
                    revision: revision
                ))
                changed = true
            }
            if !tail.isEmpty {
                result.append(Run(
                    id: nextID(from: &idPool, fallback: run.id),
                    content: .text(tail),
                    properties: run.properties,
                    revision: run.revision
                ))
            }
        }

        guard changed else { return false }
        runs = result
        return true
    }

    /// Marks `length` characters at `offset` as inserted.
    ///
    /// The mirror of `markDeleted`, used when an AI proposal adds text: the new
    /// runs carry `w:ins` so the Review pane can show them and reject them.
    @discardableResult
    public mutating func markInserted(
        atCharacterOffset offset: Int,
        length: Int,
        revision: RevisionMark,
        idPool: inout [NodeID]
    ) -> Bool {
        guard length > 0 else { return false }
        var consumed = 0
        var changed = false
        var result: [Run] = []
        let start = max(0, offset)
        let end = min(characterCount, offset + length)

        for run in runs {
            let text = run.content.plainText
            let runStart = consumed
            let runEnd = consumed + text.count
            consumed = runEnd

            if runEnd <= start || runStart >= end {
                result.append(run)
                continue
            }
            let localStart = max(0, start - runStart)
            let localEnd = min(text.count, end - runStart)
            if localStart == 0 && localEnd == text.count {
                var copy = run
                copy.revision = revision
                result.append(copy)
                changed = true
                continue
            }
            guard case .text(let original) = run.content else {
                result.append(run)
                continue
            }
            let splitLow = original.index(original.startIndex, offsetBy: localStart)
            let splitHigh = original.index(original.startIndex, offsetBy: localEnd)
            let head = String(original[..<splitLow])
            let middle = String(original[splitLow..<splitHigh])
            let tail = String(original[splitHigh...])
            if !head.isEmpty {
                result.append(Run(id: run.id, content: .text(head), properties: run.properties, revision: run.revision))
            }
            if !middle.isEmpty {
                result.append(Run(
                    id: nextID(from: &idPool, fallback: run.id),
                    content: .text(middle), properties: run.properties, revision: revision
                ))
                changed = true
            }
            if !tail.isEmpty {
                result.append(Run(
                    id: nextID(from: &idPool, fallback: run.id),
                    content: .text(tail), properties: run.properties, revision: run.revision
                ))
            }
        }

        guard changed else { return false }
        runs = result
        return true
    }

    /// Splits this paragraph at a character offset, returning the new second
    /// paragraph. `self` keeps everything before the offset.
    ///
    /// The paragraph mark's own run properties (`w:pPr/w:rPr`) travel to the
    /// *new* paragraph, because in Word the paragraph mark is a character that
    /// belongs to the end of the paragraph — pressing Return at the end of a bold
    /// paragraph should not make the next paragraph bold.
    public mutating func split(
        atCharacterOffset offset: Int,
        newID: NodeID,
        newProperties: ParagraphProperties,
        idPool: inout [NodeID]
    ) -> Paragraph? {
        let clamped = max(0, min(offset, characterCount))
        var headRuns: [Run] = []
        var tailRuns: [Run] = []
        var consumed = 0

        for run in runs {
            let text = run.content.plainText
            let runStart = consumed
            let runEnd = consumed + text.count
            consumed = runEnd

            if runEnd <= clamped {
                headRuns.append(run)
                continue
            }
            if runStart >= clamped {
                tailRuns.append(run)
                continue
            }

            guard case .text(let original) = run.content else {
                tailRuns.append(run)
                continue
            }
            let localOffset = clamped - runStart
            let splitIndex = original.index(original.startIndex, offsetBy: localOffset)
            let head = String(original[original.startIndex..<splitIndex])
            let tail = String(original[splitIndex...])
            if !head.isEmpty {
                headRuns.append(Run(id: run.id, content: .text(head), properties: run.properties, revision: run.revision))
            }
            if !tail.isEmpty {
                // A fresh id: the head keeps the original, so reusing it here
                // would put the same id in two places in the tree.
                tailRuns.append(Run(
                    id: nextID(from: &idPool, fallback: run.id),
                    content: .text(tail),
                    properties: run.properties,
                    revision: run.revision
                ))
            }
        }

        runs = headRuns

        var tailProperties = newProperties
        if let markProperties = properties.paragraphMarkRunProperties {
            tailProperties.paragraphMarkRunProperties = markProperties
        }

        return Paragraph(id: newID, properties: tailProperties, runs: tailRuns, origin: origin)
    }

    /// Appends another paragraph's runs to the end of this one. Used by the
    /// inverse of a split, i.e. Backspace at the start of a paragraph.
    public mutating func appendRuns(from other: Paragraph) {
        // The joined runs already carry their own formatting, so nothing needs
        // adjusting here; that is what makes undo of a join exact.
        runs.append(contentsOf: other.runs)
    }

    /// Maps a visible character offset to `(runIndex, offsetWithinThatRun)`.
    ///
    /// An offset past the end resolves to the last run with an offset equal to
    /// that run's length, which is how a caret at the end of a paragraph is
    /// represented.
    public func insertionPoint(forCharacterOffset offset: Int) -> RunLocation {
        guard !runs.isEmpty else { return RunLocation(runIndex: 0, characterOffset: 0) }
        var consumed = 0
        for index in runs.indices {
            let length = runs[index].content.plainText.count
            if offset <= consumed + length {
                return RunLocation(runIndex: index, characterOffset: max(0, offset - consumed))
            }
            consumed += length
        }
        let lastIndex = runs.count - 1
        return RunLocation(runIndex: lastIndex, characterOffset: runs[lastIndex].content.plainText.count)
    }

    /// The character offset of a run's first character.
    public func characterOffset(ofRunAt index: Int) -> Int {
        guard index >= 0, index < runs.count else { return characterCount }
        var total = 0
        for position in 0..<index {
            total += runs[position].content.plainText.count
        }
        return total
    }

    /// Every run id in this paragraph, for uniqueness assertions.
    public var runIDs: [NodeID] { runs.map { $0.id } }
}

// MARK: - Block location

extension DocumentModel {

    /// Where a top-level block lives, as `(sectionIndex, blockIndex)`.
    ///
    /// Returned together because almost every structural mutation needs both,
    /// and searching twice is how index bugs get introduced.
    public func location(ofBlock id: NodeID) -> BlockLocation? {
        for sectionIndex in sections.indices {
            for blockIndex in sections[sectionIndex].blocks.indices {
                if sections[sectionIndex].blocks[blockIndex].id == id {
                    return BlockLocation(sectionIndex: sectionIndex, blockIndex: blockIndex)
                }
            }
        }
        return nil
    }

    /// Inserts a new empty paragraph after the given block.
    public mutating func insertEmptyParagraph(
        after id: NodeID,
        properties: ParagraphProperties = .empty
    ) -> NodeID? {
        guard let location = location(ofBlock: id) else { return nil }
        let newID = nodeIDs.makeID()
        let runID = nodeIDs.makeID()
        let paragraph = Paragraph(
            id: newID,
            properties: properties,
            runs: [Run(id: runID, content: .text(""))]
        )
        sections[location.sectionIndex].blocks.insert(.paragraph(paragraph), at: location.blockIndex + 1)
        return newID
    }

    /// The properties Word applies to the paragraph created by Return, i.e. the
    /// `w:next` of the current paragraph's style, falling back to the same style.
    public func followingParagraphProperties(for paragraph: Paragraph) -> ParagraphProperties {
        guard let styleID = paragraph.properties.styleID,
              let style = styles.styles[styleID],
              let nextID = style.nextStyleID,
              let next = styles.styles[nextID] else {
            // No `w:next`: Word keeps the same style, which is what makes Return
            // inside a List Paragraph produce another List Paragraph.
            var inherited = paragraph.properties
            inherited.paragraphMarkRunProperties = nil
            inherited.propertyRevision = nil
            return inherited
        }
        var properties = next.paragraphProperties
        properties.paragraphMarkRunProperties = nil
        return properties
    }

    /// Allocates a pool of fresh node ids sized for one paragraph edit.
    ///
    /// A plain loop rather than `map`, because a closure would have to capture
    /// `nodeIDs` through `&self`, which Swift rejects inside a mutating method
    /// that is itself called with an `inout` document.
    public mutating func makeNodeIDPool(size: Int) -> [NodeID] {
        var pool: [NodeID] = []
        pool.reserveCapacity(max(0, size))
        for _ in 0..<max(0, size) {
            pool.append(nodeIDs.makeID())
        }
        return pool
    }
}

public struct BlockLocation: Hashable, Sendable {
    public var sectionIndex: Int
    public var blockIndex: Int

    public init(sectionIndex: Int, blockIndex: Int) {
        self.sectionIndex = sectionIndex
        self.blockIndex = blockIndex
    }
}
