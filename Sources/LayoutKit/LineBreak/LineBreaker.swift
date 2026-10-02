import Foundation
import CoreKit

// MARK: - Atom

/// One indivisible piece of a line: a grapheme cluster, a space, or a tab.
///
/// Cluster granularity rather than character granularity is what makes Indic,
/// Thai and emoji text survive layout — a break inside a cluster corrupts the
/// text, which is the class of bug glyph-indexed APIs are known for.
struct Atom {

    enum Kind {
        case text
        case space
        case nonBreakingSpace
        case tab
        /// A character between which CJK allows a break.
        case ideographic
        /// A hyphen: a break is allowed after it.
        case breakAfterPunctuation
    }

    var text: String
    /// Character offset of this atom's first character within the paragraph.
    var paragraphOffset: Int
    var style: ResolvedRunStyle
    /// Measured advance, in points. Zero for tabs, whose width is positional.
    var advance: Double
    var kind: Kind
    /// Whether a line may end after this atom.
    var canBreakAfter: Bool
}

// MARK: - LineBreaker

/// Greedy line breaking with tab stops, forced breaks, hanging trailing
/// whitespace, justification and hyphenation.
///
/// Pure: it takes a `ParagraphLayoutInput` and a `TextMeasurer` and returns
/// lines whose `frame.origin.y` is always zero. Vertical placement is the
/// paginator's job, because only the paginator knows which page a line is on.
/// Keeping the two concerns apart is what makes each independently testable and
/// what lets a line-break cache survive a page-height change.
///
/// Greedy rather than Knuth–Plass is a deliberate choice. Word is greedy; being
/// optimal-but-different produces visible reflow against the same document, and
/// fidelity to what the author sees in Word is worth more here than slightly
/// nicer rivers.
public struct LineBreaker: Sendable {

    public var measurer: any TextMeasurer

    public init(measurer: any TextMeasurer) {
        self.measurer = measurer
    }

    /// Floating-point slack.
    ///
    /// Accumulated advance widths are doubles fed by a font engine, so a line
    /// that is "exactly" full can land a fraction of a point either side. Without
    /// tolerance a paragraph Word fits on one line sometimes wraps in ours and
    /// the page count drifts. A hundredth of a point is far below anything
    /// visible and far above the accumulated error.
    static let widthTolerance: Double = 0.01

