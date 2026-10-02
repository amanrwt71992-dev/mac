# Architecture

## 0. The one decision that determines everything

> **Native Swift + AppKit + a custom CoreText-backed layout engine.**
> Not Electron. Not Tauri. Not WebKit.

Justification (full evidence in `01-RESEARCH.md`):

| Requirement | Electron/Tauri | Native AppKit + CoreText |
|---|---|---|
| Apple Writing Tools (inline rewrite, proofreading marks) | ❌ `electron/electron#44445` open since 2024-10-29 | ✅ `NSWritingToolsCoordinator` (Tier 3, built for custom text engines) |
| `FoundationModels` `LanguageModelSession` / `@Generable` / tool calling | ❌ no Swift runtime; only `/usr/bin/fm` shelling | ✅ first-class |
| `PrivateCloudComputeLanguageModel` free tier (entitlement) | ❌ | ✅ |
| Word-accurate line breaking | ❌ CSS line breaking ≠ Word | ✅ we implement Word's algorithm over CoreText metrics |
| Viewport-driven pagination (no 97 s open on 122 pages) | ❌ GenOffice #526 | ✅ by design |
| Real printing (`NSPrintOperation`, printer presets, duplex) | ❌ GenOffice #211 | ✅ free |
| System spell check, dictation, Services, Shortcuts, Siri, App Intents | ⚠️ partial | ✅ free |
| VoiceOver / `NSAccessibility` | ⚠️ Chromium's AX tree, generic | ✅ we implement the text AX protocol properly |
| Memory on a 60 MB image-heavy doc | ❌ GenOffice #459 | ✅ CoreGraphics + mmap'd images |
| App size / launch time | ~250 MB, slow | ~30–60 MB, instant |
| Native Mac look, dark UI with light page (GenOffice #1811) | ⚠️ hand-rolled | ✅ free |
| Cost of building it | Low (web stack, huge OSS ecosystem) | **High** — we write the engine |

And the decisive precedent: **Word for Mac itself uses a custom text engine on CoreText**
(TidBITS 2018, quoting Nisus Software). Pages uses WebKit. Nisus and Scrivener use Apple's
Cocoa text engine — and Nisus' own developers attribute their pagination limitations to that
choice. TextKit 2 cannot paginate (single `NSTextContainer`, no tables, irreversible
downgrade on `.layoutManager` access). There is no third option.

**The engine is the cost and the engine is the moat.**

---

## 1. Package layout

A SwiftPM workspace with one `.xcodeproj` for the app target. The split is deliberate:
**core packages have zero Apple-only imports** so they compile and unit-test on Linux, and
CI on `ubuntu-latest` catches logic bugs in seconds while macOS CI catches platform bugs.

```
<app>/                                # repo root — product name is TBD, see 06-LEGAL-AND-IP.md
├── Package.swift                         # workspace manifest
├── App.xcodeproj                         # app target, entitlements, Info.plist
├── Sources/
│   ├── CoreKit/                          # 🌍 cross-platform, no AppKit/CoreText/UIKit
│   │   ├── Model/                        #   DocumentModel & friends
│   │   ├── Editing/                      #   commands, undo, selection, ranges
│   │   ├── Styles/                       #   style cascade resolver
│   │   ├── Numbering/                    #   list numbering engine
│   │   ├── Fields/                       #   field-code parser + interpreter
│   │   ├── Revisions/                    #   tracked-changes model
│   │   ├── Diff/                         #   document diff (for Compare, AI review)
│   │   └── Search/                       #   Find/Replace incl. Word wildcard grammar
│   │
│   ├── OOXMLKit/                         # 🌍 cross-platform
│   │   ├── Container/                    #   OPC zip packaging, rels, content types
│   │   ├── ByteMap/                      #   offset-tracking tokenizer → original byte slices
│   │   ├── Reader/                       #   document.xml/styles.xml/numbering.xml → model
│   │   ├── Writer/                       #   model → OOXML fragments
│   │   ├── Splice/                       #   byte-preserving save
│   │   └── Schema/                       #   generated Swift types for w:/a:/m:/r: (from ECMA XSD)
│   │
│   ├── IntelligenceKit/                  # 🌍 protocol + adapters; Apple bits behind #if canImport
│   │   ├── Provider/                     #   AIProvider protocol, capabilities, token accounting
│   │   ├── Adapters/                     #   AppleOnDevice, ApplePCC, Claude, OpenAI, Gemini,
│   │   │                                 #   OpenAICompatible (Ollama/LM Studio/vLLM), MLXLocal
│   │   ├── Routing/                      #   task → provider policy, cost/privacy budget
│   │   ├── Redaction/                    #   PII scrubbing before anything leaves the device
│   │   ├── Tools/                        #   document tools the agent may call
│   │   └── Prompts/                      #   instruction templates, versioned
│   │
│   ├── LayoutKit/                        # 🍎 CoreText only
│   │   ├── Shaping/                      #   TextShaper protocol + CoreTextShaper
│   │   ├── LineBreak/                    #   Word-compatible greedy breaking, hyphenation, kinsoku
│   │   ├── Pagination/                   #   sections, columns, footnote reservation, widows/orphans
│   │   ├── TableLayout/                  #   Word's table algorithm
│   │   ├── Floats/                       #   anchors, wrap modes, exclusion zones, wrap points
│   │   └── Paint/                        #   CGContext drawing, PDF export, printing
│   │
│   ├── EditorKit/                        # 🍎 AppKit
│   │   ├── EditorView.swift              #   NSView: NSTextInputClient, NSServicesMenuRequestor
│   │   ├── WritingTools.swift            #   NSWritingToolsCoordinator + delegate
│   │   ├── Accessibility.swift           #   NSAccessibility text protocol
│   │   ├── Selection/                    #   mouse/keyboard/rectangular selection
│   │   ├── Rulers/                       #   horizontal + vertical, tab stops, indents
│   │   └── Caret/                        #   insertion point, marked text, IME
│   │
│   └── App/                              # 🍎 AppKit + SwiftUI
│       ├── Documents/                    #   NSDocument subclass, autosave, versions
│       ├── Ribbon/                       #   tab strip, groups, galleries, contextual tabs
│       ├── Panels/                       #   SwiftUI: styles, navigation, comments, AI, review
│       ├── Preferences/                  #   incl. the Intelligence pane
│       ├── Intents/                      #   App Intents, Shortcuts, Siri, Spotlight
│       └── Window/                       #   tabs, split, side-by-side, status bar
│
├── Tests/                                # XCTest; core tests run on Linux too
├── Fixtures/                             # .docx corpus (see §7)
├── Tools/                                # codegen, fixture generation, golden-image harness
└── .github/workflows/                    # ubuntu (core) + xcode-27 (full) + release
```

### Import rules (enforced by CI)

- `CoreKit` imports `Foundation` only. No `AppKit`, no `CoreText`, no `FoundationModels`.
- `OOXMLKit` imports `Foundation` + `ZIPFoundation`. Nothing else.
- `IntelligenceKit` imports `Foundation` + `#if canImport(FoundationModels)`.
- `LayoutKit` imports `Foundation`, `CoreText`, `CoreGraphics`, `CoreImage`.
- `EditorKit`/`App` may import anything.
- **No package may import `EditorKit` or `App`.** Dependency flow is strictly downward.

This is what lets the Linux CI job type-check ~60 % of the codebase.

---

## 2. The document model

Not `NSAttributedString`, and not a flat run array. Word's model is a **tree with a properties
cascade**, and we mirror it.

```swift
/// The whole document. Immutable value type; edits produce a new version
/// through the command layer so undo/redo and AI review are trivial.
public struct DocumentModel: Sendable {
    public var settings:      DocumentSettings        // settings.xml
    public var defaults:      DocDefaults             // docDefaults: rPrDefault, pPrDefault
    public var styles:        StyleTable              // styles.xml + latentStyles
    public var numbering:     NumberingTable          // numbering.xml
    public var theme:         Theme                   // theme1.xml (colours, fonts, effects)
    public var fonts:         FontTable               // fontTable.xml
    public var sections:      [Section]               // the body's top-level structure
    public var footnotes:     NoteCollection
    public var endnotes:      NoteCollection
    public var comments:      CommentCollection
    public var glossary:      BuildingBlocks?         // glossaryDocument.xml
    public var customXML:     [CustomXMLPart]         // incl. our own app-state part
    public var properties:    CoreProperties          // docProps/core.xml + app.xml
    public var protection:    DocumentProtection?
    /// Provenance: what we loaded from, for byte-preserving save.
    public var origin:        DocumentOrigin?
}

public struct Section: Sendable {
    public var properties: SectionProperties          // sectPr: pgSz, pgMar, cols, pgNumType,
                                                      //         docGrid, titlePg, headerRef…
    public var headers:   [HeaderFooterKind: HeaderFooter]   // default/first/even × header/footer
    public var blockables: [Block]
}

/// A top-level body element. This is the unit the byte-preserving save works on,
/// and the unit AI edits are scoped to.
public enum Block: Sendable {
    case paragraph(Paragraph)
    case table(Table)
    case sdt(StructuredDocumentTag)          // content controls, TOC containers
    case math(MathBlock)                     // m:oMathPara
    case custom(BlockCustom)                 // unknown top-level element → preserved verbatim
    case bookmark(BookmarkAnchor)            // document-level bookmarks spanning blocks
}

public struct Paragraph: Sendable {
    public var id:         NodeID            // stable, for AI tool targeting & revision anchoring
    public var properties: ParagraphProperties   // pPr: style, numPr, ind, jc, spacing,
                                                 //      keepNext, keepLines, pageBreakBefore,
                                                 //      widowControl, outlineLvl, bidi, tabs…
    public var runs:       [Run]
    public var origin:     OriginRef?        // ← back-pointer into the original bytes
    public var revision:   RevisionInfo?     // w:pPrChange etc.
}

public struct Run: Sendable {
    public var id:         NodeID
    public var content:    RunContent        // text / break / tab / symbol / drawing /
                                             // footnoteRef / fieldBegin / fieldSep /
                                             // fieldEnd / instrText / object / ruby /
                                             // proofErr / commentRangeStart…
    public var properties: RunProperties      // rPr: rFonts, b, i, caps, smallCaps, strike,
                                             //      color, spacing, w, position, sz, vertAlign,
                                             //      u, highlight, shd, effect, lang, kern…
    public var revision:   RevisionMark?     // nil | .inserted | .deleted | .moved
    public var origin:     OriginRef?
}
```

### Design rules

1. **Value semantics + `Sendable` throughout the core.** Layout runs on a background actor;
   the model must be safely shareable. Edits go through a command layer producing new
   immutable snapshots (copy-on-write via Swift COW on structs/arrays — cheap).
2. **`NodeID` is stable across saves.** AI tools, comments, bookmarks and cross-references all
   address nodes by ID. IDs are persisted in our custom XML part so they survive a round trip.
3. **Unknown elements are preserved, never dropped.** Any OOXML element we do not model is
   captured as `.custom` / `BlockCustom` with its original bytes and re-emitted verbatim.
   This is the single most important fidelity rule and the thing most naive implementations
   get wrong.
4. **`OriginRef`** records `(partKey, byteRange)` into the untouched original. Clean + not
   dirty ⇒ splice original bytes. Dirty ⇒ serialise from the model.

---

## 3. Byte-preserving save (our version of GenOffice's best idea)

```
LOAD
  original.docx  ──► kept on disk, hash-indexed, never mutated
  OPC container  ──► parts enumerated; each part's bytes retained
  document.xml   ──► offset-tracking scan of top-level children of <w:body>
                     each child → OriginRef(part:"word/document.xml", bytes: 4102..<5871)
  styles.xml, numbering.xml, settings.xml, theme1.xml, comments.xml, … ──► same treatment

EDIT
  DocumentModel is the single source of truth for the editor, layout engine and AI.
  Every mutation goes through a Command; the Command marks affected top-level blocks dirty.
  NodeID → OriginRef map is updated; unchanged nodes keep their refs.

SAVE
  for each top-level child of <w:body>, in document order:
      if !dirty && origin != nil:   write original bytes verbatim
      else:                         serialise from model, referencing existing style/rPr
                                    definitions by id only (never inline-expand a style)
  every other zip entry:            copied byte-for-byte from the original container
  our app-state part:               appended as a NEW entry (does not disturb existing bytes)
  repack with the same compression method & entry order where possible
```

**Result:** a 40-page contract with one edited sentence is bit-identical outside that one
paragraph. Word cannot tell anything touched it. Reviewers' tracked changes, custom XML,
content controls, embedded objects, `w:compat` flags, and every style we did not model all
survive untouched.

**Guarantee we can actually test:** `Tools/zipgate` — a CI check that opens a fixture,
saves it with *zero* edits, and asserts byte equality of every zip entry except our own
app-state part. If that test fails, the build fails. GenOffice's equivalent gate exists
(`packages/zip-gate`) but their own tracker shows it isn't run by `npm test` (#1678).
**Ours runs on every commit.**

---

## 4. The layout engine

The heart of the product. Everything else can be mediocre and the app is still usable;
if layout is wrong, nothing else matters.

### Pipeline

```
DocumentModel
      │
      ▼
 ① PropertyResolver      effective (rPr, pPr) for every node, after:
      │                  docDefaults → numbering rPr → style chain (basedOn, linked) →
      │                  → tblStylePr conditional → direct rPr/pPr → revision overlays
      │                  cached & invalidated per node
      ▼
 ② Shaper                TextShaper protocol
      │                    ├─ CoreTextShaper   (macOS: CTFont, CTLine, bidi, fallback,
      │                    │                    kerning, OpenType features, hyphenation)
      │                    └─ HarfBuzzShaper   (Linux CI: golden tests against the same
      │                                         expected line breaks)
      ▼
 ③ LineBreaker           Word-compatible greedy breaking over measured widths:
      │                    · kerning-aware advance widths
      │                    · justification with Word's distribution rules
      │                    · hyphenation zone, consecutive-hyphen limit
      │                    · kinsoku / East Asian rules when w:kinsoku
      │                    · character grid when w:docGrid type="lines"/"linesAndChars"
      │                    · no-break rules (NBSP, w:noBreakHyphen, keep-together)
      ▼
 ④ FloatResolver         exclusion zones from anchored drawings/text boxes
      │                  wrap modes: none/square/tight/through/topAndBottom
      │                  tight & through use the a:wrapPolygon outline
      │                  → produces a per-line available-width function
      ▼
 ⑤ BlockPlacer           paragraphs, tables (own algorithm), math blocks, SDTs
      │
      ▼
 ⑥ Paginator             sections → columns → pages, applying:
      │                    widowControl, keepNext, keepLines, pageBreakBefore,
      │                    explicit breaks (page/column/textWrapping),
      │                    table row splitting + cantSplit + tblHeader repeat,
      │                    footnote/endnote area reservation (iterative fixed point:
      │                      note height depends on the page's remaining space, which
      │                      depends on how many notes fit — iterate to convergence),
      │                    header/footer extents, page-number fields
      ▼
 ⑦ FieldResolver         PAGE / NUMPAGES / TOC / REF / PAGEREF / SEQ —
      │                  requires a SECOND pass once total page count is known;
      │                  iterate until stable (max 3 passes, then mark dirty)
      ▼
 ⑧ Painter               CGContext → screen layers / PDF / print
```

### Performance contract

- **Viewport-driven, always.** Layout is computed for the visible viewport plus an
  over-scan margin. Everything else is a *height estimate* refined lazily.
  This is the fix for GenOffice #526 (97 s to open 122 pages).
- Layout runs on a dedicated `LayoutActor` off the main thread; the view renders the last
  completed `LayoutSnapshot` and animates to the new one.
- Editing invalidates **only** from the changed node to the end of its "layout island"
  (a paragraph, or a table row, or the remainder of a footnote). A single character edit in
  the middle of a paragraph must not re-paginate the document.
- `LayoutSnapshot` is an immutable value; the view holds the newest one. No locks.
- Text is drawn into per-page `CALayer`s (or `MTKLayer` if we later need GPU text); scrolling
  is layer translation, not re-layout.
- Images are `CGImageSource`-backed with progressive downsampling — never decoded at full
  size for display. This is the fix for GenOffice #459 (60 MB doc laggy).

**Targets (measured in CI, see §7):**

| Metric | Target |
|---|---|
| Cold open → first paint, 300-page / 200k-word doc | < 1.5 s |
| Keystroke → glyph on screen | < 16 ms (one frame) |
| Scroll at 120 Hz ProMotion | 0 dropped frames steady state |
| Open a 60 MB image-heavy doc | < 3 s, no beachball |
| Save a 300-page doc with 1 edited paragraph | < 200 ms |
| Memory, 300-page doc at rest | < 400 MB |

---

## 5. Editing layer

```
User gesture (key, mouse, drag, menu, ribbon, AI tool, Writing Tools, AppleScript)
        │
        ▼
   Intent  ──►  Command (value type: what, where, why)
                    │
                    ├─► applies to DocumentModel  → new snapshot
                    ├─► pushes inverse onto UndoStack (with Word-like coalescing)
                    ├─► records RevisionMark if trackChanges is on
                    ├─► invalidates layout from the affected node
                    └─► emits DocumentEvent (for panels, AI context, AutoSave, Spotlight)
```

**Why every input goes through the same funnel:** AI edits, Writing Tools edits, macro edits,
undo/redo, and drag-and-drop all become *the same kind of object*. That is what makes
"AI writes tracked changes" and "review every AI change in the review pane" fall out for
free instead of being bolted on.

### Undo coalescing rules (match Word)

| Action | Coalescing |
|---|---|
| Typing | coalesce consecutive inserts at contiguous positions, break on pause (> ~500 ms), on a non-insert action, or on losing focus |
| Delete/Backspace | coalesce similarly; a selection delete is **one** unit |
| Formatting change | **one** unit, never coalesced with typing |
| Find & Replace All | **one** unit |
| Insert table / picture / footnote | **one** unit |
| AI edit (a whole operation) | **one** unit — so "undo the AI" is a single ⌘Z |
| Writing Tools result acceptance | **one** unit |

---

## 6. Apple Intelligence integration points

Detailed design in `04-AI-INTEGRATION.md`. The architectural commitments here:

1. `EditorView` adopts `NSTextInputClient` + `NSServicesMenuRequestor` → Writing Tools in the
   context menu (Tier 2) from day one, at almost no cost.
2. `EditorView` hosts an `NSWritingToolsCoordinator` with a full delegate → inline rewrite,
   animation, and inline proofreading marks (Tier 3). The delegate's
   `updateForReflowedText` hook is wired to our layout engine's reflow notifications, which
   is something a web engine structurally cannot do well.
3. `IntelligenceKit` exposes our own `AIProvider` protocol, with an adapter that *is* a
   `LanguageModel` conformer on macOS 27+ so third-party provider packages
   (`ClaudeForFoundationModels`, Firebase/Gemini) drop straight in.
4. Every AI edit returns a **structured `DocumentMutation`**, never a text blob. It is applied
   as a tracked change.
5. The document is exposed to Siri / Shortcuts / Spotlight via **App Intents** with entity
   schemas — so "Hey Siri, summarise this document into an email draft" works without us
   building any of that plumbing.

---

## 7. Testing strategy — designed around "we cannot compile locally"

The sandbox is Linux with no Swift toolchain and no route to `download.swift.org`. So CI is
not a convenience, it is the compiler.

| Job | Runner | What it does | Minutes |
|---|---|---|---|
| `core-tests` | `ubuntu-latest` | `swift build && swift test` for `CoreKit`, `OOXMLKit`, `IntelligenceKit`. **Fails fast, this is our primary type-check loop** | ~3 |
| `lint` | `ubuntu-latest` | SwiftLint + SwiftFormat `--lint` (config in repo) | ~1 |
| `macos-build` | `xcode-27` (arm64, macOS 27, Xcode 27) | `xcodebuild build` for the app target, all Swift, all unit tests | ~8 |
| `ui-tests` | `xcode-27` | XCUITest: open doc, type, format, paginate, save, reopen | ~15 |
| `zip-gate` | `ubuntu-latest` | Fixture → load → save with zero edits → **assert byte equality** of every original zip entry | ~2 |
| `fidelity` | `xcode-27` | Render fixture pages to PNG, compare against golden renders with a perceptual-diff threshold; report drift per fixture | ~10 |
| `perf` | `xcode-27-xlarge` | The §4 performance contract, measured, with a regression budget that fails the build | ~10 |
| `release` | `xcode-27` | Notarised `.dmg` + `.app` uploaded as artifacts | ~20 |

### Fixture corpus (`Fixtures/`)

Built up deliberately, because fidelity work is only as good as its corpus:

1. **Self-authored** documents exercising one feature each (styles, numbering, tables, floats,
   footnotes, sections, columns, fields, revisions, comments) — these we can commit freely.
2. **Generated** by a `Tools/fixturegen` script (Node/Python, runnable in *this* sandbox) that
   emits valid OOXML for edge cases: nested tables, `vMerge` continuations, empty
   `rPr`, single-quoted `Id` attributes (GenOffice #1684), tens of thousands of relationships
   (GenOffice #1687), paired `documentProtection` (GenOffice #1686), paired `w:background`
   (GenOffice #1683), `w:compat` flag permutations.
3. **Real-world** documents the user supplies from their own work — the highest-value corpus,
   and the only one that finds real fidelity bugs. Must be licensed/cleared before committing.
4. **Adversarial**: malformed XML, zip bombs, truncated parts, NaN/Infinity in numeric
   attributes (GenOffice #1682), unbounded base64 (GenOffice #715).

Because we cannot run Word here, the `fidelity` job's goldens are produced on the macOS
runner and reviewed by a human on the first run, then locked.

---

## 8. Distribution

| Concern | Decision |
|---|---|
| Primary channel | **Mac App Store** (sandboxed, notarised, auto-update, and — critically — unlocks the free Private Cloud Compute tier for apps under 2 M downloads) |
| Secondary channel | Developer-ID signed `.dmg` from GitHub Releases, for users who want a non-sandboxed build (local model files in arbitrary directories, external scripting hosts) |
| Min OS | **macOS 26 Tahoe** recommended; macOS 27 features gated with `#available`. See the open question in `07-OPEN-QUESTIONS.md` |
| Architectures | arm64 only (macOS 27 is Apple-Silicon-only anyway) |
| Updates | Sparkle on the Developer-ID build; App Store updates on MAS |
| Telemetry | **None by default.** Opt-in crash reporting only, with the AI request path never logged |

### Entitlements (MAS build)

`com.apple.security.app-sandbox` · `user-selected.read-write` · `security-scoped-bookmarks` ·
`files.user-selected.read-only` · `network.client` (BYOK providers) · `printing` ·
`personal-information.calendars`? (no) · `com.apple.developer.foundation-models.pcc`
(the PCC free-tier entitlement — requires Small Business Program enrolment) ·
App Groups for the helper/CLI target.

### What we will *not* do

- ❌ No Electron, no Node sidecar, no bundled browser runtime.
- ❌ No VBA host (impossible in a sandbox; and see `02-FEATURE-INVENTORY.md` → Macros).
- ❌ No server component. Everything runs on the user's Mac or talks **directly** to a
  provider the user configured. There is no "our cloud" to bill credits through — which is
  precisely the complaint in GenOffice's most-discussed issue ("Other AI integration?", and
  the follow-up request for "user-owned AI configuration: custom model endpoint, proxy,
  agent rules/skills").
- ❌ No telemetry, no analytics, no account requirement to edit a document.
