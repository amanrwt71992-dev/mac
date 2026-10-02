#if canImport(AppKit)
import Foundation
import CoreKit
import EditorKit
import LayoutKit

// MARK: - DocumentController

/// Owns the document and everything derived from it.
///
/// The split matters. `EditorState` is the truth: the document tree, the
/// selection, the undo stack. The layout snapshot and the flat text index are
/// both *derived* from it and are recomputed whenever it changes. Keeping them
/// here rather than in the view means there is exactly one place that knows the
/// order of operations after an edit, and the view can never be caught drawing a
/// snapshot that belongs to a previous document.
///
/// This is also why `EditorKit` is not allowed to import `LayoutKit` (CI enforces
/// it): if the editor held a snapshot, every editing path would have to remember
/// to invalidate it, and the ones that forget are the ones that leave a page of
/// text laid out for a paragraph that no longer exists.
final class DocumentController {

    private(set) var state: EditorState
    private(set) var snapshot: LayoutSnapshot = .empty
    private(set) var textIndex: DocumentTextIndex

    private let engine: LayoutEngine
    private var generation: UInt64 = 0

    /// Shared with the renderer on purpose.
    ///
    /// Measurement and drawing must resolve a font request to the *same* face. If
    /// the view built its own measurer — or, worse, constructed an `NSFont` from
    /// the family name in the model — then a document asking for a family that is
    /// not installed would be measured against CoreText's fallback and drawn with
    /// a different one, and the caret would drift away from the glyphs. One
    /// instance, one cache, one answer.
    let measurer: CoreTextMeasurer

    /// The view is a weak reference: the view owns the controller, so holding it
    /// strongly here would keep the whole window alive after it was closed.
    weak var view: EditorView?

    init(document: DocumentModel, authorName: String) {
        measurer = CoreTextMeasurer()
        engine = LayoutEngine(measurer: measurer)
        state = EditorState(document: document, authorName: authorName)
        textIndex = DocumentTextIndex(document: document, markup: state.markup)
        relayout()
    }

    /// Rebuilds the snapshot and the flat text index from the current state.
    ///
    /// `generation` is bumped so that a stale snapshot held anywhere can be
    /// recognised as stale rather than silently trusted.
    func relayout() {
        generation += 1
        snapshot = engine.layout(
            document: state.document,
            markup: state.markup,
            generation: generation
        )
        textIndex = DocumentTextIndex(document: state.document, markup: state.markup)
    }

    /// Replaces the state, re-derives everything, and tells the view to redraw.
    func commit(_ newState: EditorState) {
        state = newState
        relayout()
        view?.documentDidChange()
    }

    /// The single funnel for edits.
    ///
    /// Every keystroke, every menu command and every assistant action goes
    /// through here, so re-layout and redraw cannot be forgotten by a new caller.
    func mutate(_ body: (inout EditorState) -> Void) {
        var updated = state
        body(&updated)
        commit(updated)
    }

    var document: DocumentModel { state.document }
    var selection: TextSelection { state.selection }
    var pageCount: Int { snapshot.pageCount }

    /// Word count and character count for the status bar.
    var counts: (words: Int, characters: Int, pages: Int) {
        let text = textIndex.entries.map(\.text).joined(separator: " ")
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return (words, text.count, snapshot.pageCount)
    }
}

// MARK: - Welcome document

/// The document a new window starts with.
///
/// Deliberately not blank: a blank page cannot show you whether pagination,
/// keep-with-next, justification or list numbering are working, and those are the
/// behaviours that separate this from a text box. Every paragraph here exercises
/// something the engine does, so opening the app is itself a smoke test.
enum WelcomeDocument {

    static func make() -> DocumentModel {
        // `DocumentBuilder` starts from `DocumentModel.blank`, which is already US
        // Letter with Word's "Normal" margins — 1 in all round and 0.5 in for the
        // header and footer, leaving a 6.5 × 9 in text area of 468 × 648 pt. It is
        // not restated here so that there is one place that decides the default
        // page setup.
        var builder = DocumentBuilder(author: "Zenith")

        builder.heading("Zenith", level: 1)
        builder.paragraph(
            "A native word processor for the Mac. Type anywhere on this page — the "
                + "text you are looking at is laid out by Zenith's own pagination "
                + "engine, measured with CoreText, not by a web browser and not by "
                + "Apple's text system.",
            style: "Normal"
        )
        builder.paragraph(
            "Apple's TextKit 2 supports exactly one text container per document, "
                + "which means it cannot produce pages, columns, tables on a page, "
                + "or a print preview at all. Accessing its older layout manager "
                + "downgrades it permanently. That is why the apps that do get "
                + "pagination right — Nisus Writer Pro and Mellel — wrote their own "
                + "engine on top of CoreText, and so did we.",
            style: "Normal"
        )

        builder.heading("Things to try", level: 2)
        builder.paragraph(
            "Select some text and press ⌘B. Press Return to split a paragraph, then "
                + "⌘Z to rejoin it — the runs come back with their formatting and "
                + "their identities intact. Click in the left margin and drag to "
                + "select whole paragraphs. Use View ▸ Zoom to check that the page "
                + "still breaks in the same place at every size, which is the point "
                + "of measuring once and scaling at draw time.",
            style: "Normal"
        )
        builder.paragraph(
            "Keep typing until the text reaches the bottom of the page. It will flow "
                + "onto a second sheet, and the sheet will appear in the scroll view "
                + "below this one — widow and orphan control decides how many lines "
                + "are allowed to be left behind, exactly as Word does.",
            style: "Normal"
        )

        builder.heading("What is not here yet", level: 2)
        builder.paragraph(
            "This build cannot open or save .docx files, has no ruler, no tables, no "
                + "images, no styles gallery, no find and replace, and no assistant. "
                + "Input-method editing is stubbed, so accented dead keys and "
                + "Japanese, Korean and Chinese input will not compose correctly yet. "
                + "Those arrive next; the engine underneath already handles the hard "
                + "part, which is knowing where every glyph goes on the page.",
            style: "Normal"
        )

        return builder.build()
    }
}

#endif
