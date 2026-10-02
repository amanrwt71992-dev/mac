import Foundation

// MARK: - Block

/// A top-level child of `w:body` (or of a table cell, or a text box).
///
/// The block is the unit that matters most in this codebase, for three separate
/// reasons:
///
/// 1. **Byte-preserving save.** Each block carries an `OriginRef` back to its
///    exact byte range in the original `word/document.xml`. A block that is not
///    dirty is spliced back verbatim; only dirty blocks are re-serialised.
/// 2. **Layout islands.** Pagination invalidation stops at block boundaries, so
///    typing in one paragraph does not re-lay-out the document.
/// 3. **AI blast radius.** Assistant mutations are expressed as operations on
///    blocks by `NodeID`, which is what makes every AI change individually
///    reviewable instead of one undifferentiated rewrite.
public enum Block: Hashable, Sendable {

    case paragraph(Paragraph)
    case table(Table)
    /// `w:sdt` — a content control. Also how Word wraps a table of contents.
    case contentControl(ContentControl)
    /// `m:oMathPara`
    case math(MathBlock)
    /// A top-level element we do not model. Preserved verbatim, and spliced
    /// back byte-for-byte on save — these are exactly the blocks that must
    /// never be re-serialised, because we do not understand them well enough to.
    case preserved(PreservedBlock)

    public var id: NodeID {
        switch self {
        case .paragraph(let paragraph):     return paragraph.id
        case .table(let table):             return table.id
        case .contentControl(let control):  return control.id
        case .math(let math):               return math.id
        case .preserved(let block):         return block.id
        }
    }

    /// Whether a clean copy of the original bytes exists for this block.
    /// Preserved and (later) unknown blocks always answer `true` because they
    /// are re-emitted verbatim by construction.
    public var origin: OriginRef? {
        switch self {
        case .paragraph(let paragraph):     return paragraph.origin
        case .table(let table):             return table.origin
        case .contentControl(let control):  return control.origin
        case .math(let math):               return math.origin
        case .preserved(let block):         return block.origin
        }
    }

    public var isParagraph: Bool {
        if case .paragraph = self { return true }
        return false
    }

    public var paragraph: Paragraph? {
        if case .paragraph(let paragraph) = self { return paragraph }
        return nil
    }

    /// The outline level to show in the Navigation pane, or `nil` for body text.
    ///
    /// For a content control the level comes from the first paragraph inside it,
    /// which is how a TOC's own heading behaves.
    public var outlineLevel: OutlineLevel? {
        switch self {
        case .paragraph(let paragraph):
            return paragraph.properties.outlineLevel
        case .contentControl(let control):
            return control.blocks.first?.outlineLevel
        case .table, .math, .preserved:
            return nil
        }
    }

    /// Plain text, for search, word count, AI context and Spotlight.
    ///
    /// `markup` decides whether tracked deletions are included — a word count
    /// under "No Markup" must not count deleted text.
    public func plainText(markup: RevisionMarkup = .allMarkup) -> String {
        switch self {
        case .paragraph(let paragraph):
            return paragraph.plainText(markup: markup)
        case .table(let table):
            return table.rows
                .map { row in row.cells.map { $0.plainText(markup: markup) }.joined(separator: "\t") }
                .joined(separator: "\n")
        case .contentControl(let control):
            return control.blocks.map { $0.plainText(markup: markup) }.joined(separator: "\n")
        case .math(let math):
            return math.linearForm
        case .preserved:
            return ""
        }
    }
}

/// A top-level element we do not model, held with the identity and provenance
/// every other block has.
public struct PreservedBlock: Hashable, Sendable {
    public var id: NodeID
    public var element: PreservedElement
    public var origin: OriginRef?

    public init(id: NodeID, element: PreservedElement, origin: OriginRef? = nil) {
        self.id = id
        self.element = element
        self.origin = origin
    }
}

// MARK: - Paragraph

public struct Paragraph: Hashable, Sendable {

    public var id: NodeID
    public var properties: ParagraphProperties
    public var runs: [Run]
    /// Where this paragraph came from in the original file, if it came from one.
    public var origin: OriginRef?
    /// `w:pPr`-level tracked formatting change.
    public var propertyRevision: PropertyRevision?

