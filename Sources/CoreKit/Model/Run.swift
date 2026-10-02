import Foundation

/// What a run actually contains.
///
/// Word's `w:r` is not "a string with formatting" — it is a sequence of
/// heterogeneous children, and the ordering of those children is load-bearing
/// for fields. A field is stored as three runs (`w:fldChar begin`, `w:instrText`,
/// `w:fldChar separate`, cached result, `w:fldChar end`) interleaved with the
/// text they affect. Collapsing runs to plain text destroys fields, TOCs and
/// cross-references, so the content union is modelled in full even though M0
/// only renders `.text`.
public enum RunContent: Hashable, Sendable {

    /// `w:t`. The `String` may contain any Unicode; XML-space handling
    /// (`xml:space="preserve"`) is a serialisation concern, not a model one.
    case text(String)

    /// `w:tab`
    case tab

    /// `w:br` with no `w:type` — a manual line break (Shift+Enter).
    case lineBreak

    /// `w:br w:type="page"`
    case pageBreak

    /// `w:br w:type="column"`
    case columnBreak

    /// `w:br w:type="textWrapping"`
    case textWrappingBreak

    /// `w:cr`
    case carriageReturn

    /// `w:noBreakHyphen` — a hyphen that is not a break opportunity.
    case nonBreakingHyphen

    /// `w:softHyphen` — a hyphen shown only if the word breaks here.
    case softHyphen

    /// `w:sym w:font` / `w:char` — a glyph from a symbol font.
    case symbol(font: String, character: UInt32)

    /// `w:drawing` → `wp:inline` or `wp:anchor`. Modelled as an opaque reference
    /// in M0; `LayoutKit` needs only the extent to reserve space.
    case drawing(DrawingReference)

    /// `w:object` — an embedded OLE object.
    case embeddedObject(EmbeddedObjectReference)

    /// `w:pict` — legacy VML picture.
    case legacyPicture(LegacyPictureReference)

    /// `w:footnoteReference`
    case footnoteReference(NodeID)

    /// `w:endnoteReference`
    case endnoteReference(NodeID)

    /// `w:commentReference`
    case commentReference(NodeID)

    /// `w:annotationRef`, `w:separator`, `w:continuationSeparator`,
    /// `w:continuationNotice` — the special runs Word puts in footnote and
    /// endnote streams.
    case noteMarker(NoteMarkerKind)

    /// `w:fldChar w:fldCharType="begin|separate|end"`, with `w:dirty` preserved
    /// because Word uses it to request a field update on open.
    case fieldCharacter(FieldCharacterKind, dirty: Bool)

    /// `w:instrText` — the field code itself, e.g. `PAGE`, `TOC \o "1-3" \h`.
    case fieldInstruction(String)

    /// `w:ruby` — East Asian phonetic guide.
    case ruby(RubyReference)

    /// `w:proofErr w:type="spellStart|spellEnd|gramStart|gramEnd"`.
    /// Word persists these; dropping them makes a round trip noisy.
    case proofingErrorMarker(ProofingMarkerKind)

    /// An element we do not model, kept verbatim so it survives a save.
    /// This is the fidelity escape hatch and the reason unknown documents do
    /// not lose content.
    case preservedXML(PreservedElement)

    /// Whether this content occupies horizontal space in a line.
    public var isInlineContent: Bool {
        switch self {
        case .text, .tab, .symbol, .drawing, .embeddedObject, .legacyPicture, .ruby:
            return true
        case .lineBreak, .pageBreak, .columnBreak, .textWrappingBreak, .carriageReturn,
             .nonBreakingHyphen, .softHyphen, .footnoteReference, .endnoteReference,
             .commentReference, .noteMarker, .fieldCharacter, .fieldInstruction,
             .proofingErrorMarker, .preservedXML:
            return false
        }
    }

