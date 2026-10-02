import Foundation

// MARK: - DocumentModel

/// The whole document.
///
/// A value type. Every edit goes through a `Command` that produces a new
/// `DocumentModel`, which gives undo/redo, AI review previews, and cross-thread
/// layout a single mechanism instead of three. Swift's copy-on-write keeps this
/// cheap: mutating one paragraph in a 300-page document copies the top-level
/// array spine, not the document.
public struct DocumentModel: Hashable, Sendable {

    // MARK: Package-level parts

    /// `settings.xml`
    public var settings: DocumentSettings
    /// `styles.xml`
    public var styles: StyleTable
    /// `numbering.xml`
    public var numbering: NumberingTable
    /// `theme1.xml`
    public var theme: ThemePalette
    /// `fontTable.xml`
    public var fonts: FontTable
    /// `docProps/core.xml`
    public var coreProperties: CoreProperties
    /// `docProps/app.xml`
    public var appProperties: AppProperties
    /// `docProps/custom.xml`
    public var customProperties: [CustomProperty]

    // MARK: Body

    /// The body's sections, in order. A new blank document has exactly one.
    public var sections: [Section]

    /// `footnotes.xml`. Includes the two special separator notes Word always writes.
    public var footnotes: NoteCollection
    /// `endnotes.xml`
    public var endnotes: NoteCollection
    /// `comments.xml` plus `commentsExtended.xml`
    public var comments: CommentCollection

    // MARK: Provenance and protection

    /// What this document was loaded from. `nil` for a document created here.
    /// Drives the byte-preserving save in `OOXMLKit`.
    public var origin: DocumentOrigin?
    /// Parts of the original package we did not understand, kept for re-emission.
    public var preservedParts: [PreservedPart]
    /// `w:documentProtection`
    public var protection: DocumentProtection?
    /// `glossaryDocument.xml`
    public var glossary: BuildingBlocks?

    /// Hands out `NodeID`s. Kept on the document so ids stay unique across the
    /// whole tree and so the high-water mark can be persisted.
    public var nodeIDs: NodeIDState

    public init(
        settings: DocumentSettings = .init(),
        styles: StyleTable = .init(),
        numbering: NumberingTable = .init(),
        theme: ThemePalette = .officeDefault,
        fonts: FontTable = .init(),
        coreProperties: CoreProperties = .init(),
        appProperties: AppProperties = .init(),
        customProperties: [CustomProperty] = [],
        sections: [Section] = [],
        footnotes: NoteCollection = .empty,
        endnotes: NoteCollection = .empty,
        comments: CommentCollection = .init(),
        origin: DocumentOrigin? = nil,
        preservedParts: [PreservedPart] = [],
        protection: DocumentProtection? = nil,
        glossary: BuildingBlocks? = nil,
        nodeIDs: NodeIDState = .init()
    ) {
        self.settings = settings
        self.styles = styles
        self.numbering = numbering
        self.theme = theme
        self.fonts = fonts
        self.coreProperties = coreProperties
        self.appProperties = appProperties
        self.customProperties = customProperties
        self.sections = sections.isEmpty ? [Section(id: nodeIDs.peekNext(), properties: .init())] : sections
        self.footnotes = footnotes
        self.endnotes = endnotes
        self.comments = comments
        self.origin = origin
        self.preservedParts = preservedParts
        self.protection = protection
        self.glossary = glossary
        self.nodeIDs = nodeIDs
    }

    /// A brand-new blank document, the way Word makes one: Letter or A4
    /// depending on locale, Normal margins, Calibri 11, one empty paragraph.
    public static func blank(
        regionUsesLetter: Bool = true,
        author: String = "Galley"
    ) -> DocumentModel {
        var nodeIDs = NodeIDState()
        let sectionID = nodeIDs.makeID()
        let paragraphID = nodeIDs.makeID()
        let runID = nodeIDs.makeID()

        let section = Section(
            id: sectionID,
            properties: SectionProperties(
                pageSize: .systemDefault(regionUsesLetter: regionUsesLetter),
                margins: .normal
            ),
            blocks: [
                .paragraph(
                    Paragraph(
                        id: paragraphID,
                        properties: ParagraphProperties(styleID: "Normal"),
                        runs: [Run(id: runID, content: .text(""))]
                    )
                )
            ]
        )

        var styles = StyleTable.wordDefaults
        styles.registerLatentDefaults()

        var settings = DocumentSettings()
        settings.defaultTabStop = Twip(720)
        settings.evenAndOddHeaders = false
        settings.trackChanges = false

        return DocumentModel(
            settings: settings,
            styles: styles,
            theme: .officeDefault,
            coreProperties: CoreProperties(lastModifiedBy: author, revision: 1),
            sections: [section],
            nodeIDs: nodeIDs
        )
    }

    // MARK: - Body access

    /// Every top-level block in the body, across all sections, in order.
    public var blocks: [Block] {
        return sections.flatMap { $0.blocks }
    }

    public var paragraphs: [Paragraph] {
        return blocks.compactMap { $0.paragraph }
    }

    /// The section that a block belongs to.
    public func section(containing nodeID: NodeID) -> Section? {
        return sections.first { section in
            return section.blocks.contains { $0.id == nodeID }
        }
    }

    /// Finds a paragraph anywhere in the tree — body, tables, text boxes, notes.
    public func paragraph(withID nodeID: NodeID) -> Paragraph? {
        return ParagraphSearch.find(nodeID, in: self)
    }

    /// Replaces a paragraph anywhere in the tree. Returns `false` if not found.
    ///
    /// A single mutation path for every container means AI mutations, undo and
    /// Writing Tools all work identically whether the target is body text, a
    /// table cell or a footnote.
    @discardableResult
    public mutating func replaceParagraph(_ replacement: Paragraph) -> Bool {
        for index in sections.indices {
            if replaceParagraph(replacement, in: &sections[index].blocks) {
                return true
            }
        }
        for index in footnotes.notes.indices {
            if replaceParagraph(replacement, in: &footnotes.notes[index].blocks) { return true }
        }
        for index in endnotes.notes.indices {
            if replaceParagraph(replacement, in: &endnotes.notes[index].blocks) { return true }
        }
        return false
    }

    private mutating func replaceParagraph(_ replacement: Paragraph, in blocks: inout [Block]) -> Bool {
        for index in blocks.indices {
            switch blocks[index] {
            case .paragraph(let paragraph):
                if paragraph.id == replacement.id {
                    blocks[index] = .paragraph(replacement)
                    return true
                }
            case .table(var table):
                var changed = false
                for rowIndex in table.rows.indices {
                    for cellIndex in table.rows[rowIndex].cells.indices {
                        if replaceParagraph(replacement, in: &table.rows[rowIndex].cells[cellIndex].blocks) {
                            changed = true
                        }
                    }
                }
                if changed {
                    blocks[index] = .table(table)
                    return true
                }
            case .contentControl(var control):
                if replaceParagraph(replacement, in: &control.blocks) {
                    blocks[index] = .contentControl(control)
                    return true
                }
            case .math, .preserved:
                continue
            }
        }
        return false
    }

    // MARK: - Counts

