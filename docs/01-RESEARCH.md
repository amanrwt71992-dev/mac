# Research Findings

_Compiled 2026-10-02. Every claim here is sourced; anything unsourced is marked **[assumption]**._

This document answers four questions:

1. What did GenOffice (Genspark) actually build, and why does it feel worse than Word?
2. What does Apple give us in 2026 for on-device + pluggable AI?
3. What is the state of the art for a *native* macOS paginated text engine?
4. What are the legal constraints (format, fonts, naming)?

---

## 1. GenOffice autopsy — what it is and where it hurts

| Fact | Value | Source |
|---|---|---|
| Repo | `genspark-ai/genoffice` | GitHub API, 2026-10-02 |
| Stars / forks | 8,422 / 1,086 | GitHub API, 2026-10-02 |
| Open issues | 216 | GitHub API, 2026-10-02 |
| Licence | Apache-2.0 (core); `ee/` under a separate Enterprise Licence | repo `LICENSE`, NOTICE |
| Language split | TypeScript 38.4 MB, CSS 1.0 MB, Rust 0.86 MB, Swift 4 KB | GitHub API `/languages` |
| First release | 2026-08-03 (v0.4.110 alpha) | MarkTechPost, aitoolsreview |
| Latest | v0.11.x | GitHub Releases |
| Build provenance | ~1 engineer, ~1 week, ~$10,000 of tokens (self-reported) | MarkTechPost |

### Architecture (their words)

Six Electron apps (`docs`, `sheets`, `slides`, `pdf`, `markdown`, `shell`) over shared
TypeScript packages. Confirmed against the live repo tree:

```
packages/
  agent-core      ai-provider     ai-search       cli
  docx-engine     electron-utils  file-parse      font-metrics
  html2docx       i18n            pdf2docx        pipelines
  pptx-engine     pptx-ops        pptx-render     project-store
  ui              xlsx-gateway    zip-gate
```

Docs = TipTap/ProseMirror editor + a custom `.docx` round-trip engine.

Their `.docx` strategy is genuinely good and worth stealing as an *idea*:

```
open  → archive original by hash (never touched)
      → parse word/document.xml top-level elements (w:p / w:tbl / …) into a block tree
      → each block anchored by docxIndex + its original XML slice
save  → only dirty blocks are re-serialised to OOXML fragments
      → spliced into the original document.xml; untouched blocks keep original bytes
      → repack zip; every other entry copied byte-for-byte
```

Practical consequence: edit one sentence in a 40-page contract and the other 39 pages are
bit-identical to what your colleague sent you. Word cannot detect that anything touched them.

### Why it feels worse than Word — the evidence

These are their own open/closed issues, pulled live from the tracker:

| # | Title | Why it matters |
|---|---|---|
| 526 | "122-page document takes ~97 s to show content — full-document pagination is re-run while a phased open streams" | **The architectural tax.** Layout is not viewport-driven. |
| 459 | "x86 Mac, opening a large Word doc with images (60 MB), extremely laggy" | Same root cause. |
| 118 | "打开 Word 文档排版错乱 / Layout breaks when opening .docx" | Fidelity. |
| 211 | "Printing dialog lacks printer settings and printed text quality is visibly degraded" | Chromium print path, not `NSPrintOperation`. |
| 1074 | "Headless rendering crashes GenOffice and returns app_unavailable on macOS" | |
| 1778 | "GenOffice 0.11.0 keep crashing on win 11" | Stability. |
| 1811 | "Allow dark UI with a light document/page view" | Native apps get this for free. |
| 1687 | "docx: a rels part with tens of thousands of relationships makes the save quadratic" | |
| 1685 | "docx: removing the default header/footer reference also strips the first-page one" | OOXML depth. |
| 1686 | "docx: unprotecting a document that uses the paired documentProtection form does nothing" | |
| 1348 | "Put Navigation Pane or Outline Pane on the first/home tab" | Word-parity UX gaps still open. |
| 1784 | "markdown: no source view" | |
| 1819 | "pptx: Generation is significantly more stupid after v0.11.0 upgrade" | AI regressions. |

