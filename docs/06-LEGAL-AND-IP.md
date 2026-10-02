# Legal, IP & Naming

**This is engineering guidance, not legal advice.** Items marked ⚖️ need a qualified lawyer
before commercial launch. Everything else is a design constraint we can act on now.

---

## 1. Product name

### Hard constraints

**Must not** contain or evoke: `Word`, `Microsoft`, `MS`, `Office`, `Microsoft 365`,
`Copilot`, `Windows`, `OneDrive`, `SharePoint`. Must not use the Word icon, the Office
"four-pane" logo, or any Microsoft artwork.

**Must not** use Apple marks *in the name*: `Apple`, `Mac`, `i`-prefix (`iWord`),
`Apple Intelligence`, `Swift`, `Cocoa`. Apple publishes trademark guidelines and has a long
history of objecting to `i`-prefixed products. Descriptive nominative use *in body copy* is
fine and desirable: "Built for macOS", "Works with Apple Intelligence", "Native Swift".

**Should** be: short, pronounceable, spellable when heard aloud, available as a GitHub org
+ a domain + an App Store name, and clear of conflicts in **Nice class 9** (software) and
**class 42** (SaaS/design) ⚖️.

### Candidate shortlist — checked 2026-10-02

Availability was checked live: GitHub username (404 = free), npm, and DNS A-record
(no record ≈ likely unregistered). **None of this substitutes for a trademark search** ⚖️.

| Name | Meaning / why | GitHub | npm | Domain signal | Conflict found | Verdict |
|---|---|---|---|---|---|---|
| ~~Quire~~ | A gathering of leaves in bookbinding | `quiredoc` free | `quire-doc` free | `quire.dev` no A record | ❌ **Getty's `Quire™`, an open-source multiformat *publishing* tool** — same field, registered mark | **REJECT** |
| **Galley** | A galley proof — typeset text before pagination. Exactly our domain | `galleydoc` free | `galley-word` free | `galleydoc.app` no A record | none found in software (web search returned nothing) | ✅ strong |
| **Incipit** | Latin: "here begins" — the opening words of a manuscript | `incipitdoc` free | `incipit-doc` free | `incipit.dev` no A record | none found in software | ✅ strong, more obscure |
| **Colophon** | The publisher's note at the end of a book describing how it was made | `colophondoc` free | — | `colophon.dev` no A record | none found as a product; generic dictionary word | ✅ good |
| **Verso** | The left-hand page of a spread | `versodoc` free | `verso-doc` free | `verso.dev` **taken** (parked) | Verso Corp is a large *paper* company — adjacent ⚖️ | ⚠️ needs clearance |
| **Platen** | The plate in a press that presses paper against type | `platendoc` free | `platen-doc` free | `platen.dev` **taken** | several unrelated uses | ⚠️ needs clearance |
| **Foolscap** | A traditional paper size (~13.5″ × 17″) | `foolscapdoc` — | — | `foolscap.app` **taken** | some uses | ⚠️ weaker |
| **Palimpsest** | A manuscript page scraped clean and reused — perfect metaphor for tracked changes | `palimpsestdoc` free | — | — | a blockchain explorer uses it (unrelated field) | ✅ evocative but long |

**Recommendation: `Galley`.** It is a real printing term, unmistakably about documents,
two syllables, easy to say and spell, not used by any software product I could find, and the
`galleydoc` GitHub handle and `galleydoc.app` domain both appear free. Runner-up: `Incipit`
if we want something more distinctive and less likely to collide.

Whatever we pick:
- Register the GitHub org **and** the domain immediately, before announcing anything.
- Search USPTO TESS, EUIPO eSearch plus and WIPO Global Brand Database in classes 9 and 42 ⚖️.
- Search the Mac App Store for the exact string.
- Do **not** use a name that requires explaining, in the App Store subtitle. Subtitle should
  be functional: *"Word processor for Mac"* is fine and descriptive; *"The Microsoft Word
  alternative"* risks a nominative-use argument we do not need ⚖️.

### Bundle identifiers & UTIs

| Thing | Value | Note |
|---|---|---|
| App bundle id | `com.<ourdomain>.galley` | our own namespace |
| Helper/CLI bundle id | `com.<ourdomain>.galley.cli` | |
| App Group | `group.com.<ourdomain>.galley` | |
| **UTI we declare** | `org.openxmlformats.wordprocessingml.document` | **mandated by the standard — every implementation uses it.** We declare *conformance* / import, not ownership |
| MIME type | `application/vnd.openxmlformats.wordprocessingml.document` | standard-mandated |
| Our own UTI | `com.<ourdomain>.galley.document`, conforming to the above | so Finder/Open-With behaves, without inventing a format nobody can read |
| OOXML namespaces | `http://schemas.openxmlformats.org/wordprocessingml/2006/main`, `.../drawingml/2006/main`, `.../officeDocument/2006/relationships`, `.../package/2006/relationships`, `http://schemas.openxmlformats.org/officeDocument/2006/math`, `http://schemas.openxmlformats.org/officeDocument/2006/bibliography` | standard-mandated literal strings; **must** be used verbatim or files will not open in Word |

