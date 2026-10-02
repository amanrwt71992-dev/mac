import Foundation

// MARK: - SectionStart

/// `w:type` in `w:sectPr` — how a section begins.
public enum SectionStart: String, Hashable, Sendable {
    case nextPage
    case continuous
    case evenPage
    case oddPage
    case nextColumn
}

// MARK: - PageNumbering

/// `w:pgNumType`.
public struct PageNumbering: Hashable, Sendable {

    public enum Format: String, Hashable, Sendable {
        case decimal
        case upperRoman = "upperRoman"
        case lowerRoman = "lowerRoman"
        case upperLetter = "upperLetter"
        case lowerLetter = "lowerLetter"
        case ordinal
        case cardinalText = "cardinalText"
        case ordinalText = "ordinalText"
        case hebrew1 = "hebrew1"
        case hebrew2 = "hebrew2"
        case arabicAlpha = "arabicAlpha"
        case arabicAbjad = "arabicAbjad"
        case japaneseCounting = "japaneseCounting"
        case japaneseLegalNumbering = "japaneseLegalNumbering"
        case japaneseDigitalTenThousand = "japaneseDigitalTenThousand"
        case decimalEnclosedCircle = "decimalEnclosedCircle"
        case chineseLegalSimplified = "chineseLegalSimplified"
        case ideographTraditional = "ideographTraditional"
        case none
    }

    /// `w:fmt`
    public var format: Format
    /// `w:start` — `nil` means "continue from the previous section".
    public var start: Int32?
    /// `w:chapSep` — the separator in "1-1" style chapter numbering.
    public var chapterSeparator: ChapterSeparator?
    /// `w:chapStyle` — which heading level supplies the chapter number.
    public var chapterStyleLevel: Int32?

    public init(
        format: Format = .decimal,
        start: Int32? = nil,
        chapterSeparator: ChapterSeparator? = nil,
        chapterStyleLevel: Int32? = nil
    ) {
        self.format = format
        self.start = start
        self.chapterSeparator = chapterSeparator
        self.chapterStyleLevel = chapterStyleLevel
    }

    public static let `default` = PageNumbering()

    public enum ChapterSeparator: String, Hashable, Sendable {
        case hyphen
        case period
        case colon
        case enDash = "enDash"
        case emDash = "emDash"
    }

    /// Formats a page number in this section's style. Kept here rather than in
    /// the paint layer because fields (`PAGE`, `TOC \* roman`) need it too and
    /// both must agree.
    public func format(pageNumber: Int) -> String {
        switch format {
        case .decimal:
            return String(pageNumber)
        case .upperRoman:
            return PageNumbering.roman(pageNumber).uppercased()
        case .lowerRoman:
            return PageNumbering.roman(pageNumber)
        case .upperLetter:
            return PageNumbering.letter(pageNumber).uppercased()
        case .lowerLetter:
            return PageNumbering.letter(pageNumber)
        case .none:
            return ""
        default:
            // Non-Latin formats fall back to decimal in M0. Each is a small,
            // self-contained function to add later; getting the *shape* right
            // now is what matters for the field engine.
            return String(pageNumber)
        }
    }

    static func roman(_ value: Int) -> String {
        guard value > 0 else { return "" }
        let table: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var remaining = value
        var result = ""
        for (amount, symbol) in table {
            while remaining >= amount {
                result += symbol
                remaining -= amount
            }
        }
        return result
    }

    static func letter(_ value: Int) -> String {
        guard value > 0 else { return "" }
        // Word's letter numbering is bijective base-26: 1..26 = a..z, 27 = aa.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var remaining = value
        var result = ""
        while remaining > 0 {
            remaining -= 1
            let index = remaining % 26
            result = String(alphabet[index]) + result
            remaining /= 26
        }
        return result
    }
}

// MARK: - HeaderFooter

public enum HeaderFooterKind: Hashable, Sendable, CaseIterable {
    case headerDefault
    case headerFirst
    case headerEven
    case footerDefault
    case footerFirst
    case footerEven

    public var isHeader: Bool {
        switch self {
        case .headerDefault, .headerFirst, .headerEven: return true
        case .footerDefault, .footerFirst, .footerEven: return false
        }
    }

    /// The `w:type` value on `w:headerReference` / `w:footerReference`.
    ///
    /// Note that headers and footers share the same three type strings, which is
    /// why this is not a `String` raw value — two cases would collide.
    public var typeValue: String {
        switch self {
        case .headerDefault, .footerDefault: return "default"
        case .headerFirst, .footerFirst:     return "first"
        case .headerEven, .footerEven:       return "even"
        }
    }

