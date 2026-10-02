import Foundation

/// Character-level properties as stored in the model, i.e. `w:rPr`.
///
/// **Every field is optional, and `nil` always means "inherit".** That is what
/// makes the cascade composable: `docDefaults.rPrDefault` → linked character
/// style → paragraph style's `rPr` → numbering level's `rPr` → direct `w:rPr`,
/// merged in that order with `merging(_:)`.
///
/// One trap worth restating because it bites every implementation: for
/// `underline`, `nil` means *inherit* while `.some(.none)` means *explicitly
/// off*, which is what `w:u w:val="none"` in a document writes when it wants to
/// cancel an underline coming from a style. The same applies to `bold` and
/// `italic` — `w:b w:val="0"` is explicit-off and must override the style, not
/// merge into it.
public struct RunProperties: Hashable, Sendable {

    public var fonts: FontReference?
    public var size: HalfPoint?
    /// `w:szCs` — a separate size for complex-script text.
    public var complexScriptSize: HalfPoint?

    public var bold: Bool?
    public var italic: Bool?
    public var boldComplexScript: Bool?
    public var italicComplexScript: Bool?

    /// `nil` = inherit; `.none` = explicitly off.
    public var underline: UnderlineStyle?
    public var underlineColor: DocumentColor?

    public var strikethrough: StrikethroughStyle?
    public var verticalAlignment: VerticalAlignment?
    public var capitalisation: Capitalisation?

    public var color: DocumentColor?
    /// `w:highlight` — the sixteen named colours.
    public var highlight: HighlightColor?
    /// `w:shd` — arbitrary background shading, which `w:highlight` cannot express.
    public var shading: Shading?

    /// `w:spacing`, in twips; positive expands, negative condenses.
    public var characterSpacing: Twip?
    /// `w:position`, in twips; positive raises, negative lowers.
    public var baselineOffset: Twip?
    /// `w:w`, as a fraction where 1.0 == 100 %.
    public var horizontalScale: FiftiethsOfAPercent?
    /// `w:kern`, in half-points.
    public var kerningThreshold: HalfPoint?

    public var ligatures: LigatureSetting?
    public var numberForm: NumberForm?
    public var numberSpacing: NumberSpacing?

    /// `w:lang` — three slots, because Word keeps them separate and so must we.
    public var language: LanguageReference?

    /// `w:rtl` — right-to-left run.
    public var rightToLeft: Bool?
    /// `w:noProof` — exclude from spell check.
    public var excludeFromProofing: Bool?
    /// `w:vanish` — hidden text.
    public var hidden: Bool?
    /// `w:webHidden` — hidden in Web Layout only.
    public var hiddenInWebLayout: Bool?
    /// `w:em` — East Asian emphasis marks.
    public var emphasisMark: EmphasisMark?
    /// `w:effect` — legacy text effects.
    public var textEffect: LegacyTextEffect?

