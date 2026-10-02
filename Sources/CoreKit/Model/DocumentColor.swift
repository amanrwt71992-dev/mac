import Foundation

/// A colour as the document model understands it.
///
/// OOXML expresses colour three different ways and we have to represent all
/// three without lossy conversion, because converting a theme colour into an
/// sRGB triplet on load and writing the triplet back is exactly the kind of
/// silent mutation that breaks a round trip: the user changes their theme
/// afterwards and our text no longer follows it.
public enum DocumentColor: Hashable, Sendable {

    /// An explicit sRGB triplet — `w:color w:val="FF0000"`, `a:srgbClr`.
    case srgb(red: UInt8, green: UInt8, blue: UInt8)

    /// A named theme slot plus optional tint/shade — `a:schemeClr val="accent1"`.
    /// Preserved symbolically so theme changes propagate.
    ///
    /// Constructed through the `theme(_:luminanceModulation:)` factory below
    /// rather than directly, because Swift enum cases cannot carry default
    /// payload values and an unmodulated theme reference is by far the common
    /// case. Nine call sites each spelling out `luminanceModulation: nil` is nine
    /// opportunities to write something else by accident.
    case themeColor(ThemeColorSlot, luminanceModulation: LuminanceModulation?)

    /// A theme slot, optionally tinted or shaded.
    public static func theme(
        _ slot: ThemeColorSlot,
        luminanceModulation: LuminanceModulation? = nil
    ) -> DocumentColor {
        return .themeColor(slot, luminanceModulation: luminanceModulation)
    }

    /// One of the sixteen named colours `w:highlight` accepts. Distinct from
    /// `srgb` because OOXML stores it as a keyword, not a triplet.
    case highlight(HighlightColor)

    /// `w:color w:val="auto"` — resolved by the renderer against the page
    /// background. Must not be flattened to black: on a dark page colour Word
    /// renders `auto` as white.
    case automatic

    /// No colour specified at this level; inherit down the style cascade.
    /// Not the same as `.automatic`.
    case inherit

    public var isConcrete: Bool {
        switch self {
        case .srgb, .highlight:
            return true
        case .themeColor, .automatic, .inherit:
            return false
        }
    }

    /// Resolves to RGB for painting, given a theme and the page background.
    ///
    /// `pageIsDark` matters for `.automatic`, which Word resolves against the
    /// page colour rather than always to black.
    public func resolved(theme: ThemePalette, pageIsDark: Bool) -> RGB? {
        switch self {
        case .srgb(let r, let g, let b):
            return RGB(red: r, green: g, blue: b)
        case .themeColor(let slot, let modulation):
            let base = theme.color(for: slot)
            guard let modulation else { return base }
            return modulation.apply(to: base)
        case .highlight(let named):
            return named.rgb
        case .automatic:
            return pageIsDark ? RGB(red: 255, green: 255, blue: 255) : RGB(red: 0, green: 0, blue: 0)
        case .inherit:
            return nil
        }
    }
}

/// An 8-bit-per-channel colour with no colour space attached.
///
/// Colour management happens at the paint boundary (`LayoutKit/CoreText`), not
/// in the model, so that the model stays `Sendable` and platform-free.
public struct RGB: Hashable, Sendable, CustomStringConvertible {

    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses the six-digit hex form OOXML uses (`"FF0000"`). Returns `nil` for
    /// anything malformed rather than throwing — a corrupt colour attribute
    /// should degrade to the inherited colour, not fail the whole document.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 else { return nil }
        guard let value = UInt32(text, radix: 16) else { return nil }
        self.red = UInt8((value >> 16) & 0xFF)
        self.green = UInt8((value >> 8) & 0xFF)
        self.blue = UInt8(value & 0xFF)
    }

    public var hex: String {
        return String(format: "%02X%02X%02X", red, green, blue)
    }

    public static let black = RGB(red: 0, green: 0, blue: 0)
    public static let white = RGB(red: 255, green: 255, blue: 255)

    public var description: String { "#\(hex)" }
}

/// `a:schemeClr` values — the twelve slots in a theme's `a:clrScheme`.
public enum ThemeColorSlot: String, Hashable, Sendable, CaseIterable {
    case background1 = "bg1"
    case text1 = "tx1"
    case background2 = "bg2"
    case text2 = "tx2"
    case accent1
    case accent2
    case accent3
    case accent4
    case accent5
    case accent6
    case hyperlink = "hlink"
    case followedHyperlink = "folHlink"
}

/// The `a:lumMod` / `a:lumOff` pair Word uses for tints and shades.
///
/// Both are percentages in thousandths (`75000` = 75 %). A tint is
/// `lumMod < 100 %` with `lumOff = 100 % − lumMod`; a shade is `lumMod < 100 %`
/// with `lumOff = 0`.
public struct LuminanceModulation: Hashable, Sendable {

    /// `a:lumMod`, as a fraction where 1.0 == 100 %.
    public var mod: Double
    /// `a:lumOff`, as a fraction where 1.0 == 100 %.
    public var off: Double

    public init(mod: Double, off: Double) {
        self.mod = mod
        self.off = off
    }

    /// Word's "Lighter 25 %" is `lumMod 75000, lumOff 25000`.
    public static func lighter(_ fraction: Double) -> LuminanceModulation {
        return LuminanceModulation(mod: 1.0 - fraction, off: fraction)
    }

    /// Word's "Darker 25 %" is `lumMod 75000, lumOff 0`.
    public static func darker(_ fraction: Double) -> LuminanceModulation {
        return LuminanceModulation(mod: 1.0 - fraction, off: 0)
    }

