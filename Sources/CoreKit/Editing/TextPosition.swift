import Foundation

// MARK: - TextPosition

/// A caret position: a paragraph, and a character offset within it.
///
/// Addressed by paragraph rather than by a flat document offset on purpose. A
/// flat offset has to be recomputed for every paragraph after an edit, which
/// makes typing O(document length); a paragraph-relative position stays valid no
/// matter what happens elsewhere in the file. On a 200,000-word document that is
/// the difference between a keystroke budget of 16 ms and one of 160 ms.
/// Deliberately **not** `Comparable`.
///
/// `NodeID` is `Comparable`, so a synthesised `<` would compile — and it would be
/// wrong. Ids are allocated over time, so a paragraph inserted earlier in the
/// file today can carry a higher id than one that follows it. A `<` that quietly
/// disagrees with document order is exactly the kind of API that produces
/// selections which jump to the wrong end. Use `ParagraphOrdering.ordered(_:before:)`
/// or `TextSelection.ordered(in:)`, both of which consult the document.
public struct TextPosition: Hashable, Sendable, CustomStringConvertible {

    public var paragraphID: NodeID
    /// Character offset within the paragraph's visible text.
    public var characterOffset: Int

    /// The table cell this position is inside, when it is inside one.
    ///
    /// Kept here rather than inferred from the paragraph because a paragraph in a
    /// nested table has two cell ancestors, and because the same paragraph id
    /// could in principle appear in a content control. Layout and hit-testing
    /// both need the full address.
    public var cellPath: [TableCellAddress]?

    public init(paragraphID: NodeID, characterOffset: Int, cellPath: [TableCellAddress]? = nil) {
        self.paragraphID = paragraphID
        self.characterOffset = max(0, characterOffset)
        self.cellPath = cellPath
    }

    /// Whether both ends of a comparison sit in the same paragraph, where the
    /// character offset alone decides the order.
    public func precedes(_ other: TextPosition, inSameParagraphOnly requireSameParagraph: Bool = true) -> Bool {
        if requireSameParagraph, paragraphID != other.paragraphID { return false }
        return characterOffset < other.characterOffset
    }

    public var description: String { "\(paragraphID):\(characterOffset)" }

    public func advanced(by delta: Int) -> TextPosition {
        TextPosition(paragraphID: paragraphID, characterOffset: max(0, characterOffset + delta), cellPath: cellPath)
    }
}

/// A position inside a table cell, as a chain of `(row, column)` pairs.
///
/// A chain rather than a single pair because tables nest.
public struct TableCellAddress: Hashable, Sendable {
    public var tableID: NodeID
    public var row: Int
    public var column: Int

    public init(tableID: NodeID, row: Int, column: Int) {
        self.tableID = tableID
        self.row = row
        self.column = column
    }
}

// MARK: - TextSelection

/// A range of text, possibly spanning paragraphs.
///
/// `start` and `end` are kept in the order the user created them, not in
/// document order. That matters for shift-click and shift-arrow selection, where
/// extending a backwards selection has to keep growing leftwards — normalising
/// eagerly is how editors end up with selections that jump to the other end when
/// you hold shift and press left.
/// Named `TextSelection` rather than `TextRange`: an Apple framework exports a
/// top-level `TextRange`, which makes the shorter name ambiguous at every
/// unqualified use site in any module that also imports Foundation on macOS. The
/// longer name is also the more accurate one — this type holds an anchor and a
/// focus, which is a selection, not merely a span of offsets.
public struct TextSelection: Hashable, Sendable, CustomStringConvertible {

    /// The anchored end — where the user pressed down.
    public var anchor: TextPosition
    /// The moving end — where the caret is now.
    public var focus: TextPosition