    public init(
        id: NodeID,
        properties: ParagraphProperties = .empty,
        runs: [Run] = [],
        origin: OriginRef? = nil,
        propertyRevision: PropertyRevision? = nil
    ) {
        self.id = id
        self.properties = properties
        self.runs = runs
        self.origin = origin
        self.propertyRevision = propertyRevision
    }

    /// A paragraph containing a single unformatted text run.
    public static func plain(id: NodeID, text: String) -> Paragraph {
        return Paragraph(id: id, runs: [Run(id: NodeID(0), content: .text(text))])
    }

    public var isEmpty: Bool {
        return runs.allSatisfy { !$0.content.isInlineContent }
    }

    /// Character count excluding the paragraph mark, used by Word Count.
    public var characterCount: Int {
        return runs.reduce(0) { $0 + $1.content.plainText.count }
    }

    public func plainText(markup: RevisionMarkup = .allMarkup) -> String {
        var result = ""
        for run in runs where run.isVisible(markup: markup) {
            result += run.content.plainText
        }
        return result
    }

    /// A character offset into this paragraph's visible plain text, expressed as
    /// `(runIndex, offsetWithinRunContent)`.
    ///
    /// The editor's caret lives in this space; the layout engine needs the
    /// run-relative form to attach attributes. Returning both halves avoids
    /// every caller re-walking the runs.
    public func locate(characterOffset offset: Int, markup: RevisionMarkup = .allMarkup) -> RunLocation? {
        var remaining = offset
        for (index, run) in runs.enumerated() where run.isVisible(markup: markup) {
            let text = run.content.plainText
            if remaining < text.count || (remaining == text.count && index == runs.count - 1) {
                return RunLocation(runIndex: index, characterOffset: remaining)
            }
            remaining -= text.count
        }
        return nil
    }

    /// Appends text as a new run, or extends the last run when the properties
    /// match — which is what keeps a document from fragmenting into thousands of
    /// single-character runs as the user types. Run fragmentation is a real
    /// `.docx` quality problem: it bloats the file and slows every consumer.
    public mutating func appendText(
        _ text: String,
        properties: RunProperties,
        nextID: NodeID
    ) {
        if let last = runs.last, last.properties == properties, last.revision == nil,
           case .text(let existing) = last.content {
            runs[runs.count - 1].content = .text(existing + text)
        } else {
            runs.append(Run(id: nextID, content: .text(text), properties: properties))
        }
    }
}

/// A position inside a paragraph, in run-relative terms.
public struct RunLocation: Hashable, Sendable {
    public var runIndex: Int
    public var characterOffset: Int

    public init(runIndex: Int, characterOffset: Int) {
        self.runIndex = runIndex
        self.characterOffset = characterOffset
    }
}

// MARK: - OriginRef

/// A pointer into the untouched original package.
///
/// The original file is the source of truth. We archive it by hash and never
/// mutate it; every block we understand carries one of these so that on save we
/// can splice the original bytes back in for anything the user did not touch.
public struct OriginRef: Hashable, Sendable {

    /// Which part of the package, e.g. `"word/document.xml"`.
    public var partName: String
    /// Byte range within that part, half-open.
    public var range: Range<Int>
    /// Index of this block among its parent's children in the original file.
    /// Used to detect insertions, deletions and reordering.
    public var indexAmongSiblings: Int

    public init(partName: String, range: Range<Int>, indexAmongSiblings: Int) {
        self.partName = partName
        self.range = range
        self.indexAmongSiblings = indexAmongSiblings
    }

    public var length: Int { range.upperBound - range.lowerBound }
}

/// A whole part we did not understand, kept for verbatim re-emission.
public struct PreservedPart: Hashable, Sendable {
    public var partName: String
    public var contentType: String?
    public var bytes: Data

    public init(partName: String, contentType: String? = nil, bytes: Data) {
        self.partName = partName
        self.contentType = contentType
        self.bytes = bytes
    }
}

// MARK: - Table

/// `w:tbl`.
///
/// Modelled in full here even though M0 does not lay tables out, because the
/// model shape drives the codec and the codec drives the fixtures — discovering
/// in M2 that the model cannot express `vMerge` continuations would mean
/// rewriting M1.
public struct Table: Hashable, Sendable {

    public var id: NodeID
    public var properties: TableProperties
    /// `w:tblGrid/w:gridCol` — the definitive column widths. Word's layout
    /// algorithm is driven by this grid, not by the cells' own widths.
    public var grid: [Twip]
    public var rows: [TableRow]
    public var origin: OriginRef?