    /// The plain text this content contributes, if any.
    public var plainText: String {
        switch self {
        case .text(let string):
            return string
        case .tab:
            return "\t"
        case .lineBreak, .textWrappingBreak:
            return "\n"
        case .carriageReturn:
            return "\r"
        case .columnBreak, .pageBreak:
            return "\u{000C}"
        case .nonBreakingHyphen:
            return "\u{2011}"
        case .softHyphen:
            return "\u{00AD}"
        case .symbol(_, let character):
            // Decoding rather than `Unicode.Scalar(_:)`, which traps on values
            // that are not valid scalars — and a corrupt `w:sym` in a real
            // document is exactly the kind of input we must survive.
            return String(decoding: [character], as: UTF32.self)
        default:
            return ""
        }
    }

    /// Whether this content forces a layout break, and of what kind.
    public var forcedBreak: ForcedBreak? {
        switch self {
        case .pageBreak:        return .page
        case .columnBreak:      return .column
        case .lineBreak, .textWrappingBreak: return .line
        case .carriageReturn:   return .line
        default:                return nil
        }
    }
}

public enum ForcedBreak: Hashable, Sendable {
    case line
    case column
    case page
}

public enum FieldCharacterKind: String, Hashable, Sendable {
    case begin
    case separate
    case end
}

public enum NoteMarkerKind: String, Hashable, Sendable {
    case annotationRef
    case separator
    case continuationSeparator
    case continuationNotice
}

public enum ProofingMarkerKind: String, Hashable, Sendable {
    case spellStart
    case spellEnd
    case gramStart
    case gramEnd
}

// MARK: - Opaque references

/// A drawing object. The full DrawingML model is large (`wp:`, `a:`, `pic:`);
/// M0 needs the extent and the anchor kind so the line breaker can reserve
/// space, and OOXMLKit keeps the rest verbatim.
public struct DrawingReference: Hashable, Sendable {

    public enum Placement: Hashable, Sendable {
        /// `wp:inline` — participates in the line like a big glyph.
        case inline
        /// `wp:anchor` — floats relative to a paragraph, column, margin or page.
        case anchored(AnchorPlacement)
    }

    /// The relationship id pointing at the image part.
    public var relationshipID: String?
    public var placement: Placement
    public var extentWidth: EMU
    public var extentHeight: EMU
    public var alternativeText: String?
    public var name: String?

    public init(
        relationshipID: String? = nil,
        placement: Placement = .inline,
        extentWidth: EMU = .zero,
        extentHeight: EMU = .zero,
        alternativeText: String? = nil,
        name: String? = nil
    ) {
        self.relationshipID = relationshipID
        self.placement = placement
        self.extentWidth = extentWidth
        self.extentHeight = extentHeight
        self.alternativeText = alternativeText
        self.name = name
    }

    public var sizePoints: Size {
        return Size(width: extentWidth.points, height: extentHeight.points)
    }

    public var isAnchored: Bool {
        if case .anchored = placement { return true }
        return false
    }
}

/// Where an anchored object is positioned and how text wraps around it.
public struct AnchorPlacement: Hashable, Sendable {

    public enum WrapMode: String, Hashable, Sendable {
        /// `wp:wrapNone` — behind or in front of text.
        case none
        /// `wp:wrapSquare` — wraps to the bounding box.
        case square
        /// `wp:wrapTight` — wraps to the polygon outline.
        case tight
        /// `wp:wrapThrough` — wraps into the polygon's interior gaps.
        case through
        /// `wp:wrapTopAndBottom` — text stops above and resumes below.
        case topAndBottom
    }

    public enum ZPosition: Hashable, Sendable {
        case behindText
        case inFrontOfText
    }

    public enum RelativeFrom: String, Hashable, Sendable {
        case margin
        case page
        case column
        case paragraph
        case character
        case line
    }

    public enum HorizontalAlignment: String, Hashable, Sendable {
        case left
        case center
        case right
        case inside
        case outside
    }

    public enum VerticalAlignment: String, Hashable, Sendable {
        case top
        case center
        case bottom
        case inside
        case outside
    }