    public init(anchor: TextPosition, focus: TextPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    /// A collapsed range, i.e. a caret with no selection.
    public init(caret: TextPosition) {
        self.anchor = caret
        self.focus = caret
    }

    public var isCollapsed: Bool { anchor == focus }

    /// The two ends in document order, plus whether the selection runs backwards.
    ///
    /// Consults the document rather than comparing `NodeID`s, because ids are
    /// allocated over time and so do not encode reading order.
    public func ordered(in document: DocumentModel) -> (start: TextPosition, end: TextPosition, isBackward: Bool) {
        if anchor.paragraphID == focus.paragraphID {
            if anchor.characterOffset <= focus.characterOffset {
                return (anchor, focus, false)
            }
            return (focus, anchor, true)
        }
        let anchorIndex = document.paragraphOrderIndex(anchor.paragraphID)
        let focusIndex = document.paragraphOrderIndex(focus.paragraphID)
        if anchorIndex < focusIndex { return (anchor, focus, false) }
        if focusIndex < anchorIndex { return (focus, anchor, true) }
        return (anchor, focus, false)
    }

    /// Extends the focus, keeping the anchor fixed.
    public func extending(to position: TextPosition) -> TextSelection {
        TextSelection(anchor: anchor, focus: position)
    }

    public var description: String {
        isCollapsed ? "\(anchor) (collapsed)" : "\(anchor) → \(focus)"
    }
}

// MARK: - Paragraph ordering

extension DocumentModel {

    /// The index of a paragraph in reading order, or `Int.max` when absent.
    ///
    /// Building this per call is O(document). Callers that need many lookups —
    /// selection normalisation during a drag, for instance — should use
    /// `paragraphOrderIndex()` on a `ParagraphOrdering` snapshot instead.
    public func paragraphOrderIndex(_ id: NodeID) -> Int {
        var index = 0
        for section in sections {
            for block in section.blocks {
                switch block {
                case .paragraph(let paragraph):
                    if paragraph.id == id { return index }
                    index += 1
                case .table(let table):
                    for row in table.rows {
                        for cell in row.cells {
                            for inner in cell.blocks {
                                if case .paragraph(let paragraph) = inner {
                                    if paragraph.id == id { return index }
                                    index += 1
                                }
                            }
                        }
                    }
                case .contentControl(let control):
                    for inner in control.blocks {
                        if case .paragraph(let paragraph) = inner {
                            if paragraph.id == id { return index }
                            index += 1
                        }
                    }
                case .math, .preserved:
                    continue
                }
            }
        }
        return Int.max
    }

    /// Every paragraph id in reading order.
    public var paragraphIDsInOrder: [NodeID] {
        var result: [NodeID] = []
        result.reserveCapacity(sections.reduce(0) { $0 + $1.blocks.count })
        for section in sections {
            for block in section.blocks {
                appendParagraphIDs(from: block, into: &result)
            }
        }
        return result
    }

    private func appendParagraphIDs(from block: Block, into result: inout [NodeID]) {
        switch block {
        case .paragraph(let paragraph):
            result.append(paragraph.id)
        case .table(let table):
            for row in table.rows {
                for cell in row.cells {
                    for inner in cell.blocks { appendParagraphIDs(from: inner, into: &result) }
                }
            }
        case .contentControl(let control):
            for inner in control.blocks { appendParagraphIDs(from: inner, into: &result) }
        case .math, .preserved:
            break
        }
    }
}

// MARK: - ParagraphOrdering

/// A cached reading-order map, for callers that resolve many positions at once.
public struct ParagraphOrdering: Hashable, Sendable {

    private var order: [NodeID: Int]

    public init(document: DocumentModel) {
        var map: [NodeID: Int] = [:]
        for (index, id) in document.paragraphIDsInOrder.enumerated() {
            map[id] = index
        }
        self.order = map
    }

    public func index(of id: NodeID) -> Int { order[id] ?? Int.max }

    public func ordered(_ lhs: TextPosition, before rhs: TextPosition) -> Bool {
        let left = index(of: lhs.paragraphID)
        let right = index(of: rhs.paragraphID)
        if left != right { return left < right }
        return lhs.characterOffset < rhs.characterOffset
    }
}