Using these is not trademark use — they are identifiers defined by ECMA-376/ISO 29500 that
the format *requires*. LibreOffice, OnlyOffice, Apache POI and GenOffice all use them.

---

## 2. The `.docx` format — safe to implement

- **ECMA-376** (1st ed. 2006-12-07) → **ISO/IEC 29500:2008** → 4th ed. 2016-10-26.
  A published, open international standard.
- Ecma standards "are made available to all interested persons or organizations, **free of
  charge and copyright**."
- Microsoft's **Open Specification Promise**: *"Microsoft irrevocably promises not to assert
  any Microsoft Necessary Claims against you for making, using, selling, offering for sale,
  importing or distributing any implementation to the extent it conforms to a Covered
  Specification."* Microsoft explicitly amended the OSP FAQ to confirm it covers **GPL**
  implementations.
- Microsoft's `[MS-OE376]` Open Specifications documentation permits making copies "in order
  to develop implementations" and redistributing included schemas, IDLs and code samples.
- Precedent is overwhelming: LibreOffice, Collabora, OnlyOffice, Google Docs, Apple Pages
  (imports .docx), Apache POI, Microsoft's own Open XML SDK (Apache-2.0), GenOffice.

### Honest caveats

- ⚖️ The OSP covers **Necessary Claims** for **conforming** implementations. Critics (the
  EOOXML objections, Groklaw) argued the "only the required portions" wording may not extend
  to *optional* parts of the spec. **Never tested in court.** Practically, every OSS office
  suite on earth ships on this basis, so the risk is accepted industry-wide — but it is real
  and should be disclosed to counsel.
- ⚖️ If we ever license the app commercially, confirm the OSP's "distributing" language covers
  our distribution model (MAS + direct download both look fine).
- **Do not reverse-engineer Word.** Work from the published ECMA/ISO schemas, the XSDs, and
  Microsoft's Open Specifications. Do not decompile, do not instrument Word's binaries, do not
  capture and redistribute Word's output as "expected results" beyond transient local testing.
- **Do not ship anything extracted from a Word installation** — templates, clip art, SmartArt
  layouts, `OMML2MML.XSL`/`MML2OMML.XSL`, `Normal.dotm`, the equation gallery, the cover-page
  gallery, the Avery label artwork. All of it must be authored by us or come from an open source.

### Our licence choice ⚖️

| Option | Effect |
|---|---|
| **Apache-2.0** | Same as GenOffice. Permissive, patent grant included (valuable here), commercial forks allowed. Best if we want contributors and ecosystem. |
| **MIT** | Simpler, but no explicit patent grant — a real loss given the OOXML patent question. |
| **GPL-3.0 / AGPL-3.0** | Copyleft. **Compatible with the OSP** (Microsoft amended the FAQ to say so explicitly), but AGPL is awkward with a Mac App Store binary and deters contributors from companies. |
| **Open-core (Apache-2.0 + `ee/` under a commercial licence)** | What GenOffice does. Works, but the `ee/` directory must be clearly separated and licenced from day one, not retrofitted. |
| **Proprietary / closed** | Simplest commercially, loses community leverage. |

**Recommendation: Apache-2.0 for the engine packages** (`CoreKit`, `OOXMLKit`,
`IntelligenceKit`, `LayoutKit`) so others can build on the format work, **and** either
Apache-2.0 or a separate commercial licence for the app. Decide before the first public
commit — retro-licensing is painful ⚖️. Note: the repository is currently private and
unlicenced; nothing is public yet, so this is still fully open.

---

## 3. Fonts — the trap everyone falls into

### Never bundle these
`Calibri`, `Cambria`, `Candara`, `Consolas`, `Constantia`, `Corbel`, `Segoe UI`,
`Times New Roman`, `Arial`, `Courier New`, `Tahoma`, `Verdana`, `Georgia`, `Impact`,
`Comic Sans MS`, `Trebuchet MS`, `Wingdings`, `Webdings`, `Symbol`, `Marlett`.
These are licensed **to Microsoft** (mostly via Monotype) and are **not redistributable**.
Word's own default is Calibri, so every `.docx` we open will ask for it — but *asking* is
fine; *shipping* it is not.

