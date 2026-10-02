#if canImport(AppKit)
import AppKit
import CoreKit
import EditorKit
import LayoutKit

// MARK: - EditorView

/// The page view: renders the layout snapshot, owns the caret and the selection,
/// and accepts typing.
///
/// The view is **flipped** — y grows downward, origin at the top-left. That is not
/// a stylistic choice: the layout snapshot is in page coordinates measured from
/// the top-left of the sheet, so a flipped view means a page coordinate and a view
/// coordinate differ by one addition and one multiplication. In an unflipped view
/// every y in the codebase would need inverting, and the arithmetic errors that
/// produces are the hardest kind to spot without a screen.
///
/// The view holds no document state. It reads `controller.state` and
/// `controller.snapshot` and writes only through `controller.mutate`, so there is
/// one path by which an edit becomes pixels.
final class EditorView: NSView {

    let controller: DocumentController
    private let renderer: PageRenderer

    /// Top-left of each sheet, in view coordinates. Recomputed on every
    /// re-layout, resize and zoom change, because centring depends on the width
    /// the scroll view happens to have at that moment.
    private var pageOrigins: [CGPoint] = []
    private var contentWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0

    /// Display scale. Zoom changes the scale only, never the layout: the snapshot
    /// is measured at 100 % and multiplied at draw time. Re-laying out per zoom
    /// level would be slower and would mean the page breaks you see at 150 % are
    /// not the page breaks you get when you print.
    private var zoom: CGFloat = 1

    private var caretVisible = true
    private var blinkTimer: Timer?

    /// Anchor for a shift-click or a drag, captured at mouse-down so that dragging
    /// extends from where the gesture started rather than from wherever the
    /// selection happened to end last time.
    private var dragAnchor: TextPosition?

    /// The x the caret wants to return to when moving vertically.
    ///
    /// Moving up past a short line and then down again should put the caret back
    /// where it was, not at the end of the short line. Word, TextEdit and every
    /// other editor remember this; without it, arrowing up through a document
    /// walks the caret to the left margin.
    private var desiredCaretX: Double?

    /// Guards against re-entering geometry work when we set our own frame size.
    private var adjustingFrame = false

    /// Called after every re-layout with the text for the window's status bar.
    /// A closure rather than a delegate so the view does not have to know that a
    /// status bar exists.
    var statusHandler: ((String) -> Void)?

    init(frame: NSRect, controller: DocumentController) {
        self.controller = controller
        self.renderer = PageRenderer(measurer: controller.measurer)
        super.init(frame: frame)
        wantsLayer = false
        documentDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("EditorView is not created from a nib")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            caretVisible = true
            restartBlink()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        blinkTimer?.invalidate()
        blinkTimer = nil
        return super.resignFirstResponder()
    }

    // MARK: Input context

    // A custom text view would normally hand AppKit its own input context here:
    //
    //     private lazy var context = NSInputContext(client: self)
    //     override var inputContext: NSInputContext? { context }
    //
    // `NSInputContext` is not exported to Swift by the macOS 27 SDK — the compiler
    // reports "cannot find type 'NSInputContext' in scope" even with AppKit
    // imported. This is the same class of gap as `kCTFontSymbolicTraitKey` and
    // `CTFontCreateCopyWithSymbolicTraits` in the layout engine: the symbol exists
    // in Objective-C and is simply not visible from Swift on this SDK.
    //
    // The consequence is that no input-method editor attaches, so composition is
    // impossible rather than merely stubbed. Typing still works because
    // `interpretKeyEvents` falls back to `NSResponder.insertText(_:)`, which is
    // overridden below. Restoring IME needs either the Objective-C runtime
    // (`NSClassFromString("NSInputContext")` plus a `perform`-based constructor)
    // or a file compiled as Objective-C++ and bridged in; recorded as the first
    // thing to fix, because a word processor that cannot type Japanese, Chinese
    // or Korean is not a word processor.

    // MARK: Geometry

    /// Recomputes the page stack and resizes the view to fit it.
    func documentDidChange() {
        layoutStack()
        adjustingFrame = true
        setFrameSize(NSSize(width: contentWidth, height: contentHeight))
        adjustingFrame = false
        needsDisplay = true
        restartBlink()
        publishStatus()
    }

