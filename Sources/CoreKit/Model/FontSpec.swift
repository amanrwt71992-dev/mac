import Foundation

/// A font reference as `w:rFonts` stores it.
///
/// This is the most commonly botched part of a `.docx` reader. Word stores
/// **four** family slots, and which one applies depends on the *script of the
/// character being rendered*, not on the paragraph language:
///
/// - `ascii` — characters in the Basic Latin + Latin-1 Supplement ranges
/// - `hAnsi` — "high ANSI": everything not covered by `ascii`, `cs` or `eastAsia`
/// - `eastAsia` — CJK ideographs, kana, Hangul
/// - `cs` — complex script: Arabic, Hebrew, Thai, Devanagari and friends
///
/// A document set in Calibri with `w:eastAsia="MS Mincho"` renders Latin text in
/// Calibri and Japanese text in MS Mincho, in the same run, with no language
/// property involved. Collapsing the four slots into one family name is the
/// single fastest way to make a document look wrong.
public struct FontReference: Hashable, Sendable {

    public var ascii: String?
    public var hAnsi: String?
    public var eastAsia: String?
    public var complexScript: String?
    /// `w:hint` — `eastAsia` tells Word to prefer the eastAsia slot for
    /// ambiguous characters. Absent means "decide from the character".
    public var hint: FontHint?

    public init(
        ascii: String? = nil,
        hAnsi: String? = nil,
        eastAsia: String? = nil,
        complexScript: String? = nil,
        hint: FontHint? = nil
    ) {
        self.ascii = ascii
        self.hAnsi = hAnsi
        self.eastAsia = eastAsia
        self.complexScript = complexScript
        self.hint = hint
    }

    /// The common case: one family for everything, as `Font` pickers produce.
    public init(family: String) {
        self.ascii = family
        self.hAnsi = family
        self.eastAsia = nil
        self.complexScript = nil
        self.hint = nil
    }

    public static let empty = FontReference()

    public var isEmpty: Bool {
        return ascii == nil && hAnsi == nil && eastAsia == nil && complexScript == nil && hint == nil
    }

    /// Picks the slot that applies to a given character.
    public func family(for scalar: Unicode.Scalar) -> String? {
        switch FontScript.of(scalar) {
        case .basicLatin:
            return ascii ?? hAnsi
        case .eastAsian:
            if hint == .eastAsia { return eastAsia ?? hAnsi ?? ascii }
            return eastAsia ?? hAnsi ?? ascii
        case .complexScript:
            return complexScript ?? hAnsi ?? ascii
        case .other:
            return hAnsi ?? ascii ?? eastAsia ?? complexScript
        }
    }

    /// Merges another reference on top, slot by slot. `nil` slots in `other`
    /// leave ours intact — which is how the style cascade composes `w:rFonts`.
    public func merging(_ other: FontReference) -> FontReference {
        var result = self
        if let value = other.ascii { result.ascii = value }
        if let value = other.hAnsi { result.hAnsi = value }
        if let value = other.eastAsia { result.eastAsia = value }
        if let value = other.complexScript { result.complexScript = value }
        if let value = other.hint { result.hint = value }
        return result
    }

    /// The family a UI font picker should display.
    public var primaryFamily: String? { ascii ?? hAnsi ?? eastAsia ?? complexScript }
}

public enum FontHint: String, Hashable, Sendable {
    /// Not specified.
    case none = "none"
    case eastAsia
    case cs
}

/// Which `w:rFonts` slot a character selects.
public enum FontScript: Hashable, Sendable {
    case basicLatin
    case eastAsian
    case complexScript
    case other

    /// A deliberately coarse classification — enough to pick the right slot.
    /// Full script itemisation belongs in the shaping layer, where CoreText and
    /// ICU already do it properly; here we only need the four-way OOXML split.
    public static func of(_ scalar: Unicode.Scalar) -> FontScript {
        let value = scalar.value
        switch value {
        // Basic Latin + Latin-1 Supplement + Latin Extended-A/B + IPA + spacing modifiers
        case 0x0000...0x024F:
            return .basicLatin
        // Greek and Coptic, Cyrillic — Word puts these in hAnsi, not cs
        case 0x0370...0x052F:
            return .other
        // Hebrew
        case 0x0590...0x05FF:
            return .complexScript
        // Arabic
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .complexScript
        // Syriac, Arabic Supplement, Thaana, NKo
        case 0x0700...0x074F, 0x0780...0x07BF, 0x07C0...0x07FF:
            return .complexScript
        // Devanagari through Khmer, and the rest of the Indic block
        case 0x0900...0x0DFF, 0x1780...0x17FF:
            return .complexScript
        // Thai, Lao
        case 0x0E00...0x0EFF:
            return .complexScript
        // Tibetan, Myanmar, Georgian, Hangul Jamo
        case 0x0F00...0x0FFF, 0x1000...0x109F, 0x10A0...0x10FF, 0x1100...0x11FF:
            return .complexScript
        // CJK: Hangul syllables, CJK radicals, kana, CJK unified ideographs,
        // Yi, Hangul Jamo Extended, CJK compatibility
        case 0x2E80...0x2EFF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x312F,
             0x3130...0x318F, 0x31A0...0x31BF, 0x31F0...0x31FF, 0x3200...0x32FF,
             0x3300...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0x1F200...0x1F2FF, 0x20000...0x2FA1F:
            return .eastAsian
        default:
            return .other
        }
    }
}