    /// Lays out one paragraph into lines.
    ///
    /// Never returns an empty array: an empty paragraph still occupies one line,
    /// because the paragraph mark is a character with a height, and dropping it
    /// changes the page count of every document containing a blank line.
    public func breakParagraph(_ input: ParagraphLayoutInput) -> [LayoutLine] {
        let atoms = flatten(input)
        let forced = Dictionary(
            input.breaks.map { ($0.characterOffset, $0.kind) },
            uniquingKeysWith: { first, _ in first }
        )

        var lines: [LayoutLine] = []
        var lineIndex = 0
        var lineStart = 0
        var cursor = 0
        /// Atom index after which the current line may break; -1 means none yet.
        var lastBreakAtom = -1
        var width = 0.0
        var consecutiveHyphens = 0
        /// A manual page/column break at the end of the paragraph must still be
        /// reported to the paginator even when it produces no further lines.
        var trailingForcedBreak: ForcedBreak?

        func firstLineExtra() -> Double { lineIndex == 0 ? input.firstLineIndent : 0 }
        func currentX() -> Double { input.indentStart + firstLineExtra() + width }

        func finishLine() {
            width = 0
            lastBreakAtom = -1
            lineIndex += 1
        }

        while cursor < atoms.count {
            let atom = atoms[cursor]
            let available = input.availableWidth(lineIndex: lineIndex)

            // A manual break always ends the line, whatever the width.
            if let kind = forced[atom.paragraphOffset] {
                let isLastAtom = cursor + 1 >= atoms.count
                lines.append(emit(
                    atoms: Array(atoms[lineStart..<cursor]),
                    input: input,
                    lineIndex: lineIndex,
                    isFirst: lineIndex == 0,
                    isLast: isLastAtom && kind == .line,
                    forcedBreak: kind
                ))
                if isLastAtom { trailingForcedBreak = kind }
                cursor += 1
                lineStart = cursor
                consecutiveHyphens = 0
                finishLine()
                continue
            }

            let atomWidth = self.width(of: atom, atX: currentX(), input: input)

            if width + atomWidth > available + Self.widthTolerance, cursor > lineStart {
                // Prefer the last legal break opportunity.
                if lastBreakAtom >= lineStart {
                    let slice = Array(atoms[lineStart...lastBreakAtom])
                    // `emit` already hangs trailing whitespace when the
                    // compatibility flag says to, so no second pass is needed —
                    // applying it twice would subtract the space's width from
                    // the line twice and shift every justified line short.
                    lines.append(emit(
                        atoms: slice,
                        input: input,
                        lineIndex: lineIndex,
                        isFirst: lineIndex == 0,
                        isLast: false,
                        forcedBreak: nil
                    ))
                    cursor = lastBreakAtom + 1
                    // Spaces consumed by the break do not start the next line.
                    while cursor < atoms.count, atoms[cursor].kind == .space { cursor += 1 }
                    lineStart = cursor
                    consecutiveHyphens = 0
                    finishLine()
                    continue
                }

                // No opportunity yet: hyphenate if we are allowed to.
                if let hyphenated = tryHyphenate(
                    atoms: atoms,
                    lineStart: lineStart,
                    cursor: cursor,
                    available: available,
                    input: input,
                    lineIndex: lineIndex,
                    consecutiveHyphens: consecutiveHyphens
                ) {
                    lines.append(hyphenated.line)
                    cursor = hyphenated.nextAtom
                    lineStart = cursor
                    consecutiveHyphens += 1
                    finishLine()
                    continue
                }

                // An unbreakable word longer than the line. Split here rather
                // than loop forever — Word does the same, which is why a very
                // long URL overflows identically in both.
                lines.append(emit(
                    atoms: Array(atoms[lineStart..<cursor]),
                    input: input,
                    lineIndex: lineIndex,
                    isFirst: lineIndex == 0,
                    isLast: false,
                    forcedBreak: nil
                ))
                lineStart = cursor
                // The spaces after an overflowing word belong to the line that
                // just ended. Skipping them here is what stops a line consisting
                // of nothing but a space from being emitted between two long
                // words — the breaker would otherwise find its only break
                // opportunity *on* that space and emit it as a line of its own.
                while lineStart < atoms.count, atoms[lineStart].kind == .space { lineStart += 1 }
                cursor = lineStart
                consecutiveHyphens = 0
                finishLine()
                continue
            }

            width += atomWidth
            if atom.canBreakAfter { lastBreakAtom = cursor }
            cursor += 1
        }

        if lineStart < atoms.count {
            lines.append(emit(
                atoms: Array(atoms[lineStart..<atoms.count]),
                input: input,
                lineIndex: lineIndex,
                isFirst: lineIndex == 0,
                isLast: true,
                forcedBreak: trailingForcedBreak
            ))
        } else if let kind = trailingForcedBreak, !lines.isEmpty {
            // The paragraph ended with a manual break: record it on the last
            // line so the paginator still starts a new page or column.
            lines[lines.count - 1] = Self.remark(line: lines[lines.count - 1], forcedBreak: kind)
        }

        // A break past the end of the text — `abc` followed by a manual line
        // break, or a paragraph containing nothing but a page break — has no atom
        // to attach to, so the main loop never sees it. It still ends a line and
        // still leaves the paragraph mark on the line after it, which is why this
        // emits two lines rather than one.
        let totalCharacters = input.segments.reduce(0) { $0 + $1.text.count }
        if let breakAtEnd = input.breaks.first(where: { $0.characterOffset >= totalCharacters }) {
            if lines.isEmpty {
                lines.append(emit(
                    atoms: [], input: input, lineIndex: 0,
                    isFirst: true, isLast: false, forcedBreak: breakAtEnd.kind
                ))
            } else {
                lines[lines.count - 1] = Self.remark(line: lines[lines.count - 1], forcedBreak: breakAtEnd.kind)
            }
            lines.append(emit(
                atoms: [], input: input, lineIndex: lines.count,
                isFirst: false, isLast: true, forcedBreak: nil
            ))
        }

        // An empty paragraph is still one line: the paragraph mark is a character
        // with a height, and dropping it changes the page count of every document
        // that contains a blank line.
        if lines.isEmpty {
            lines.append(emit(
                atoms: [], input: input, lineIndex: 0,
                isFirst: true, isLast: true, forcedBreak: input.breaks.first?.kind
            ))
        }

        return lines
    }