    public var isEvenPage: Bool { self == .headerEven || self == .footerEven }
    public var isFirstPage: Bool { self == .headerFirst || self == .footerFirst }
}

/// A header or footer story.
///
/// A section that has no explicit reference for a given kind **inherits the
/// reference from the previous section** — it does not become empty. That
/// inheritance chain is why `headerReferences` stores relationship ids rather
/// than resolved content: resolving eagerly loses the distinction between
/// "inherits" and "explicitly empty", and GenOffice's #1685 (removing the
/// default reference also strips the first-page one) is a bug in exactly this
/// area.
public struct HeaderFooter: Hashable, Sendable {

    public var kind: HeaderFooterKind
    /// Relationship id into the package, e.g. `"rId7"`.
    public var relationshipID: String
    public var blocks: [Block]

    public init(kind: HeaderFooterKind, relationshipID: String, blocks: [Block] = []) {
        self.kind = kind
        self.relationshipID = relationshipID
        self.blocks = blocks
    }

    public func plainText(markup: RevisionMarkup = .allMarkup) -> String {
        return blocks.map { $0.plainText(markup: markup) }.joined(separator: "\n")
    }
}

// MARK: - SectionProperties

/// `w:sectPr`.
///
/// The final section's `sectPr` is a direct child of `w:body`; every earlier
/// section's `sectPr` is the **last child of the last paragraph in that
/// section**. That asymmetry trips up readers constantly and is modelled
/// explicitly by keeping properties on the section rather than on a paragraph.
public struct SectionProperties: Hashable, Sendable {

    public var pageSize: PageSize
    public var margins: PageMargins
    public var columns: ColumnSet
    public var grid: DocumentGrid
    public var pageNumbering: PageNumbering
    public var start: SectionStart

    /// `w:titlePg` — use the first-page header/footer.
    public var differentFirstPage: Bool
    /// Driven by `w:evenAndOddHeaders` in `settings.xml`, but applies per section
    /// at layout time, so it is resolved onto the section.
    public var differentOddAndEvenPages: Bool
    /// `w:rtlGutter`
    public var gutterOnRight: Bool
    /// `w:bidi`
    public var bidirectional: Bool
    /// `w:verticalAlign` — top/center/bottom/both for the whole text area.
    public var verticalAlignment: PageVerticalAlignment
    /// `w:lnNumType`
    public var lineNumbers: LineNumbering?
    /// `w:formProt`
    public var formProtection: Bool
    /// `w:vAlign`
    /// `w:noEndnote` — this section's endnotes move to the next section.
    public var suppressEndnotes: Bool
    /// The header/footer references this section declares. Absent kinds inherit.
    public var headerFooterReferences: [HeaderFooterKind: String]
    /// `w:sectPrChange`
    public var propertyRevision: PropertyRevision?

    public init(
        pageSize: PageSize = .letter,
        margins: PageMargins = .normal,
        columns: ColumnSet = .single,
        grid: DocumentGrid = .none,
        pageNumbering: PageNumbering = .default,
        start: SectionStart = .nextPage,
        differentFirstPage: Bool = false,
        differentOddAndEvenPages: Bool = false,
        gutterOnRight: Bool = false,
        bidirectional: Bool = false,
        verticalAlignment: PageVerticalAlignment = .top,
        lineNumbers: LineNumbering? = nil,
        formProtection: Bool = false,
        suppressEndnotes: Bool = false,
        headerFooterReferences: [HeaderFooterKind: String] = [:],
        propertyRevision: PropertyRevision? = nil
    ) {
        self.pageSize = pageSize
        self.margins = margins
        self.columns = columns
        self.grid = grid
        self.pageNumbering = pageNumbering
        self.start = start
        self.differentFirstPage = differentFirstPage
        self.differentOddAndEvenPages = differentOddAndEvenPages
        self.gutterOnRight = gutterOnRight
        self.bidirectional = bidirectional
        self.verticalAlignment = verticalAlignment
        self.lineNumbers = lineNumbers
        self.formProtection = formProtection
        self.suppressEndnotes = suppressEndnotes
        self.headerFooterReferences = headerFooterReferences
        self.propertyRevision = propertyRevision
    }

    /// The width available for text on a page in this section, in points,
    /// before columns are taken into account.
    public var textAreaWidthPoints: Double {
        let pageWidth = pageSize.width.points
        let consumed = margins.left.points + margins.right.points + margins.gutter.points
        return max(0, pageWidth - consumed)
    }