    /// The statistics Word shows in the status bar and caches in `docProps/app.xml`.
    ///
    /// `markup` matters: under "No Markup" deleted text is not counted, and
    /// under "Original" inserted text is not. Word counts footnotes and text
    /// boxes separately from the body and reports both.
    public func statistics(markup: RevisionMarkup = .allMarkup, includeTextboxes: Bool = false) -> DocumentStatistics {
        var words = 0
        var characters = 0
        var charactersExcludingSpaces = 0
        var paragraphCount = 0
        var lines = 0

        func absorb(_ text: String, isParagraph: Bool) {
            characters += text.count
            charactersExcludingSpaces += text.filter { !$0.isWhitespace }.count
            words += Self.countWords(in: text)
            if isParagraph { paragraphCount += 1 }
        }

        for section in sections {
            for block in section.blocks {
                switch block {
                case .paragraph(let paragraph):
                    absorb(paragraph.plainText(markup: markup), isParagraph: true)
                case .table, .contentControl, .math, .preserved:
                    absorb(block.plainText(markup: markup), isParagraph: false)
                }
            }
            for headerFooter in section.headersAndFooters.values where includeTextboxes {
                absorb(headerFooter.plainText(markup: markup), isParagraph: false)
            }
        }
        for note in footnotes.notes where !note.isSeparator {
            for block in note.blocks {
                absorb(block.plainText(markup: markup), isParagraph: block.isParagraph)
            }
        }
        for note in endnotes.notes where !note.isSeparator {
            for block in note.blocks {
                absorb(block.plainText(markup: markup), isParagraph: block.isParagraph)
            }
        }

        // Line count is a layout result, not a model property. It is filled in
        // by the paginator once a LayoutSnapshot exists; 0 here is honest.
        lines = 0

        return DocumentStatistics(
            pages: 0,
            words: words,
            characters: characters,
            charactersExcludingSpaces: charactersExcludingSpaces,
            paragraphs: paragraphCount,
            lines: lines,
            footnotes: footnotes.notes.filter { !$0.isSeparator }.count,
            endnotes: endnotes.notes.filter { !$0.isSeparator }.count
        )
    }

    /// Word's word-splitting rule: whitespace-delimited, but a run of
    /// punctuation between two word characters does not split them
    /// ("state-of-the-art" is one word) and an em dash does ("word—word" is two).
    ///
    /// This is worth getting right because the status-bar count is the most
    /// visible number in a word processor and a mismatch with Word is noticed
    /// immediately.
    static func countWords(in text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if character.isWhitespace || character.isNewline {
                inWord = false
                continue
            }
            if character.isLetter || character.isNumber {
                if !inWord { count += 1 }
                inWord = true
                continue
            }
            // Punctuation and symbols: an em/en dash ends a word, a hyphen or
            // apostrophe inside a word does not.
            if character == "\u{2014}" || character == "\u{2013}" {
                inWord = false
            }
        }
        return count
    }
}

// MARK: - Supporting types

/// `NodeID` allocation state, persisted so ids are stable across a save.
public struct NodeIDState: Hashable, Sendable {

    public var highWaterMark: UInt64

    public init(highWaterMark: UInt64 = 0) {
        self.highWaterMark = highWaterMark
    }

    public mutating func makeID() -> NodeID {
        highWaterMark += 1
        return NodeID(highWaterMark)
    }

    /// The next id without consuming it — for initialisers that need a section
    /// id before the model exists.
    public func peekNext() -> NodeID {
        return NodeID(highWaterMark + 1)
    }

    public mutating func reserve(upTo observed: UInt64) {
        if observed > highWaterMark { highWaterMark = observed }
    }
}

public struct DocumentStatistics: Hashable, Sendable {
    public var pages: Int
    public var words: Int
    public var characters: Int
    public var charactersExcludingSpaces: Int
    public var paragraphs: Int
    public var lines: Int
    public var footnotes: Int
    public var endnotes: Int

    public init(
        pages: Int, words: Int, characters: Int, charactersExcludingSpaces: Int,
        paragraphs: Int, lines: Int, footnotes: Int, endnotes: Int
    ) {
        self.pages = pages
        self.words = words
        self.characters = characters
        self.charactersExcludingSpaces = charactersExcludingSpaces
        self.paragraphs = paragraphs
        self.lines = lines
        self.footnotes = footnotes
        self.endnotes = endnotes
    }
}

/// What the document was loaded from.
///
/// The original archive is never mutated. It is kept on disk under this hash so
/// that a save can splice untouched bytes straight back out of it.
public struct DocumentOrigin: Hashable, Sendable {

    /// SHA-256 of the original file, hex-encoded.
    public var sourceHash: String
    /// Where the app stashed the pristine copy.
    public var archivePath: String
    /// The original file's own location, for "Revert to Saved".
    public var originalURL: String
    /// Byte length of the original file.
    public var byteLength: Int
    /// When we loaded it.
    public var loadedAt: Date

    public init(
        sourceHash: String,
        archivePath: String,
        originalURL: String,
        byteLength: Int,
        loadedAt: Date
    ) {
        self.sourceHash = sourceHash
        self.archivePath = archivePath
        self.originalURL = originalURL
        self.byteLength = byteLength
        self.loadedAt = loadedAt
    }
}

// MARK: - DocumentSettings

/// `settings.xml`.
///
/// Word writes roughly eighty settings here and most of them change behaviour in
/// ways users can see. We model the ones that affect layout and editing; the
/// rest are preserved verbatim by `OOXMLKit`.
public struct DocumentSettings: Hashable, Sendable {

    /// `w:defaultTabStop`, in twips. Word's default is 720 (0.5″).
    public var defaultTabStop: Twip
    /// `w:evenAndOddHeaders`
    public var evenAndOddHeaders: Bool
    /// `w:trackChanges`
    public var trackChanges: Bool
    /// `w:autoHyphenation`
    public var autoHyphenation: Bool
    /// `w:hyphenationZone`, in twips.
    public var hyphenationZone: Twip
    /// `w:consecutiveHyphenLimit`
    public var consecutiveHyphenLimit: Int32?
    /// `w:doNotHyphenate`
    public var suppressHyphenation: Bool
    /// `w:characterSpacingControl` — how Word compresses punctuation.
    public var characterSpacingControl: CharacterSpacingControl
    /// `w:compat` — the compatibility flags. Each one changes layout behaviour
    /// and they are read from the incoming file, never invented. Ignoring these
    /// is a major source of round-trip drift.
    public var compatibility: CompatibilitySettings
    /// `w:proofState`
    public var proofingState: ProofingState?
    /// `w:zoom`
    public var zoomPercent: Int32
    /// `w:doNotTrackMoves` / `w:doNotTrackFormatting`
    public var doNotTrackMoves: Bool
    public var doNotTrackFormatting: Bool
    /// `w:decimalSymbol` / `w:listSeparator` — locale-dependent and used by fields.
    public var decimalSymbol: String
    public var listSeparator: String
    /// `w:themeFontLang`
    public var themeFontLanguage: LanguageReference
    /// `w:clrSchemeMapping` — remaps theme colour slots. Rare, but when present
    /// it changes every themed colour in the document.
    public var colorSchemeMapping: [ThemeColorSlot: ThemeColorSlot]?
    /// `w:attachedTemplate` — the document's template.
    public var attachedTemplateRelationshipID: String?
    /// Settings we do not model, kept for verbatim re-emission.
    public var preservedSettings: [PreservedElement]