    /// Attaches a trailing forced break to an already-emitted line.
    ///
    /// Also clears `isLastLineOfParagraph`, because a line that ends in a manual
    /// break is by definition not the paragraph's last line — the paragraph mark
    /// sits on the line after it. Justification depends on this: Word justifies a
    /// line that ends in a manual break, and would not if it believed the line
    /// were the last one.
    private static func remark(line: LayoutLine, forcedBreak kind: ForcedBreak) -> LayoutLine {
        var copy = line
        copy.pendingBreak = kind
        copy.isLastLineOfParagraph = false
        return copy
    }

    // MARK: - Flattening

    /// Turns styled segments into atoms, measuring each segment exactly once.
    ///
    /// Measuring once per segment matters for the keystroke budget: re-measuring
    /// per candidate line would make layout quadratic in paragraph length.
    private func flatten(_ input: ParagraphLayoutInput) -> [Atom] {
        var atoms: [Atom] = []
        var paragraphOffset = 0

        for segment in input.segments {
            guard !segment.text.isEmpty else { continue }

            let measured = measurer.measure(segment.text, style: segment.style)
            let offsets = measured.clusterOffsets
            let advances = measured.advances
            guard !offsets.isEmpty else { continue }

            // Character offsets (segment-local) before which a break is legal.
            let opportunities = Set(measurer.breakOpportunities(in: segment.text, style: segment.style))

            for clusterIndex in offsets.indices {
                let start = min(offsets[clusterIndex], segment.text.count)
                let end = clusterIndex + 1 < offsets.count
                    ? min(offsets[clusterIndex + 1], segment.text.count)
                    : segment.text.count
                guard end > start else { continue }

                let lower = segment.text.index(segment.text.startIndex, offsetBy: start)
                let upper = segment.text.index(segment.text.startIndex, offsetBy: end)
                let text = String(segment.text[lower..<upper])
                let advance = clusterIndex < advances.count ? advances[clusterIndex] : 0
                let kind = Self.classify(text)

                var canBreak = opportunities.contains(end)
                switch kind {
                case .ideographic, .breakAfterPunctuation, .space:
                    canBreak = true
                case .tab:
                    canBreak = true
                case .text, .nonBreakingSpace:
                    break
                }
                // Never break so that a non-breaking space would start a line;
                // UAX #14 forbids it and the measurer may not model NBSP.
                if canBreak, end < segment.text.count {
                    let next = segment.text[segment.text.index(segment.text.startIndex, offsetBy: end)]
                    if next == "\u{00A0}" || next == "\u{2007}" || next == "\u{202F}" {
                        canBreak = false
                    }
                }

                atoms.append(Atom(
                    text: text,
                    paragraphOffset: paragraphOffset + start,
                    style: segment.style,
                    advance: advance,
                    kind: kind,
                    canBreakAfter: canBreak
                ))
            }
            paragraphOffset += segment.text.count
        }
        return atoms
    }

    static func classify(_ text: String) -> Atom.Kind {
        switch text {
        case "\t": return .tab
        case " ": return .space
        case "\u{00A0}", "\u{2007}", "\u{202F}": return .nonBreakingSpace
        // U+2011 NON-BREAKING HYPHEN is deliberately absent: it exists precisely
        // to forbid a break, and treating it like a hyphen is how a word gets
        // split where the author asked for it not to be.
        case "-", "\u{2010}", "\u{00AD}", "/": return .breakAfterPunctuation
        default: break
        }
        guard let scalar = text.unicodeScalars.first else { return .text }
        switch scalar.value {
        case 0x2E80...0x2FFF,   // CJK radicals, Kangxi, symbols and punctuation
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK ext A
             0x4E00...0x9FFF,   // CJK unified
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFFEF:   // Halfwidth and fullwidth forms
            return .ideographic
        default:
            return .text
        }
    }

    // MARK: - Widths and tabs

    /// Advance width of an atom at a given x position.
    ///
    /// Only tabs are positional: a tab's width is the distance to the next stop,
    /// so it depends on how much of the line is already filled.
    private func width(of atom: Atom, atX x: Double, input: ParagraphLayoutInput) -> Double {
        guard atom.kind == .tab else { return atom.advance }
        let target = nextTabStop(after: x, input: input)
        return max(0, target - x)
    }

    /// The next tab stop after `x`, honouring explicit stops and the default grid.
    ///
    /// Explicit stops are measured from the text-area edge, not from the indent —
    /// which is why a first-line indent shifts text but not where tabs land.
    func nextTabStop(after x: Double, input: ParagraphLayoutInput) -> Double {
        let stops = input.tabStops
            .map { $0.position.points }
            .filter { $0 > x + Self.widthTolerance }
            .sorted()
        if let first = stops.first { return first }

        let grid = input.defaultTabStop
        guard grid > 0 else { return x + grid }
        return (floor(x / grid) + 1) * grid
    }

