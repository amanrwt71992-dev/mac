# Roadmap

Sequenced so that **a useful app exists at every stage** rather than a half-built monolith
at the end. Each milestone has an exit test that is objectively pass/fail.

Effort is in **focused developer-weeks** for one experienced engineer. Treat as order-of-
magnitude, not commitments. The two big uncertainties are the layout engine (§M0–M2) and
OOXML fidelity (§M2–M4); both have a long tail.

```
M0 ── M0.5 ── M1 ─── M2 ─── M3 ─── M4 ─── M5 ─── M6 ───►
engine  docx  word-   AI    review  pro     scale
 proof   I/O  class  layer  &collab features & polish
 4w     6w    10w     5w     5w      8w      ongoing
        └──── 20 weeks to "better than GenOffice for real documents" ────┘
```

---

## M0 — The engine proof (≈ 4 weeks)

**Goal:** prove the architecture works before committing to it. A native window that shows
real pages of real text, laid out by us, at 120 fps.

Deliverables
- SwiftPM workspace with the package split from `03-ARCHITECTURE.md` and the import rules
  enforced by CI.
- CI green on `ubuntu-latest` (core) **and** `xcode-27` (full app build). This is set up on
  day one, because it is our only compiler.
- `LayoutKit`: `TextShaper` protocol + `CoreTextShaper`; greedy line breaker; single-section
  paginator with margins, page size, orientation.
- `EditorKit`: `EditorView` (NSView) with `NSTextInputClient` — typing, IME marked text,
  emoji, dictation; caret; mouse selection by character/word/paragraph; keyboard navigation;
  clipboard.
- Basic character formatting: font family, size, bold, italic, underline, colour, alignment,
  line spacing. Basic paragraph formatting: indents, spacing before/after.
- Page rendering with visible page edges, margins, and a horizontal ruler.
- Zoom, scroll, viewport-driven layout.
- `zip-gate` CI job wired up (trivially passing at first, then load-bearing).

**Exit test**
1. A 300-page, 200,000-word document opens to first paint in **< 1.5 s** and scrolls at
   120 Hz with **zero** dropped frames, measured in CI on `xcode-27-xlarge`.
2. Typing a CJK paragraph with an IME produces correct marked-text behaviour.
3. Right-clicking selected text shows **Writing Tools** (Tier 2), and accepting a rewrite
   puts the result back correctly. ← *This alone already beats GenOffice, which cannot do it
   at all.*