    public init(
        defaultTabStop: Twip = Twip(720),
        evenAndOddHeaders: Bool = false,
        trackChanges: Bool = false,
        autoHyphenation: Bool = false,
        hyphenationZone: Twip = Twip(720),
        consecutiveHyphenLimit: Int32? = nil,
        suppressHyphenation: Bool = false,
        characterSpacingControl: CharacterSpacingControl = .doNotCompress,
        compatibility: CompatibilitySettings = .init(),
        proofingState: ProofingState? = nil,
        zoomPercent: Int32 = 100,
        doNotTrackMoves: Bool = false,
        doNotTrackFormatting: Bool = false,
        decimalSymbol: String = ".",
        listSeparator: String = ",",
        themeFontLanguage: LanguageReference = LanguageReference(value: "en-US"),
        colorSchemeMapping: [ThemeColorSlot: ThemeColorSlot]? = nil,
        attachedTemplateRelationshipID: String? = nil,
        preservedSettings: [PreservedElement] = []
    ) {
        self.defaultTabStop = defaultTabStop
        self.evenAndOddHeaders = evenAndOddHeaders
        self.trackChanges = trackChanges
        self.autoHyphenation = autoHyphenation
        self.hyphenationZone = hyphenationZone
        self.consecutiveHyphenLimit = consecutiveHyphenLimit
        self.suppressHyphenation = suppressHyphenation
        self.characterSpacingControl = characterSpacingControl
        self.compatibility = compatibility
        self.proofingState = proofingState
        self.zoomPercent = zoomPercent
        self.doNotTrackMoves = doNotTrackMoves
        self.doNotTrackFormatting = doNotTrackFormatting
        self.decimalSymbol = decimalSymbol
        self.listSeparator = listSeparator
        self.themeFontLanguage = themeFontLanguage
        self.colorSchemeMapping = colorSchemeMapping
        self.attachedTemplateRelationshipID = attachedTemplateRelationshipID
        self.preservedSettings = preservedSettings
    }
}

public enum CharacterSpacingControl: String, Hashable, Sendable {
    case doNotCompress
    case compressPunctuation
    case compressPunctuationAndJapaneseKana = "compressPunctuationAndJapaneseKana"
}

public struct ProofingState: Hashable, Sendable {
    public var spelling: String?
    public var grammar: String?
    public init(spelling: String? = nil, grammar: String? = nil) {
        self.spelling = spelling
        self.grammar = grammar
    }
}

/// `w:compat`.
///
/// Roughly forty flags, each of which changes layout or editing behaviour for
/// documents written by older Word versions. The important property is not that
/// we implement all of them — it is that we **read them from the incoming file,
/// honour the ones that matter, and write them back unchanged**. Inventing
/// defaults here is what makes a document reflow after a round trip.
public struct CompatibilitySettings: Hashable, Sendable {

    /// `w:compatSetting w:name="compatibilityMode"` — 11, 12, 14, 15 or 16.
    /// This single value gates most of the others; Word 365 writes 15.
    public var compatibilityMode: Int32

    public var spaceForUnderline: Bool
    public var wrapTrailingSpaces: Bool
    public var noTabStopForHangingIndent: Bool
    public var noLeading: Bool
    public var doNotExpandShiftReturn: Bool
    public var balanceSingleByteDoubleByteWidth: Bool
    public var noColumnBalance: Bool
    public var balanceSingleByteDoubleByte: Bool
    public var useWord2002TableStyleRules: Bool
    public var growAutofit: Bool
    public var useFELayout: Bool
    public var useNormalStyleForList: Bool
    public var doNotUseIndentAsNumberingTabStop: Bool
    public var useAltKinsokuLineBreakRules: Bool
    public var allowSpaceOfSameStyle: Bool
    public var doNotSuppressIndentation: Bool
    public var doNotAutofitConstrainedTables: Bool
    public var autofitToFirstFixedWidthCell: Bool
    public var displayHangulFixedWidth: Bool
    public var splitPgBreakAndParaMark: Bool
    public var doNotVerticallyAlignCellWithSp: Bool
    public var doNotBreakConstrainedForcedTable: Bool
    public var doNotVerticallyAlignInTxbx: Bool
    public var doNotUseHTMLParagraphAutoSpacing: Bool
    public var layoutRawTableWidth: Bool
    public var layoutTableCellsApart: Bool
    public var useWord2013TrackBottomHyphenation: Bool
    public var overrideTableStyleFontSizeAndJustification: Bool
    public var enableOpenTypeKerning: Bool
    public var doNotFlipMirrorIndents: Bool
    public var differentiateOddAndEvenHeaderFooter: Bool

    /// Flags we do not model, kept verbatim.
    public var preservedFlags: [PreservedElement]

    public init(
        compatibilityMode: Int32 = 15,
        spaceForUnderline: Bool = false,
        wrapTrailingSpaces: Bool = false,
        noTabStopForHangingIndent: Bool = false,
        noLeading: Bool = false,
        doNotExpandShiftReturn: Bool = false,
        balanceSingleByteDoubleByteWidth: Bool = false,
        noColumnBalance: Bool = false,
        balanceSingleByteDoubleByte: Bool = false,
        useWord2002TableStyleRules: Bool = false,
        growAutofit: Bool = false,
        useFELayout: Bool = false,
        useNormalStyleForList: Bool = false,
        doNotUseIndentAsNumberingTabStop: Bool = false,
        useAltKinsokuLineBreakRules: Bool = false,
        allowSpaceOfSameStyle: Bool = false,
        doNotSuppressIndentation: Bool = false,
        doNotAutofitConstrainedTables: Bool = false,
        autofitToFirstFixedWidthCell: Bool = false,
        displayHangulFixedWidth: Bool = false,
        splitPgBreakAndParaMark: Bool = false,
        doNotVerticallyAlignCellWithSp: Bool = false,
        doNotBreakConstrainedForcedTable: Bool = false,
        doNotVerticallyAlignInTxbx: Bool = false,
        doNotUseHTMLParagraphAutoSpacing: Bool = false,
        layoutRawTableWidth: Bool = false,
        layoutTableCellsApart: Bool = false,
        useWord2013TrackBottomHyphenation: Bool = false,
        overrideTableStyleFontSizeAndJustification: Bool = false,
        enableOpenTypeKerning: Bool = false,
        doNotFlipMirrorIndents: Bool = false,
        differentiateOddAndEvenHeaderFooter: Bool = false,
        preservedFlags: [PreservedElement] = []
    ) {
        self.compatibilityMode = compatibilityMode
        self.spaceForUnderline = spaceForUnderline
        self.wrapTrailingSpaces = wrapTrailingSpaces
        self.noTabStopForHangingIndent = noTabStopForHangingIndent
        self.noLeading = noLeading
        self.doNotExpandShiftReturn = doNotExpandShiftReturn
        self.balanceSingleByteDoubleByteWidth = balanceSingleByteDoubleByteWidth
        self.noColumnBalance = noColumnBalance
        self.balanceSingleByteDoubleByte = balanceSingleByteDoubleByte
        self.useWord2002TableStyleRules = useWord2002TableStyleRules
        self.growAutofit = growAutofit
        self.useFELayout = useFELayout
        self.useNormalStyleForList = useNormalStyleForList
        self.doNotUseIndentAsNumberingTabStop = doNotUseIndentAsNumberingTabStop
        self.useAltKinsokuLineBreakRules = useAltKinsokuLineBreakRules
        self.allowSpaceOfSameStyle = allowSpaceOfSameStyle
        self.doNotSuppressIndentation = doNotSuppressIndentation
        self.doNotAutofitConstrainedTables = doNotAutofitConstrainedTables
        self.autofitToFirstFixedWidthCell = autofitToFirstFixedWidthCell
        self.displayHangulFixedWidth = displayHangulFixedWidth
        self.splitPgBreakAndParaMark = splitPgBreakAndParaMark
        self.doNotVerticallyAlignCellWithSp = doNotVerticallyAlignCellWithSp
        self.doNotBreakConstrainedForcedTable = doNotBreakConstrainedForcedTable
        self.doNotVerticallyAlignInTxbx = doNotVerticallyAlignInTxbx
        self.doNotUseHTMLParagraphAutoSpacing = doNotUseHTMLParagraphAutoSpacing
        self.layoutRawTableWidth = layoutRawTableWidth
        self.layoutTableCellsApart = layoutTableCellsApart
        self.useWord2013TrackBottomHyphenation = useWord2013TrackBottomHyphenation
        self.overrideTableStyleFontSizeAndJustification = overrideTableStyleFontSizeAndJustification
        self.enableOpenTypeKerning = enableOpenTypeKerning
        self.doNotFlipMirrorIndents = doNotFlipMirrorIndents
        self.differentiateOddAndEvenHeaderFooter = differentiateOddAndEvenHeaderFooter
        self.preservedFlags = preservedFlags
    }
}

