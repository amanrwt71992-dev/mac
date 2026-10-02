import Foundation
import CoreKit

// MARK: - ResolvedParagraphStyle

/// A paragraph's properties after the whole style cascade has run.
///
/// Everything is a concrete number or a concrete enum by this point. That is the
/// deal that makes the line breaker pure: it never has to know what a style is,
/// only how wide the line may be and how the text is aligned.
public struct ResolvedParagraphStyle: Hashable, Sendable {

    public var styleID: String?
    public var alignment: ParagraphAlignment
    public var lineSpacing: LineSpacing
    public var spaceBefore: Double
    public var spaceAfter: Double
    public var indentStart: Double
    public var indentEnd: Double
    public var firstLineIndent: Double
    public var tabStops: [TabStop]
    public var rightToLeft: Bool

    public var keepLinesTogether: Bool
    public var keepWithNext: Bool
    public var pageBreakBefore: Bool
    public var widowControl: Bool
    public var contextualSpacing: Bool

    /// The style in effect for text with no direct formatting, i.e. the
    /// paragraph mark's own style. Used for an empty paragraph's height.
    public var markStyle: ResolvedRunStyle

    public init(
        styleID: String? = nil,
        alignment: ParagraphAlignment = .left,
        lineSpacing: LineSpacing = .single,
        spaceBefore: Double = 0,
        spaceAfter: Double = 0,
        indentStart: Double = 0,
        indentEnd: Double = 0,
        firstLineIndent: Double = 0,
        tabStops: [TabStop] = [],
        rightToLeft: Bool = false,
        keepLinesTogether: Bool = false,
        keepWithNext: Bool = false,
        pageBreakBefore: Bool = false,
        widowControl: Bool = true,
        contextualSpacing: Bool = false,
        markStyle: ResolvedRunStyle = .documentDefault
    ) {
        self.styleID = styleID
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.spaceBefore = spaceBefore
        self.spaceAfter = spaceAfter
        self.indentStart = indentStart
        self.indentEnd = indentEnd
        self.firstLineIndent = firstLineIndent
        self.tabStops = tabStops
        self.rightToLeft = rightToLeft
        self.keepLinesTogether = keepLinesTogether
        self.keepWithNext = keepWithNext
        self.pageBreakBefore = pageBreakBefore
        self.widowControl = widowControl
        self.contextualSpacing = contextualSpacing
        self.markStyle = markStyle
    }
}

// MARK: - StyleResolver

/// Runs the OOXML style cascade.
///
/// The order is normative and easy to get wrong, so it is written out here once:
///
/// 1. `w:docDefaults` (`rPrDefault`, then `pPrDefault`)
/// 2. the paragraph's style chain, base style first, walking `w:basedOn`
/// 3. a numbering style, if the paragraph is numbered
/// 4. the paragraph's direct `w:pPr`
/// 5. for runs: the paragraph's `w:rPr` in `w:pPr` (the paragraph mark style),
///    then the run's own direct `w:rPr`
///
/// `nil` means inherit and `.some(.none)` means explicitly off — conflating the
/// two is the single most common cause of "bold disappears when I save" bugs, so
/// `RunProperties` keeps them distinct all the way down.
public struct StyleResolver: Sendable {

    public var styles: StyleTable
    public var numbering: NumberingTable
    public var settings: DocumentSettings
    public var theme: ThemePalette
    public var defaults: ResolvedRunStyle

    public init(
        styles: StyleTable,
        numbering: NumberingTable = NumberingTable(),
        settings: DocumentSettings = DocumentSettings(),
        theme: ThemePalette = .officeDefault,
        defaults: ResolvedRunStyle = .documentDefault
    ) {
        self.styles = styles
        self.numbering = numbering
        self.settings = settings
        self.theme = theme
        self.defaults = defaults
    }

    /// Builds a resolver from a document.
    public init(document: DocumentModel) {
        self.init(
            styles: document.styles,
            numbering: document.numbering,
            settings: document.settings,
            theme: document.theme,
            defaults: ResolvedRunStyle(
                font: FontSpec(
                    family: document.styles.defaultRunProperties.fonts?.primaryFamily ?? "Calibri",
                    sizePoints: document.styles.defaultRunProperties.size?.points ?? 11
                ),
                language: document.styles.defaultRunProperties.language?.value
            )
        )
    }

    /// Folds the style chain into one set of paragraph properties.
    public func inheritedParagraphProperties(styleID: String?) -> ParagraphProperties {
        var result = styles.defaultParagraphProperties
        guard let styleID else { return result }
        for style in styles.resolveChain(styleID: styleID) {
            result = result.merging(style.paragraphProperties)
        }
        return result
    }

    /// Folds the style chain into one set of run properties.
    public func inheritedRunProperties(styleID: String?) -> RunProperties {
        var result = styles.defaultRunProperties
        guard let styleID else { return result }
        for style in styles.resolveChain(styleID: styleID) {
            // Only paragraph and character styles contribute run properties. A
            // table style's `w:rPr` applies to text in the table, which is
            // handled where the table is resolved, not here.
            guard style.kind == .paragraph || style.kind == .character else { continue }
            result = result.merging(style.runProperties)
        }
        return result
    }