4. Dark UI with a white page (GenOffice #1811), for free.

**Risk to retire in M0:** can a CoreText-based engine actually hit the perf contract? If not,
we learn it in week 2, not month 18.

### M0 status — 2026-10-02

Landed, and green in CI on all three jobs (`checks`, Linux Swift 6.2, macOS 27 / Xcode 27) with
zero compiler warnings.

**What the milestone actually became.** The plan above describes a *visible* M0: a window, a
ruler, IME, Writing Tools in the context menu. What shipped instead is the engine underneath all
of that, verified by a headless harness (`swift run Galley selftest`, `layout`, `providers`).
That was a deliberate substitution, not a shortfall. Two reasons:

1. The exit question at this stage is "does the engine lay a document out correctly", and that
   is answerable without a single pixel. A harness runs identically on a Linux runner and on
   `xcode-27`, so it is checked on every push instead of by hand once a week.
2. There is no Swift toolchain in the development sandbox. CI is the compiler. Writing an AppKit
   view layer means debugging hit-testing and `NSTextInputClient` marked-text through a
   three-minute remote loop; writing the model, the breaker and the paginator means debugging
   arithmetic through the same loop, and arithmetic is what the exit test is actually about.

The window, ruler, IME, clipboard, zoom and Writing Tools move to **M0.5** unchanged. Nothing
below was descoped to make room for them.

**Delivered**

| Package | Contents |
|---|---|
| `CoreKit` | twip/half-point/EMU/fiftieths-of-a-percent units; page sizes and margin presets; the OOXML document tree; `NodeID`; the mutation algebra with inverse capture; Word-like undo coalescing; character-level paragraph editing; `TextPosition`/`TextSelection`; `DocumentBuilder`; the font-substitution policy |
| `LayoutKit` | `StyleResolver` (cascade → concrete numbers), greedy `LineBreaker`, `Paginator`, `LayoutSnapshot`, `CoreTextMeasurer` behind `#if canImport(CoreText)`, `FixedWidthMeasurer` for tests and Linux |
| `EditorKit` | `EditorState`: typing, Return/Backspace/fn-Delete, cross-paragraph deletion, character and paragraph formatting, tracked changes. Depends on `CoreKit` alone — CI fails if it imports `LayoutKit` |
| `IntelligenceKit` | `AIProvider` protocol, task taxonomy with an honest Writing Tools mapping, redaction policy, `AssistantMutationBuilder`, provider catalogue (Apple Intelligence + OpenAI-compatible + Anthropic + local Ollama) |
| `GalleyApp` | headless harness: `selftest`, `layout`, `providers`, `version` |

Fidelity rules that are implemented and tested, not merely documented: `nil` vs explicit-off,
`w:numId val="0"` cancellation, `w:tab val="clear"` removing inherited stops, the four `w:rFonts`
slots selected by character script, Word's reserved footnote ids −1 and 0, bijective base-26
letter page numbering, `w:contextualSpacing`, suppression of `w:spacing w:before` at a column
top, trailing whitespace hanging into the margin by default, the paragraph mark contributing to
an empty paragraph's height, and `w:type="continuous"` **not** starting a page.

**Deferred from the original M0 list, with reasons**

- `EditorView` (`NSView` + `NSTextInputClient`), caret, mouse selection, clipboard, zoom, ruler,
  page rendering → M0.5. All of it is AppKit surface; none of it changes the engine.
- `zip-gate` CI job → M1, with `OOXMLKit`. It has nothing to gate until something can save.
- Perf contract measurement → M0.5. It needs the 300-page fixture and a scrolling view to
  measure against; asserting a frame budget on a headless harness would be theatre.

**Gaps found while building, all recorded in `07-OPEN-QUESTIONS.md` §E.** The two that matter
most: a page can hold content from two sections after a continuous break, which `PageLayout`
cannot express; and bold/italic are resolved by face name rather than by symbolic traits,
because both trait APIs changed shape in the macOS 27 SDK.

---

## M0.5 — Make it visible (≈ 2 weeks)

**Goal:** the same engine, on screen.

Deliverables
- `EditorView` (`NSView`) drawing `LayoutSnapshot` pages, with page edges, margins and shadows.
- `NSTextInputClient`: typing, IME marked text, emoji, dictation.
- Caret, and mouse selection by character/word/paragraph; keyboard navigation.
- Clipboard, zoom, scroll, viewport-driven layout.
- Horizontal ruler.
- Perf contract measured in CI on `xcode-27-xlarge` against the 300-page fixture.

**Exit test:** the four M0 exit tests above, all of which need pixels.

---

### M0.5 status — 2026-10-03

Slice 1 shipped and is downloadable. CI builds a release binary, runs it headless
to prove the shipped executable lays out a real document, assembles `Zenith.app`,
ad-hoc signs it, and publishes it as an Actions artifact.

Working: a window with paginated US Letter sheets, caret and blinking, click and
shift-click and drag to select, typing, Backspace, Delete, Return, Tab, arrows
including vertical movement that remembers the horizontal position it wants to
return to, Home/End, ⌘A ⌘C ⌘X ⌘V ⌘Z ⇧⌘Z, ⌘B and ⌘I with Word's any-not-bold
rule, zoom that scales the drawing rather than re-laying out, a status bar, and
text flowing onto further sheets under widow/orphan and keep-with-next control.

Not working, deliberately rather than accidentally: `.docx` open and save (the
menu items are disabled, not stubbed), input-method composition, colour, ruler,
styles gallery, find and replace, tables, images, headers and footers on screen,
and the assistant.

Still to do in M0.5:

| item | note |
|---|---|
| IME / `NSTextInputClient` composition | blocked, see F1 — needs a bridged Objective-C++ file or runtime construction |
| Ruler | |
| Performance contract on `xcode-27-xlarge` | needs a 300-page fixture |
| Font bundling | see F6 — the substitution policy is currently inert |
| Full Galley → product rename | mechanical, ~48 files, done once the name is settled |

Slice 2 started the same day: `OOXMLKit` with a ZIP reader and a DEFLATE decoder,
green on Linux and macOS against archives produced by Python. The container is
done; the OOXML reader is next.

## M1 — DOCX round trip (≈ 6 weeks)

**Goal:** open real Word files and save them without breaking anything.

Deliverables
- `OOXMLKit`: OPC container (content types, rels, parts) on ZIPFoundation; offset-tracking
  tokenizer producing `OriginRef` byte ranges for every top-level body element.
- Reader: `document.xml`, `styles.xml`, `numbering.xml`, `settings.xml`, `theme1.xml`,
  `fontTable.xml`, `docProps/*`. Sections, `sectPr`, headers/footers (default/first/even).
- **Style cascade resolver** — docDefaults → numbering rPr → style chain → direct formatting.
  This is the highest-value, highest-risk item in M1.
- Writer + byte-preserving splice; `.custom` passthrough for every element we do not model.
- `w:compat` honoured.
- Undo/redo command stack with Word-matching coalescing.
- Font substitution: real font if installed, metric-compatible fallback otherwise, original
  name preserved in output. Bundle Carlito (Apache-2.0), Caladea (OFL), Liberation (OFL).
- File > Open/Save/Save As, `NSDocument`, autosave, versions, recent documents.

**Exit test**
1. `zip-gate`: 50 fixtures opened and saved with **zero edits** ⇒ every original zip entry
   **byte-identical**. Non-negotiable; the build fails otherwise.
2. 10 representative real documents (a CV, a contract, an academic paper, a report with
   tables and images, a newsletter with columns, a legal doc with tracked changes) open,
   render recognisably, survive an edit-and-save round trip, and **re-open in Word on the
   user's Mac without layout drift**. The user verifies this — we cannot run Word here.
3. Style cascade unit tests: 200 cases with known-effective formatting.

---

## M2 — Word-class editing (≈ 10 weeks)

**Goal:** the P0 features people actually use every day.

Deliverables, in this order
1. **Find & Replace** — full Word wildcard grammar + the `^p ^t ^b ^n ^l ^# ^$ ^~ ^+ ^s ^g ^c
   ^f ^e ^d ^w ^^` special codes, search by formatting and style, replace-all as one undo,
   Go To, Navigation pane (headings / pages / results).
2. **Lists** — `numbering.xml` engine: bullets, numbering, multilevel, restart/continue,
   list library, custom symbols, legal numbering.
3. **Tables** — insert/delete/merge/split, cell margins, alignment, text direction, row
   header repeat, `cantSplit`, autofit (contents / window / fixed), borders & shading,
   table styles with banding, sort, convert text↔table. Word's table layout algorithm.
4. **Images & floating objects** — inline images; anchors; wrap modes; position; align;
   rotate; z-order; Selection pane; Edit Wrap Points.
5. **Footnotes & endnotes** — with separators, continuation, numbering formats, per-section
   restart, convert between. The iterative page-space fixed point.
6. **Headers & footers** — galleries, page numbers (position/format/start-at), different
   first page, different odd & even, link-to-previous.
7. **Sections & breaks** — next page / continuous / even / odd, column breaks, page setup
   dialog, columns with custom widths and line-between.
8. **Proofing** — `NSSpellChecker`, per-language, custom dictionaries, language detection,
   `w:proofErr` markers, AutoCorrect (incl. the border keys, smart quotes, ordinals,
   AutoFormat-As-You-Type).
9. **Views** — Print Layout (done), Draft, Web Layout, Outline; rulers (both); gridlines;
   status bar; mini toolbar; zoom presets; split.
10. **Export** — PDF via the layout engine's painter; RTF; plain text; HTML; Markdown.

**Exit test**
1. A user can take an existing Word document with tables, images, footnotes, headers and
   numbered lists, edit it for an hour, and not notice they aren't in Word.
2. The P0 checklist in `02-FEATURE-INVENTORY.md` is ≥ 90 % ticked.
3. `perf` job still green with the fixtures now containing tables and floats.

---

## M3 — Intelligence layer (≈ 5 weeks)

**Goal:** the differentiator. Runs partly in parallel with M2 from week 3 onwards, because
`IntelligenceKit` is independent of `LayoutKit`.

Deliverables
- `AIProvider` protocol, `PrivacyClass`, Router, Policy, Redaction (all of `04-AI-INTEGRATION.md` §3, §6).
- Adapters: Apple on-device, Apple PCC, Claude (via `ClaudeForFoundationModels`), Gemini
  (Firebase SDK), OpenAI, OpenAI-compatible (Ollama / LM Studio / vLLM), MLX local.
- Keychain-backed key management; loopback validation for local endpoints.
- Preferences → Intelligence pane with the privacy default, per-task routing, provider list,
  redaction toggles, request log.
- The always-visible privacy dot (🟢 on-device / 🟡 PCC / 🔴 third-party).
- Task taxonomy (§4) implemented for: proofread, rewrite(tone), shorten, expand, summarise,
  translate, changeReadingLevel, extractActionItems, generateAltText, continueWriting, draft.
- `DocumentMutation` + `MutationPlanner` validation + the preview/accept/reject UI.
- **AI edits land as tracked changes** with author `Assistant (<provider>)`.
- Writing Tools **Tier 3**: `NSWritingToolsCoordinator` + full delegate.
- Golden evaluation suite in CI.

**Exit test**
1. With "Keep everything on this Mac" selected, every task above works **offline**, and a
   network trace shows zero outbound connections. Proven in CI with a network-blocked job.
2. Adding a Claude key and switching the *Draft long-form* route to it changes nothing else;
   the dot turns 🔴 only for that task.
3. A multi-paragraph AI rewrite appears in the Review pane as individually
   acceptable/rejectable tracked changes and survives a save-and-reopen in Word.
4. Right-click → Writing Tools gives the full inline animated rewrite with proofreading
   marks — the thing no Electron office suite can do.

---

## M4 — Review, collaboration & protection (≈ 5 weeks)

Deliverables
- Full **Track Changes** UI: simple/all/no/original markup, balloons, by-reviewer filtering,
  review pane, accept/reject flows, all the `*PrChange` revision elements.
- **Comments**: threads, replies, resolve, `@mentions`, by-reviewer filtering, `commentsExtended`.
- **Compare & Combine** — a real diff engine over the document model.
- **Restrict Editing** — track-changes-only, comments-only, read-only, form-filling, range
  exceptions, password. (And fix the paired-`documentProtection` case that breaks GenOffice.)
- Accessibility Checker with VoiceOver-integrated live results.
- `NSAccessibility` text protocol completed for the custom view (this should start in M0 and
  finish here).
- App Intents + Shortcuts + Siri + Spotlight semantic index.

**Exit test:** a two-reviewer workflow — one edits with Track Changes on, the other comments,
then Compare merges them — works end to end and round-trips through Word.

---

## M5 — Professional features (≈ 8 weeks)

Deliverables
- **Fields engine** — PAGE, NUMPAGES, SECTIONPAGES, TOC, REF, PAGEREF, NOTEREF, SEQ, STYLEREF,
  DOCPROPERTY, DATE/TIME, AUTHOR, INCLUDEPICTURE/TEXT, HYPERLINK — with switch parsing and
  the two-pass resolve; update-fields prompt on open/print.
- **Table of Contents** with hyperlinks, tab leaders, custom levels, update modes.
- **Cross-references** and **captions**.
- **Citations & Bibliography** via **CSL** (open, ~12,000 public styles) + BibTeX/CSL-JSON/
  Zotero import — a superset of Word's undocumented style engine, and genuinely open.
- **Index** (mark entry, auto-mark, indented/run-in, columns).
- **Mail merge** — the field interpreter already exists from Fields; add data sources
  (CSV, xlsx, Contacts), recipient list editing, rules (IF/ASK/FILLIN/SKIPIF), ADDRESSBLOCK,
  GREETINGLINE, finish-to-new-document / print / email.
- **Envelopes & labels** with our own geometry catalogue.
- **Equations (OMML)** — professional/linear, structures, symbols, Ink Equation via PencilKit.
- **Draw tab** via PencilKit.
- **Picture/Shape/Table contextual tabs** — CoreImage-based corrections/colour/artistic
  effects, DrawingML preset geometry, crop, effects, 3-D.
- Text boxes incl. linked text boxes; drop caps; page borders; watermarks; page colour.
- Document tabs, new window, arrange all, view side by side, synchronous scrolling.
- Read Mode.

**Exit test:** an academic user can produce a thesis — TOC, cross-referenced figures,
footnotes, bibliography in their required style, index — without leaving the app.

---

## M6 — Scale & polish (ongoing)

- Master documents & subdocuments; SmartArt (render-only first, edit later); charts; 3D models.
- PDF → editable document import (PDFKit + Vision OCR + layout analysis).
- `.odt` codec. `.doc` via a lossy `textutil` path.
- A scripting host (JS or Lua) as the honest answer to VBA, plus first-class AppleScript/JXA.
- Localisation of the app itself (start: en, hi, de, fr, es, ja, zh-Hans, ar — and note that
  `ar` exercises RTL end to end).
- Performance work on ever-larger documents; incremental layout islands.
- Mac App Store submission; Developer-ID `.dmg` releases with Sparkle.

---

## Explicitly deferred / probably never

| Item | Reason |
|---|---|
| VBA macro host | Impossible in a sandboxed MAS app; no VBA runtime exists for third-party Mac apps. AppleScript/JXA/Shortcuts + a scripting host + the AI agent is the honest substitute. |
| Real-time multi-user co-editing | Requires a server and CRDT/OT — a different product. Single-user with excellent tracked-changes review covers most real workflows. Could become a separate paid/cloud tier later. |
| Office Add-ins (Office.js) | Requires hosting Microsoft's runtime and their manifest ecosystem. |
| Excel/PowerPoint/PDF siblings | Scope discipline. Word first, as the user asked. The architecture is deliberately shaped so `CoreKit`/`OOXMLKit`/`IntelligenceKit` can later back other editors — but we do not build them now. |
| Windows / Linux | The entire thesis is native Apple Intelligence integration. Cross-platform would mean Electron, which is the thing we are rejecting. |

---

## What "done" means for v1.0

Ship M0–M3 (plus as much of M2's tail as is stable) as **v1.0**. That is roughly
**25 focused developer-weeks**, and it is an app that:

- opens and saves real `.docx` without breaking it;
- lays out pages like Word, not like a browser;
- has tables, lists, images, footnotes, headers/footers, sections, find & replace, spelling;
- runs AI **entirely on the Mac** by default, with any provider the user configures;
- shows AI edits as reviewable tracked changes;
- and offers Apple's Writing Tools inline — which no open-source office suite on any
  platform currently can.

That is a defensible, genuinely different product, and it is honest about what it is not:
it will not have SmartArt, charts, equations, mail merge or a VBA host on day one.