**Searches that returned zero results** across all 1,800+ issues: `apple intelligence`,
`foundation models`. `writing tools` matched only an unrelated MCP proposal (#338).

### Root-cause analysis

The single decision that explains most of the above is **Electron**.

1. **Layout.** Word's line breaking runs its own greedy algorithm against real font metrics
   with kerning, hyphenation zones, kinsoku (East Asian) rules, character grid, widow/orphan
   and keep-with-next. Chromium's CSS line breaking is a different algorithm with different
   metrics. It will never converge on Word's output, and it must lay out the whole flow to
   know where page N ends → issue #526.
2. **Apple Intelligence.** Electron has had an open feature request for Writing Tools since
   **2024-10-29** (`electron/electron#44445`) that is still unresolved. Electron apps do not
   use `NSTextView`, so the system never offers Writing Tools. They also cannot use the
   `FoundationModels` Swift API at all — only by shelling out to `/usr/bin/fm` or the Python
   SDK. There is no path from Chromium to `NSWritingToolsCoordinator`.
3. **Native surface area.** Menus, Services, `NSSpellChecker`, dictation, drag-and-drop,
   `NSPrintOperation`, Quick Look, Versions, `NSAccessibility`/VoiceOver, Continuity — all
   must be re-implemented over IPC in Electron, and mostly aren't.
4. **Perf/memory.** A renderer process per document, plus a JS object model for a 60 MB
   document, plus a Rust sidecar.

### What we should take from GenOffice

- ✅ **Byte-preserving OOXML round trip.** Correct architecture; adopt the idea, write our own.
- ✅ **AI edits at block granularity with review/diff.** We will do better: land AI edits as
  real OOXML tracked changes (`w:ins` / `w:del`), so they are reviewable in *our* app and in
  *Word*.
- ✅ **Apache-2.0 engine packages with no Electron dependency.** Our core will likewise be
  pure Swift with zero AppKit imports, so it is testable on Linux CI and reusable.
- ✅ **Fixture-driven testing.** They have a `fixtures/` tree. We need one, bigger.
- ❌ Do **not** fork their TypeScript. Mixing a Node sidecar into a native app reintroduces
  the perf problem and inherits 216 open issues. We may reuse *fixtures* and *NOTICE*-compliant
  ideas; we write our own code.

---

## 2. The Apple AI landscape as of October 2026

### OS baseline

- **macOS 27 "Golden Gate"** shipped **2026-09-14**; current 27.0.1 (2026-09-28); 27.2 in beta.
- **Apple Silicon only** — Intel support and Rosetta 2 dropped. (macOS 26 Tahoe was the last
  with full Rosetta 2.)
- Predecessor **macOS 26 Tahoe** shipped Sept 2025 and introduced the Foundation Models framework.

### Apple Foundation Models — third generation ("AFM 3")

| Model | Where | Size | Notes |
|---|---|---|---|
| AFM 3 Core | On-device (Neural Engine) | 3 B dense | **8,192-token context window** |
| AFM 3 Core Advanced | On-device | 20 B sparse, 1–4 B active | Multimodal (image input); Instruction-Following Pruning |
| AFM 3 Cloud | Private Cloud Compute | — | Privacy-preserving Apple Silicon servers |
| AFM 3 Cloud Pro | Private Cloud Compute | — | Heaviest tier |
| ADM 3 Cloud | Private Cloud Compute | — | Image generation |

Apple's own human-eval numbers (side-by-side preference vs their 2025 models): AFM 3 Core
preferred 38.0 % vs 23.0 % on English text (39.0 % ties); non-English gains larger;
AFM 3 Cloud 56.0 % vs 11.0 % on the server side.

Also new on macOS 27: `/usr/bin/fm`, a preinstalled CLI to the on-device model, plus a
Python SDK (`apple/python-apple-fm-sdk`).

### The thing that changes our whole design: the `LanguageModel` protocol

At WWDC 2026 (2026-06-08/09, sessions 241, 339) Apple **open-sourced the Foundation Models
framework** and introduced a public `LanguageModel` protocol (with `LanguageModelExecutor`).

> "Any conforming implementation, Apple's own or a third party's, can back a
> `LanguageModelSession`."

- `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` already conform.
- Apple ships open-source **`CoreAILanguageModel`** (Neural Engine) and **`MLXLanguageModel`**
  (GPU) for running *local* open models.
- **Anthropic** shipped `ClaudeForFoundationModels` (github.com/anthropics/ClaudeForFoundationModels,
  v0.1.0, targets iOS/macOS/visionOS/watchOS 27, Xcode 27). Requests go app → Anthropic
  directly; Apple is not in the path. `.proxied(headers:)` auth recommended so no key ships in
  the binary.
- **Google** ships Gemini conformance through the Firebase Apple SDK.
- Sessions and responses now carry a `usage` property: input tokens, cached input tokens,
  response tokens, reasoning tokens.
- **Dynamic Profiles** let you swap models, tools and instructions mid-session without
  breaking continuity.
- New **system-provided tools**: Vision OCR, barcode reading, exposed for the model to call.
- **Evaluations framework** (WWDC26 sessions 298/299/335) for verifying AI behaviour beyond
  unit tests.
- `fm` CLI + Python SDK for scripting.

**Free Private Cloud Compute tier:** if you are enrolled in the App Store Small Business
Program *and* your app has fewer than 2 million cumulative first-time App Store downloads,
you can use AFM on Private Cloud Compute **at no cloud API cost** (entitlement required).

→ *This is exactly the user's requirement: "use Apple AI so things remain within Mac, and
also configure our own AI providers." Apple now hands us a single protocol that does both.*

### Writing Tools — the Apple Intelligence UI surface

Three adoption tiers (WWDC24 session 10168, WWDC25 session 265):

| Tier | Requirement | What you get |
|---|---|---|
| 1 — free | `UITextView` / `NSTextView` **on TextKit 2**, or `WKWebView` | Full inline rewrite + animation |
| 2 — cheap | Custom view adopting `NSTextInputClient` + **`NSServicesMenuRequestor`** (override `validRequestor(forSendType:returnType:)`, implement `readSelection`/`writeSelection`) | Writing Tools in the context menu; results returned as a blob |
| 3 — full | **`NSWritingToolsCoordinator`** (AppKit; `UIWritingToolsCoordinator` on UIKit) + delegate | Inline rewrite in place, animation, **inline proofreading marks**, `.presentationIntent` rich results |

The Tier-3 coordinator was added in WWDC25 specifically **for custom text engines**. Its
delegate "prepares the context for Writing Tools to work on, incorporates changes, provides
preview objects for animations, provides coordinates for Writing Tools to draw proofreading
marks, and responds to state changes." There are `updateRange:withText:` and
`updateForReflowedText` methods to keep Writing Tools in sync with our own layout.

`NSWritingToolsBehavior` = `.complete` / `.limited` / `.none`; `allowedWritingToolsResultOptions`
declares which output shapes we can render (plain, rich, list, table, `.presentationIntent`).

**Critical constraint:** Apple's own Writing Tools runs **task-trained LoRA adapters** (one
per tone, one for proofreading, one for summarising) that the public `FoundationModels` API
does **not** expose. You cannot reproduce Writing Tools quality by prompting the base model.
The only way to get Apple's adapters is to *integrate Writing Tools itself* (Tier 2/3) — which
is a strong argument for a native engine.
_(Source: `LinShanify/WritingToolsAnywhere` README, an independent reverse-engineering write-up.)_

