import Foundation

// MARK: - DocumentBuilder

/// Builds a `DocumentModel` without hand-allocating node ids.
///
/// Constructing a document by hand means threading `NodeIDState` through every
/// paragraph, run and section, and getting an id wrong produces a document that
/// looks fine until two nodes collide and an edit updates both. The builder owns
/// the counter so callers cannot.
///
/// It is also what the test suite and the layout harness use, which keeps their
/// fixtures readable — a test that says `.paragraph("Hello", style: "Normal")`
/// is a test a reader can check against the assertion on the next line.
public struct DocumentBuilder {

    private var model: DocumentModel
    private var pendingBlocks: [Block]
    /// The section currently being accumulated.
    private var currentProperties: SectionProperties
    private var hasOpenSection: Bool

    public init(
        regionUsesLetter: Bool = true,
        author: String = "Galley",
        styles: StyleTable? = nil,
        settings: DocumentSettings? = nil
    ) {
        let base = DocumentModel.blank(regionUsesLetter: regionUsesLetter, author: author)
        var model = base
        if let styles { model.styles = styles }
        if let settings { model.settings = settings }
        // `blank()` seeds one empty paragraph; a builder starts from nothing and
        // adds what it is told to.
        model.sections = []
        self.model = model
        self.pendingBlocks = []
        self.currentProperties = base.sections.first?.properties ?? SectionProperties()
        self.hasOpenSection = false
    }

    // MARK: Sections

    /// Starts a new section. The previous one, if any, is closed and committed.
    ///
    /// A section break is how page setup changes mid-document, so the builder has
    /// to be able to express one; without it, every multi-page-size fixture has
    /// to be assembled by hand.
    @discardableResult
    public mutating func section(
        properties: SectionProperties? = nil,
        start: SectionStart = .nextPage
    ) -> Int {
        closeSection()
        var resolved = properties ?? currentProperties
        resolved.start = start
        currentProperties = resolved
        hasOpenSection = true
        return model.sections.count
    }

    /// Sets the properties of the section currently being built.
    public mutating func setSectionProperties(_ properties: SectionProperties) {
        currentProperties = properties
        hasOpenSection = true
    }

    /// Sets the page size and margins of the current section.
    ///
    /// `textAreaWidth` is the more useful knob for tests: it names the quantity
    /// the line breaker actually consumes, so a test can say "60 points wide"
    /// rather than back-computing margins from a page size.
    public mutating func setPageSize(_ pageSize: PageSize, margins: PageMargins = .normal) {
        var properties = currentProperties
        properties.pageSize = pageSize
        properties.margins = margins
        currentProperties = properties
        hasOpenSection = true
    }

    /// Chooses margins so the text area comes out at exactly `widthPoints`.
    @discardableResult
    public mutating func setTextAreaWidth(_ widthPoints: Double, pageSize: PageSize = .letter) -> PageMargins {
        let available = pageSize.width.points
        let each = max(0, (available - widthPoints) / 2)
        let margins = PageMargins(
            top: Twip(1440),
            right: Twip(points: each),
            bottom: Twip(1440),
            left: Twip(points: each)
        )
        setPageSize(pageSize, margins: margins)
        return margins
    }

    private mutating func closeSection() {
        guard hasOpenSection || !pendingBlocks.isEmpty else { return }
        let id = model.nodeIDs.makeID()
        model.sections.append(Section(id: id, properties: currentProperties, blocks: pendingBlocks))
        pendingBlocks = []
        hasOpenSection = false
    }

    // MARK: Blocks

    /// Appends a paragraph of plain text in one run.
    @discardableResult
    public mutating func paragraph(
        _ text: String,
        style: String? = "Normal",
        runProperties: RunProperties = .empty,
        paragraphProperties: ParagraphProperties = .empty
    ) -> NodeID {
        var properties = paragraphProperties
        if let style { properties.styleID = style }
        let paragraphID = model.nodeIDs.makeID()
        let runID = model.nodeIDs.makeID()
        let runs: [Run] = text.isEmpty ? [] : [Run(id: runID, content: .text(text), properties: runProperties)]
        pendingBlocks.append(.paragraph(Paragraph(id: paragraphID, properties: properties, runs: runs)))
        hasOpenSection = true
        return paragraphID
    }

    /// Appends a paragraph built from several differently formatted runs.
    @discardableResult
    public mutating func paragraph(
        runs: [(text: String, properties: RunProperties)],
        style: String? = "Normal",
        paragraphProperties: ParagraphProperties = .empty
    ) -> NodeID {
        var properties = paragraphProperties
        if let style { properties.styleID = style }
        let paragraphID = model.nodeIDs.makeID()
        var built: [Run] = []
        for entry in runs {
            guard !entry.text.isEmpty else { continue }
            built.append(Run(id: model.nodeIDs.makeID(), content: .text(entry.text), properties: entry.properties))
        }
        pendingBlocks.append(.paragraph(Paragraph(id: paragraphID, properties: properties, runs: built)))
        hasOpenSection = true
        return paragraphID
    }

    /// Appends a heading using one of Word's nine built-in heading styles.
    @discardableResult
    public mutating func heading(_ text: String, level: Int = 1) -> NodeID {
        let clamped = max(1, min(9, level))
        return paragraph(text, style: "Heading\(clamped)")
    }

    /// Appends an empty paragraph — the thing a blank line in a document is.
    @discardableResult
    public mutating func emptyParagraph(style: String? = "Normal") -> NodeID {
        paragraph("", style: style)
    }

    /// Appends a paragraph containing only a manual page break.
    @discardableResult
    public mutating func pageBreak() -> NodeID {
        let paragraphID = model.nodeIDs.makeID()
        let runID = model.nodeIDs.makeID()
        pendingBlocks.append(.paragraph(Paragraph(
            id: paragraphID,
            properties: ParagraphProperties(styleID: "Normal"),
            runs: [Run(id: runID, content: .pageBreak)]
        )))
        hasOpenSection = true
        return paragraphID
    }

    /// Appends a paragraph whose text is followed by a manual line break.
    @discardableResult
    public mutating func paragraphWithLineBreak(_ text: String, style: String? = "Normal") -> NodeID {
        let paragraphID = model.nodeIDs.makeID()
        pendingBlocks.append(.paragraph(Paragraph(
            id: paragraphID,
            properties: ParagraphProperties(styleID: style),
            runs: [
                Run(id: model.nodeIDs.makeID(), content: .text(text)),
                Run(id: model.nodeIDs.makeID(), content: .lineBreak),
            ]
        )))
        hasOpenSection = true
        return paragraphID
    }

    /// Appends a block verbatim, for fixtures exercising unmodelled elements.
    public mutating func append(block: Block) {
        pendingBlocks.append(block)
        hasOpenSection = true
    }

    // MARK: Finishing

    /// Commits the accumulated sections and returns the document.
    ///
    /// Consumes the builder, because a builder that could keep appending after
    /// `build()` would leave two copies of the same node ids in circulation.
    public mutating func build() -> DocumentModel {
        closeSection()
        if model.sections.isEmpty {
            // A document with no sections has no page setup at all, which is not
            // a state Word can express. Emit one empty section rather than a
            // model the paginator would have to defend against.
            let id = model.nodeIDs.makeID()
            model.sections.append(Section(id: id, properties: currentProperties, blocks: []))
        }
        return model
    }

    /// The document, without consuming the builder.
    public var snapshot: DocumentModel {
        var copy = self
        return copy.build()
    }

    /// The next node id that would be allocated. Useful for assertions that need
    /// to name a paragraph the builder created.
    public var nextNodeID: NodeID { model.nodeIDs.peekNext() }
}
