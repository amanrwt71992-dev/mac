# A native Mac word processor, with AI that stays on your Mac

**Galley** — name checked and clear as of 2026-10-02 (GitHub `galleydoc`, npm `galley-word`,
and `galleydoc.app` were all unregistered). See [`docs/06-LEGAL-AND-IP.md`](docs/06-LEGAL-AND-IP.md).

A Microsoft Word–class word processor for macOS, built **native** — Swift, AppKit, and a
custom CoreText layout engine — with Apple Intelligence and bring-your-own AI providers
wired into the editor rather than bolted on beside it.

**Status: M0 engine core landed and CI-verified** (2026-10-02). The document model, the style
cascade, the greedy line breaker, the paginator, the editing layer and the AI provider
abstraction are written, and all three CI jobs are green: policy checks, Linux (Swift 6.2) and
macOS 27 (Xcode 27) — with `37/37` layout self-test checks passing on both platforms and
`27/27` of the metric-independent checks passing against real CoreText measurement. Zero
compiler warnings.

What is **not** here yet: any pixels. M0 shipped a headless harness (`swift run Galley
selftest`) rather than an AppKit window, because the exit question at this stage is whether the
engine lays a document out correctly, and a harness that runs identically on Linux and macOS
answers that on every push. The window, the ruler, IME and Writing Tools follow in M0.5/M1.
See the status block in [`docs/05-ROADMAP.md`](docs/05-ROADMAP.md) for exactly what was built
and what was deferred, and [`docs/07-OPEN-QUESTIONS.md`](docs/07-OPEN-QUESTIONS.md) §E for the
gaps discovered while building it.

---

## Why

There is already an excellent open-source attempt at this: **GenOffice** by Genspark
(`genspark-ai/genoffice`, Apache-2.0, 8.4k stars, 216 open issues as of 2026-10-02). It edits
real `.docx` files and its byte-preserving save strategy is genuinely clever.

It is also **six Electron apps**, and that one decision explains most of why it does not feel
like Word. From its own issue tracker:

| Issue | Symptom | Root cause |
|---|---|---|
| [#526](https://github.com/genspark-ai/genoffice/issues/526) | A 122-page document takes ~97 s to show content | Layout is not viewport-driven; CSS layout must measure the whole flow |
| [#459](https://github.com/genspark-ai/genoffice/issues/459) | A 60 MB image-heavy `.docx` is unusably laggy | Renderer-process + JS object model per document |
| [#211](https://github.com/genspark-ai/genoffice/issues/211) | Print dialog lacks printer settings; printed text quality is degraded | Chromium print path, not `NSPrintOperation` |
| [#118](https://github.com/genspark-ai/genoffice/issues/118) | Layout breaks when opening `.docx` | CSS line breaking ≠ Word's algorithm |
| [#1811](https://github.com/genspark-ai/genoffice/issues/1811) | Cannot have a dark UI with a light page | Hand-rolled theming |
| [#1778](https://github.com/genspark-ai/genoffice/issues/1778), [#1074](https://github.com/genspark-ai/genoffice/issues/1074) | Crashes | |

And the decisive one: **searching all 1,800+ GenOffice issues for "apple intelligence",
"foundation models" and "writing tools" returns nothing.** Electron has had an open feature
request for Apple Writing Tools since **2024-10-29**
([`electron/electron#44445`](https://github.com/electron/electron/issues/44445)) that is still
unresolved. Electron apps do not use `NSTextView`, so macOS never offers Writing Tools, and
there is no route from Chromium to the `FoundationModels` Swift API.

**Word for Mac itself uses a custom text engine on CoreText** (TidBITS 2018, quoting Nisus
Software). Pages uses WebKit. Nisus and Scrivener use Apple's Cocoa text engine — and Nisus'
own developers attribute their pagination limitations to that choice. TextKit 2 cannot
paginate at all: one `NSTextContainer` per layout manager, no tables, and an irreversible
downgrade to TextKit 1 the moment you touch `.layoutManager`.

So there is no shortcut. **The engine is the cost, and the engine is the moat.**

---

## What that buys us

| | Electron office suite | This project |
|---|---|---|
| Apple **Writing Tools** — inline rewrite, animation, inline proofreading marks | ❌ impossible | ✅ `NSWritingToolsCoordinator`, the API Apple built *for custom text engines* |
| Apple's own **task-trained LoRA adapters** (one per tone, one for proofreading) | ❌ not exposed publicly | ✅ obtained by integrating Writing Tools — cannot be reproduced by prompting the base model |
| **On-device AI**, free, offline, private | ⚠️ only by shelling out to `/usr/bin/fm` | ✅ `LanguageModelSession`, `@Generable` structured output, tool calling |
| **Free Private Cloud Compute** tier | ❌ | ✅ with the App Store entitlement (< 2 M downloads) |
| **Any AI provider** through one API | ⚠️ each hand-rolled over HTTP | ✅ Apple's `LanguageModel` protocol (macOS 27): Anthropic's `ClaudeForFoundationModels`, Google's Gemini via Firebase, `MLXLanguageModel`, `CoreAILanguageModel` |
| Word-accurate **line breaking & pagination** | ❌ CSS | ✅ Word's algorithm over real CoreText metrics |
| Open a 300-page document | ⚠️ tens of seconds | 🎯 < 1.5 s to first paint, viewport-driven |
| **Printing** | ⚠️ | ✅ `NSPrintOperation`, printer presets, duplex |
| Menus, Services, `NSSpellChecker`, dictation, Shortcuts, Siri, Spotlight, VoiceOver, Versions, Quick Look, Continuity | ⚠️ re-implemented over IPC, mostly isn't | ✅ free |
| Dark UI, white page | ⚠️ | ✅ free |
| App size / launch | ~250 MB, slow | ~30–60 MB, instant |
| **RTL and complex scripts** | ❌ missing entirely | ✅ CoreText bidi + shaping |

Plus one thing neither has: **AI edits land as real OOXML tracked changes** (`w:ins` /
`w:del`, author `Assistant (<provider>)`), so every AI change is individually
acceptable/rejectable in our Review pane — *and in Microsoft Word afterwards*.

And a hard privacy line: **no account, no credits, no server of ours, no telemetry.** The app
talks to your Mac or directly to a provider you configured. That is the precise answer to
GenOffice's most-discussed issue ("Other AI integration?") and the follow-up request for
"user-owned AI configuration: custom model endpoint, proxy, agent rules/skills".

---

## Documentation

| | |
|---|---|
| [`docs/01-RESEARCH.md`](docs/01-RESEARCH.md) | GenOffice autopsy (live issue evidence), the Apple AI landscape as of Oct 2026, the native-text-engine reality, format/font/naming law, and what we can and cannot build in this workspace |
| [`docs/02-FEATURE-INVENTORY.md`](docs/02-FEATURE-INVENTORY.md) | **The complete Word feature surface** — all 11 ribbon tabs + contextual tabs + cross-cutting behaviours, each with tier, OOXML element mapping and a risk rating |
| [`docs/03-ARCHITECTURE.md`](docs/03-ARCHITECTURE.md) | Package layout, document model, byte-preserving save, the 8-stage layout pipeline, editing layer, testing strategy, distribution |
| [`docs/04-AI-INTEGRATION.md`](docs/04-AI-INTEGRATION.md) | Writing Tools tiers, Foundation Models usage, the provider abstraction, the task taxonomy, structured edits, the agentic loop, redaction, evaluation |
| [`docs/05-ROADMAP.md`](docs/05-ROADMAP.md) | M0–M6 with objective exit tests and effort estimates |
| [`docs/06-LEGAL-AND-IP.md`](docs/06-LEGAL-AND-IP.md) | Name shortlist with live availability checks, OOXML/OSP analysis, font licensing, look-and-feel boundaries, dependency licence policy, privacy posture |
| [`docs/07-OPEN-QUESTIONS.md`](docs/07-OPEN-QUESTIONS.md) | Every decision that blocks code, with a recommendation for each |

---

## The plan in one paragraph

Prove the engine first (**M0**, ~4 weeks): a native window showing real pages of real text,
laid out by us, hitting the performance contract, with Apple Writing Tools already working in
the context menu. Then make it read and write real `.docx` without breaking anything
(**M1**, ~6 weeks), enforced by a CI gate that fails the build if saving an unedited document
changes a single byte. Then the everyday Word feature set (**M2**, ~10 weeks): find & replace
with Word's full wildcard grammar, lists, tables, images and floating objects, footnotes,
headers and footers, sections, spelling, AutoCorrect, views, PDF export. Then the AI layer
(**M3**, ~5 weeks): on-device by default, any provider the user adds, every edit a reviewable
tracked change. Then review/collaboration (**M4**), professional features (**M5**: fields,
TOC, cross-references, CSL citations, index, mail merge, equations), and scale (**M6**).

**v1.0 = M0–M3, roughly 25 focused developer-weeks.**

---

## Building

Requires macOS 27 and Xcode 27, or any Swift 6.0+ toolchain for the cross-platform packages.

```sh
swift build                          # everything
swift test --parallel                # CoreKit, LayoutKit and EditorKit suites
swift run Galley selftest            # the layout harness; exits 1 on any failed check
swift run Galley layout --verbose    # lay out the sample document and print every line
swift run Galley providers           # what AI is compiled in, and whether it is usable
```

`Galley selftest --measurer coretext` runs the same checks against real font metrics on macOS,
skipping the ones whose expected numbers were derived from the synthetic measurer. The synthetic
run is the one that asserts arithmetic; the CoreText run is the one that proves the measurement
backend works end to end. Both run in CI.

CI is three jobs on every push: `checks` (seconds, no compiler — package layering, the font
redistribution policy, the dependency-licence allowlist), `linux` (Swift 6.2 in a container —
the fast feedback loop), and `macos` (`xcode-27`, arm64, macOS 27 — the only job that can verify
measurement against the real platform). Compiler diagnostics and test failures are re-emitted as
workflow annotations, because runner logs are not reachable from every environment.

The split is load-bearing: `CoreKit`, `IntelligenceKit` and `EditorKit` import `Foundation` only,
so most of the codebase type-checks and unit-tests on Linux in under a minute. `LayoutKit` uses
CoreText behind `#if canImport(CoreText)`, and keeps its line breaker and paginator free of it so
they can be tested against a measurer with numbers a reader can check by hand. AppKit arrives in
M0.5 and will be confined to the view layer.

---

## Legal

Format: implementing ECMA-376 / ISO 29500 is covered by Microsoft's Open Specification
Promise; LibreOffice, OnlyOffice, Collabora, Google Docs, Apache POI and GenOffice all ship on
that basis. Fonts: we bundle only Apache-2.0 / OFL metric-compatible faces (Carlito,
Caladea, Liberation, Noto, DejaVu) and never redistribute Calibri or Cambria. Naming: no
Microsoft or Apple marks in the product name; GUI layout and functional command organisation
are not copyrightable (*Apple v. Microsoft*, *Lotus v. Borland*) but icons, templates,
gallery artwork and help copy are, so all of it is authored by us.

**Engineering guidance, not legal advice.** Details and the items needing counsel are in
[`docs/06-LEGAL-AND-IP.md`](docs/06-LEGAL-AND-IP.md).