    public enum HorizontalPosition: Hashable, Sendable {
        case aligned(HorizontalAlignment)
        case offset(EMU)
    }

    public enum VerticalPosition: Hashable, Sendable {
        case aligned(VerticalAlignment)
        case offset(EMU)
    }

    public var horizontal: HorizontalPosition
    public var horizontalRelativeFrom: RelativeFrom
    public var vertical: VerticalPosition
    public var verticalRelativeFrom: RelativeFrom
    public var wrapMode: WrapMode
    public var zPosition: ZPosition
    /// `wp:effectExtent` — how far the object's shadow/glow extends beyond its box.
    public var effectExtent: EffectExtent
    /// `a:wrapPolygon` — the outline `tight` and `through` wrapping follow.
    public var wrapPolygon: [Point]?
    /// `wp:allowOverlap`
    public var allowOverlap: Bool
    /// `wp:simplePos` — a legacy positioning mode we must preserve.
    public var useSimplePosition: Bool
    /// `wp:layoutInCell`
    public var layoutInCell: Bool
    /// `wp:locked`
    public var locked: Bool
    /// `wp:distT/B/L/R` — extra clearance around the object.
    public var distanceTop: EMU
    public var distanceBottom: EMU
    public var distanceLeft: EMU
    public var distanceRight: EMU

    public init(
        horizontal: HorizontalPosition = .aligned(.left),
        horizontalRelativeFrom: RelativeFrom = .column,
        vertical: VerticalPosition = .aligned(.top),
        verticalRelativeFrom: RelativeFrom = .paragraph,
        wrapMode: WrapMode = .square,
        zPosition: ZPosition = .inFrontOfText,
        effectExtent: EffectExtent = .zero,
        wrapPolygon: [Point]? = nil,
        allowOverlap: Bool = true,
        useSimplePosition: Bool = false,
        layoutInCell: Bool = true,
        locked: Bool = false,
        distanceTop: EMU = .zero,
        distanceBottom: EMU = .zero,
        distanceLeft: EMU = .zero,
        distanceRight: EMU = .zero
    ) {
        self.horizontal = horizontal
        self.horizontalRelativeFrom = horizontalRelativeFrom
        self.vertical = vertical
        self.verticalRelativeFrom = verticalRelativeFrom
        self.wrapMode = wrapMode
        self.zPosition = zPosition
        self.effectExtent = effectExtent
        self.wrapPolygon = wrapPolygon
        self.allowOverlap = allowOverlap
        self.useSimplePosition = useSimplePosition
        self.layoutInCell = layoutInCell
        self.locked = locked
        self.distanceTop = distanceTop
        self.distanceBottom = distanceBottom
        self.distanceLeft = distanceLeft
        self.distanceRight = distanceRight
    }

    /// Whether text flows around the object at all.
    public var excludesText: Bool {
        return zPosition == .inFrontOfText && wrapMode != .none
    }
}

public struct EffectExtent: Hashable, Sendable {
    public var left: EMU
    public var top: EMU
    public var right: EMU
    public var bottom: EMU

    public init(left: EMU = .zero, top: EMU = .zero, right: EMU = .zero, bottom: EMU = .zero) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public static let zero = EffectExtent()
}

public struct EmbeddedObjectReference: Hashable, Sendable {
    public var relationshipID: String?
    public var progID: String?
    public var drawnAsIcon: Bool
    public init(relationshipID: String? = nil, progID: String? = nil, drawnAsIcon: Bool = false) {
        self.relationshipID = relationshipID
        self.progID = progID
        self.drawnAsIcon = drawnAsIcon
    }
}

public struct LegacyPictureReference: Hashable, Sendable {
    public var relationshipID: String?
    public init(relationshipID: String? = nil) {
        self.relationshipID = relationshipID
    }
}

public struct RubyReference: Hashable, Sendable {
    /// The phonetic guide text.
    public var base: String
    /// The text it annotates.
    public var annotation: String
    public init(base: String, annotation: String) {
        self.base = base
        self.annotation = annotation
    }
}