    public init(
        fonts: FontReference? = nil,
        size: HalfPoint? = nil,
        complexScriptSize: HalfPoint? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        boldComplexScript: Bool? = nil,
        italicComplexScript: Bool? = nil,
        underline: UnderlineStyle? = nil,
        underlineColor: DocumentColor? = nil,
        strikethrough: StrikethroughStyle? = nil,
        verticalAlignment: VerticalAlignment? = nil,
        capitalisation: Capitalisation? = nil,
        color: DocumentColor? = nil,
        highlight: HighlightColor? = nil,
        shading: Shading? = nil,
        characterSpacing: Twip? = nil,
        baselineOffset: Twip? = nil,
        horizontalScale: FiftiethsOfAPercent? = nil,
        kerningThreshold: HalfPoint? = nil,
        ligatures: LigatureSetting? = nil,
        numberForm: NumberForm? = nil,
        numberSpacing: NumberSpacing? = nil,
        language: LanguageReference? = nil,
        rightToLeft: Bool? = nil,
        excludeFromProofing: Bool? = nil,
        hidden: Bool? = nil,
        hiddenInWebLayout: Bool? = nil,
        emphasisMark: EmphasisMark? = nil,
        textEffect: LegacyTextEffect? = nil
    ) {
        self.fonts = fonts
        self.size = size
        self.complexScriptSize = complexScriptSize
        self.bold = bold
        self.italic = italic
        self.boldComplexScript = boldComplexScript
        self.italicComplexScript = italicComplexScript
        self.underline = underline
        self.underlineColor = underlineColor
        self.strikethrough = strikethrough
        self.verticalAlignment = verticalAlignment
        self.capitalisation = capitalisation
        self.color = color
        self.highlight = highlight
        self.shading = shading
        self.characterSpacing = characterSpacing
        self.baselineOffset = baselineOffset
        self.horizontalScale = horizontalScale
        self.kerningThreshold = kerningThreshold
        self.ligatures = ligatures
        self.numberForm = numberForm
        self.numberSpacing = numberSpacing
        self.language = language
        self.rightToLeft = rightToLeft
        self.excludeFromProofing = excludeFromProofing
        self.hidden = hidden
        self.hiddenInWebLayout = hiddenInWebLayout
        self.emphasisMark = emphasisMark
        self.textEffect = textEffect
    }

    public static let empty = RunProperties()

    public var isEmpty: Bool { self == RunProperties.empty }

    /// Overlays `other` on top of `self`; `other`'s non-`nil` fields win.
    public func merging(_ other: RunProperties) -> RunProperties {
        var result = self
        if let value = other.fonts { result.fonts = result.fonts.map { $0.merging(value) } ?? value }
        if let value = other.size { result.size = value }
        if let value = other.complexScriptSize { result.complexScriptSize = value }
        if let value = other.bold { result.bold = value }
        if let value = other.italic { result.italic = value }
        if let value = other.boldComplexScript { result.boldComplexScript = value }
        if let value = other.italicComplexScript { result.italicComplexScript = value }
        if let value = other.underline { result.underline = value }
        if let value = other.underlineColor { result.underlineColor = value }
        if let value = other.strikethrough { result.strikethrough = value }
        if let value = other.verticalAlignment { result.verticalAlignment = value }
        if let value = other.capitalisation { result.capitalisation = value }
        if let value = other.color { result.color = value }
        if let value = other.highlight { result.highlight = value }
        if let value = other.shading { result.shading = value }
        if let value = other.characterSpacing { result.characterSpacing = value }
        if let value = other.baselineOffset { result.baselineOffset = value }
        if let value = other.horizontalScale { result.horizontalScale = value }
        if let value = other.kerningThreshold { result.kerningThreshold = value }
        if let value = other.ligatures { result.ligatures = value }
        if let value = other.numberForm { result.numberForm = value }
        if let value = other.numberSpacing { result.numberSpacing = value }
        if let value = other.language { result.language = result.language.map { $0.merging(value) } ?? value }
        if let value = other.rightToLeft { result.rightToLeft = value }
        if let value = other.excludeFromProofing { result.excludeFromProofing = value }
        if let value = other.hidden { result.hidden = value }
        if let value = other.hiddenInWebLayout { result.hiddenInWebLayout = value }
        if let value = other.emphasisMark { result.emphasisMark = value }
        if let value = other.textEffect { result.textEffect = value }
        return result
    }
}

// MARK: - Supporting enums

public enum LigatureSetting: String, Hashable, Sendable {
    case none
    case standard
    case contextual
    case historical
    case standardContextual
    case standardHistorical
    case contextualHistorical
    case all
}

public enum NumberForm: String, Hashable, Sendable {
    case proportional = "proportional"
    case oldStyle
    case lining
    case tabular
}

public enum NumberSpacing: String, Hashable, Sendable {
    case proportional
    case tabular
}

public enum EmphasisMark: String, Hashable, Sendable {
    case none
    case dot
    case comma
    case circle
    case underDot
}