    private func publishStatus() {
        guard let statusHandler = statusHandler else { return }
        let counts = controller.counts
        let pages = counts.pages == 1 ? "1 page" : "\(counts.pages) pages"
        let words = counts.words == 1 ? "1 word" : "\(counts.words) words"
        statusHandler("\(pages)   \u{00B7}   \(words)   \u{00B7}   \(Int((zoom * 100).rounded()))%")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !adjustingFrame else { return }
        // The scroll view resized us: re-centre the sheets against the new width.
        layoutStack()
        needsDisplay = true
    }

    private func layoutStack() {
        let pages = controller.snapshot.pages
        let outer = CGFloat(PageRenderer.outerMargin)
        let gap = CGFloat(PageRenderer.pageGap)

        var widest: CGFloat = 0
        for page in pages {
            widest = max(widest, CGFloat(page.pageSize.widthPoints) * zoom)
        }
        let minimumWidth = widest + outer * 2

        // When the window is wider than the sheet, centre it; when narrower, let
        // the scroll view clip rather than squeezing the page.
        let available = max(bounds.width, minimumWidth)

        var origins: [CGPoint] = []
        var y = outer
        for page in pages {
            let width = CGFloat(page.pageSize.widthPoints) * zoom
            let height = CGFloat(page.pageSize.heightPoints) * zoom
            origins.append(CGPoint(x: (available - width) / 2, y: y))
            y += height + gap
        }

        pageOrigins = origins
        contentWidth = available
        contentHeight = pages.isEmpty
            ? outer * 2
            : y - gap + outer
    }