**Corollary:** Electron apps get **none** of this. Chromium's writing-tools integration exists
in the codebase but is not exposed by Electron (`electron/electron#44445`, open since Oct 2024).

### Other Apple surfaces worth adopting

- **App Intents** — expose document actions to Siri / Shortcuts / Spotlight. WWDC26 added
  *App Schemas* (system-defined intent + entity schemas), *View Annotations* (map on-screen
  views to entities for conversational reference), and an **App Intents Testing framework**.
  Entity schemas feed the Spotlight **semantic index** → "LLM search using Core Spotlight".
- **Multimodal prompts** — pass images alongside text.
- **Instruments** — debug/profile agentic experiences.

---

## 3. Native macOS text engines — the hard part, honestly assessed

### TextKit 2 is not the answer

Confirmed from Apple's own forums, WWDC21/22 sessions, and three independent practitioners
(Scrivener/Literature & Latte, Krzyżanowski — *STTextView*, Jalkut — *Coppice*):

- `NSTextLayoutManager` supports **exactly one `NSTextContainer`**. No array of containers ⇒
  **no page-based layout**, no multi-column, no printing pagination.
- `NSTextContentManager` in practice only works with `NSTextContentStorage`; `NSTextElement`
  in practice only works with `NSTextParagraph` subclasses (runtime assertions otherwise).
