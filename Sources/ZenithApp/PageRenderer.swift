#if canImport(AppKit)
import AppKit
import CoreKit
import LayoutKit

// MARK: - PageRenderer

/// Draws laid-out pages.
///
/// Two deliberate choices worth recording, because both look like shortcuts and
/// are actually the reason this renders correctly on the first try:
///
/// **No CoreText text matrix.** Text is drawn with `NSAttributedString.draw(at:)`
/// rather than `CTLineDraw`. The view is flipped (y grows downward, matching the
/// layout snapshot) and AppKit's text drawing already understands a flipped
/// context, whereas `CTLineDraw` needs an explicit matrix and a per-line flip
/// that is easy to get subtly wrong and impossible to diagnose without a screen
/// in front of you.
///
/// **No CTM scaling for zoom.** Coordinates are multiplied by `zoom` by hand and
/// fonts are created at `size * zoom`, instead of scaling the graphics context.
/// Scaled contexts and font hinting interact badly at fractional zoom levels, and
/// doing it by hand keeps one point on screen equal to one point of the snapshot
/// divided by a known number.
///
/// Fonts come from `CoreTextMeasurer.postScriptName(for:)`, which reads back the
/// face CoreText actually resolved — including its silent fallback when a family
/// is not installed. Reconstructing "Family Bold Italic" here instead would pick
/// a different face whenever the family is missing, and the glyphs would drift
/// away from the advances the layout snapshot was built from.
final class PageRenderer {

    /// Grey gutter around the page stack and between consecutive pages.
    static let outerMargin: Double = 24
    static let pageGap: Double = 20

    private let measurer: CoreTextMeasurer
    private var fontCache: [FontCacheKey: NSFont] = [:]
    private var nameCache: [NameCacheKey: String] = [:]

    init(measurer: CoreTextMeasurer) {
        self.measurer = measurer
    }

    private struct FontCacheKey: Hashable {
        let postScriptName: String
        let size: CGFloat
    }

    private struct NameCacheKey: Hashable {
        let family: String
        let sizePoints: Double
        let bold: Bool
        let italic: Bool
        let horizontalScale: Double
    }

    // MARK: Pages

    /// Frame of a page in view coordinates, given its stack origin and the zoom.
    static func pageRect(
        for page: PageLayout,
        at origin: CGPoint,
        zoom: CGFloat
    ) -> NSRect {
        NSRect(
            x: origin.x,
            y: origin.y,
            width: CGFloat(page.pageSize.widthPoints) * zoom,
            height: CGFloat(page.pageSize.heightPoints) * zoom
        )
    }

    /// Draws the paper: a soft shadow, the white sheet, and a hairline edge.
    func drawPaper(_ rect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(rect: rect.offsetBy(dx: 0, dy: 3)).fill()

        NSColor.white.setFill()
        NSBezierPath(rect: rect).fill()

        NSColor(white: 0.68, alpha: 1).setStroke()
        NSBezierPath(rect: rect).stroke()
    }

    /// Draws every line of a page.
    ///
    /// `origin` is the top-left of the sheet in view coordinates. The page's own
    /// coordinate space — margins, columns, line frames — is measured from the
    /// top-left of the sheet too, so the two combine by addition.
    func draw(page: PageLayout, at origin: CGPoint, zoom: CGFloat) {
        for paragraph in page.paragraphs {
            for line in paragraph.lines {
                draw(line: line, at: origin, zoom: zoom)
            }
        }
    }

    private func draw(line: LayoutLine, at origin: CGPoint, zoom: CGFloat) {
        // Where the glyphs start, top-down. `baselineOffset` is measured from the
        // top of the line box and already includes the line's leading, so the top
        // of the ink is the baseline minus the ascent.
        let inkTop = (line.frame.y + line.baselineOffset - line.ascent) * zoom

        for segment in line.segments {
            guard !segment.text.isEmpty else { continue }

            let font = nsFont(for: segment.style, zoom: zoom)
            let attributed = NSAttributedString(
                string: segment.text,
                attributes: attributes(style: segment.style, font: font, zoom: zoom)
            )

            attributed.draw(
                at: CGPoint(
                    x: origin.x + CGFloat(segment.x) * zoom,
                    y: origin.y + CGFloat(inkTop)
                )
            )
        }
    }

    // MARK: Font resolution

    private func postScriptName(for style: ResolvedRunStyle) -> String {
        let spec = style.font
        let key = NameCacheKey(
            family: spec.family,
            sizePoints: spec.sizePoints,
            bold: spec.bold,
            italic: spec.italic,
            horizontalScale: spec.horizontalScale
        )
        if let cached = nameCache[key] { return cached }
        let name = measurer.postScriptName(for: spec)
        nameCache[key] = name
        return name
    }

    func nsFont(for style: ResolvedRunStyle, zoom: CGFloat) -> NSFont {
        let name = postScriptName(for: style)
        let size = CGFloat(style.font.sizePoints) * zoom
        let key = FontCacheKey(postScriptName: name, size: size)
        if let cached = fontCache[key] { return cached }
        let font = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
        fontCache[key] = font
        return font
    }

    private func attributes(
        style: ResolvedRunStyle,
        font: NSFont,
        zoom: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        let spec = style.font
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // v1 renders text in the document's foreground colour only once the
            // colour model is wired through; until then everything is black so
            // that layout and caret geometry can be verified without a second
            // variable in play.
            .foregroundColor: NSColor.black,
        ]

        // `.none` is a *present* value meaning "explicitly no underline" — it is
        // inherited from a style, not the absence of a request. Testing the
        // optional alone would draw a line under every run that inherited it.
        if let underline = spec.underline, underline != .none {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if spec.strikethrough != .none {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if abs(spec.baselineOffsetPoints) > 0.001 {
            attributes[.baselineOffset] = CGFloat(spec.baselineOffsetPoints) * zoom
        }
        if abs(spec.characterSpacingPoints) > 0.001 {
            attributes[.kern] = CGFloat(spec.characterSpacingPoints) * zoom
        }
        return attributes
    }
}

#endif