    /// Resolves a paragraph's full style.
    ///
    /// `characterWidth` feeds the `Chars` indent forms, which are specified in
    /// hundredths of a character rather than in twips — a CJK feature whose
    /// resolution depends on the font size in effect.
    public func resolveParagraph(
        _ properties: ParagraphProperties,
        characterWidth: Double = 11
    ) -> ResolvedParagraphStyle {
        let inherited = inheritedParagraphProperties(styleID: properties.styleID)
        let merged = inherited.merging(properties)

        let inheritedRun = inheritedRunProperties(styleID: properties.styleID)
        let markRun = inheritedRun
            .merging(properties.paragraphMarkRunProperties ?? .empty)
        let markStyle = ResolvedRunStyle.resolve(markRun, defaults: defaults, theme: theme)

        let rightToLeft = merged.bidirectional ?? markStyle.rightToLeft
        let indentation = merged.indentation ?? .none

        let indentStart = indentation.leadingIndent(isRightToLeft: rightToLeft)?.points ?? 0
        let indentEnd = indentation.trailingIndent(isRightToLeft: rightToLeft)?.points ?? 0
        let firstLine = indentation.firstLineOffsetPoints(characterWidth: markStyle.font.sizePoints)

        return ResolvedParagraphStyle(
            styleID: properties.styleID,
            alignment: merged.alignment ?? (rightToLeft ? .right : .left),
            lineSpacing: merged.lineSpacing ?? .single,
            spaceBefore: merged.spacingBefore?.points ?? 0,
            spaceAfter: merged.spacingAfter?.points ?? 0,
            indentStart: indentStart,
            indentEnd: indentEnd,
            firstLineIndent: firstLine,
            tabStops: merged.tabs ?? [],
            rightToLeft: rightToLeft,
            keepLinesTogether: merged.keepLinesTogether ?? false,
            keepWithNext: merged.keepWithNext ?? false,
            pageBreakBefore: merged.pageBreakBefore ?? false,
            // Word's default is widow control ON; `w:widowControl w:val="0"` turns it off.
            widowControl: merged.widowControl ?? true,
            contextualSpacing: merged.contextualSpacing ?? false,
            markStyle: markStyle
        )
    }

    /// Resolves a single run's style.
    public func resolveRun(_ run: Run, paragraphStyleID: String?) -> ResolvedRunStyle {
        let inherited = inheritedRunProperties(styleID: paragraphStyleID)
        return ResolvedRunStyle.resolve(inherited: inherited, direct: run.properties, defaults: defaults, theme: theme)
    }

    /// Flattens a paragraph into the form the line breaker consumes.
    ///
    /// Text and tabs are concatenated into `segments`; forced breaks are carried
    /// separately in `breaks`, because `RunContent.plainText` collapses page and
    /// column breaks into one character and the breaker must tell them apart.
    public func flatten(
        paragraph: Paragraph,
        resolved: ResolvedParagraphStyle,
        availableWidth: Double,
        markup: RevisionMarkup = .allMarkup,
        hyphenation: HyphenationSettings? = nil
    ) -> ParagraphLayoutInput {
        var segments: [StyledText] = []
        var breaks: [BreakMarker] = []
        var buffer = ""
        var bufferStyle: ResolvedRunStyle?
        var offset = 0

        func flush() {
            guard !buffer.isEmpty, let style = bufferStyle else {
                buffer = ""
                return
            }
            segments.append(StyledText(text: buffer, style: style))
            buffer = ""
        }

        func appendText(_ text: String, run: Run) {
            guard !text.isEmpty else { return }
            let style = resolveRun(run, paragraphStyleID: paragraph.properties.styleID)
            // Consecutive runs with an identical resolved style are joined.
            // Fewer segments means fewer measure calls and fewer draw calls, and
            // it costs nothing because the style is already resolved.
            if bufferStyle == style {
                buffer += text
            } else {
                flush()
                buffer = text
                bufferStyle = style
            }
            offset += text.count
        }

        for run in paragraph.runs {
            guard run.isVisible(markup: markup) else { continue }

            // Forced breaks are consulted first, through the model's own
            // mapping, so that `w:br`, `w:cr` and `w:noBreakHyphen`-adjacent
            // content are all classified by one authority rather than two.
            if let kind = run.content.forcedBreak {
                flush()
                breaks.append(BreakMarker(characterOffset: offset, kind: kind))
                offset += 1
                continue
            }

            switch run.content {
            case .text(let text):
                appendText(text, run: run)
            case .tab:
                appendText("\t", run: run)
            case .nonBreakingHyphen:
                appendText("\u{2011}", run: run)
            case .symbol:
                appendText(run.content.plainText, run: run)
            case .softHyphen:
                // A soft hyphen is invisible unless it lands at a line break,
                // where it becomes a visible hyphen. Emitting it as text would
                // show stray hyphens mid-line, so it is dropped here; the
                // opportunity it represents is recovered by the measurer's
                // hyphenation candidates.
                continue
            default:
                // Fields, drawings and note references contribute no breakable
                // text in M0. From M2 they are laid out as fixed-width
                // placeholders; skipping them here still leaves the surrounding
                // text breaking correctly.
                continue
            }
        }
        flush()

        let hyphenationSettings = hyphenation ?? HyphenationSettings(
            enabled: settings.autoHyphenation,
            zonePoints: settings.hyphenationZone.points,
            consecutiveLimit: settings.consecutiveHyphenLimit.map { Int($0) }
        )

        return ParagraphLayoutInput(
            paragraphID: paragraph.id,
            segments: segments,
            breaks: breaks,
            alignment: resolved.alignment,
            lineSpacing: resolved.lineSpacing,
            widthAtLine: .constant(availableWidth),
            indentStart: resolved.indentStart,
            indentEnd: resolved.indentEnd,
            firstLineIndent: resolved.firstLineIndent,
            tabStops: resolved.tabStops,
            defaultTabStop: settings.defaultTabStop.points,
            rightToLeft: resolved.rightToLeft,
            wrapsTrailingSpaces: settings.compatibility.wrapTrailingSpaces,
            hyphenation: hyphenationSettings,
            markStyle: resolved.markStyle
        )
    }
}