// MARK: - Styles

/// A single `w:style`.
public struct Style: Hashable, Sendable {

    public enum Kind: String, Hashable, Sendable {
        case paragraph
        case character
        case table
        case numbering
    }

    public var styleID: String
    public var kind: Kind
    /// `w:name w:val` — the user-visible name. Note that Word's built-in names
    /// are matched case-insensitively and localised in the UI but stored in
    /// English in the file.
    public var name: String
    /// `w:basedOn`
    public var basedOn: String?
    /// `w:next` — the style applied to the paragraph after this one.
    public var nextStyleID: String?
    /// `w:link` — the paired character style for a paragraph style, or vice versa.
    public var linkedStyleID: String?
    /// `w:uiPriority`
    public var uiPriority: Int32?
    /// `w:semiHidden` — hidden from the gallery but still applied.
    public var isSemiHidden: Bool
    /// `w:unhideWhenUsed`
    public var unhideWhenUsed: Bool
    /// `w:qFormat` — show in the Quick Style gallery.
    public var showInQuickGallery: Bool
    /// `w:default` — the fallback style for its kind.
    public var isDefaultForKind: Bool
    /// `w:locked`
    public var isLocked: Bool

    public var paragraphProperties: ParagraphProperties
    public var runProperties: RunProperties
    public var tableProperties: TableProperties?

    public init(
        styleID: String,
        kind: Kind,
        name: String,
        basedOn: String? = nil,
        nextStyleID: String? = nil,
        linkedStyleID: String? = nil,
        uiPriority: Int32? = nil,
        isSemiHidden: Bool = false,
        unhideWhenUsed: Bool = false,
        showInQuickGallery: Bool = false,
        isDefaultForKind: Bool = false,
        isLocked: Bool = false,
        paragraphProperties: ParagraphProperties = .empty,
        runProperties: RunProperties = .empty,
        tableProperties: TableProperties? = nil
    ) {
        self.styleID = styleID
        self.kind = kind
        self.name = name
        self.basedOn = basedOn
        self.nextStyleID = nextStyleID
        self.linkedStyleID = linkedStyleID
        self.uiPriority = uiPriority
        self.isSemiHidden = isSemiHidden
        self.unhideWhenUsed = unhideWhenUsed
        self.showInQuickGallery = showInQuickGallery
        self.isDefaultForKind = isDefaultForKind
        self.isLocked = isLocked
        self.paragraphProperties = paragraphProperties
        self.runProperties = runProperties
        self.tableProperties = tableProperties
    }
}

/// `styles.xml`.
public struct StyleTable: Hashable, Sendable {

    /// `w:docDefaults/w:rPrDefault/w:rPr`
    public var defaultRunProperties: RunProperties
    /// `w:docDefaults/w:pPrDefault/w:pPr`
    public var defaultParagraphProperties: ParagraphProperties

    public var styles: [String: Style]
    /// `w:latentStyles` — Word's built-in style names that appear in the UI even
    /// when the document does not define them.
    public var latentStyleDefaults: LatentStyleDefaults

    /// Insertion order, because the gallery is ordered by `w:uiPriority` then by
    /// definition order, and a dictionary alone loses the tiebreaker.
    public var declarationOrder: [String]

    public init(
        defaultRunProperties: RunProperties = .empty,
        defaultParagraphProperties: ParagraphProperties = .empty,
        styles: [String: Style] = [:],
        latentStyleDefaults: LatentStyleDefaults = .init(),
        declarationOrder: [String] = []
    ) {
        self.defaultRunProperties = defaultRunProperties
        self.defaultParagraphProperties = defaultParagraphProperties
        self.styles = styles
        self.latentStyleDefaults = latentStyleDefaults
        self.declarationOrder = declarationOrder
    }

    public mutating func insert(_ style: Style) {
        styles[style.styleID] = style
        if !declarationOrder.contains(style.styleID) {
            declarationOrder.append(style.styleID)
        }
    }

    public mutating func registerLatentDefaults() {
        latentStyleDefaults = LatentStyleDefaults.wordDefaults
    }

    /// The style marked `w:default` for a kind.
    public func defaultStyle(for kind: Style.Kind) -> Style? {
        return styles.values.first { $0.kind == kind && $0.isDefaultForKind }
    }

    /// Walks the `w:basedOn` chain and merges properties, base first.
    ///
    /// Cycle-safe: a malformed file can contain `A basedOn B basedOn A`, and
    /// Word tolerates it. So must we — an infinite loop on open is a hang, and a
    /// hang is worse than slightly wrong formatting.
    public func resolveChain(styleID: String) -> [Style] {
        var chain: [Style] = []
        var visited: Set<String> = []
        var current: String? = styleID
        while let id = current, !visited.contains(id) {
            visited.insert(id)
            guard let style = styles[id] else { break }
            chain.insert(style, at: 0)
            current = style.basedOn
        }
        return chain
    }

    /// Paragraph properties after the full style chain, excluding direct formatting.
    public func inheritedParagraphProperties(styleID: String?) -> ParagraphProperties {
        var result = defaultParagraphProperties
        guard let styleID else { return result }
        for style in resolveChain(styleID: styleID) where style.kind == .paragraph {
            result = result.merging(style.paragraphProperties)
        }
        return result
    }

    /// Run properties after the full style chain, excluding direct formatting.
    public func inheritedRunProperties(styleID: String?) -> RunProperties {
        var result = defaultRunProperties
        guard let styleID else { return result }
        for style in resolveChain(styleID: styleID) {
            // A paragraph style contributes its rPr; a linked character style
            // contributes too, and the character style wins on conflict.
            if style.kind == .paragraph || style.kind == .character {
                result = result.merging(style.runProperties)
            }
        }
        return result
    }

