#if canImport(CoreText)
import Foundation
import CoreText
import CoreGraphics
import CoreKit

/// The macOS measurement backend.
///
/// Everything platform-specific about layout lives in this one file. The line
/// breaker and the paginator never see CoreText, which is why they can be tested
/// on a Linux CI runner in seconds against a mock measurer.
///
/// A class rather than a struct because it owns caches. Font creation is the
/// expensive part of text layout — `CTFontCreateWithName` walks the font
/// database — and doing it per run per keystroke would blow the 16 ms budget on
/// its own. The caches are keyed by the resolved style, so a cache hit is a
/// dictionary lookup.
public final class CoreTextMeasurer: TextMeasurer, @unchecked Sendable {

    private let lock = NSLock()
    private var fontCache: [FontCacheKey: CTFont] = [:]
    private var metricsCache: [ResolvedRunStyle: FontLineMetrics] = [:]
    private var attributesCache: [ResolvedRunStyle: [NSAttributedString.Key: Any]] = [:]
    private var familyAvailability: [String: Bool] = [:]
    private var hyphenWidthCache: [ResolvedRunStyle: Double] = [:]

    public init() {}

    // MARK: - TextMeasurer

    public func measure(_ text: String, style: ResolvedRunStyle) -> MeasuredRun {
        guard !text.isEmpty else { return MeasuredRun() }

        let line = ctLine(for: text, style: style)
        guard let line else { return MeasuredRun() }

        // Advances are derived from string-index offsets rather than from glyph
        // advances, because glyphs and grapheme clusters are not 1:1. A ligature
        // is one glyph for two or more characters, and an Indic syllable is one
        // cluster spanning several code units. Offsets are correct in both cases;
        // glyph arithmetic is not.
        var clusterOffsets: [Int] = []
        var advances: [Double] = []
        var graphemeIndex = 0
        var utf16Offset = 0

        for character in text {
            let clusterLength = String(character).utf16.count
            // CGFloat, not Double: CoreText takes this as
            // `UnsafeMutablePointer<CGFloat>?`, and pointers are invariant, so the
            // CGFloat/Double implicit conversion that works everywhere else in
            // this file does not apply here.
            var subClusterOffset = CGFloat(0)
            let start = CTLineGetOffsetForStringIndex(line, CFIndex(utf16Offset), &subClusterOffset)
            let end = CTLineGetOffsetForStringIndex(line, CFIndex(utf16Offset + clusterLength), nil)
            clusterOffsets.append(graphemeIndex)
            advances.append(max(0, Double(end - start)))
            graphemeIndex += 1
            utf16Offset += clusterLength
        }

        return MeasuredRun(clusterOffsets: clusterOffsets, advances: advances)
    }

    public func lineMetrics(for style: ResolvedRunStyle) -> FontLineMetrics {
        lock.lock()
        if let cached = metricsCache[style] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let font = ctFont(for: style.font)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        let metrics = FontLineMetrics(
            ascent: ascent,
            descent: descent,
            leading: leading,
            capHeight: CTFontGetCapHeight(font),
            xHeight: CTFontGetXHeight(font),
            underlinePosition: CTFontGetUnderlinePosition(font),
            underlineThickness: CTFontGetUnderlineThickness(font),
            strikeoutPosition: -CTFontGetXHeight(font) / 2,
            strikeoutThickness: max(0.5, CTFontGetSize(font) / 20)
        )

        lock.lock()
        metricsCache[style] = metrics
        lock.unlock()
        return metrics
    }

    public func breakOpportunities(in text: String, style: ResolvedRunStyle) -> [Int] {
        guard !text.isEmpty else { return [] }

        // Thai, Lao, Khmer and Burmese do not write spaces between words, so
        // break opportunities cannot be found by scanning for punctuation — they
        // need a dictionary. Foundation's word enumeration is backed by ICU and
        // does exactly that, so it is used only for the scripts that need it.
        if Self.requiresDictionaryBreaking(text) {
            var opportunities: [Int] = []
            text.enumerateSubstrings(in: text.startIndex..., options: [.byWords]) { _, range, _, _ in
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                if end > 0, end < text.count { opportunities.append(end) }
            }
            return opportunities
        }

        // Fast path for space-delimited scripts. This is a linear scan rather
        // than an ICU call, which matters because it runs on every paragraph of
        // every re-layout.
        var opportunities: [Int] = []
        for (index, character) in text.enumerated() {
            switch character {
            case " ", "-", "\u{2010}", "\u{00AD}", "\u{2013}", "\u{2014}", "/":
                opportunities.append(index + 1)
            default:
                break
            }
        }
        return opportunities
    }