public enum LegacyTextEffect: String, Hashable, Sendable {
    case none
    case blinkBackground = "blinkBackground"
    case lights
    case antsBlack = "antsBlack"
    case antsRed = "antsRed"
    case shimmer
}

/// `w:shd` — fill, pattern and colour. Used for character shading, paragraph
/// shading, table cell shading and page colour, so it lives at the model root.
public struct Shading: Hashable, Sendable {

    public var pattern: ShadingPattern
    public var color: DocumentColor
    public var fill: DocumentColor

    public init(
        pattern: ShadingPattern = .clear,
        color: DocumentColor = .automatic,
        fill: DocumentColor = .automatic
    ) {
        self.pattern = pattern
        self.color = color
        self.fill = fill
    }

    public static let none = Shading()
}

public enum ShadingPattern: String, Hashable, Sendable {
    case clear
    case solid
    case nil_ = "nil"
    case diagonalCross = "diagCross"
    case horizontal = "horz"
    case vertical = "vert"
    case percent5
    case percent10
    case percent12
    case percent15
    case percent20
    case percent25
    case percent30
    case percent35
    case percent37
    case percent40
    case percent45
    case percent50
    case percent55
    case percent60
    case percent62
    case percent65
    case percent70
    case percent75
    case percent80
    case percent85
    case percent87
    case percent90
    case percent95
}

/// `w:lang`. Three independent slots, all BCP-47-ish strings as Word writes them.
public struct LanguageReference: Hashable, Sendable {

    /// `w:val` — the Latin/primary language, e.g. `en-US`.
    public var value: String?
    /// `w:eastAsia` — e.g. `ja-JP`.
    public var eastAsia: String?
    /// `w:bidi` — the complex-script language, e.g. `ar-SA`.
    public var bidi: String?

    public init(value: String? = nil, eastAsia: String? = nil, bidi: String? = nil) {
        self.value = value
        self.eastAsia = eastAsia
        self.bidi = bidi
    }

    public static let empty = LanguageReference()

    public func merging(_ other: LanguageReference) -> LanguageReference {
        var result = self
        if let value = other.value { result.value = value }
        if let value = other.eastAsia { result.eastAsia = value }
        if let value = other.bidi { result.bidi = value }
        return result
    }

    /// Picks the language that applies to a character, mirroring `FontReference.family(for:)`.
    public func language(for scalar: Unicode.Scalar) -> String? {
        switch FontScript.of(scalar) {
        case .eastAsian:      return eastAsia ?? value
        case .complexScript:  return bidi ?? value
        case .basicLatin, .other: return value ?? eastAsia ?? bidi
        }
    }
}

// MARK: - ResolvedRunStyle

/// Run properties after the cascade has fully resolved.
///
/// Nothing here is optional, so the layout and paint layers never have to ask
/// "what if this is nil". This is the boundary between the style system and the
/// text engine, and keeping it non-optional is what makes the engine testable.
public struct ResolvedRunStyle: Hashable, Sendable {

    public var font: FontSpec
    public var color: DocumentColor
    public var highlight: HighlightColor?
    public var shading: Shading?
    public var language: String?
    public var rightToLeft: Bool
    public var hidden: Bool
    public var excludeFromProofing: Bool
    public var emphasisMark: EmphasisMark
    public var textEffect: LegacyTextEffect
    public var numberForm: NumberForm?
    public var numberSpacing: NumberSpacing?
    public var ligatures: LigatureSetting

    public init(
        font: FontSpec,
        color: DocumentColor = .automatic,
        highlight: HighlightColor? = nil,
        shading: Shading? = nil,
        language: String? = nil,
        rightToLeft: Bool = false,
        hidden: Bool = false,
        excludeFromProofing: Bool = false,
        emphasisMark: EmphasisMark = .none,
        textEffect: LegacyTextEffect = .none,
        numberForm: NumberForm? = nil,
        numberSpacing: NumberSpacing? = nil,
        ligatures: LigatureSetting = .standard
    ) {
        self.font = font
        self.color = color
        self.highlight = highlight
        self.shading = shading
        self.language = language
        self.rightToLeft = rightToLeft
        self.hidden = hidden
        self.excludeFromProofing = excludeFromProofing
        self.emphasisMark = emphasisMark
        self.textEffect = textEffect
        self.numberForm = numberForm
        self.numberSpacing = numberSpacing
        self.ligatures = ligatures
    }