    /// The style set a brand-new document gets: Normal plus the nine built-in
    /// headings, Title, Subtitle, Quote, Intense Quote, List Paragraph and the
    /// two hyperlink character styles.
    ///
    /// The ids and names are OOXML facts — Word writes exactly these strings and
    /// a file that says `w:styleId="Heading1"` must open with our `Heading1`.
    /// The formatting values are the Office theme's, which are also facts about
    /// the default theme rather than Microsoft expression.
    public static let wordDefaults = StyleTable(
        defaultRunProperties: RunProperties(
            fonts: FontReference(ascii: "Calibri", hAnsi: "Calibri", eastAsia: nil, complexScript: nil, hint: nil),
            size: HalfPoint(22),
            complexScriptSize: HalfPoint(22),
            language: LanguageReference(value: "en-US", eastAsia: "en-US", bidi: "ar-SA")
        ),
        defaultParagraphProperties: ParagraphProperties(
            spacingAfter: Twip(160),
            lineSpacing: .multiple(twelfthsOfALine: 259)
        ),
        styles: StyleTable.builtinStyles,
        declarationOrder: Array(StyleTable.builtinStyles.keys).sorted()
    )

    static let builtinStyles: [String: Style] = {
        var result: [String: Style] = [:]

        result["Normal"] = Style(
            styleID: "Normal", kind: .paragraph, name: "Normal",
            uiPriority: 0, showInQuickGallery: true, isDefaultForKind: true
        )

        // Headings 1–9. Word's Office-theme sizes, in half-points.
        let headingSizes: [Int32] = [32, 26, 24, 24, 22, 22, 22, 22, 22]
        let headingSpacingBefore: [Twip] = [
            Twip(480), Twip(200), Twip(200), Twip(160), Twip(160),
            Twip(160), Twip(160), Twip(160), Twip(160),
        ]
        for level in 1...9 {
            let id = "Heading\(level)"
            let previous = level == 1 ? "Normal" : "Heading\(level - 1)"
            result[id] = Style(
                styleID: id, kind: .paragraph, name: "heading \(level)",
                basedOn: previous, nextStyleID: "Normal", linkedStyleID: "\(id)Char",
                uiPriority: Int32(9 * level), showInQuickGallery: true,
                paragraphProperties: ParagraphProperties(
                    spacingBefore: headingSpacingBefore[level - 1],
                    spacingAfter: Twip(0),
                    lineSpacing: .multiple(twelfthsOfALine: 259),
                    keepLinesTogether: true,
                    keepWithNext: true,
                    outlineLevel: OutlineLevel(rawValue: Int32(level - 1))
                ),
                runProperties: RunProperties(
                    fonts: FontReference(ascii: "Calibri Light", hAnsi: "Calibri Light"),
                    size: HalfPoint(headingSizes[level - 1]),
                    bold: level <= 3 ? nil : false,
                    color: DocumentColor.theme(.accent1)
                )
            )
            result["\(id)Char"] = Style(
                styleID: "\(id)Char", kind: .character, name: "\(id) Char",
                basedOn: nil, linkedStyleID: id, uiPriority: Int32(9 * level),
                isSemiHidden: true, unhideWhenUsed: true,
                runProperties: result[id]?.runProperties ?? .empty
            )
        }

        result["Title"] = Style(
            styleID: "Title", kind: .paragraph, name: "Title",
            basedOn: "Normal", nextStyleID: "Normal", linkedStyleID: "TitleChar",
            uiPriority: 10, showInQuickGallery: true,
            paragraphProperties: ParagraphProperties(
                spacingAfter: Twip(300),
                lineSpacing: .multiple(twelfthsOfALine: 240),
                borders: ParagraphBorders(bottom: BorderDefinition(style: .single, width: EighthOfAPoint(6), color: DocumentColor.theme(.text2), spacePoints: 4))
            ),
            runProperties: RunProperties(
                fonts: FontReference(ascii: "Calibri Light", hAnsi: "Calibri Light"),
                size: HalfPoint(56),
                color: DocumentColor.theme(.text2)
            )
        )

        result["Subtitle"] = Style(
            styleID: "Subtitle", kind: .paragraph, name: "Subtitle",
            basedOn: "Normal", nextStyleID: "Normal", linkedStyleID: "SubtitleChar",
            uiPriority: 11, showInQuickGallery: true,
            paragraphProperties: ParagraphProperties(spacingAfter: Twip(160), lineSpacing: .multiple(twelfthsOfALine: 240)),
            runProperties: RunProperties(size: HalfPoint(22), color: DocumentColor.theme(.text2))
        )

        result["Quote"] = Style(
            styleID: "Quote", kind: .paragraph, name: "Quote",
            basedOn: "Normal", nextStyleID: "Normal", linkedStyleID: "QuoteChar",
            uiPriority: 29, showInQuickGallery: true,
            paragraphProperties: ParagraphProperties(alignment: .center, spacingBefore: Twip(200), spacingAfter: Twip(160)),
            runProperties: RunProperties(italic: true, color: DocumentColor.theme(.text1))
        )

        result["IntenseQuote"] = Style(
            styleID: "IntenseQuote", kind: .paragraph, name: "Intense Quote",
            basedOn: "Normal", nextStyleID: "Normal", linkedStyleID: "IntenseQuoteChar",
            uiPriority: 30, showInQuickGallery: true,
            paragraphProperties: ParagraphProperties(
                alignment: .center,
                indentation: ParagraphIndentation(start: Twip(576), end: Twip(576)),
                spacingBefore: Twip(200), spacingAfter: Twip(160)
            ),
            runProperties: RunProperties(bold: true, italic: true, color: DocumentColor.theme(.accent1))
        )

        result["ListParagraph"] = Style(
            styleID: "ListParagraph", kind: .paragraph, name: "List Paragraph",
            basedOn: "Normal", uiPriority: 34,
            paragraphProperties: ParagraphProperties(
                indentation: ParagraphIndentation(start: Twip(720)),
                contextualSpacing: true
            )
        )

        result["Hyperlink"] = Style(
            styleID: "Hyperlink", kind: .character, name: "Hyperlink",
            uiPriority: 99, isSemiHidden: true, unhideWhenUsed: true,
            runProperties: RunProperties(underline: .single, color: DocumentColor.theme(.hyperlink))
        )

        result["FootnoteText"] = Style(
            styleID: "FootnoteText", kind: .paragraph, name: "footnote text",
            basedOn: "Normal", uiPriority: 99, isSemiHidden: true, unhideWhenUsed: true,
            paragraphProperties: ParagraphProperties(spacingAfter: Twip(0), lineSpacing: .multiple(twelfthsOfALine: 240)),
            runProperties: RunProperties(size: HalfPoint(20))
        )

        result["Caption"] = Style(
            styleID: "Caption", kind: .paragraph, name: "caption",
            basedOn: "Normal", nextStyleID: "Normal", uiPriority: 35,
            isSemiHidden: true, unhideWhenUsed: true,
            paragraphProperties: ParagraphProperties(spacingBefore: Twip(120), spacingAfter: Twip(0)),
            runProperties: RunProperties(size: HalfPoint(18), italic: true, color: DocumentColor.theme(.text2))
        )

        return result
    }()
}

/// `w:latentStyles`.
public struct LatentStyleDefaults: Hashable, Sendable {
    public var defaultPriority: Int32?
    public var semiHiddenByDefault: Bool
    public var unhideWhenUsedByDefault: Bool
    public var quickGalleryByDefault: Bool
    public var lockedByDefault: Bool
    public var count: Int32?
    public var exceptions: [String: LatentStyleException]

