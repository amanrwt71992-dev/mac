import Foundation

// MARK: - FontSubstitution

/// The font-substitution policy.
///
/// Lives in CoreKit rather than LayoutKit because it is a policy about the model
/// and about licensing, not a measurement: the OOXML writer needs it to decide
/// what may be embedded, and the legal CI job needs it to assert that no
/// Microsoft face is in the bundle.
///
/// Two hard rules:
///
/// 1. **Never redistribute a Microsoft font.** Calibri, Cambria, Consolas and the
///    rest are licensed to Windows and Office only. We reference them by name so
///    a machine that has them uses them, and fall back to a metric-compatible
///    libre face when it does not.
/// 2. **Never rewrite the font name in the saved file.** Substitution is a
///    *rendering* decision. A document that says Calibri must still say Calibri
///    when we save it, or the author's file has been silently altered.
///
/// Metric-compatible substitutes are what make this workable: Carlito is
/// metrically identical to Calibri and Caladea to Cambria, so line breaks land in
/// the same places and the page count does not drift.
public enum FontSubstitution: Sendable {

    /// A family we may not ship, mapped to one we may.
    public static let metricCompatible: [String: String] = [
        "Calibri": "Carlito",
        "Calibri Light": "Carlito",
        "Cambria": "Caladea",
        "Cambria Math": "Caladea",
        "Arial": "Liberation Sans",
        "Helvetica": "Liberation Sans",
        "Times New Roman": "Liberation Serif",
        "Times": "Liberation Serif",
        "Courier New": "Liberation Mono",
        "Courier": "Liberation Mono",
    ]

    /// Families that must never be embedded or bundled, whatever the platform.
    public static let neverBundle: Set<String> = [
        "Calibri", "Calibri Light", "Cambria", "Cambria Math", "Consolas",
        "Candara", "Constantia", "Corbel", "Segoe UI", "Times New Roman",
        "Arial", "Courier New", "Tahoma", "Verdana", "Georgia", "Impact",
        "Comic Sans MS", "Trebuchet MS", "Wingdings", "Webdings", "Symbol",
        "Marlett",
    ]

    /// The families we ship. All are redistributable under Apache-2.0 or OFL 1.1.
    public static let bundled: [String] = [
        "Carlito", "Caladea",
        "Liberation Sans", "Liberation Serif", "Liberation Mono",
        "Noto Sans", "Noto Serif", "Noto Sans CJK", "Noto Serif CJK",
        "Noto Sans Arabic", "Noto Sans Hebrew", "Noto Sans Devanagari",
        "DejaVu Sans", "DejaVu Serif", "DejaVu Sans Mono",
    ]

    /// Resolves a requested family to one we can actually draw with.
    ///
    /// `isInstalled` is injected rather than calling into CoreText directly, so
    /// the policy is testable without a font system.
    public static func resolve(
        family: String,
        isInstalled: (String) -> Bool
    ) -> (family: String, substituted: Bool) {
        if isInstalled(family) { return (family, false) }
        // The substitute is returned whether or not it is installed: if neither
        // face is present the system's own fallback chain takes over, and naming
        // the metric-compatible face gives it a better starting point than the
        // unlicensed original.
        if let substitute = metricCompatible[family] {
            return (substitute, true)
        }
        return (family, false)
    }

    /// Whether shipping a face with this name would be a licence problem.
    public static func mayBundle(family: String) -> Bool {
        !neverBundle.contains(family)
    }
}