    /// The style of a brand-new document's default text.
    public static let documentDefault = ResolvedRunStyle(font: .documentDefault, language: "en-US")

    /// Collapses the optional cascade representation into a concrete style.
    ///
    /// `inherited` is what the style chain produced; `direct` is the run's own
    /// `w:rPr`. The two are merged before resolving so that direct formatting
    /// wins, exactly as Word does.
    public static func resolve(
        inherited: RunProperties,
        direct: RunProperties,
        defaults: ResolvedRunStyle,
        theme: ThemePalette
    ) -> ResolvedRunStyle {
        let merged = inherited.merging(direct)
        return resolve(merged, defaults: defaults, theme: theme)
    }

    public static func resolve(
        _ properties: RunProperties,
        defaults: ResolvedRunStyle,
        theme: ThemePalette
    ) -> ResolvedRunStyle {
        let defaultFont = defaults.font

        // Family: take the slot appropriate to the text, falling back through
        // the reference and then to the inherited family.
        let family: String
        if let reference = properties.fonts {
            family = reference.primaryFamily ?? defaultFont.family
        } else {
            family = defaultFont.family
        }

        let sizePoints = properties.size?.points ?? defaultFont.sizePoints
        let bold = properties.bold ?? defaultFont.bold
        let italic = properties.italic ?? defaultFont.italic

        var font = FontSpec(
            family: family,
            sizePoints: sizePoints,
            bold: bold,
            italic: italic,
            underline: properties.underline ?? defaultFont.underline,
            strikethrough: properties.strikethrough ?? defaultFont.strikethrough,
            verticalAlignment: properties.verticalAlignment ?? defaultFont.verticalAlignment,
            capitalisation: properties.capitalisation ?? defaultFont.capitalisation,
            characterSpacingPoints: properties.characterSpacing?.points ?? defaultFont.characterSpacingPoints,
            baselineOffsetPoints: properties.baselineOffset?.points ?? defaultFont.baselineOffsetPoints,
            horizontalScale: properties.horizontalScale?.fraction ?? defaultFont.horizontalScale,
            kerningThresholdPoints: properties.kerningThreshold?.points ?? defaultFont.kerningThresholdPoints,
            enableLigatures: (properties.ligatures ?? defaults.ligatures) != .none,
            enableDiscretionaryLigatures: defaults.font.enableDiscretionaryLigatures,
            enableContextualAlternates: defaults.font.enableContextualAlternates
        )

        if properties.ligatures == .all || properties.ligatures == .contextualHistorical
            || properties.ligatures == .standardHistorical || properties.ligatures == .historical {
            font.enableDiscretionaryLigatures = true
        }
        if properties.ligatures == .contextual || properties.ligatures == .all
            || properties.ligatures == .standardContextual || properties.ligatures == .contextualHistorical {
            font.enableContextualAlternates = true
        }

        return ResolvedRunStyle(
            font: font,
            color: properties.color ?? defaults.color,
            highlight: properties.highlight ?? defaults.highlight,
            shading: properties.shading ?? defaults.shading,
            language: properties.language?.value ?? defaults.language,
            rightToLeft: properties.rightToLeft ?? defaults.rightToLeft,
            hidden: properties.hidden ?? defaults.hidden,
            excludeFromProofing: properties.excludeFromProofing ?? defaults.excludeFromProofing,
            emphasisMark: properties.emphasisMark ?? defaults.emphasisMark,
            textEffect: properties.textEffect ?? defaults.textEffect,
            numberForm: properties.numberForm ?? defaults.numberForm,
            numberSpacing: properties.numberSpacing ?? defaults.numberSpacing,
            ligatures: properties.ligatures ?? defaults.ligatures
        )
    }
}