    public init(
        id: NodeID,
        properties: TableProperties = .init(),
        grid: [Twip] = [],
        rows: [TableRow] = [],
        origin: OriginRef? = nil
    ) {
        self.id = id
        self.properties = properties
        self.grid = grid
        self.rows = rows
        self.origin = origin
    }

    public var columnCount: Int { grid.count }
    public var rowCount: Int { rows.count }
}

public struct TableProperties: Hashable, Sendable {

    public enum WidthPreference: Hashable, Sendable {
        case auto
        case fixed(Twip)
        case percent(FiftiethsOfAPercent)
    }

    public enum LayoutAlgorithm: String, Hashable, Sendable {
        /// `w:tblLayout w:type="fixed"` — column widths are taken from the grid.
        case fixed
        /// `w:tblLayout w:type="autofit"` — recomputed from cell content.
        case autofit
    }

    public enum Alignment: String, Hashable, Sendable {
        case left
        case center
        case right
    }

    /// `w:tblW`
    public var widthPreference: WidthPreference
    /// `w:tblLayout`
    public var layout: LayoutAlgorithm
    public var alignment: Alignment
    /// `w:jc` — table justification, distinct from alignment in strict mode.
    public var indentation: Twip
    /// `w:tblCellMar`
    public var cellMargins: CellMargins
    /// `w:tblBorders`
    public var borders: TableBorders
    public var shading: Shading?
    /// `w:tblStyle`
    public var styleID: String?
    /// `w:tblLook` — which banding flags are actually enabled.
    public var look: TableLook
    /// `w:tblCellSpacing`
    public var cellSpacing: Twip?
    /// `w:tblOverlap`
    public var overlap: Bool
    /// `w:tblpPr` — a floating table.
    public var floatingPosition: TableFloatingPosition?

    public init(
        widthPreference: WidthPreference = .auto,
        layout: LayoutAlgorithm = .autofit,
        alignment: Alignment = .left,
        indentation: Twip = .zero,
        cellMargins: CellMargins = .wordDefault,
        borders: TableBorders = .none,
        shading: Shading? = nil,
        styleID: String? = nil,
        look: TableLook = .init(),
        cellSpacing: Twip? = nil,
        overlap: Bool = false,
        floatingPosition: TableFloatingPosition? = nil
    ) {
        self.widthPreference = widthPreference
        self.layout = layout
        self.alignment = alignment
        self.indentation = indentation
        self.cellMargins = cellMargins
        self.borders = borders
        self.shading = shading
        self.styleID = styleID
        self.look = look
        self.cellSpacing = cellSpacing
        self.overlap = overlap
        self.floatingPosition = floatingPosition
    }
}

public struct CellMargins: Hashable, Sendable {
    public var top: Twip
    public var start: Twip
    public var bottom: Twip
    public var end: Twip

    public init(top: Twip, start: Twip, bottom: Twip, end: Twip) {
        self.top = top
        self.start = start
        self.bottom = bottom
        self.end = end
    }

    /// Word's default: 0 top and bottom, 0.08″ (115 twips) left and right.
    public static let wordDefault = CellMargins(
        top: Twip(0), start: Twip(108), bottom: Twip(0), end: Twip(108)
    )
}

public struct TableBorders: Hashable, Sendable {
    public var top: BorderDefinition?
    public var start: BorderDefinition?
    public var bottom: BorderDefinition?
    public var end: BorderDefinition?
    public var insideHorizontal: BorderDefinition?
    public var insideVertical: BorderDefinition?

    public init(
        top: BorderDefinition? = nil,
        start: BorderDefinition? = nil,
        bottom: BorderDefinition? = nil,
        end: BorderDefinition? = nil,
        insideHorizontal: BorderDefinition? = nil,
        insideVertical: BorderDefinition? = nil
    ) {
        self.top = top
        self.start = start
        self.bottom = bottom
        self.end = end
        self.insideHorizontal = insideHorizontal
        self.insideVertical = insideVertical
    }

    public static let none = TableBorders()
}

/// `w:tblLook`. The flags say which conditional formatting to apply; the
/// `firstRow`/`lastRow`/`firstColumn`/`lastColumn`/`noHBand`/`noVBand`
/// *attributes* are the modern form and the `w:val` hex mask is the legacy form.
/// Both appear in real files, so both are kept.
public struct TableLook: Hashable, Sendable {
    public var firstRow: Bool
    public var lastRow: Bool
    public var firstColumn: Bool
    public var lastColumn: Bool
    public var noHorizontalBanding: Bool
    public var noVerticalBanding: Bool
    /// The legacy `w:val` bitmask, preserved verbatim when present.
    public var legacyMask: UInt16?