- Viewport-driven layout means total document height is an **estimate that keeps changing**
  as you scroll — the "jiggery" problem.
- TextKit 2 **does not support tables**. Writing Tools can *generate tables*, which is a
  cruel irony.
- Accessing `.layoutManager` silently and **irreversibly downgrades** the view to TextKit 1
  (and on macOS 26 there is a live regression where this happens unexpectedly; workaround is
  the private `NSTextViewAllowsDowngradeToLayoutManager=NO`).
- Literature & Latte (Scrivener), as of Nov 2024, still refuse to adopt TK2 for exactly two
  reasons: multiple containers/pages, and printing.

### What Word itself does

> "…Apple's Cocoa text engine (compared to WebKit, which Pages uses, and **Word's custom text
> engine that apparently relies on Apple's CoreText framework**)."
> — TidBITS, *Nisus Writer Pro 3.0*, 2018-10-29, quoting Nisus Software

Mellel likewise "sports its own text engine, that is not reliant on macOS text support."

So: **Word for Mac = custom layout engine on CoreText.** Pages = WebKit. Nisus/Scrivener =
Cocoa text engine (and Nisus' own devs attribute their pagination quirks to that choice).

That settles the architecture. We build a **custom CoreText-backed paginated layout engine**
inside an `NSView` that adopts `NSTextInputClient` (IME/dictation), `NSServicesMenuRequestor`
(Writing Tools Tier 2, Services menu), `NSAccessibility` (VoiceOver), and hosts an
`NSWritingToolsCoordinator` (Tier 3).

### What we must build ourselves (no framework gives it to us)

| Concern | Notes |
|---|---|
| Shaping | `CTFontCreatePathForGlyph`, `CTLineCreateWithAttributedString`, `CTFramesetterSuggestLineBreak` — CoreText gives us HarfBuzz-class shaping, bidi, and font fallback for free |
| Line breaking | Greedy break against the measured line width, with kerning, hyphenation (`CTLine` + `NSHyphenationFactor` / CoreText hyphenation), kinsoku rules |
| Pagination | Widow/orphan, keep-with-next, keep-together, page-break-before, section breaks, columns, footnote/endnote area reservation (iterative: footnote height depends on layout, layout depends on footnote height) |
| Tables | Word's table layout algorithm: fixed / autofit-to-window / autofit-to-contents, preferred widths in %/dxa/auto, cell margins, gridSpan, vMerge, nested tables, row split across pages, `cantSplit` |
| Floating objects | Anchors, wrap modes (square, tight, through, top-and-bottom, behind/in front), exclusion zones feeding back into line breaking — **the hardest single item** |
| Fields | PAGE / NUMPAGES / TOC / REF / SEQ / cross-refs need a **two-pass** layout with a `FieldResolver` |
| Input | `NSTextInputClient` (marked text, IME, emoji, dictation), selection by mouse/keyboard/word/paragraph, drag & drop, clipboard in 6+ flavours |
| Undo | Command stack, coalescing rules matching Word's (typing coalesces; formatting doesn't) |
| Accessibility | `NSAccessibility` text protocol: character/word/line ranges, attributes, insertion point — a custom engine must implement this by hand |
| Writing Tools | `NSWritingToolsCoordinator` delegate: context, previews, proofreading-mark coordinates, reflow notifications |

### Existing Swift/OSS pieces (mostly inadequate)