/// An OOXML element we do not model, retained verbatim.
///
/// This is the single most important type for round-trip fidelity. Anything the
/// reader does not understand is captured here and re-emitted byte-for-byte, so
/// opening and saving a document never silently deletes content — the failure
/// mode that makes people distrust alternative office suites.
public struct PreservedElement: Hashable, Sendable {
    /// The qualified element name, e.g. `"w:customXml"`.
    public var name: String
    /// The exact original serialisation, including namespace declarations.
    public var xml: String

    public init(name: String, xml: String) {
        self.name = name
        self.xml = xml
    }
}

// MARK: - Run

/// A run: contiguous content sharing one set of character properties.
public struct Run: Hashable, Sendable {

    public var id: NodeID
    public var content: RunContent
    /// Direct `w:rPr`. `nil` fields inherit through the cascade.
    public var properties: RunProperties
    /// Non-`nil` when this run is a tracked insertion or deletion.
    public var revision: RevisionMark?

    public init(
        id: NodeID,
        content: RunContent,
        properties: RunProperties = .empty,
        revision: RevisionMark? = nil
    ) {
        self.id = id
        self.content = content
        self.properties = properties
        self.revision = revision
    }

    public var plainText: String { content.plainText }

    public var isDeleted: Bool { revision?.kind == .deletion }

    /// Whether the run is visible at all under a given revision display mode.
    public func isVisible(markup: RevisionMarkup) -> Bool {
        guard let revision else { return true }
        switch revision.kind {
        case .deletion:
            // Deleted text shows in All Markup and Original, hides in No Markup.
            return markup != .noMarkup
        case .insertion, .moveTo, .moveFrom:
            return markup != .original
        }
    }

    /// Splits this run in two at a character offset within `.text` content.
    /// Returns `nil` for non-text content, which cannot be split.
    public func split(atCharacterOffset offset: Int, nextID: NodeID) -> (Run, Run)? {
        guard case .text(let string) = content else { return nil }
        guard offset > 0 && offset < string.count else { return nil }
        let lowerIndex = string.index(string.startIndex, offsetBy: offset)
        let head = String(string[string.startIndex..<lowerIndex])
        let tail = String(string[lowerIndex...])
        let left = Run(id: id, content: .text(head), properties: properties, revision: revision)
        let right = Run(id: nextID, content: .text(tail), properties: properties, revision: revision)
        return (left, right)
    }
}

// MARK: - Revisions

public enum RevisionKind: String, Hashable, Sendable {
    case insertion
    case deletion
    case moveFrom
    case moveTo
}

/// The `w:ins` / `w:del` / `w:moveFrom` / `w:moveTo` wrapper.
///
/// Our AI edits are written as `.insertion` and `.deletion` marks with an author
/// of `Assistant (<provider>)`, so every AI change is individually
/// acceptable and rejectable — in this app, and in Microsoft Word afterwards.
public struct RevisionMark: Hashable, Sendable {

    public var id: Int32
    public var author: String
    public var date: Date
    public var kind: RevisionKind
    /// `w:moveFromRangeStart` / `w:moveToRangeStart` pairing, when applicable.
    public var moveDestination: NodeID?

    public init(id: Int32, author: String, date: Date, kind: RevisionKind, moveDestination: NodeID? = nil) {
        self.id = id
        self.author = author
        self.date = date
        self.kind = kind
        self.moveDestination = moveDestination
    }
}

/// Review → Tracking → "Show Markup", i.e. how revisions are *displayed*.
///
/// This never changes the stored document; it changes what the layout engine
/// includes and what the painter draws.
public enum RevisionMarkup: String, Hashable, Sendable, CaseIterable {
    /// Final result, revisions applied, nothing shown.
    case noMarkup
    /// Final result with a thin change bar in the margin.
    case simpleMarkup
    /// Everything visible, inline or in balloons.
    case allMarkup
    /// The document as it was before any revisions.
    case original
}