    /// The alignment and leader of the stop a tab actually landed on.
    func tabStopLanded(on x: Double, input: ParagraphLayoutInput) -> (alignment: TabStop.Alignment, leader: TabStop.Leader) {
        if let match = input.tabStops.min(by: { abs($0.position.points - x) < abs($1.position.points - x) }),
           abs(match.position.points - x) < Self.widthTolerance {
            return (match.alignment, match.leader)
        }
        return (.left, .none)
    }

    // MARK: - Emitting lines

    /// Builds a `LayoutLine` from the atoms placed on it.
    private func emit(
        atoms: [Atom],
        input: ParagraphLayoutInput,
        lineIndex: Int,
        isFirst: Bool,
        isLast: Bool,
        forcedBreak: ForcedBreak?
    ) -> LayoutLine {
        let available = input.availableWidth(lineIndex: lineIndex)
        let originX = input.indentStart + (lineIndex == 0 ? input.firstLineIndent : 0)

        var segments: [LineSegment] = []
        var x = originX
        var maxAscent = 0.0
        var maxDescent = 0.0
        var maxLeading = 0.0
        var gapOffsets: [Int] = []
        var contentWidth = 0.0

        var index = 0
        while index < atoms.count {
            let atom = atoms[index]
            let metrics = measurer.lineMetrics(for: atom.style)
            maxAscent = max(maxAscent, metrics.ascent + atom.style.font.baselineOffsetPoints)
            maxDescent = max(maxDescent, metrics.descent - atom.style.font.baselineOffsetPoints)
            maxLeading = max(maxLeading, metrics.leading)

            // Group consecutive atoms that share a style and a tab-ness, so the
            // renderer gets one draw call per contiguous run.
            var groupText = ""
            var groupAdvances: [Double] = []
            var groupOffsets: [Int] = []
            let groupStartX = x
            var leader: TabStop.Leader?
            var leaderWidth = 0.0

            if atom.kind == .tab {
                let target = nextTabStop(after: x, input: input)
                let tabWidth = max(0, target - x)
                let landed = tabStopLanded(on: target, input: input)
                leader = landed.leader == .none ? nil : landed.leader
                leaderWidth = tabWidth
                x = target
                segments.append(LineSegment(
                    text: "",
                    characterOffset: atom.paragraphOffset,
                    style: atom.style,
                    x: groupStartX,
                    width: tabWidth,
                    tabLeader: leader,
                    tabLeaderWidth: leaderWidth
                ))
                index += 1
                continue
            }

            while index < atoms.count,
                  atoms[index].kind != .tab,
                  atoms[index].style == atom.style {
                let member = atoms[index]
                groupText += member.text
                groupAdvances.append(member.advance)
                groupOffsets.append(member.paragraphOffset)
                if member.kind == .space || member.kind == .nonBreakingSpace {
                    gapOffsets.append(groupOffsets.count - 1)
                }
                x += member.advance
                index += 1
            }

            contentWidth = x - originX
            segments.append(LineSegment(
                text: groupText,
                characterOffset: atom.paragraphOffset,
                style: atom.style,
                x: groupStartX,
                width: groupAdvances.reduce(0, +),
                advances: groupAdvances,
                clusterOffsets: groupOffsets
            ))
        }

        // Trailing whitespace handling for alignment and for the hanging margin.
        var hanging = 0.0
        var justificationExtra = 0.0
        var justificationGaps = 0

        var trailingSpaces = 0
        if !atoms.isEmpty, !input.wrapsTrailingSpaces {
            var trailing = atoms.count - 1
            while trailing >= 0, atoms[trailing].kind == .space || atoms[trailing].kind == .tab {
                hanging += atoms[trailing].advance
                if atoms[trailing].kind == .space { trailingSpaces += 1 }
                trailing -= 1
            }
        }
        let effectiveWidth = max(0, contentWidth - hanging)

        // Justification. Word does not justify the last line of a paragraph
        // unless that line ends with a manual break, and it never justifies a
        // line with no gaps at all.
        // `stretchesToFillLine` already encodes which OOXML alignments stretch,
        // including the kashida variants, so the breaker does not keep a second
        // copy of that rule that could drift from the model.
        let justifies = input.alignment.stretchesToFillLine
            && (!isLast || forcedBreak == .line)
            && gapOffsets.count > 0
        if justifies, effectiveWidth < available {
            let extra = available - effectiveWidth
            // A hanging trailing space is not a gap: it is not between two words,
            // so stretching it would push the last word short of the margin while
            // every other gap absorbed less. Excluding it is what makes justified
            // text actually reach the right margin.
            justificationGaps = max(0, gapOffsets.count - trailingSpaces)
            justificationExtra = extra / Double(max(1, justificationGaps))
        }

        // The paragraph mark contributes to the height of the paragraph's last
        // line, and to an empty paragraph's only line. This is Word's rule, not
        // an approximation: an empty paragraph formatted at 24 pt is 24 pt tall.
        if isLast || atoms.isEmpty {
            let markMetrics = measurer.lineMetrics(for: input.markStyle)
            let markOffset = input.markStyle.font.baselineOffsetPoints
            maxAscent = max(maxAscent, markMetrics.ascent + markOffset)
            maxDescent = max(maxDescent, markMetrics.descent - markOffset)
            maxLeading = max(maxLeading, markMetrics.leading)
        }

        let naturalHeight = maxAscent + maxDescent + maxLeading
        let height = input.lineSpacing.height(naturalHeight: max(naturalHeight, 1))

        let characterStart = atoms.first?.paragraphOffset ?? 0
        let characterEnd = atoms.isEmpty
            ? characterStart
            : (atoms[atoms.count - 1].paragraphOffset + atoms[atoms.count - 1].text.count)

        var line = LayoutLine(
            segments: segments,
            frame: Rect(x: originX, y: 0, width: input.widthAtLine.width(lineIndex: lineIndex), height: height),
            baselineOffset: maxAscent,
            ascent: maxAscent,
            descent: maxDescent,
            paragraphID: input.paragraphID,
            characterRange: characterStart..<max(characterStart, characterEnd),
            isFirstLineOfParagraph: isFirst,
            isLastLineOfParagraph: isLast,
            contentWidth: effectiveWidth,
            hangingTrailingWhitespace: hanging,
            justificationExtraPerGap: justificationExtra,
            justificationGapCount: justificationGaps
        )
        line.pendingBreak = forcedBreak
        return line
    }