### Do this instead
1. **Runtime substitution, original name preserved.** If the user has Calibri installed
   (every Word-for-Mac user does, via Office), CoreText resolves it and we get pixel-accurate
   layout. The `.docx` we write still says `w:rFonts ascii="Calibri"`. Nothing to redistribute.
2. **Metric-compatible fallbacks when the real font is absent** — bundle only these:
   | Bundled | Substitutes for | Licence |
   |---|---|---|
   | **Carlito** | Calibri | Apache-2.0 |
   | **Caladea** | Cambria | OFL 1.1 |
   | **Liberation Sans / Serif / Mono** | Arial / Times New Roman / Courier New | OFL 1.1 (+ GPL exception) |
   | **Noto Sans / Serif** (incl. CJK, Arabic, Hebrew, Devanagari subsets) | everything else | OFL 1.1 |
   | **DejaVu** | broad Unicode coverage | Bitstream Vera licence (permissive) |
   This is exactly GenOffice's approach and it is correct. Every licence text goes in `NOTICE`.
3. **macOS system fonts** (`Helvetica Neue`, `SF Pro`, `SF Mono`, `New York`, `Menlo`,
   `Avenir Next`, `Charter`, `Palatino`, `Baskerville`, `Optima`, `Futura`, `Gill Sans`,
   `Didot`, `Copperplate`, `Chalkboard`, `Marker Felt`, …) are licensed for use **on macOS**.
   Since we are macOS-only, using them for our own UI and as fallbacks is fine. Do **not**
   embed them into exported documents or a cross-platform build.
4. **UI typeface:** use SF Pro / SF Symbols for the interface. That is what makes it feel
   native, and it is free to use in an Apple-platform app.
5. **Our own wordmark** must be drawn by us or commissioned ⚖️. Do not use a Microsoft or
   Apple typeface as the logo, and do not set the logo in Calibri.
6. **Exported PDFs:** embed only fonts we have the right to embed. System fonts on macOS
   generally permit embedding for print/PDF; Carlito/Caladea/Liberation/Noto explicitly do.
   Set `CGPDFContext` embedding flags accordingly and subset-embed to keep files small.

### Symbol & icon assets
- **SF Symbols** is free to use in Apple-platform apps, but SF Symbols assets cannot be
  redistributed outside Apple platforms and cannot be used in marketing artwork without care.
  For ribbon icons, prefer SF Symbols where available (it also makes us look native) and draw
  custom vector assets for the rest.