    public init(
        firstRow: Bool = false,
        lastRow: Bool = false,
        firstColumn: Bool = false,
        lastColumn: Bool = false,
        noHorizontalBanding: Bool = false,
        noVerticalBanding: Bool = false,
        legacyMask: UInt16? = nil
    ) {
        self.firstRow = firstRow
        self.lastRow = lastRow
        self.firstColumn = firstColumn
        self.lastColumn = lastColumn
        self.noHorizontalBanding = noHorizontalBanding
        self.noVerticalBanding = noVerticalBanding
        self.legacyMask = legacyMask
    }
}

public struct TableFloatingPosition: Hashable, Sendable {
    public var leftFromText: Twip
    public var rightFromText: Twip
    public var verticalAnchor: AnchorPlacement.RelativeFrom
    public var horizontalAnchor: AnchorPlacement.RelativeFrom
    public var verticalOffset: Twip
    public var horizontalOffset: Twip

    public init(
        leftFromText: Twip = Twip(180),
        rightFromText: Twip = Twip(180),
        verticalAnchor: AnchorPlacement.RelativeFrom = .text,
        horizontalAnchor: AnchorPlacement.RelativeFrom = .text,
        verticalOffset: Twip = .zero,
        horizontalOffset: Twip = .zero
    ) {
        self.leftFromText = leftFromText
        self.rightFromText = rightFromText
        self.verticalAnchor = verticalAnchor
        self.horizontalAnchor = horizontalAnchor
        self.verticalOffset = verticalOffset
        self.horizontalOffset = horizontalOffset
    }
}

public struct TableRow: Hashable, Sendable {

    public var id: NodeID
    public var properties: TableRowProperties
    public var cells: [TableCell]

    public init(id: NodeID, properties: TableRowProperties = .init(), cells: [TableCell] = []) {
        self.id = id
        self.properties = properties
        self.cells = cells
    }
}

public struct TableRowProperties: Hashable, Sendable {
    /// `w:trHeight` plus `w:hRule` (`atLeast` / `exact`).
    public var height: Twip?
    public var heightRule: HeightRule
    /// `w:tblHeader` — repeat as a header row on each page.
    public var repeatsAsHeader: Bool
    /// `w:cantSplit` — do not break this row across pages.
    public var cannotSplitAcrossPages: Bool
    /// `w:tblCellSpacing`
    public var cellSpacing: Twip?
    /// `w:jc`
    public var alignment: TableProperties.Alignment?
    /// `w:trPr/w:ins|del` — the row itself is a tracked change.
    public var revision: RevisionMark?

    public init(
        height: Twip? = nil,
        heightRule: HeightRule = .atLeast,
        repeatsAsHeader: Bool = false,
        cannotSplitAcrossPages: Bool = false,
        cellSpacing: Twip? = nil,
        alignment: TableProperties.Alignment? = nil,
        revision: RevisionMark? = nil
    ) {
        self.height = height
        self.heightRule = heightRule
        self.repeatsAsHeader = repeatsAsHeader
        self.cannotSplitAcrossPages = cannotSplitAcrossPages
        self.cellSpacing = cellSpacing
        self.alignment = alignment
        self.revision = revision
    }

    public enum HeightRule: String, Hashable, Sendable {
        case atLeast
        case exact
        case auto
    }
}

public struct TableCell: Hashable, Sendable {

    public var id: NodeID
    public var properties: TableCellProperties
    public var blocks: [Block]

    public init(id: NodeID, properties: TableCellProperties = .init(), blocks: [Block] = []) {
        self.id = id
        self.properties = properties
        self.blocks = blocks
    }

    public func plainText(markup: RevisionMarkup = .allMarkup) -> String {
        return blocks.map { $0.plainText(markup: markup) }.joined(separator: "\n")
    }
}