    func setZoom(_ newZoom: CGFloat) {
        zoom = min(max(newZoom, 0.25), 4)
        documentDidChange()
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }
    func zoomToActualSize() { setZoom(1) }
    var currentZoom: CGFloat { zoom }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.42, alpha: 1).setFill()
        bounds.fill()

        let pages = controller.snapshot.pages
        for (index, page) in pages.enumerated() {
            guard index < pageOrigins.count else { break }
            let origin = pageOrigins[index]
            let rect = PageRenderer.pageRect(for: page, at: origin, zoom: zoom)
            guard rect.intersects(dirtyRect) else { continue }

            renderer.drawPaper(rect)

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            drawSelection(on: page, at: origin)
            renderer.draw(page: page, at: origin, zoom: zoom)
            NSGraphicsContext.restoreGraphicsState()
        }

        drawCaret()
    }

    private func drawSelection(on page: PageLayout, at origin: CGPoint) {
        let selection = controller.state.selection
        guard !selection.isCollapsed else { return }
        let (start, end, _) = selection.ordered(in: controller.state.document)
        guard start != end else { return }

        let ordering = ParagraphOrdering(document: controller.state.document)
        let firstParagraph = ordering.index(of: start.paragraphID)
        let lastParagraph = ordering.index(of: end.paragraphID)
        guard firstParagraph <= lastParagraph else { return }

        NSColor.selectedTextBackgroundColor.setFill()

        for paragraph in page.paragraphs {
            let paragraphIndex = ordering.index(of: paragraph.paragraphID)
            guard paragraphIndex >= firstParagraph, paragraphIndex <= lastParagraph else { continue }

            for line in paragraph.lines {
                var low = line.characterRange.lowerBound
                var high = line.characterRange.upperBound

                // The first and last paragraphs of the selection are partial; a
                // paragraph strictly between them is taken whole.
                if paragraphIndex == firstParagraph { low = max(low, start.characterOffset) }
                if paragraphIndex == lastParagraph { high = min(high, end.characterOffset) }
                guard low < high else { continue }

                let x0 = line.xOffset(forCharacterOffset: low)
                let x1 = line.xOffset(forCharacterOffset: high)
                let top = (line.frame.y + line.baselineOffset - line.ascent) * zoom
                let height = (line.ascent + line.descent) * zoom

                NSRect(
                    x: origin.x + CGFloat(x0) * zoom,
                    y: origin.y + CGFloat(top),
                    width: CGFloat(x1 - x0) * zoom,
                    height: CGFloat(height)
                ).fill()
            }
        }
    }

    private func drawCaret() {
        guard caretVisible, window?.firstResponder === self else { return }
        guard let rect = caretRect(for: controller.state.selection.focus) else { return }
        NSColor.black.setFill()
        rect.fill()
    }

    private func restartBlink() {
        caretVisible = true
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard window != nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.caretVisible.toggle()
            self.needsDisplay = true
        }
    }

    // MARK: Caret and hit testing

    /// The caret rectangle for a document position, in view coordinates.
    func caretRect(for position: TextPosition) -> NSRect? {
        guard let found = line(containing: position) else { return nil }
        let (line, pageIndex) = found
        guard pageIndex < pageOrigins.count else { return nil }

        let origin = pageOrigins[pageIndex]
        let clamped = min(
            max(position.characterOffset, line.characterRange.lowerBound),
            max(line.characterRange.lowerBound, line.characterRange.upperBound)
        )
        let x = line.xOffset(forCharacterOffset: clamped)
        let top = (line.frame.y + line.baselineOffset - line.ascent) * zoom
        let height = (line.ascent + line.descent) * zoom

        return NSRect(
            x: origin.x + CGFloat(x) * zoom,
            y: origin.y + CGFloat(top),
            width: 1.5,
            height: CGFloat(max(height, 8))
        )
    }

    /// The line a position falls on, and the page that line is on.
    ///
    /// A caret at a line boundary belongs to the *start* of the following line,
    /// which is what `characterRange.contains` gives us for free because the range
    /// is half-open. A caret at the very end of the paragraph belongs to no line's
    /// range and has to fall back to the last line.
    private func line(containing position: TextPosition) -> (LayoutLine, Int)? {
        for (pageIndex, page) in controller.snapshot.pages.enumerated() {
            for paragraph in page.paragraphs where paragraph.paragraphID == position.paragraphID {
                var first: LayoutLine?
                var last: LayoutLine?
                for line in paragraph.lines {
                    if first == nil { first = line }
                    last = line
                    if line.characterRange.contains(position.characterOffset) {
                        return (line, pageIndex)
                    }
                }
                if let first = first, position.characterOffset <= first.characterRange.lowerBound {
                    return (first, pageIndex)
                }
                if let last = last { return (last, pageIndex) }
                return nil
            }
        }
        return nil
    }

    /// The document position nearest a point in view coordinates.
    ///
    /// Clicks in the grey gutter outside a sheet snap to the nearest sheet rather
    /// than doing nothing — that is what makes "click below the last page to go to
    /// the end of the document" work.
    func textPosition(at point: NSPoint) -> TextPosition? {
        let pages = controller.snapshot.pages
        guard !pages.isEmpty else { return nil }

        for (index, page) in pages.enumerated() {
            guard index < pageOrigins.count else { break }
            let rect = PageRenderer.pageRect(for: page, at: pageOrigins[index], zoom: zoom)
            guard rect.contains(point) else { continue }
            let pageX = Double(point.x - rect.origin.x) / Double(zoom)
            let pageY = Double(point.y - rect.origin.y) / Double(zoom)
            return nearestPosition(on: page, pageX: pageX, pageY: pageY)
        }

        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, page) in pages.enumerated() {
            guard index < pageOrigins.count else { break }
            let rect = PageRenderer.pageRect(for: page, at: pageOrigins[index], zoom: zoom)
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard let index = bestIndex else { return nil }

        let rect = PageRenderer.pageRect(for: pages[index], at: pageOrigins[index], zoom: zoom)
        let pageX = Double(min(max(point.x, rect.minX), rect.maxX) - rect.minX) / Double(zoom)
        let pageY = Double(min(max(point.y, rect.minY), rect.maxY) - rect.minY) / Double(zoom)
        return nearestPosition(on: pages[index], pageX: pageX, pageY: pageY)
    }

    private func nearestPosition(on page: PageLayout, pageX: Double, pageY: Double) -> TextPosition? {
        var bestLine: LayoutLine?
        var bestDistance = Double.greatestFiniteMagnitude

        for paragraph in page.paragraphs {
            for line in paragraph.lines {
                let middle = line.frame.y + line.frame.height / 2
                let distance = abs(middle - pageY)
                if distance < bestDistance {
                    bestDistance = distance
                    bestLine = line
                }
            }
        }
        guard let line = bestLine else { return nil }
        return TextPosition(
            paragraphID: line.paragraphID,
            characterOffset: line.characterOffset(nearestX: pageX)
        )
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let position = textPosition(at: point) else { return }

        let extends = event.modifierFlags.contains(.shift)
        dragAnchor = extends ? controller.state.selection.anchor : position

        controller.mutate { state in
            if extends {
                state.selection = state.selection.extending(to: position)
            } else {
                state.selection = TextSelection(caret: position)
            }
        }
        desiredCaretX = nil
        caretVisible = true
        restartBlink()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let anchor = dragAnchor, let position = textPosition(at: point) else { return }
        controller.mutate { state in
            state.selection = TextSelection(anchor: anchor, focus: position)
        }
        desiredCaretX = nil
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
    }

    override func keyDown(with event: NSEvent) {
        caretVisible = true
        interpretKeyEvents([event])
    }

    // MARK: Menu commands

    /// Named with a `zenith` prefix rather than using the standard selectors
    /// (`copy:`, `selectAll:` and friends) because several of those are declared on
    /// `NSResponder` with signatures that must be matched exactly to override.
    /// Distinct names mean the menu wiring cannot collide with an inherited method,
    /// and the key equivalents still work because they are carried by the menu item.
    @objc func zenithUndo(_ sender: Any?) {
        controller.mutate { $0.undo(timestamp: Date()) }
        desiredCaretX = nil
    }

    @objc func zenithRedo(_ sender: Any?) {
        controller.mutate { $0.redo(timestamp: Date()) }
        desiredCaretX = nil
    }

    @objc func zenithSelectAll(_ sender: Any?) {
        controller.mutate { state in
            let index = DocumentTextIndex(document: state.document, markup: state.markup)
            guard let first = index.entries.first, let last = index.entries.last else { return }
            state.selection = TextSelection(
                anchor: TextPosition(paragraphID: first.paragraphID, characterOffset: 0),
                focus: TextPosition(paragraphID: last.paragraphID, characterOffset: last.clusterCount)
            )
        }
        desiredCaretX = nil
    }

    @objc func zenithCopy(_ sender: Any?) {
        let (start, end, _) = controller.state.selection.ordered(in: controller.state.document)
        guard start != end else { NSSound.beep(); return }
        let text = text(from: start, to: end)
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func zenithCut(_ sender: Any?) {
        zenithCopy(sender)
        guard !controller.state.selection.isCollapsed else { return }
        controller.mutate { $0.deleteBackward(timestamp: Date()) }
        desiredCaretX = nil
    }

    @objc func zenithPaste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        controller.mutate { state in
            let now = Date()
            // Paste is a sequence of edits in the model, but it must be a single
            // undo step: nobody wants ⌘Z to remove one character of a paragraph
            // they just pasted.
            var lines = text.components(separatedBy: "\n")
            guard let first = lines.first else { return }
            state.insertText(first, timestamp: now)
            lines.removeFirst()
            for line in lines {
                state.insertParagraphBreak(timestamp: now)
                if !line.isEmpty { state.insertText(line, timestamp: now) }
            }
        }
        desiredCaretX = nil
    }

    @objc func zenithZoomIn(_ sender: Any?) { zoomIn() }

    @objc func zenithZoomOut(_ sender: Any?) { zoomOut() }

    @objc func zenithZoomToActualSize(_ sender: Any?) { zoomToActualSize() }

    @objc func zenithToggleBold(_ sender: Any?) {
        controller.mutate { $0.toggleBold(timestamp: Date()) }
    }

    @objc func zenithToggleItalic(_ sender: Any?) {
        controller.mutate { $0.toggleItalic(timestamp: Date()) }
    }

    // MARK: Text extraction

    /// Plain text between two positions, with paragraph marks as newlines.
    private func text(from start: TextPosition, to end: TextPosition) -> String {
        let index = controller.textIndex
        let ordering = ParagraphOrdering(document: controller.state.document)
        let firstParagraph = ordering.index(of: start.paragraphID)
        let lastParagraph = ordering.index(of: end.paragraphID)
        guard firstParagraph <= lastParagraph else { return "" }

        var pieces: [String] = []
        for entry in index.entries {
            let position = ordering.index(of: entry.paragraphID)
            guard position >= firstParagraph, position <= lastParagraph else { continue }

            let characters = Array(entry.text)
            var low = 0
            var high = characters.count
            if position == firstParagraph { low = min(max(start.characterOffset, 0), characters.count) }
            if position == lastParagraph { high = min(max(end.characterOffset, low), characters.count) }

            if position != firstParagraph { pieces.append("\n") }
            guard low < high else { continue }
            pieces.append(String(characters[low ..< high]))
        }
        return pieces.joined()
    }
}