    public init(
        defaultPriority: Int32? = nil,
        semiHiddenByDefault: Bool = false,
        unhideWhenUsedByDefault: Bool = false,
        quickGalleryByDefault: Bool = false,
        lockedByDefault: Bool = false,
        count: Int32? = nil,
        exceptions: [String: LatentStyleException] = [:]
    ) {
        self.defaultPriority = defaultPriority
        self.semiHiddenByDefault = semiHiddenByDefault
        self.unhideWhenUsedByDefault = unhideWhenUsedByDefault
        self.quickGalleryByDefault = quickGalleryByDefault
        self.lockedByDefault = lockedByDefault
        self.count = count
        self.exceptions = exceptions
    }

    public static let wordDefaults = LatentStyleDefaults(
        defaultPriority: 99,
        semiHiddenByDefault: false,
        unhideWhenUsedByDefault: false,
        quickGalleryByDefault: false,
        lockedByDefault: false,
        count: 376
    )
}

public struct LatentStyleException: Hashable, Sendable {
    public var name: String
    public var uiPriority: Int32?
    public var isSemiHidden: Bool?
    public var unhideWhenUsed: Bool?
    public var showInQuickGallery: Bool?
    public var isLocked: Bool?

    public init(
        name: String,
        uiPriority: Int32? = nil,
        isSemiHidden: Bool? = nil,
        unhideWhenUsed: Bool? = nil,
        showInQuickGallery: Bool? = nil,
        isLocked: Bool? = nil
    ) {
        self.name = name
        self.uiPriority = uiPriority
        self.isSemiHidden = isSemiHidden
        self.unhideWhenUsed = unhideWhenUsed
        self.showInQuickGallery = showInQuickGallery
        self.isLocked = isLocked
    }
}

// MARK: - Numbering

/// `numbering.xml`.
///
/// Modelled as the two-level indirection Word actually uses: an
/// `AbstractNumbering` defines nine levels of formatting, and a concrete
/// `Numbering` binds a `numId` to an `abstractNumId` plus per-level overrides.
/// Multiple lists sharing one abstract definition is how Word implements
/// "continue numbering" across a document, and collapsing the two levels is how
/// implementations lose that.
public struct NumberingTable: Hashable, Sendable {

    public var abstractDefinitions: [Int32: AbstractNumbering]
    public var concrete: [Int32: Numbering]
    /// `w:numIdMacAtCleanup`
    public var macCleanupID: Int32?

    public init(
        abstractDefinitions: [Int32: AbstractNumbering] = [:],
        concrete: [Int32: Numbering] = [:],
        macCleanupID: Int32? = nil
    ) {
        self.abstractDefinitions = abstractDefinitions
        self.concrete = concrete
        self.macCleanupID = macCleanupID
    }

    public static let empty = NumberingTable()

    /// Resolves a `(numId, level)` pair to the effective level definition,
    /// applying the concrete definition's `w:lvlOverride` on top of the
    /// abstract one.
    public func resolve(numberID: Int32, level: Int32) -> NumberingLevel? {
        guard let concrete = concrete[numberID] else { return nil }
        guard let abstract = abstractDefinitions[concrete.abstractNumberID] else { return nil }
        if let override = concrete.overrides.first(where: { $0.level == level }) {
            if let startOverride = override.startOverride, override.definition == nil {
                var base = abstract.levels.first { $0.level == level } ?? NumberingLevel(level: level)
                base.startAt = startOverride
                return base
            }
            if let definition = override.definition { return definition }
        }
        return abstract.levels.first { $0.level == level }
    }
}

public struct AbstractNumbering: Hashable, Sendable {
    public var abstractNumberID: Int32
    /// `w:multiLevelType`
    public var multiLevelType: MultiLevelType
    /// `w:nsid` — Word uses this to decide whether two lists are "the same" list
    /// for continue/restart purposes. Dropping it silently merges lists.
    public var namespaceID: String?
    /// `w:tmpl`
    public var templateID: String?
    public var levels: [NumberingLevel]
    /// `w:styleLink` / `w:numStyleLink`
    public var styleLink: String?
    public var numberingStyleLink: String?

    public init(
        abstractNumberID: Int32,
        multiLevelType: MultiLevelType = .hybridMultilevel,
        namespaceID: String? = nil,
        templateID: String? = nil,
        levels: [NumberingLevel] = [],
        styleLink: String? = nil,
        numberingStyleLink: String? = nil
    ) {
        self.abstractNumberID = abstractNumberID
        self.multiLevelType = multiLevelType
        self.namespaceID = namespaceID
        self.templateID = templateID
        self.levels = levels
        self.styleLink = styleLink
        self.numberingStyleLink = numberingStyleLink
    }

    public enum MultiLevelType: String, Hashable, Sendable {
        case singleLevel
        case multilevel
        case hybridMultilevel
    }
}

public struct Numbering: Hashable, Sendable {
    public var numberID: Int32
    public var abstractNumberID: Int32
    public var overrides: [LevelOverride]

    public init(numberID: Int32, abstractNumberID: Int32, overrides: [LevelOverride] = []) {
        self.numberID = numberID
        self.abstractNumberID = abstractNumberID
        self.overrides = overrides
    }

    public struct LevelOverride: Hashable, Sendable {
        public var level: Int32
        public var definition: NumberingLevel?
        public var startOverride: Int32?

        public init(level: Int32, definition: NumberingLevel? = nil, startOverride: Int32? = nil) {
            self.level = level
            self.definition = definition
            self.startOverride = startOverride
        }
    }
}

/// One level of a list definition — `w:lvl`.
public struct NumberingLevel: Hashable, Sendable {

    /// `w:numFmt`
    public enum Format: String, Hashable, Sendable {
        case decimal
        case upperRoman = "upperRoman"
        case lowerRoman = "lowerRoman"
        case upperLetter = "upperLetter"
        case lowerLetter = "lowerLetter"
        case ordinal
        case cardinalText = "cardinalText"
        case ordinalText = "ordinalText"
        case bullet
        case none
        case decimalZero = "decimalZero"
        case japaneseCounting = "japaneseCounting"
        case chineseCounting = "chineseCounting"
        case ideographTraditional = "ideographTraditional"
        case custom = "custom"
    }

    /// `w:lvlText` — the display template, where `%1`…`%9` are level counters.
    public var level: Int32
    public var format: Format
    public var text: String
    /// `w:start`
    public var startAt: Int32
    /// `w:lvlJc`
    public var justification: ParagraphAlignment
    /// `w:pPr` applied to numbered paragraphs — the indent and tab that make the
    /// number and the text line up.
    public var paragraphProperties: ParagraphProperties
    /// `w:rPr` applied to the number itself.
    public var runProperties: RunProperties
    /// `w:suff` — what separates the number from the text.
    public var suffix: NumberSuffix
    /// `w:lvlRestart`
    public var restartAfterLevel: Int32?
    /// `w:isLgl` — legal numbering forces every level to decimal.
    public var isLegalNumbering: Bool
    /// `w:legacy` / `w:legacySpace` / `w:legacyIndent`
    public var useLegacyIndentation: Bool
    /// `w:pStyle` — binds this level to a paragraph style.
    public var boundStyleID: String?