| Library | Licence | Verdict |
|---|---|---|
| `shinjukunian/DocX` | MIT | `NSAttributedString` → `.docx` **writer only**. Its own README: "NSAttributedString has no concept of pagination." No reader. Not a foundation. |
| `Techopolis/SwiftDocX` | MIT | 3 commits, 24 days old, Jan 2026. Too young. |
| `germanhl36/DocReader` | — | Read-only: page count, dimensions, metadata, PDF/raster export. Uses ZIPFoundation + `XMLParser` + CoreText. Useful as a *reference* for OOXML→CoreText rendering. Not an editor. |
| `Cocoanetics/SwiftText` (`SwiftTextDOCX`) | — | Text extraction to Markdown for LLMs. Useful for our "feed the document to AI" path only. |
| ZIPFoundation | MIT | Use for the OOXML container. |
| `libxml2` / `XMLParser` | system | For parsing. Note: `XMLParser` (NSXMLParser) is SAX and fine; for byte-preserving splice we need our own **offset-tracking** tokenizer anyway, because we must record the exact byte range of each top-level element. |

**Conclusion: no off-the-shelf Swift foundation exists. We build the engine. That is also the
moat.**

---

## 4. Legal / IP constraints

### The `.docx` format itself — safe

- ECMA-376 (1st ed. Dec 2006), later ISO/IEC 29500:2008, 4th ed. 2016-10-26. **Open standard.**
- Ecma standards "are made available to all interested persons or organizations, free of
  charge and copyright."
- Microsoft's **Open Specification Promise**: "Microsoft irrevocably promises not to assert
  any Microsoft Necessary Claims against you for making, using, selling, offering for sale,
  importing or distributing any implementation to the extent it conforms to a Covered
  Specification." Microsoft explicitly amended the OSP FAQ to confirm it **applies to GPL
  implementations**.
- Precedent: LibreOffice, OnlyOffice, Collabora, Google Docs, GenOffice, Apache POI,
  Microsoft's own Open XML SDK (Apache-2.0) all implement it.

Caveats to record honestly:
- The OSP covers **necessary claims** for **conforming** implementations. Critics (Groklaw,
  the EOOXML objections) argued the OSP's "only the required portions" language may not cover
  *optional* parts of the spec. This has **never been tested in court**. Practically, the risk
  is considered low — it's the same basis on which every other OSS office suite ships.
- Microsoft's `[MS-OE376]` Open Specifications documentation is separately published with its
  own IP notice permitting copies "in order to develop implementations" and redistribution of
  included schemas/IDLs/code samples.
- **Do not** decompile or reverse-engineer Word itself; work from the published ECMA/ISO
  schemas and Microsoft's Open Specifications.
- **[Not legal advice.]** Before commercial launch, have counsel review: OSP scope for
  optional elements, the `ee/`-style open-core question if we ever add one, and trademark
  clearance for the product name.

### Fonts — the trap everyone falls into

- **Calibri, Cambria, Consolas, Candara, Constantia, Corbel, Segoe UI** are licensed *to
  Microsoft* and are **not redistributable**. We must not bundle them.
- GenOffice's approach (per their NOTICE): bundle metric-compatible substitutes —
  **Carlito** (≈ Calibri, Apache-2.0), **Caladea** (≈ Cambria, OFL), **Liberation**
  (≈ Arial/Times/Courier, OFL w/ GPL exception), **Noto CJK** subsets.
- Better on macOS: **font substitution at runtime.** If the user has Calibri installed (every
  Word-for-Mac user does, via Office), use the real font — that's what gives pixel-accurate
  round trips. If not, fall back to the metric-compatible substitute *and record the original
  font name in the OOXML* so the file still says Calibri.
- macOS system fonts (`Helvetica Neue`, `SF Pro`, `Menlo`, `New York`, `Avenir`,
  `Charter`…) are licensed for use *on macOS*, not for embedding in a cross-platform app —
  fine for us since we are macOS-only.
- Any font we *bundle* must be OFL or Apache-2.0, with the licence text in `NOTICE`.

### Naming and trade dress

**Must avoid:** "Word", "Microsoft", "Office", "Microsoft 365", "Copilot", the Word icon,
the four-pane coloured Office logo, and any name that reads as a Microsoft product
("WinWord", "MSWord", "WordPro" — the last is a Corel mark anyway).

**Also be careful with Apple marks.** "Apple", "Mac", "Apple Intelligence", "macOS" are
Apple trademarks. Nominative use in *descriptive* text is fine ("Built for macOS",
"Works with Apple Intelligence"); using them **in the product name** ("AppleWord",
"MacWord", "iWord") is not, and Apple has a published trademark-guidelines page plus a
history of objecting to `i`-prefixed names.