public struct TableCellProperties: Hashable, Sendable {
    public var widthPreference: TableProperties.WidthPreference
    /// `w:gridSpan` — how many grid columns this cell spans.
    public var gridSpan: Int32
    /// `w:vMerge` — vertical merge. `.continue` means "the cell above continues
    /// into here"; a file may write it with no `w:val` at all, which means the
    /// same thing, and conflating that with `.restart` merges cells incorrectly.
    public var verticalMerge: VerticalMerge?
    public var borders: TableBorders
    public var shading: Shading?
    public var margins: CellMargins?
    public var verticalAlignment: TableCellVerticalAlignment
    /// `w:textDirection`
    public var textDirection: TextDirection?
    /// `w:tcFitText`
    public var fitText: Bool
    /// `w:vAlign` + `w:noWrap`
    public var noWrap: Bool
    /// `w:tcPrChange`
    public var propertyRevision: PropertyRevision?

    public init(
        widthPreference: TableProperties.WidthPreference = .auto,
        gridSpan: Int32 = 1,
        verticalMerge: VerticalMerge? = nil,
        borders: TableBorders = .none,
        shading: Shading? = nil,
        margins: CellMargins? = nil,
        verticalAlignment: TableCellVerticalAlignment = .top,
        textDirection: TextDirection? = nil,
        fitText: Bool = false,
        noWrap: Bool = false,
        propertyRevision: PropertyRevision? = nil
    ) {
        self.widthPreference = widthPreference
        self.gridSpan = gridSpan
        self.verticalMerge = verticalMerge
        self.borders = borders
        self.shading = shading
        self.margins = margins
        self.verticalAlignment = verticalAlignment
        self.textDirection = textDirection
        self.fitText = fitText
        self.noWrap = noWrap
        self.propertyRevision = propertyRevision
    }

    public enum VerticalMerge: String, Hashable, Sendable {
        case restart
        case `continue`
    }
}

public enum TextDirection: String, Hashable, Sendable {
    case leftToRight = "lrTb"
    case topToBottom = "tbRl"
    case bottomToTopLeftToRight = "btLr"
    case rightToLeftTopToBottom = "rlTb"
}

// MARK: - Content control

/// `w:sdt`.
///
/// Word wraps a table of contents in one of these, and content controls are how
/// modern templates carry structured data. Treating them as opaque preserves
/// both.
public struct ContentControl: Hashable, Sendable {

    public var id: NodeID
    public var properties: ContentControlProperties
    public var blocks: [Block]
    public var origin: OriginRef?

    public init(
        id: NodeID,
        properties: ContentControlProperties = .init(),
        blocks: [Block] = [],
        origin: OriginRef? = nil
    ) {
        self.id = id
        self.properties = properties
        self.blocks = blocks
        self.origin = origin
    }
}

public struct ContentControlProperties: Hashable, Sendable {
    public var tag: String?
    public var alias: String?
    public var identifier: String?
    public var cannotBeEdited: Bool
    public var cannotBeDeleted: Bool
    public var showAsCheckBox: Bool?
    public var placeholderDocumentPartID: String?
    /// Everything in `w:sdtPr` we do not model.
    public var preservedProperties: [PreservedElement]

    public init(
        tag: String? = nil,
        alias: String? = nil,
        identifier: String? = nil,
        cannotBeEdited: Bool = false,
        cannotBeDeleted: Bool = false,
        showAsCheckBox: Bool? = nil,
        placeholderDocumentPartID: String? = nil,
        preservedProperties: [PreservedElement] = []
    ) {
        self.tag = tag
        self.alias = alias
        self.identifier = identifier
        self.cannotBeEdited = cannotBeEdited
        self.cannotBeDeleted = cannotBeDeleted
        self.showAsCheckBox = showAsCheckBox
        self.placeholderDocumentPartID = placeholderDocumentPartID
        self.preservedProperties = preservedProperties
    }
}

// MARK: - Math

/// `m:oMathPara` / `m:oMath`.
///
/// Full OMML rendering is M5. In M0 we keep the linear (Unicode) form so the
/// text is searchable and the AI can read it, and preserve the original XML so
/// the equation is not destroyed by a save — which is what a naive
/// implementation would do.
public struct MathBlock: Hashable, Sendable {
    public var id: NodeID
    public var linearForm: String
    public var preservedXML: PreservedElement?
    public var origin: OriginRef?

    public init(
        id: NodeID,
        linearForm: String = "",
        preservedXML: PreservedElement? = nil,
        origin: OriginRef? = nil
    ) {
        self.id = id
        self.linearForm = linearForm
        self.preservedXML = preservedXML
        self.origin = origin
    }
}