    public init(
        level: Int32 = 0,
        format: Format = .decimal,
        text: String = "%1.",
        startAt: Int32 = 1,
        justification: ParagraphAlignment = .left,
        paragraphProperties: ParagraphProperties = .empty,
        runProperties: RunProperties = .empty,
        suffix: NumberSuffix = .tab,
        restartAfterLevel: Int32? = nil,
        isLegalNumbering: Bool = false,
        useLegacyIndentation: Bool = false,
        boundStyleID: String? = nil
    ) {
        self.level = level
        self.format = format
        self.text = text
        self.startAt = startAt
        self.justification = justification
        self.paragraphProperties = paragraphProperties
        self.runProperties = runProperties
        self.suffix = suffix
        self.restartAfterLevel = restartAfterLevel
        self.isLegalNumbering = isLegalNumbering
        self.useLegacyIndentation = useLegacyIndentation
        self.boundStyleID = boundStyleID
    }

    /// The bullet glyphs Word uses for its default three-level bullet list.
    /// These are Unicode code points in Symbol and Courier New — facts about the
    /// default numbering definition, not font files.
    public static let defaultBulletGlyphs: [String] = ["\u{F0B7}", "o", "\u{F0A7}"]

    public enum NumberSuffix: String, Hashable, Sendable {
        case tab
        case space
        case nothing
    }

    /// Renders a counter tuple into the label, expanding `%1`…`%9`.
    ///
    /// `counters` is indexed by level (0-based). This is shared with the field
    /// engine so that a `LISTNUM` field and a rendered list agree.
    public func label(counters: [Int32]) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            guard let digit = iterator.next(), let levelIndex = digit.wholeNumberValue, levelIndex >= 1 else {
                result.append("%")
                continue
            }
            let counterIndex = levelIndex - 1
            guard counterIndex < counters.count else {
                result.append("%\(digit)")
                continue
            }
            result.append(Self.format(counter: counters[counterIndex], format: format, forLevel: Int32(counterIndex)))
        }
        return result
    }

    static func format(counter: Int32, format: Format, forLevel level: Int32) -> String {
        let value = Int(counter)
        switch format {
        case .decimal:
            return String(value)
        case .decimalZero:
            return String(format: "%02d", value)
        case .upperRoman:
            return PageNumbering.roman(value).uppercased()
        case .lowerRoman:
            return PageNumbering.roman(value)
        case .upperLetter:
            return PageNumbering.letter(value).uppercased()
        case .lowerLetter:
            return PageNumbering.letter(value)
        case .bullet, .none:
            return ""
        default:
            return String(value)
        }
    }
}

// MARK: - Notes

public struct NoteCollection: Hashable, Sendable {

    public var notes: [Note]

    public init(notes: [Note] = []) {
        self.notes = notes
    }

    /// Word always writes two special notes with ids 0 and 1: the separator and
    /// the continuation separator. They are not user content and must not be
    /// numbered, counted, or shown in the notes pane.
    public static let empty = NoteCollection(notes: [])

    public func note(withID id: NodeID) -> Note? {
        return notes.first { $0.id == id }
    }

    public var userNotes: [Note] {
        return notes.filter { !$0.isSeparator }
    }
}

public struct Note: Hashable, Sendable {
    /// `w:id` — Word uses -1 and 0 for the separator and continuation separator,
    /// so this is signed.
    public var footnoteIndex: Int32
    public var id: NodeID
    public var blocks: [Block]

    public init(footnoteIndex: Int32, id: NodeID, blocks: [Block] = []) {
        self.footnoteIndex = footnoteIndex
        self.id = id
        self.blocks = blocks
    }

    /// `w:type="separator"` (id -1) or `"continuationSeparator"` (id 0).
    ///
    /// Word reserves the non-positive ids for its own separator stories and
    /// numbers user notes from 1, so `<= 0` is the correct test — using `< 0`
    /// leaks the continuation separator into word counts and the notes pane.
    public var isSeparator: Bool { footnoteIndex <= 0 }

    public static func separator(id: NodeID) -> Note {
        return Note(footnoteIndex: -1, id: id)
    }

    public static func continuationSeparator(id: NodeID) -> Note {
        return Note(footnoteIndex: 0, id: id)
    }
}

// MARK: - Comments

public struct CommentCollection: Hashable, Sendable {

    public var comments: [Comment]

    public init(comments: [Comment] = []) {
        self.comments = comments
    }

    public func comment(withID id: NodeID) -> Comment? {
        return comments.first { $0.id == id }
    }

    public var unresolved: [Comment] { comments.filter { !$0.isResolved } }

    public mutating func insert(_ comment: Comment) {
        if let index = comments.firstIndex(where: { $0.id == comment.id }) {
            comments[index] = comment
        } else {
            comments.append(comment)
        }
    }

    public mutating func remove(id: NodeID) {
        comments.removeAll { $0.id == id }
    }
}

public struct Comment: Hashable, Sendable {
    public var id: NodeID
    /// `w:commentId` in the file, which is a separate small integer from our NodeID.
    public var commentID: Int32
    public var author: String
    public var authorInitials: String
    public var date: Date
    public var blocks: [Block]
    /// `w15:done` from `commentsExtended.xml`.
    public var isResolved: Bool
    /// `w15:paraIdParent` — threading.
    public var parentCommentID: Int32?
    /// `w15:people.xml` — the author's email, if known.
    public var authorEmail: String?

    public init(
        id: NodeID,
        commentID: Int32,
        author: String,
        authorInitials: String = "",
        date: Date = Date(timeIntervalSince1970: 0),
        blocks: [Block] = [],
        isResolved: Bool = false,
        parentCommentID: Int32? = nil,
        authorEmail: String? = nil
    ) {
        self.id = id
        self.commentID = commentID
        self.author = author
        self.authorInitials = authorInitials
        self.date = date
        self.blocks = blocks
        self.isResolved = isResolved
        self.parentCommentID = parentCommentID
        self.authorEmail = authorEmail
    }
}

// MARK: - Properties

/// `docProps/core.xml` — Dublin Core.
public struct CoreProperties: Hashable, Sendable {
    public var title: String?
    public var subject: String?
    public var creator: String?
    public var keywords: String?
    public var description: String?
    public var lastModifiedBy: String?
    public var revision: Int32
    public var created: Date?
    public var modified: Date?
    public var category: String?
    public var contentStatus: String?
    public var language: String?
    public var version: String?
    public var identifier: String?

    public init(
        title: String? = nil,
        subject: String? = nil,
        creator: String? = nil,
        keywords: String? = nil,
        description: String? = nil,
        lastModifiedBy: String? = nil,
        revision: Int32 = 1,
        created: Date? = nil,
        modified: Date? = nil,
        category: String? = nil,
        contentStatus: String? = nil,
        language: String? = nil,
        version: String? = nil,
        identifier: String? = nil
    ) {
        self.title = title
        self.subject = subject
        self.creator = creator
        self.keywords = keywords
        self.description = description
        self.lastModifiedBy = lastModifiedBy
        self.revision = revision
        self.created = created
        self.modified = modified
        self.category = category
        self.contentStatus = contentStatus
        self.language = language
        self.version = version
        self.identifier = identifier
    }
}

/// `docProps/app.xml`.
///
/// Word caches the statistics here. We recompute them rather than trusting the
/// cache, but we still write the part because some downstream tooling reads it
/// without opening the document.
public struct AppProperties: Hashable, Sendable {
    public var application: String
    public var appVersion: String
    public var template: String
    public var company: String?
    public var manager: String?
    public var totalTimeMinutes: Int32
    public var cachedPages: Int32
    public var cachedWords: Int32
    public var cachedCharacters: Int32
    public var cachedParagraphs: Int32
    public var cachedLines: Int32
    public var scaleCrop: Bool
    public var linksUpToDate: Bool
    public var sharedDocument: Bool
    public var hyperlinksChanged: Bool
    public var applicationVersion: String