- **Never** trace, reference, or "recreate closely" Word's ribbon icons. Draw our own from the
  *concept* (a bold "B" is not copyrightable; Word's specific bold glyph artwork is).

---

## 4. Look and feel — what we may and may not copy

### May copy (functional, unprotected)

- The **idea** of a ribbon with tabs and grouped commands.
- **Tab names and command organisation** that are functional/descriptive: Home, Insert,
  Design, Layout, References, Mailings, Review, View. These are generic English words
  describing what the commands do.
- **Keyboard shortcuts** that are platform conventions: ⌘B ⌘I ⌘U ⌘Z ⌘F ⌘S ⌘P.
  (Note Word for Mac itself already maps these; we follow the *Mac* convention, which
  is also the Word-for-Mac convention.)
- **Standard-mandated identifiers** (UTIs, MIME types, OOXML namespaces, element names).
- Word's **feature semantics**: what "widow/orphan control" means, what `^p` means in Find,
  how a multilevel list restarts. Facts and methods of operation.

Basis: GUI layout and functional command hierarchy have repeatedly been held not
copyrightable — *Apple Computer v. Microsoft* (9th Cir. 1994) on the idea/expression
distinction and merger; *Lotus Development v. Borland* (1st Cir. 1995) holding a menu
command hierarchy is a "method of operation" under §102(b). Also relevant: §102(b) excludes
"any idea, procedure, process, system, method of operation, concept, principle, or discovery."

### May not copy (expression, protected)

- ❌ Word's **icons, artwork, illustrations, gallery thumbnails**.
- ❌ Word's **built-in templates, cover pages, SmartArt layouts, chart styles, equation
  gallery entries, watermark gallery art, label artwork**.
- ❌ Word's **help text, tooltip copy, marketing copy, error strings**. Write our own.
- ❌ Word's **exact colour values as a distinctive palette** used in a way that reads as
  their brand (the Word blue `#2B579A` / `#185ABD` in our icon or chrome) ⚖️. Pick our own
  accent colour. Apple's own HIG accent blue is fine and expected.
- ❌ Screenshots of Word in our marketing, or side-by-side comparisons using their UI imagery,
  without permission ⚖️. Text comparisons are safer.
- ❌ Any use of their marks in a way suggesting endorsement or provenance ("Word-compatible"
  as a *factual* interoperability statement is generally acceptable nominative use —
  "opens and saves Microsoft Word (.docx) files" — but ⚖️ have counsel confirm the exact
  wording, and never stylise it in Microsoft's typography or with their logo).

### Safe comparative language

✅ "Opens and saves `.docx` files. Your documents stay yours."
✅ "A native Mac word processor."
✅ "Works with Apple Intelligence. Bring your own AI, or keep it all on your Mac."
⚠️ "The best Microsoft Word alternative for Mac" — commonly used in the press and probably
fine as nominative comparative advertising, but ⚖️ clear it before putting it in the App Store.
❌ "Microsoft Word for Mac, reimagined."

---

## 5. Third-party dependencies — licence hygiene

Rule: **only MIT, Apache-2.0, BSD-2/3-Clause, ISC, OFL-1.1, Unlicense, CC0.**
No GPL/LGPL/AGPL in the app binary (a Mac App Store + Developer-ID dual distribution makes
LGPL dynamic-linking compliance annoying and GPL incompatible with MAS terms ⚖️).

| Dependency | Licence | Used for | Verdict |
|---|---|---|---|
| ZIPFoundation | MIT | OPC container | ✅ |
| swift-algorithms / swift-collections (Apple) | Apache-2.0 | utility | ✅ |
| swift-log, swift-metrics | Apache-2.0 | local logging | ✅ |
| `ClaudeForFoundationModels` (Anthropic) | check at adoption ⚖️ | Claude via Apple's protocol | verify |
| Firebase Apple SDK (Google) | Apache-2.0 + Firebase terms | Gemini | ⚖️ check the Firebase ToS for a desktop app |
| MLX / MLX-Swift (Apple) | MIT | local models | ✅ |
| Carlito, Caladea, Liberation, Noto, DejaVu | Apache-2.0 / OFL-1.1 / Vera | bundled fonts | ✅ ship licence text |
| libxml2 (system) | MIT | XML parsing | ✅ (or use our own tokenizer) |
| Citation Style Language styles | CC BY-SA 3.0 | citation styles | ⚠️ CC BY-SA on *data* is fine; keep attribution + share-alike for the style bundle only |
| HarfBuzz (Linux CI only) | MIT (Old MIT) | golden layout tests on Linux | ✅ not shipped |

Maintain a `NOTICE` and a generated `THIRD-PARTY-NOTICES.txt` in the app bundle, produced by
a CI job that fails if any dependency resolves to a disallowed licence. GenOffice does this
and it is the right instinct.

---

## 6. Privacy posture (this is a legal document too)

Because "keep it on the Mac" is the core promise, it must be *structurally* true, not a
marketing claim:

1. **No account required** to open, edit or save a document.
2. **No telemetry by default.** If we add opt-in crash reporting, it must contain no document
   content, and the AI request path must never be logged to it.
3. **No first-party server.** App → provider, direct. There is no infrastructure of ours that
   could be breached, subpoenaed, or switched off.
4. **Keys in the Keychain only**, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
5. **Local request log stays local**, in the app container, user-visible, user-deletable.
6. **A published Privacy Policy** that is short and specific ⚖️ — and, if we ship on the Mac
   App Store, an App Store **Privacy Nutrition Label** that can honestly say
   "Data Not Collected".
7. **GDPR/CCPA**: since we collect nothing, the honest answer is "we are not a controller of
   your document content" ⚖️ — but confirm with counsel, especially for the BYOK cloud path
   where the *provider* becomes controller and we must say so clearly in-app.
8. **Export control** ⚖️: encryption is used (TLS for BYOK providers, Keychain). File the
   annual self-classification report for US BIS if distributing internationally. Mass-market
   encryption exemption generally applies; confirm.

---

## 7. Repository & repo name

The current repo is `amanrwt71992-dev/mac`, private, one commit, no licence.

Options:
- **Keep it** as a private incubation repo and rename later. Cheapest, no churn.
- **Create a new repo** under a new GitHub org named after the product (e.g. `galleydoc/galley`)
  once the name is cleared. Cleaner history, and the org name is reserved.

Recommendation: decide the name first (it determines the org), then create the org + repo,
and migrate. Until then, keep working in `amanrwt71992-dev/mac` — no public commitment is
being made and nothing is announced.

⚖️ Before making the repo public: choose the licence (§2), add `NOTICE`, run the trademark
search (§1), and confirm no fixture `.docx` in `Fixtures/` is someone else's copyrighted
document.
