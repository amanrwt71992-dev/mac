#if canImport(AppKit)
import Foundation
import CoreKit

// MARK: - DocumentTextIndex

/// Maps between the document's own positions and the flat integer offsets that
/// Cocoa's text-input protocol insists on.
///
/// The mismatch is real and has three parts, which is why this type exists
/// rather than the view doing arithmetic inline:
///
/// 1. Our `TextPosition` is (paragraph, character offset). `NSTextInputClient`
///    speaks a single flat range over the whole document.
/// 2. Our offsets count grapheme clusters, because that is what the line breaker
///    measured and what the user perceives as a character. `NSRange` counts
///    UTF-16 code units, because that is what Cocoa's text system uses. For
///    anything beyond ASCII the two disagree.
/// 3. A paragraph mark occupies one position in the flat space but belongs to no
///    paragraph's text.
///
/// Getting any of these wrong shows up as an input-method editor committing text
/// in the wrong place, or a marked-text underline drawn over the wrong
/// characters — the kind of bug that is invisible in an English-only smoke test
/// and embarrassing the first time someone types Japanese.
struct DocumentTextIndex {

    struct Entry {
        let paragraphID: NodeID
        let text: String
        /// Cluster offset of this paragraph's first character in the flat space.
        let clusterStart: Int
        /// UTF-16 offset of this paragraph's first character in the flat space.
        let utf16Start: Int

        var clusterCount: Int { text.count }
        var utf16Count: Int { text.utf16.count }
    }

    let entries: [Entry]

    /// Total flat length including one trailing paragraph mark per paragraph.
    let totalClusters: Int
    let totalUTF16: Int

    private let byParagraphID: [NodeID: Entry]

    init(document: DocumentModel, markup: RevisionMarkup) {
        var built: [Entry] = []
        var lookup: [NodeID: Entry] = [:]
        var clusters = 0
        var units = 0

        for id in document.paragraphIDsInOrder {
            guard let paragraph = document.paragraph(withID: id) else { continue }
            let text = paragraph.plainText(markup: markup)
            let entry = Entry(
                paragraphID: id,
                text: text,
                clusterStart: clusters,
                utf16Start: units
            )
            built.append(entry)
            lookup[id] = entry
            // The paragraph mark is a real character to the input system: it is
            // what Return inserts and what Backspace at offset 0 deletes.
            clusters += text.count + 1
            units += text.utf16.count + 1
        }

        entries = built
        byParagraphID = lookup
        totalClusters = clusters
        totalUTF16 = units
    }

    func entry(for paragraphID: NodeID) -> Entry? { byParagraphID[paragraphID] }

    func clusterLength(of paragraphID: NodeID) -> Int {
        byParagraphID[paragraphID]?.clusterCount ?? 0
    }

    /// Flat UTF-16 offset of a document position. Clamps rather than traps: the
    /// input system routinely probes one past the end of the text.
    func utf16Offset(of position: TextPosition) -> Int {
        guard let entry = byParagraphID[position.paragraphID] else { return totalUTF16 }
        let characters = Array(entry.text)
        let count = max(0, min(position.characterOffset, characters.count))
        guard count > 0 else { return entry.utf16Start }
        return entry.utf16Start + String(characters[0 ..< count]).utf16.count
    }

    /// Flat cluster offset of a document position.
    func clusterOffset(of position: TextPosition) -> Int {
        guard let entry = byParagraphID[position.paragraphID] else { return totalClusters }
        return entry.clusterStart + max(0, min(position.characterOffset, entry.clusterCount))
    }

    /// Document position for a flat UTF-16 offset.
    func position(utf16Offset raw: Int) -> TextPosition {
        guard !entries.isEmpty else {
            return TextPosition(paragraphID: NodeID(0), characterOffset: 0)
        }
        let target = max(0, min(raw, totalUTF16))

        var chosen = entries[0]
        for entry in entries {
            guard entry.utf16Start <= target else { break }
            chosen = entry
        }

        let local = target - chosen.utf16Start
        var consumed = 0
        var clusters = 0
        for character in chosen.text {
            let width = String(character).utf16.count
            guard consumed + width <= local else { break }
            consumed += width
            clusters += 1
        }
        return TextPosition(paragraphID: chosen.paragraphID, characterOffset: clusters)
    }

    /// The document's text with paragraph marks as newlines.
    ///
    /// Used for the pasteboard and for the input system's substring queries.
    var plainText: String {
        entries.map(\.text).joined(separator: "\n")
    }
}

#endif
