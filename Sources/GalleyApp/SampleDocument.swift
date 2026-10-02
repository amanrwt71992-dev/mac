import Foundation
import CoreKit
import LayoutKit

// MARK: - SampleDocument

/// Deterministic fixtures for the harness.
///
/// Every fixture states its own arithmetic in the comments, because a layout test
/// whose expected numbers cannot be checked by hand is a test that will be
/// "fixed" by changing the assertion the first time it fails.
enum SampleDocument {

    /// The `FixedWidthMeasurer.tenPoint` metrics, restated so the arithmetic in
    /// this file can be read without opening another one.
    ///
    /// 6 pt per cluster, 6 pt per space, ascent 9, descent 3, leading 0 — so a
    /// single-spaced line is 12 pt tall and a 60 pt column holds 10 clusters.
    static let clusterWidth = 6.0
    static let lineHeight = 12.0

    /// A multi-page document with headings, body text, a list-like run of
    /// paragraphs sharing a style, a manual page break and a manual line break.
    static func make(widthPoints: Double = 468) -> DocumentModel {
        var builder = DocumentBuilder(author: "Galley harness")
        builder.setTextAreaWidth(widthPoints)

        builder.heading("Galley", level: 1)
        builder.paragraph(
            "A native Mac word processor. The document model is OOXML, the layout engine is ours, "
                + "and the assistant runs on this Mac unless you tell it otherwise.",
            style: "Normal"
        )

        builder.heading("Why not Electron", level: 2)
        builder.paragraph(
            "A paginated document is not a web page. Page breaks depend on font metrics, on widow and "
                + "orphan control, on keep-with-next, on section breaks, on floating objects and on "
                + "headers that grow into the top margin. None of that exists in a browser layout "
                + "engine, so it has to be rebuilt on top of one — and then it has to be rebuilt again "
                + "every time the DOM changes shape underneath it.",
            style: "Normal"
        )
        builder.paragraph(
            "Building on CoreText instead means the metrics come from the same font engine the rest of "
                + "the system uses, so a document that fits on one page in Word fits on one page here.",
            style: "Normal"
        )

        builder.heading("Fidelity", level: 2)
        for index in 1...6 {
            builder.paragraph(
                "Fidelity rule \(index): never lose what we do not understand. An element this build "
                    + "cannot model is preserved verbatim and spliced back into the package byte for "
                    + "byte on save, rather than being dropped or rewritten.",
                style: "ListParagraph"
            )
        }

        builder.pageBreak()

        builder.heading("After the break", level: 2)
        builder.paragraphWithLineBreak("This paragraph ends with a manual line break,")
        builder.paragraph("and this one follows it in the same flow.")

        builder.emptyParagraph()
        builder.paragraph(
            "The empty paragraph above is not a nothing. It is a paragraph mark with a height, and a "
                + "layout engine that skips it produces a different page count from Word's on any "
                + "document that contains a blank line.",
            style: "Normal"
        )

        return builder.build()
    }

    /// A style table with no spacing and single line height.
    ///
    /// Word's real defaults are 8 pt after and 1.08× line height, which are
    /// correct for a document and unusable for arithmetic. A fixture that has to
    /// reason about "three lines per page" needs numbers a reader can check by
    /// hand, so the spacing defaults are zeroed and line spacing is exactly
    /// single — 12 pt per line under `FixedWidthMeasurer.tenPoint`.
    static let flatStyles = StyleTable(
        defaultRunProperties: .empty,
        defaultParagraphProperties: ParagraphProperties(
            spacingAfter: Twip(0),
            lineSpacing: .single
        ),
        styles: [:],
        declarationOrder: []
    )

    /// A document whose text area is exactly `heightPoints` tall and
    /// `widthPoints` wide, for tests that need to reason about line counts.
    static func sized(
        widthPoints: Double,
        heightPoints: Double,
        styles: StyleTable? = SampleDocument.flatStyles,
        configure: (inout DocumentBuilder) -> Void
    ) -> DocumentModel {
        var builder = DocumentBuilder(author: "Galley harness", styles: styles)
        // Letter is 612 × 792 pt. Margins of 72 pt left and right leave the
        // requested width; top and bottom margins are set so the remainder is
        // exactly the requested height.
        let pageSize = PageSize(
            width: Twip(points: widthPoints + 144),
            height: Twip(points: heightPoints + 144)
        )
        builder.setPageSize(pageSize, margins: PageMargins(
            top: Twip(1440),
            right: Twip(1440),
            bottom: Twip(1440),
            left: Twip(1440)
        ))
        configure(&builder)
        return builder.build()
    }

    /// `count` lines of text in one paragraph, each exactly `clustersPerLine`
    /// clusters wide under `FixedWidthMeasurer.tenPoint`, separated by spaces.
    ///
    /// A line of 10 clusters in a 60 pt column fills it exactly, so this
    /// produces a paragraph with a known line count and no ambiguity about where
    /// the breaks fall.
    static func text(lines count: Int, clustersPerLine: Int = 10) -> String {
        guard count > 0 else { return "" }
        let line = String(repeating: "x", count: clustersPerLine)
        return Array(repeating: line, count: count).joined(separator: " ")
    }
}