    public init(
        application: String = "Galley",
        appVersion: String = "0.1",
        template: String = "Normal.dotm",
        company: String? = nil,
        manager: String? = nil,
        totalTimeMinutes: Int32 = 0,
        cachedPages: Int32 = 0,
        cachedWords: Int32 = 0,
        cachedCharacters: Int32 = 0,
        cachedParagraphs: Int32 = 0,
        cachedLines: Int32 = 0,
        scaleCrop: Bool = false,
        linksUpToDate: Bool = false,
        sharedDocument: Bool = false,
        hyperlinksChanged: Bool = false,
        applicationVersion: String = "16.0000"
    ) {
        self.application = application
        self.appVersion = appVersion
        self.template = template
        self.company = company
        self.manager = manager
        self.totalTimeMinutes = totalTimeMinutes
        self.cachedPages = cachedPages
        self.cachedWords = cachedWords
        self.cachedCharacters = cachedCharacters
        self.cachedParagraphs = cachedParagraphs
        self.cachedLines = cachedLines
        self.scaleCrop = scaleCrop
        self.linksUpToDate = linksUpToDate
        self.sharedDocument = sharedDocument
        self.hyperlinksChanged = hyperlinksChanged
        self.applicationVersion = applicationVersion
    }
}

public struct CustomProperty: Hashable, Sendable {
    public var formatID: String
    public var name: String
    public var value: CustomPropertyValue

    public init(formatID: String = "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}", name: String, value: CustomPropertyValue) {
        self.formatID = formatID
        self.name = name
        self.value = value
    }
}

public enum CustomPropertyValue: Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case date(Date)
}

/// `fontTable.xml`.
///
/// Word lists every font the document references, with charset, family and pitch
/// hints. We preserve it so that a document referencing a font we have never
/// seen still round-trips its font table intact.
public struct FontTable: Hashable, Sendable {
    public var entries: [FontTableEntry]

    public init(entries: [FontTableEntry] = []) {
        self.entries = entries
    }

    public mutating func register(family: String) {
        guard !family.isEmpty, !entries.contains(where: { $0.name == family }) else { return }
        entries.append(FontTableEntry(name: family))
    }
}

public struct FontTableEntry: Hashable, Sendable {
    public var name: String
    public var panose: String?
    public var charset: Int32?
    public var family: FontFamilyKind?
    public var pitch: FontPitch?
    public var signature: String?
    /// `w:embedRegular` etc. — we never embed fonts we do not have the right to
    /// embed, but we preserve embedding declarations already in a file.
    public var embeddedRelationshipIDs: [String: String]

    public init(
        name: String,
        panose: String? = nil,
        charset: Int32? = nil,
        family: FontFamilyKind? = nil,
        pitch: FontPitch? = nil,
        signature: String? = nil,
        embeddedRelationshipIDs: [String: String] = [:]
    ) {
        self.name = name
        self.panose = panose
        self.charset = charset
        self.family = family
        self.pitch = pitch
        self.signature = signature
        self.embeddedRelationshipIDs = embeddedRelationshipIDs
    }
}

public enum FontFamilyKind: String, Hashable, Sendable {
    case decorative
    case modern
    case roman
    case script
    case swiss
    case auto
}

public enum FontPitch: String, Hashable, Sendable {
    case fixed
    case variable
    case `default`
}

/// `w:documentProtection`.
public struct DocumentProtection: Hashable, Sendable {

    public enum Kind: String, Hashable, Sendable {
        case none
        case readOnly
        case comments
        case trackedChanges
        case fillingForms
    }

    public enum Enforcement: Hashable, Sendable {
        case notEnforced
        case enforced(passwordHash: PasswordHash?)
    }

    public var kind: Kind
    public var enforcement: Enforcement

    public init(kind: Kind = .none, enforcement: Enforcement = .notEnforced) {
        self.kind = kind
        self.enforcement = enforcement
    }

    public var isEnforced: Bool {
        if case .enforced = enforcement { return true }
        return false
    }
}

/// `w:hash`, `w:algorithm` and friends.
///
/// Word has written several protection-hash schemes over the years and files in
/// the wild use all of them. GenOffice's #1686 — "unprotecting a document that
/// uses the paired documentProtection form does nothing" — is what happens when
/// only one form is handled.
public struct PasswordHash: Hashable, Sendable {
    public var algorithm: String?
    public var hashValue: String?
    public var salt: String?
    public var spinCount: Int32?
    /// Legacy `w:cryptProviderType` / `w:cryptAlgorithmSid` form.
    public var legacyProvider: String?

    public init(
        algorithm: String? = nil,
        hashValue: String? = nil,
        salt: String? = nil,
        spinCount: Int32? = nil,
        legacyProvider: String? = nil
    ) {
        self.algorithm = algorithm
        self.hashValue = hashValue
        self.salt = salt
        self.spinCount = spinCount
        self.legacyProvider = legacyProvider
    }
}

/// `glossaryDocument.xml` — building blocks, AutoText and the cover-page gallery.
public struct BuildingBlocks: Hashable, Sendable {
    public var galleries: [BuildingBlockGallery]
    public var preservedXML: PreservedElement?

    public init(galleries: [BuildingBlockGallery] = [], preservedXML: PreservedElement? = nil) {
        self.galleries = galleries
        self.preservedXML = preservedXML
    }
}

public struct BuildingBlockGallery: Hashable, Sendable {
    public var name: String
    public var entries: [BuildingBlockEntry]

    public init(name: String, entries: [BuildingBlockEntry] = []) {
        self.name = name
        self.entries = entries
    }
}

public struct BuildingBlockEntry: Hashable, Sendable {
    public var name: String
    public var styleID: String?
    public var blocks: [Block]

    public init(name: String, styleID: String? = nil, blocks: [Block] = []) {
        self.name = name
        self.styleID = styleID
        self.blocks = blocks
    }
}

// MARK: - Search helper

/// Depth-first paragraph lookup across every container in the document.
///
/// Kept separate so that adding a new container type (text boxes are next) is a
/// one-place change rather than a hunt through every caller.
enum ParagraphSearch {

    static func find(_ id: NodeID, in document: DocumentModel) -> Paragraph? {
        for section in document.sections {
            if let found = find(id, in: section.blocks) { return found }
            for headerFooter in section.headersAndFooters.values {
                if let found = find(id, in: headerFooter.blocks) { return found }
            }
        }
        for note in document.footnotes.notes {
            if let found = find(id, in: note.blocks) { return found }
        }
        for note in document.endnotes.notes {
            if let found = find(id, in: note.blocks) { return found }
        }
        for comment in document.comments.comments {
            if let found = find(id, in: comment.blocks) { return found }
        }
        return nil
    }

    static func find(_ id: NodeID, in blocks: [Block]) -> Paragraph? {
        for block in blocks {
            switch block {
            case .paragraph(let paragraph):
                if paragraph.id == id { return paragraph }
            case .table(let table):
                for row in table.rows {
                    for cell in row.cells {
                        if let found = find(id, in: cell.blocks) { return found }
                    }
                }
            case .contentControl(let control):
                if let found = find(id, in: control.blocks) { return found }
            case .math, .preserved:
                continue
            }
        }
        return nil
    }
}