    /// Applies the modulation in sRGB space, which is what Word does — it is
    /// not perceptually correct, and matching Word matters more than being right.
    public func apply(to color: RGB) -> RGB {
        func channel(_ value: UInt8) -> UInt8 {
            let normalised = Double(value) / 255.0
            let result = normalised * mod + off
            let clamped = max(0.0, min(1.0, result))
            return UInt8((clamped * 255.0).rounded())
        }
        return RGB(red: channel(color.red), green: channel(color.green), blue: channel(color.blue))
    }
}

/// The sixteen fixed names `w:highlight` accepts. Word will not accept an
/// arbitrary RGB here; an arbitrary colour goes in `w:shd` instead.
public enum HighlightColor: String, Hashable, Sendable, CaseIterable {
    case yellow
    case green
    case cyan
    case magenta
    case blue
    case red
    case darkBlue
    case darkCyan
    case darkGreen
    case darkMagenta
    case darkRed
    case darkYellow
    case darkGray
    case lightGray
    case black
    case none

    public var rgb: RGB {
        switch self {
        case .yellow:      return RGB(red: 0xFF, green: 0xFF, blue: 0x00)
        case .green:       return RGB(red: 0x00, green: 0xFF, blue: 0x00)
        case .cyan:        return RGB(red: 0x00, green: 0xFF, blue: 0xFF)
        case .magenta:     return RGB(red: 0xFF, green: 0x00, blue: 0xFF)
        case .blue:        return RGB(red: 0x00, green: 0x00, blue: 0xFF)
        case .red:         return RGB(red: 0xFF, green: 0x00, blue: 0x00)
        case .darkBlue:    return RGB(red: 0x00, green: 0x00, blue: 0x80)
        case .darkCyan:    return RGB(red: 0x00, green: 0x80, blue: 0x80)
        case .darkGreen:   return RGB(red: 0x00, green: 0x80, blue: 0x00)
        case .darkMagenta: return RGB(red: 0x80, green: 0x00, blue: 0x80)
        case .darkRed:     return RGB(red: 0x80, green: 0x00, blue: 0x00)
        case .darkYellow:  return RGB(red: 0x80, green: 0x80, blue: 0x00)
        case .darkGray:    return RGB(red: 0x80, green: 0x80, blue: 0x80)
        case .lightGray:   return RGB(red: 0xC0, green: 0xC0, blue: 0xC0)
        case .black:       return RGB(red: 0x00, green: 0x00, blue: 0x00)
        case .none:        return RGB(red: 0xFF, green: 0xFF, blue: 0xFF)
        }
    }
}

/// The resolved twelve-slot theme palette, from `theme1.xml`'s `a:clrScheme`.
public struct ThemePalette: Hashable, Sendable {

    public var background1: RGB
    public var text1: RGB
    public var background2: RGB
    public var text2: RGB
    public var accent1: RGB
    public var accent2: RGB
    public var accent3: RGB
    public var accent4: RGB
    public var accent5: RGB
    public var accent6: RGB
    public var hyperlink: RGB
    public var followedHyperlink: RGB

    public init(
        background1: RGB, text1: RGB, background2: RGB, text2: RGB,
        accent1: RGB, accent2: RGB, accent3: RGB, accent4: RGB,
        accent5: RGB, accent6: RGB, hyperlink: RGB, followedHyperlink: RGB
    ) {
        self.background1 = background1
        self.text1 = text1
        self.background2 = background2
        self.text2 = text2
        self.accent1 = accent1
        self.accent2 = accent2
        self.accent3 = accent3
        self.accent4 = accent4
        self.accent5 = accent5
        self.accent6 = accent6
        self.hyperlink = hyperlink
        self.followedHyperlink = followedHyperlink
    }

    public func color(for slot: ThemeColorSlot) -> RGB {
        switch slot {
        case .background1:        return background1
        case .text1:              return text1
        case .background2:        return background2
        case .text2:              return text2
        case .accent1:            return accent1
        case .accent2:            return accent2
        case .accent3:            return accent3
        case .accent4:            return accent4
        case .accent5:            return accent5
        case .accent6:            return accent6
        case .hyperlink:          return hyperlink
        case .followedHyperlink:  return followedHyperlink
        }
    }

    /// The Office theme Word applies to a new blank document. These are facts
    /// about the OOXML default theme, not Microsoft artwork.
    public static let officeDefault = ThemePalette(
        background1: RGB(red: 0xFF, green: 0xFF, blue: 0xFF),
        text1: RGB(red: 0x00, green: 0x00, blue: 0x00),
        background2: RGB(red: 0xE7, green: 0xE6, blue: 0xE6),
        text2: RGB(red: 0x44, green: 0x54, blue: 0x6A),
        accent1: RGB(red: 0x44, green: 0x72, blue: 0xC4),
        accent2: RGB(red: 0xED, green: 0x7D, blue: 0x31),
        accent3: RGB(red: 0xA5, green: 0xA5, blue: 0xA5),
        accent4: RGB(red: 0xFF, green: 0xC0, blue: 0x00),
        accent5: RGB(red: 0x5B, green: 0x9B, blue: 0xD5),
        accent6: RGB(red: 0x70, green: 0xAD, blue: 0x47),
        hyperlink: RGB(red: 0x05, green: 0x63, blue: 0xC1),
        followedHyperlink: RGB(red: 0x95, green: 0x4F, blue: 0x72)
    )
}