// MARK: - Caret movement

extension EditorView {

    /// Moves the caret horizontally, crossing paragraph boundaries.
    func moveHorizontally(by delta: Int, extendSelection: Bool) {
        guard delta != 0 else { return }
        controller.mutate { state in
            let document = state.document
            let order = document.paragraphIDsInOrder
            var focus = state.selection.focus
            guard let current = order.firstIndex(of: focus.paragraphID) else { return }

            let length = document.paragraph(withID: focus.paragraphID)?.characterCount ?? 0

            if delta < 0 {
                if focus.characterOffset > 0 {
                    focus.characterOffset -= 1
                } else if current > 0 {
                    let previous = order[current - 1]
                    let previousLength = document.paragraph(withID: previous)?.characterCount ?? 0
                    focus = TextPosition(paragraphID: previous, characterOffset: previousLength)
                }
            } else {
                if focus.characterOffset < length {
                    focus.characterOffset += 1
                } else if current + 1 < order.count {
                    focus = TextPosition(paragraphID: order[current + 1], characterOffset: 0)
                }
            }

            if extendSelection {
                state.selection = state.selection.extending(to: focus)
            } else {
                state.selection = TextSelection(caret: focus)
            }
        }
        desiredCaretX = nil
    }

    /// Moves the caret one visual line up or down, preserving the horizontal
    /// position across lines that are too short to reach it.
    func moveVertically(by delta: Int, extendSelection: Bool) {
        guard delta != 0 else { return }

        var lines: [LayoutLine] = []
        for page in controller.snapshot.pages {
            for paragraph in page.paragraphs {
                lines.append(contentsOf: paragraph.lines)
            }
        }
        guard !lines.isEmpty else { return }

        let focus = controller.state.selection.focus

        // Resolve the caret's line by index rather than by comparing line values:
        // `LayoutLine` is a struct, so there is no identity to compare, and two
        // structurally equal lines in different paragraphs would be
        // indistinguishable anyway. Same precedence as `line(containing:)` — the
        // first line whose half-open range holds the offset, else the paragraph's
        // last line.
        var firstOfParagraph: Int?
        var lastOfParagraph: Int?
        var exact: Int?
        for (index, line) in lines.enumerated() {
            guard line.paragraphID == focus.paragraphID else { continue }
            if firstOfParagraph == nil { firstOfParagraph = index }
            lastOfParagraph = index
            if line.characterRange.contains(focus.characterOffset) {
                exact = index
                break
            }
        }
        guard let currentIndex = exact ?? lastOfParagraph ?? firstOfParagraph else { return }
        let currentLine = lines[currentIndex]

        let targetIndex = min(max(currentIndex + delta, 0), lines.count - 1)
        let target = lines[targetIndex]

        let wantedX = desiredCaretX ?? currentLine.xOffset(forCharacterOffset: focus.characterOffset)
        desiredCaretX = wantedX

        let newPosition = TextPosition(
            paragraphID: target.paragraphID,
            characterOffset: target.characterOffset(nearestX: wantedX)
        )

        controller.mutate { state in
            if extendSelection {
                state.selection = state.selection.extending(to: newPosition)
            } else {
                state.selection = TextSelection(caret: newPosition)
            }
        }
    }
}