    /// Returns no candidates.
    ///
    /// macOS exposes no public hyphenation API: CoreText has none, and TextKit's
    /// `hyphenationFactor` drives a private implementation we cannot call and
    /// must not link against. Shipping a Liang-style pattern table for the
    /// languages we support is the correct answer and it is planned for M2 —
    /// it is also the only answer that produces *identical* hyphenation on every
    /// machine, which a private OS routine would not.
    ///
    /// Returning nothing is safe because `HyphenationSettings.enabled` defaults
    /// to false and the breaker treats an empty candidate list as "do not
    /// hyphenate".
    public func hyphenationCandidates(in word: String, style: ResolvedRunStyle) -> [Int] {
        []
    }

    public func hyphenWidth(style: ResolvedRunStyle) -> Double {
        lock.lock()
        if let cached = hyphenWidthCache[style] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let width = measure("-", style: style).width
        lock.lock()
        hyphenWidthCache[style] = width
        lock.unlock()
        return width
    }

    // MARK: - Font resolution

    private struct FontCacheKey: Hashable {
        var family: String
        var sizePoints: Double
        var bold: Bool
        var italic: Bool
        var horizontalScale: Double

        init(_ spec: FontSpec) {
            self.family = spec.family
            self.sizePoints = spec.sizePoints
            self.bold = spec.bold
            self.italic = spec.italic
            self.horizontalScale = spec.horizontalScale
        }
    }

    /// Creates (or reuses) the CoreText font for a resolved spec.
    ///
    /// Public because the renderer must draw with the *same* face the measurer
    /// measured with. If the two disagree — typically because a document asks for
    /// Calibri, which we neither ship nor may bundle, and CoreText's silent
    /// fallback differs from whatever the UI layer guessed — glyphs drift away
    /// from the advances in the layout snapshot and the caret stops sitting where
    /// the text is. `postScriptName(for:)` below is the safe way to ask.
    public func ctFont(for spec: FontSpec) -> CTFont {
        let key = FontCacheKey(spec)
        lock.lock()
        if let cached = fontCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Our substitution policy runs first so that a document asking for
        // Calibri lands on Carlito when Carlito is what we ship. CoreText's own
        // fallback would pick something metrically different, which shifts line
        // breaks and changes the page count.
        let requested = resolvedFamily(for: spec.family)

        // Bold and italic are requested by **face name** — "Carlito Bold Italic"
        // — rather than through symbolic traits.
        //
        // Both trait routes have changed shape between SDKs and neither can be
        // relied on blindly: the descriptor route needs `kCTFontTraitsAttribute`'s
        // inner trait-key constants, whose documented spellings the macOS 27 SDK
        // does not export to Swift, and `CTFontCreateCopyWithSymbolicTraits`
        // imports here with five parameters rather than the four it has had since
        // 10.5. `CTFontCreateWithName` goes through the same lookup CoreText uses
        // for a font's full name, takes three parameters on every SDK, and when no
        // such face exists returns the family's closest match instead of failing —
        // which is the behaviour we want anyway.
        //
        // M1 refinement: read back `CTFontGetSymbolicTraits` and, when the face
        // does not carry what was asked for, record that this run's metrics are
        // approximate so the fidelity matrix can report it rather than silently
        // differing from Word.
        var faceName = requested
        if spec.bold && spec.italic {
            faceName += " Bold Italic"
        } else if spec.bold {
            faceName += " Bold"
        } else if spec.italic {
            faceName += " Italic"
        }

        var font = CTFontCreateWithName(faceName as CFString, CGFloat(spec.sizePoints), nil)

        // `w:w` horizontal scaling is a font transform, not a size change:
        // scaling the size would also scale the vertical metrics and change the
        // line height, which Word does not do.
        if abs(spec.horizontalScale - 1.0) > 0.001 {
            var transform = CGAffineTransform(scaleX: CGFloat(spec.horizontalScale), y: 1)
            font = CTFontCreateWithFontDescriptor(
                CTFontCopyFontDescriptor(font),
                CGFloat(spec.sizePoints),
                &transform
            )
        }

        lock.lock()
        fontCache[key] = font
        lock.unlock()
        return font
    }