// MARK: - FontSpec

/// A fully resolved font request, handed to the shaping layer.
///
/// Unlike `FontReference` this carries no optionality: the style cascade has
/// already run and every slot is filled in. Keeping the two types separate means
/// the cascade can be tested without a font system, and the shaper can be
/// tested without a style table.
public struct FontSpec: Hashable, Sendable {

    public var family: String
    public var sizePoints: Double
    public var bold: Bool
    public var italic: Bool

    /// `w:strike` / `w:dstrike` are not font traits but they are resolved here
    /// because CoreText applies them as part of the same run attributes.
    public var underline: UnderlineStyle?
    public var strikethrough: StrikethroughStyle

    /// `w:vertAlign`
    public var verticalAlignment: VerticalAlignment

    /// `w:caps` / `w:smallCaps`. Modelled rather than baked into the string so
    /// that Find still matches the user's original characters.
    public var capitalisation: Capitalisation

    /// `w:spacing` — additional inter-character spacing, in points. Positive
    /// expands, negative condenses.
    public var characterSpacingPoints: Double

    /// `w:position` — raise (positive) or lower (negative), in points.
    public var baselineOffsetPoints: Double

    /// `w:w` — horizontal scaling as a fraction, 1.0 == 100 %.
    public var horizontalScale: Double

    /// `w:kern` — the size at or above which kerning is applied, in points.
    /// Word's default behaviour is kerning for fonts ≥ 2 pt, i.e. effectively on.
    public var kerningThresholdPoints: Double

    public var enableLigatures: Bool
    public var enableDiscretionaryLigatures: Bool
    public var enableContextualAlternates: Bool

    public init(
        family: String,
        sizePoints: Double,
        bold: Bool = false,
        italic: Bool = false,
        underline: UnderlineStyle? = nil,
        strikethrough: StrikethroughStyle = .none,
        verticalAlignment: VerticalAlignment = .baseline,
        capitalisation: Capitalisation = .normal,
        characterSpacingPoints: Double = 0,
        baselineOffsetPoints: Double = 0,
        horizontalScale: Double = 1.0,
        kerningThresholdPoints: Double = 2.0,
        enableLigatures: Bool = true,
        enableDiscretionaryLigatures: Bool = false,
        enableContextualAlternates: Bool = true
    ) {
        self.family = family
        self.sizePoints = sizePoints
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.verticalAlignment = verticalAlignment
        self.capitalisation = capitalisation
        self.characterSpacingPoints = characterSpacingPoints
        self.baselineOffsetPoints = baselineOffsetPoints
        self.horizontalScale = horizontalScale
        self.kerningThresholdPoints = kerningThresholdPoints
        self.enableLigatures = enableLigatures
        self.enableDiscretionaryLigatures = enableDiscretionaryLigatures
        self.enableContextualAlternates = enableContextualAlternates
    }

    /// The de-facto default for a new blank document: Calibri 11.
    ///
    /// We *reference* Calibri, which is fine — every Word user has it installed
    /// and we never redistribute it. `FontSubstitution` in LayoutKit falls back
    /// to Carlito (Apache-2.0, metric-compatible) when it is absent, and the
    /// written file still says Calibri.
    public static let documentDefault = FontSpec(family: "Calibri", sizePoints: 11)

    public var traits: FontTraits {
        var traits = FontTraits(rawValue: 0)
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return traits
    }
}

public struct FontTraits: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = FontTraits(rawValue: 1 << 0)
    public static let italic = FontTraits(rawValue: 1 << 1)
}

public enum UnderlineStyle: String, Hashable, Sendable {
    case none
    case single
    case words           // `w:u val="words"` — underlines words but not spaces
    case doubleLine = "double"
    case dotted
    case thick
    case dash
    case dotDash
    case dotDotDash
    case wavy
    case dashedHeavy = "dashedHeavy"
    case dottedHeavy = "dottedHeavy"
    case wavyHeavy = "wavyHeavy"
    case dashLong = "dashLong"
    case wavyDouble = "wavyDouble"

    /// `w:u val="none"` and the absence of `w:u` both mean "no underline", but
    /// only the former should override an inherited underline. The distinction
    /// is preserved by `nil` (inherit) vs `.none` (explicitly off).
    public var drawsLine: Bool { self != .none }
}

public enum StrikethroughStyle: Hashable, Sendable {
    case none
    case single          // `w:strike`
    case doubleLine      // `w:dstrike`
}

public enum VerticalAlignment: String, Hashable, Sendable {
    case baseline
    case superscript
    case subscript
}

public enum Capitalisation: Hashable, Sendable {
    case normal
    case allCaps         // `w:caps`
    case smallCaps       // `w:smallCaps`
}