    /// The height available for text on a page, in points.
    ///
    /// Headers and footers do **not** reduce this unless they intrude into the
    /// margin, which happens when the header distance plus the header's own
    /// height exceeds the top margin. That case is resolved by the paginator,
    /// which knows the header's laid-out height; here we give the nominal value.
    public var textAreaHeightPoints: Double {
        let pageHeight = pageSize.height.points
        let consumed = margins.top.points + margins.bottom.points
        return max(0, pageHeight - consumed)
    }

    /// The full page rect in points, origin top-left.
    public var pageRect: Rect {
        return Rect(x: 0, y: 0, width: pageSize.width.points, height: pageSize.height.points)
    }

    /// The text area rect in points, in page coordinates.
    public var textAreaRect: Rect {
        return Rect(
            x: margins.left.points + margins.gutter.points,
            y: margins.top.points,
            width: textAreaWidthPoints,
            height: textAreaHeightPoints
        )
    }

    /// Distance from the page edge to the header baseline area.
    public var headerDistancePoints: Double { margins.header.points }
    public var footerDistancePoints: Double { margins.footer.points }
}

public enum PageVerticalAlignment: String, Hashable, Sendable {
    case top
    case center
    case bottom
    case both
}

/// `w:lnNumType`.
public struct LineNumbering: Hashable, Sendable {

    public enum RestartRule: String, Hashable, Sendable {
        case newPage
        case newSection
        case continuous
    }

    /// `w:countBy` — number every nth line. `nil` means every line.
    public var countBy: Int32?
    /// `w:restart`
    public var restart: RestartRule
    /// `w:distance`, in twips, from the text edge.
    public var distance: Twip?
    /// `w:start`
    public var start: Int32

    public init(
        countBy: Int32? = nil,
        restart: RestartRule = .newPage,
        distance: Twip? = nil,
        start: Int32 = 1
    ) {
        self.countBy = countBy
        self.restart = restart
        self.distance = distance
        self.start = start
    }
}

// MARK: - Section

/// One section of the body.
///
/// A section owns its page geometry and its header/footer stories, and contains
/// an ordered list of top-level blocks. The last section's properties are the
/// ones Word shows in the Page Setup dialog when the cursor is at the end of the
/// document.
public struct Section: Hashable, Sendable {

    public var id: NodeID
    public var properties: SectionProperties
    public var blocks: [Block]
    /// Resolved header/footer stories, keyed by kind. Inherited ones are
    /// materialised here by the document resolver so the paginator never has to
    /// walk backwards through sections at layout time.
    public var headersAndFooters: [HeaderFooterKind: HeaderFooter]

    public init(
        id: NodeID,
        properties: SectionProperties = .init(),
        blocks: [Block] = [],
        headersAndFooters: [HeaderFooterKind: HeaderFooter] = [:]
    ) {
        self.id = id
        self.properties = properties
        self.blocks = blocks
        self.headersAndFooters = headersAndFooters
    }

    /// A single-section document, which is what a new blank file is.
    public static func singleSection(id: NodeID, properties: SectionProperties = .init()) -> Section {
        return Section(id: id, properties: properties)
    }

    public var isFirstPageHeaderEnabled: Bool { properties.differentFirstPage }
    public var isEvenPageHeaderEnabled: Bool { properties.differentOddAndEvenPages }

    /// Picks the header or footer that applies to a given page.
    ///
    /// Word's resolution order: if it is the first page of the section and
    /// `titlePg` is set, use `first`; else if even/odd headers are on, use
    /// `even` for even pages; else `default`. A missing kind falls back to
    /// `default`, and a missing `default` means nothing is drawn.
    public func headerFooter(isHeader: Bool, isFirstPageOfSection: Bool, isEvenPage: Bool) -> HeaderFooter? {
        if isFirstPageOfSection && properties.differentFirstPage {
            if let found = lookup(isHeader: isHeader, type: "first") { return found }
        }
        if properties.differentOddAndEvenPages && isEvenPage {
            if let found = lookup(isHeader: isHeader, type: "even") { return found }
        }
        return lookup(isHeader: isHeader, type: "default")
    }

    private func lookup(isHeader: Bool, type: String) -> HeaderFooter? {
        let key: HeaderFooterKind
        switch (isHeader, type) {
        case (true, "first"):  key = .headerFirst
        case (true, "even"):   key = .headerEven
        case (true, _):        key = .headerDefault
        case (false, "first"): key = .footerFirst
        case (false, "even"):  key = .footerEven
        case (false, _):       key = .footerDefault
        }
        return headersAndFooters[key]
    }
}