// MARK: - NSTextInputClient

extension EditorView: NSTextInputClient {

    /// Plain typing.
    ///
    /// `interpretKeyEvents` calls this single-argument method when there is no
    /// input context — which, on this SDK, is always. It is the reason the app can
    /// be typed into at all without `NSInputContext`.
    ///
    /// `@objc` and *not* `override`. `insertText(_:)` is an optional requirement of
    /// `NSStandardKeyBindingResponding` that `NSResponder` does not implement, so
    /// there is nothing in the superclass to override — the compiler rejects the
    /// keyword. `doCommand(by:)`, by contrast, *is* implemented by `NSResponder`
    /// and does require it. Marking this `@objc` publishes the `insertText:`
    /// selector, which is how `interpretKeyEvents` finds it at runtime.
    @objc func insertText(_ insertString: String) {
        insert(string: insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// What an input-method editor calls when it commits composed text.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let plain = string as? String {
            text = plain
        } else if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else {
            return
        }
        insert(string: text, replacementRange: replacementRange)
    }

    /// The one place a keystroke becomes a model edit.
    private func insert(string text: String, replacementRange: NSRange) {
        // Read the index *before* the edit: `replacementRange` is expressed
        // against the text as the input system last saw it.
        let index = controller.textIndex

        controller.mutate { state in
            if replacementRange.location != NSNotFound, replacementRange.length > 0 {
                let start = index.position(utf16Offset: replacementRange.location)
                let end = index.position(
                    utf16Offset: replacementRange.location + replacementRange.length
                )
                state.selection = TextSelection(anchor: start, focus: end)
            }

            let now = Date()
            switch text {
            case "\n", "\r", "\u{0003}":
                state.insertParagraphBreak(timestamp: now)
            case "\t":
                state.insertTab(timestamp: now)
            default:
                state.insertText(text, timestamp: now)
            }
        }
        desiredCaretX = nil
        caretVisible = true
        scrollCaretToVisible()
    }