    // MARK: - Hyphenation

    private struct HyphenationResult {
        var line: LayoutLine
        var nextAtom: Int
    }

    /// Tries to hyphenate the unbreakable word occupying `atoms[lineStart..<cursor]`.
    ///
    /// Returns `nil` when hyphenation is off, when the word is too short to
    /// hyphenate respectably, when the consecutive-hyphen limit is reached, or
    /// when the hyphen would not actually fit.
    private func tryHyphenate(
        atoms: [Atom],
        lineStart: Int,
        cursor: Int,
        available: Double,
        input: ParagraphLayoutInput,
        lineIndex: Int,
        consecutiveHyphens: Int
    ) -> HyphenationResult? {
        guard input.hyphenation.enabled else { return nil }
        if let limit = input.hyphenation.consecutiveLimit, consecutiveHyphens >= limit { return nil }

        let word = atoms[lineStart..<cursor]
        guard word.count >= 4 else { return nil }

        let style = atoms[lineStart].style
        let candidates = measurer.hyphenationCandidates(
            in: word.map { $0.text }.joined(),
            style: style
        )
        guard !candidates.isEmpty else { return nil }

        let hyphenWidth = measurer.hyphenWidth(style: style)

        // Respect `w:hyphenationZone`: Word will not hyphenate when the break
        // would land further from the right margin than the zone allows.
        let minimumWidth = max(0, available - input.hyphenation.zonePoints)

        var used = 0.0
        var bestSplit: Int?
        for offset in 0..<(cursor - lineStart) {
            let atom = atoms[lineStart + offset]
            let next = used + atom.advance
            if next + hyphenWidth > available + Self.widthTolerance { break }
            used = next
            if used >= minimumWidth { bestSplit = offset + 1 }
        }
        guard let split = bestSplit, split > 0, split < word.count else { return nil }
        // Word does not hyphenate so close to the start that only one or two
        // characters remain on the line.
        guard split >= 2 else { return nil }

        let slice = Array(atoms[lineStart..<(lineStart + split)])
        var line = emit(
            atoms: slice,
            input: input,
            lineIndex: lineIndex,
            isFirst: lineIndex == 0,
            isLast: false,
            forcedBreak: nil
        )
        line.hyphenInsertedAt = slice[slice.count - 1].paragraphOffset + slice[slice.count - 1].text.count
        return HyphenationResult(line: line, nextAtom: lineStart + split)
    }
}