    /// The PostScript name of the font CoreText actually resolved for a spec.
    ///
    /// This is the name to hand to a UI-layer font constructor. It is read back
    /// from the created `CTFont` rather than reconstructed from the request, so
    /// it already reflects both our substitution policy and CoreText's own
    /// fallback for a family that is not installed. A renderer that rebuilds
    /// "Family Bold Italic" itself gets a different face whenever the requested
    /// family is missing, and silently lays text out at the wrong metrics.
    public func postScriptName(for spec: FontSpec) -> String {
        CTFontCopyPostScriptName(ctFont(for: spec)) as String
    }

    /// Applies `FontSubstitution`, memoising the availability probe.
    ///
    /// The probe asks CoreText to create the family and compares the family it
    /// actually returned: CoreText silently substitutes a fallback for a family
    /// that is not installed, so a name mismatch means "not installed".
    private func resolvedFamily(for family: String) -> String {
        lock.lock()
        let cached = familyAvailability[family]
        lock.unlock()

        let installed: Bool
        if let known = cached {
            installed = known
        } else {
            let probe = CTFontCreateWithName(family as CFString, 12, nil)
            let actual = CTFontCopyFamilyName(probe) as String
            installed = actual.caseInsensitiveCompare(family) == .orderedSame
            lock.lock()
            familyAvailability[family] = installed
            lock.unlock()
        }

        guard !installed else { return family }
        return FontSubstitution.metricCompatible[family] ?? family
    }

    // MARK: - Attributed strings

    private func attributes(for style: ResolvedRunStyle) -> [NSAttributedString.Key: Any] {
        lock.lock()
        if let cached = attributesCache[style] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let font = ctFont(for: style.font)
        var result: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            // Ligatures: standard on by default, matching Word. Discretionary
            // ligatures are opt-in via `w:ligatures`.
            NSAttributedString.Key(kCTLigatureAttributeName as String):
                NSNumber(value: style.font.enableDiscretionaryLigatures ? 2 : (style.font.enableLigatures ? 1 : 0)),
        ]

        // `w:spacing` is inter-character spacing, which maps onto kerning.
        if abs(style.font.characterSpacingPoints) > 0.001 {
            result[NSAttributedString.Key(kCTKernAttributeName as String)] =
                NSNumber(value: style.font.characterSpacingPoints)
        } else if style.font.sizePoints >= style.font.kerningThresholdPoints {
            // CoreText kerns by default; an explicit zero would disable it. Word
            // kerns at or above `w:kern`, which defaults to effectively always.
            result[NSAttributedString.Key(kCTKernAttributeName as String)] = nil
        }

        // `w:rtl` sets the base writing direction. Without it, right-to-left
        // paragraphs are laid out left-to-right and mirrored punctuation lands
        // on the wrong side.
        if style.rightToLeft {
            result[NSAttributedString.Key(kCTWritingDirectionAttributeName as String)] =
                [NSNumber(value: CTWritingDirection.rightToLeft.rawValue)]
        }

        // `w:caps` and `w:smallCaps` are deliberately not handled here.
        //
        // They must be applied as a font feature, not by rewriting the string:
        // upper-casing the text would make Find stop matching the author's own
        // characters and would corrupt the file on save. The model carries
        // `capitalisation` through the cascade unchanged, and the renderer
        // applies the feature when drawing. Wiring it up is an M1 item, tracked
        // in docs/05-ROADMAP.md, and until then small caps render as normal
        // case rather than as silently transformed text.

        lock.lock()
        attributesCache[style] = result
        lock.unlock()
        return result
    }

    private func ctLine(for text: String, style: ResolvedRunStyle) -> CTLine? {
        let attributed = NSAttributedString(string: text, attributes: attributes(for: style))
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }

    // MARK: - Script detection

    /// Scripts that need a dictionary to find word boundaries.
    static func requiresDictionaryBreaking(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0E00...0x0E7F,   // Thai
                 0x0E80...0x0EFF,   // Lao
                 0x1000...0x109F,   // Myanmar
                 0x1780...0x17FF,   // Khmer
                 0x1980...0x19DF,   // New Tai Lue
                 0x1A00...0x1A1F,   // Buginese
                 0x1A20...0x1AAF,   // Tai Tham
                 0xA980...0xA9DF,   // Javanese
                 0xAA00...0xAA5F,   // Cham
                 0x11000...0x1107F: // Brahmi
                return true
            default:
                continue
            }
        }
        return false
    }
}
#endif