    /// v1 does not implement composition.
    ///
    /// Marked text is inserted as final text instead of being held in a
    /// composing state, which means an input-method editor commits each keystroke
    /// immediately. That is wrong for Chinese, Japanese and Korean input and for
    /// dead-key accents, and it is the first thing to fix — it is recorded here
    /// rather than left implicit so that nobody mistakes this build for
    /// IME-complete.
    func hasMarkedText() -> Bool { false }

    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        insertText(string, replacementRange: replacementRange)
    }

    func unmarkText() {}

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func selectedRange() -> NSRange {
        let index = controller.textIndex
        let (start, end, _) = controller.state.selection.ordered(in: controller.state.document)
        let low = index.utf16Offset(of: start)
        let high = index.utf16Offset(of: end)
        return NSRange(location: min(low, high), length: abs(high - low))
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        let index = controller.textIndex
        let location = max(0, min(range.location, index.totalUTF16))
        let length = max(0, min(range.length, index.totalUTF16 - location))

        if let actual = actualRange {
            actual.pointee = NSRange(location: location, length: length)
        }

        let start = index.position(utf16Offset: location)
        let end = index.position(utf16Offset: location + length)
        let string = text(from: start, to: end)

        return NSAttributedString(
            string: string,
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
    }

    func characterIndex(for point: NSPoint) -> Int {
        let index = controller.textIndex
        guard let position = textPosition(at: point) else { return index.totalUTF16 }
        return index.utf16Offset(of: position)
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let index = controller.textIndex
        if let actual = actualRange { actual.pointee = range }

        let position = index.position(utf16Offset: range.location)
        guard let rect = caretRect(for: position), let window = window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// Routes the standard key bindings.
    ///
    /// Compared by name rather than by `Selector` equality: `NSStringFromSelector`
    /// is unambiguous and cannot be confused with an inherited `NSResponder`
    /// method of the same shape.
    override func doCommand(by commandSelector: Selector) {
        let now = Date()

        switch NSStringFromSelector(commandSelector) {
        case "deleteBackward:":
            controller.mutate { $0.deleteBackward(timestamp: now) }
        case "deleteForward:":
            controller.mutate { $0.deleteForward(timestamp: now) }
        case "deleteToEndOfParagraph:", "deleteToEndOfText:":
            controller.mutate { state in
                state.zenithDeleteToEndOfParagraph()
            }
        case "deleteToBeginningOfParagraph:", "deleteToBeginningOfText:":
            controller.mutate { state in
                state.zenithDeleteToStartOfParagraph()
            }
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:":
            controller.mutate { $0.insertParagraphBreak(timestamp: now) }
        case "insertTab:", "insertTabIgnoringFieldEditor:":
            controller.mutate { $0.insertTab(timestamp: now) }
        case "insertBacktab:":
            controller.mutate { $0.insertTab(timestamp: now) }

        case "moveLeft:", "moveBackward:":
            moveHorizontally(by: -1, extendSelection: false)
        case "moveRight:", "moveForward:":
            moveHorizontally(by: 1, extendSelection: false)
        case "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:":
            moveHorizontally(by: -1, extendSelection: true)
        case "moveRightAndModifySelection:", "moveForwardAndModifySelection:":
            moveHorizontally(by: 1, extendSelection: true)

        case "moveUp:":
            moveVertically(by: -1, extendSelection: false)
        case "moveUpAndModifySelection:":
            moveVertically(by: -1, extendSelection: true)
        case "moveDown:":
            moveVertically(by: 1, extendSelection: false)
        case "moveDownAndModifySelection:":
            moveVertically(by: 1, extendSelection: true)

        case "moveToBeginningOfParagraph:", "moveToBeginningOfLine:":
            moveToStartOfParagraph(extendSelection: false)
        case "moveToEndOfParagraph:", "moveToEndOfLine:":
            moveToEndOfParagraph(extendSelection: false)
        case "moveToBeginningOfDocument:":
            moveToDocumentStart(extendSelection: false)
        case "moveToEndOfDocument:":
            moveToDocumentEnd(extendSelection: false)

        case "moveToBeginningOfParagraphAndModifySelection:",
             "moveToBeginningOfLineAndModifySelection:",
             "moveToBeginningOfDocumentAndModifySelection:":
            moveToStartOfParagraph(extendSelection: true)
        case "moveToEndOfParagraphAndModifySelection:",
             "moveToEndOfLineAndModifySelection:",
             "moveToEndOfDocumentAndModifySelection:":
            moveToEndOfParagraph(extendSelection: true)

        case "selectAll:":
            zenithSelectAll(nil)
        case "copy:":
            zenithCopy(nil)
        case "cut:":
            zenithCut(nil)
        case "paste:":
            zenithPaste(nil)
        case "undo:":
            zenithUndo(nil)
        case "redo:":
            zenithRedo(nil)

        default:
            // An unhandled binding should be silent, not a beep: AppKit sends a
            // great many speculative commands and beeping at them makes the app
            // feel broken.
            break
        }

        // Note: `desiredCaretX` is deliberately *not* reset here. Vertical moves
        // set it and must be allowed to keep it across repeated commands; the
        // handlers that invalidate it — typing, horizontal moves, mouse clicks —
        // clear it themselves.
        caretVisible = true
        scrollCaretToVisible()
    }

    private func moveToStartOfParagraph(extendSelection: Bool) {
        let target = TextPosition(
            paragraphID: controller.state.selection.focus.paragraphID,
            characterOffset: 0
        )
        apply(target, extendSelection: extendSelection)
    }

    private func moveToEndOfParagraph(extendSelection: Bool) {
        let focus = controller.state.selection.focus
        let length = controller.state.document.paragraph(withID: focus.paragraphID)?.characterCount ?? 0
        apply(TextPosition(paragraphID: focus.paragraphID, characterOffset: length), extendSelection: extendSelection)
    }

    private func moveToDocumentStart(extendSelection: Bool) {
        guard let first = controller.textIndex.entries.first else { return }
        apply(TextPosition(paragraphID: first.paragraphID, characterOffset: 0), extendSelection: extendSelection)
    }

    private func moveToDocumentEnd(extendSelection: Bool) {
        guard let last = controller.textIndex.entries.last else { return }
        apply(
            TextPosition(paragraphID: last.paragraphID, characterOffset: last.clusterCount),
            extendSelection: extendSelection
        )
    }

    private func apply(_ target: TextPosition, extendSelection: Bool) {
        controller.mutate { state in
            if extendSelection {
                state.selection = state.selection.extending(to: target)
            } else {
                state.selection = TextSelection(caret: target)
            }
        }
    }

    /// Keeps the caret on screen after an edit.
    ///
    /// The rectangle is grown before scrolling so the caret does not stop exactly
    /// flush against the edge of the visible area, which reads as clipped.
    private func scrollCaretToVisible() {
        guard let rect = caretRect(for: controller.state.selection.focus) else { return }
        scrollRectToVisible(rect.insetBy(dx: -48, dy: -12))
    }
}

// MARK: - Deletions the model does not yet expose

extension EditorState {

    /// ⌘⌫ / ⌘⌦. Deletes to the paragraph boundary.
    ///
    /// Implemented by repeated single-character deletion so that the coalescing
    /// rules in `EditorState` still apply and the whole gesture lands as one undo
    /// step. Not the fastest possible implementation; correct first, then fast.
    mutating func zenithDeleteToEndOfParagraph() {
        let now = Date()
        let paragraphID = selection.focus.paragraphID
        let length = document.paragraph(withID: paragraphID)?.characterCount ?? 0
        var guardCounter = 0
        while selection.focus.paragraphID == paragraphID,
              selection.focus.characterOffset < length,
              guardCounter < 100_000 {
            deleteForward(timestamp: now)
            guardCounter += 1
        }
    }

    mutating func zenithDeleteToStartOfParagraph() {
        let now = Date()
        let paragraphID = selection.focus.paragraphID
        var guardCounter = 0
        while selection.focus.paragraphID == paragraphID,
              selection.focus.characterOffset > 0,
              guardCounter < 100_000 {
            deleteBackward(timestamp: now)
            guardCounter += 1
        }
    }
}

#endif