**Look and feel.** GUI layout and functional command organisation are generally not
copyrightable in the US (*Apple v. Microsoft*, 1994, affirmed on the idea/expression
distinction and the merger doctrine; *Lotus v. Borland*, 1st Cir. 1995, on menu command
hierarchy). Practically that means: **a ribbon with Home/Insert/Layout/References/Mailings/
Review/View tabs and standard command groupings is fine.** What is *not* fine:
- copying Word's **icons** or artwork (that's straight copyright) — draw our own, ideally
  with an SF Symbols-first visual language that reads as native Mac;
- copying Word's exact **marketing copy**, help text, or template gallery content;
- shipping Word's **default templates**, clip art, or SmartArt layouts;
- using `Microsoft`/`Word` in bundle identifiers, UTIs we invent, or window titles in a way
  that implies provenance.

Note we *must* keep certain **interop identifiers** because OOXML requires them: the UTI
`org.openxmlformats.wordprocessingml.document`, the MIME type
`application/vnd.openxmlformats-officedocument.wordprocessingml.document`, the OOXML
namespace URIs `http://schemas.openxmlformats.org/wordprocessingml/2006/main`, and the
`w:` element names. These are standard-mandated strings, not branding, and every OSS
implementation uses them.

### Our own file format

Recommendation: **`.docx` is the native format** (with byte-preserving saves), plus an
in-package custom XML part for app-private state (AI history, comment threads, view state).
Adding a *new* zip entry does not modify existing entries, so byte-preservation holds.

We should *also* register our own UTI (e.g. `dev.<ourname>.document`) as a **conformance**
to the OOXML UTI so we appear correctly in Finder/Open-With without inventing a format nobody
can read.

---

## 5. Build-and-test reality in this workspace

| Check | Result |
|---|---|
| Sandbox OS | Debian 12, Linux x86_64, 2 vCPU, 4 GB RAM, 20 GB free |
| Swift toolchain | ❌ not installed; `swift.org` and `download.swift.org` are **unreachable** from the sandbox |
| Xcode | ❌ impossible (Linux) |
| Rust | ❌ not installed; `static.rust-lang.org` unreachable |
| Node / npm | ✅ v22.22.3 / 10.9.8 |
| Python | ✅ 3.11.2 |
| `github.com`, `api.github.com`, `codeload.github.com` | ✅ reachable |
| `gh` auth | ✅ logged in as `amanrwt71992-dev` (the repo owner) with `GH_TOKEN` |
| GitHub Actions macOS runners | ✅ `macos-26` (macOS 26.6.1, Xcode 26.6 default), **`xcode-27`** (arm64, macOS 27 base since 2026-09-16, Xcode 27 default) |

**This is the key operational insight.** We cannot compile Swift locally — but GitHub Actions
provides real Apple Silicon macOS 27 runners with Xcode 27. So the loop is:

```
write Swift here → git push → GH Actions builds on `xcode-27` (arm64, macOS 27)
                  → read `gh run view --log` → fix → repeat
                  → upload .app/.dmg as a build artifact the user downloads
```

To make the most of that loop we design the package so the **core has zero Apple-only
imports** and therefore also compiles and unit-tests on Linux:

```
Targets that build everywhere (CI: ubuntu + macos):
  WordCore          document model, styles, numbering, revisions, fields, undo
  OOXMLCodec        docx ⇄ model, byte-preserving splice
  IntelligenceCore  AIProvider protocol, prompt/tool schemas, routing, redaction

Targets that build on Apple platforms only (CI: macos):
  WordLayout        CoreText shaping + pagination + tables + floats
  WordEditorKit     NSView, NSTextInputClient, WritingTools coordinator, accessibility
  WordApp           AppKit/SwiftUI shell, ribbon, panels, preferences
```

Because we cannot type-check locally, we must be disciplined: small files, explicit types,
no clever inference, and a CI job that fails fast on the first error with full output.
We should also add a **SwiftLint/SwiftFormat** job (both are preinstalled on the macOS 26
runner image) so style is enforced without a local toolchain.
