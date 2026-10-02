# Feature Inventory — full Microsoft Word parity

Word 365 (2026) has **eleven** ribbon tabs: File, Home, Insert, Draw, Design, Layout,
References, Mailings, Review, View, Help — plus **Copilot** when licensed, plus contextual
tabs (Picture Format, Shape Format, Table Design, Header & Footer, Link, Math, Drawing Tools).

Below is the complete surface, decomposed. Every feature carries:

- **Tier** — `P0` must-have for a credible v1.0, `P1` v1.x, `P2` v2.x, `P3` nice-to-have / may never
- **OOXML** — the ECMA-376 element(s) that carry it, so the codec and the model stay honest
- **Risk** — 🔴 hard / under-documented, 🟡 medium, 🟢 straightforward

---

## File (Backstage)

| Feature | Tier | OOXML / notes | Risk |
|---|---|---|---|
| New (blank + template gallery) | P0 | Template = a `.dotx` package we author ourselves. **Never** ship Word's templates | 🟢 |
| Open / Open Recent | P0 | `NSDocumentController`, security-scoped bookmarks | 🟢 |
| Save / Save As / Save a Copy | P0 | Byte-preserving save path | 🟡 |
| AutoSave + Versions | P0 | `NSDocument` + `NSFileVersion`; AutoSave to iCloud Drive | 🟢 |
| AutoRecover after crash | P0 | Periodic snapshot to app container | 🟢 |
| Export → PDF | P0 | `NSPrintOperation` to PDF, or CoreGraphics PDF context over our layout | 🟡 |
| Export → RTF / plain text / HTML / Markdown / EPUB | P1 | RTF is Apple-native (`NSAttributedString.rtf`); Markdown we own | 🟢 |
| Export → ODT | P2 | ISO 26300 — a whole second codec | 🔴 |
| Import `.doc` (binary, Word 97–2003) | P2 | `[MS-DOC]` compound binary. Enormous. Consider delegating to `textutil` for a lossy path | 🔴 |
| Import `.odt`, `.rtf`, `.html`, `.txt`, `.md`, `.epub` | P1 | RTF/HTML/TXT via `NSAttributedString`; ODT/EPUB own work | 🟡 |
| Import PDF → editable document | P2 | CoreGraphics/PDFKit text extraction + layout analysis + Vision OCR for scans. GenOffice has this; it's a real differentiator | 🔴 |
| Print (full `NSPrintOperation`, printer presets, page range, copies, duplex, scaling) | P0 | **Where GenOffice fails (#211)** — we get it free from AppKit | 🟢 |
| Document Properties / Metadata | P0 | `docProps/core.xml` (Dublin Core), `docProps/app.xml` (extended), `custom.xml` | 🟢 |
| Inspect Document (remove hidden metadata, personal info) | P1 | Strip `w:comment`, `w:ins/del` author, `docProps`, custom XML | 🟡 |
| Protect Document (password, read-only recommended, restrict editing) | P1 | `w:documentProtection` — note GenOffice bug #1686 on the *paired* form | 🟡 |
| Share (AirDrop, Mail, iCloud link, Collaborate) | P1 | `NSSharingServicePicker` | 🟢 |
| Account / Licence | P0 | | 🟢 |
| Options / Preferences | P0 | `NSPreferences` window with panes (see below) | 🟢 |
| Close | P0 | | 🟢 |

### Preferences panes (Word's Options dialog, mapped to Mac idiom)

General · Display · Proofing · Save · Language · Accessibility · Advanced (editing options,
cut/copy/paste behaviour, layout options) · **Intelligence** (ours — see `04-AI-INTEGRATION.md`) ·
Customise Ribbon / Keyboard · File Locations · Trust Center (macro & privacy settings).

---

## Home

### Clipboard
Paste · Paste Special (`NSPasteboard` with multiple types: our private model, RTF, HTML, plain, image, file URLs) ·
**Set Default Paste** (Keep Source Formatting / Merge Formatting / Keep Text Only) ·
Cut · Copy · Format Painter (**P1** — needs a property bag + one-shot mode) · Clipboard history (**P3**)

### Font
| Feature | Tier | OOXML | Risk |
|---|---|---|---|
| Font family (with live preview + recent + theme fonts) | P0 | `w:rFonts` (`ascii`/`hAnsi`/`cs`/`eastAsia`) — note Word stores **four** slots | 🟡 |
| Font size, Grow/Shrink | P0 | `w:sz`, `w:szCs` (half-points) | 🟢 |
| Bold / Italic / Underline (+ style & colour) / Strikethrough / Double strikethrough | P0 | `w:b`, `w:i`, `w:u val/color`, `w:strike`, `w:dstrike` | 🟢 |
| Subscript / Superscript | P0 | `w:vertAlign` | 🟢 |
| Text highlight colour | P0 | `w:highlight` (16 named) — **not** arbitrary colour; arbitrary uses `w:shd` | 🟡 |
| Font colour | P0 | `w:color`, `w:shd` for shading | 🟢 |
| Text Effects & Typography (shadow, reflection, glow, bevel, 3-D, outline, ligatures, stylistic sets, number spacing, number forms) | P2 | `w14:textEffects`, `w14:ligatures`, `w14:stylisticSet`, `w14:numForm`, `w14:numSpacing`. **OpenType features via CoreText `kCTFontFeatureSettingsAttribute`** | 🔴 |
| Character spacing: scale, position (raise/lower), kerning threshold | P2 | `w:w` (scale %), `w:position` (twips), `w:kern` | 🟡 |
| All Caps / Small Caps / Clear Formatting | P0 | `w:caps`, `w:smallCaps`, `w:rPrChange` | 🟢 |
| Change Case (Sentence/lower/UPPER/Title/tOGGLE) | P0 | app-level command | 🟢 |
| Font dialog (full, with preview) | P1 | | 🟡 |
| East Asian typography: emphasis marks, phonetic guide (ruby), character spacing grid, kumimoji | P3 | `w:em`, `w:ruby`, `w:rubyPr`, `w:kumimoji`, `w:kinsoku` | 🔴 |

### Paragraph
| Feature | Tier | OOXML | Risk |
|---|---|---|---|
| Bullets / Numbering / Multilevel list (+ list library, define new, custom bullets from symbol/picture/font) | P0 | `w:numPr` (`numId`+`ilvl`) → `numbering.xml` `w:abstractNum`/`w:num`. **Deep.** Restart numbering, continue numbering, legal numbering | 🔴 |
| Indent / Outdent, Left & Right indent, First-line / Hanging, Mirrored indents | P0 | `w:ind` (`left`/`start`/`right`/`end`/`firstLine`/`hanging`, and the `Chars` variants for CJK) | 🟡 |
| Alignment: Left / Centre / Right / Justify / **Distributed** | P0 | `w:jc` (`both`, `distribute`, `mediumKashida`, `highKashida`, `thaiDistribute`) | 🟡 |
| Line spacing (single/1.5/double/at least/exactly/multiple) + Before/After paragraph spacing + "Don't add space between paragraphs of the same style" | P0 | `w:spacing` (`line`, `lineRule` = auto/atLeast/exact, `before`, `after`, `beforeLines`/`afterLines`) | 🟡 |
| Borders (paragraph borders, box/individual sides, art borders) | P1 | `w:pBdr`, `w:tblBorders` for cells | 🟡 |
| Shading (paragraph & character background) | P1 | `w:shd` (fill, pattern, colour) | 🟡 |
| Sort (A–Z / Z–A / by field / numeric, multi-key) | P1 | app-level | 🟢 |
| Show/Hide ¶ (formatting marks: pilcrow, spaces, tabs, section breaks, optional hyphens, object anchors) | P0 | app-level rendering flag | 🟢 |
| Text direction (LTR / RTL / vertical) | P0 | `w:bidi`, `w:textDirection`. **GenOffice lacks RTL — a differentiator for us** | 🔴 |
| Line numbers (continuous / per page / restart per section) | P2 | `w:lnNumType` in `sectPr` | 🟡 |
| Hyphenation (automatic / manual / none, hyphenation zone, limit consecutive) | P1 | `w:hyphenationZone`, `w:consecutiveHyphenLimit`, `w:doNotHyphenate`. Manual = `w:softHyphen`/`w:noBreakHyphen` | 🟡 |
| Tabs dialog (tab stops, leader styles, clear) + ruler drag | P0 | `w:tabs` (`val`=left/center/right/decimal/bar/clear, `leader`=none/dot/hyphen/underscore/heavy/middleDot, `pos`) | 🟡 |
| Word count (live, in status bar + dialog with pages/words/chars±spaces/paragraphs/lines/footnotes/textboxes) | P0 | `docProps/app.xml` caches these; we recompute | 🟢 |

### Styles
| Feature | Tier | OOXML | Risk |
|---|---|---|---|
| Style gallery with live previews + theme-driven | P0 | `styles.xml`: `w:style` (`paragraph`/`character`/`table`/`numbering`), `w:basedOn`, `w:next`, `w:link`, `w:uiPriority`, `w:semiHidden`, `w:unhideWhenUsed`, `w:qFormat`, `w:latentStyles` | 🔴 |
| Style inheritance resolution (document defaults → style chain → numbering → direct formatting) | P0 | `w:docDefaults` (`rPrDefault`, `pPrDefault`), then `basedOn` chain, then `w:rPr`/`w:pPr`. **This cascade is the single most important thing to get right** | 🔴 |
| Create / Modify / Delete style; New Style dialog with full formatting | P0 | | 🟡 |
| Style Inspector ("Reveal Formatting" — show effective formatting at the cursor with its provenance) | P1 | | 🟡 |
| Clear All / Clear Formatting | P0 | | 🟢 |
| Style sets / Change Styles (Word's Design→Styles group) | P2 | | 🟡 |
| Organiser: copy styles between documents | P2 | | 🟡 |
| Linked styles (paragraph + character pair, e.g. Heading 1 / Heading 1 Char) | P1 | `w:link` | 🟡 |

### Editing
Find (basic / advanced with wildcards `? * @ < > # [ ] ! \ ^n ^t ^b` and regex) ·
Replace (single / all / with formatting / replace-with special chars) ·
Replace-all with **undo as one operation** ·
Select All / Select Objects / Select Text with Similar Formatting ·
Go To (page, section, line, footnote, endnote, comment, bookmark, table, graphic, equation, field, heading, object) ·
Navigation pane with headings/results/pages

> Word's Find & Replace special codes are a **documented, distinctive grammar** we must match
> exactly for muscle memory: `^p` paragraph mark, `^t` tab, `^b` section break, `^n` column
> break, `^l` manual line break, `^#` any digit, `^$` any letter, `^~` any manual hyphen,
> `^+` any em dash, `^s` non-breaking space, `^g` any graphic, `^c` clipboard contents,
> `^f` footnote mark, `^e` endnote mark, `^d` field, `^w` whitespace, `^^` caret.
> Wildcard mode uses a different table (`<`, `>`, `!`, `[a-z]`, `{n}`, `{n,}`, `@`, `()`
> with `\1` back-references). **Tier P0, risk 🟡** — it's just a translator layer, but it must
> be complete or power users will notice instantly.

---

## Insert

| Group | Feature | Tier | OOXML | Risk |
|---|---|---|---|---|
| Pages | Cover Page gallery | P3 | Building blocks (`glossaryDocument.xml`) — and we must author our own covers | 🟡 |
| Pages | Blank Page, Page Break | P0 | `w:br type="page"`, `w:lastRenderedPageBreak` | 🟢 |
| Tables | Insert table (grid picker, n×m) | P0 | `w:tbl`, `w:tblGrid`, `w:tc`, `w:tr` | 🔴 |
| Tables | Draw Table / Eraser | P2 | | 🔴 |
| Tables | Insert row/column, delete, split/merge cells, split table | P0 | `w:gridSpan`, `w:vMerge` | 🟡 |
| Tables | AutoFit (to contents / to window / fixed) | P0 | `w:tblLayout type=fixed/autofit`, `w:tblW`, `w:tcW` | 🔴 |
| Tables | Cell margins, alignment, text direction, cell shading/borders | P1 | `w:tblCellMar`, `w:tcPr` | 🟡 |
| Tables | Repeat header row, allow row to break across pages, `cantSplit` | P1 | `w:tblHeader`, `w:cantSplit` | 🟡 |
| Tables | Table styles (gallery) | P1 | `w:tblStylePr` (banding: `firstRow`, `lastRow`, `firstColumn`, `lastColumn`, `band1Horz`…) | 🔴 |
| Tables | Sort, Formula (`=SUM(ABOVE)`) | P2 | `w:fldSimple` with `FORMULA` field | 🟡 |
| Tables | Convert text↔table | P1 | | 🟢 |
| Illustrations | Pictures (from file / online) | P0 | `w:drawing` → `wp:inline`/`wp:anchor` → `a:graphic` → `pic:pic`, with `r:embed` rels | 🟡 |
| Illustrations | Shapes (full preset geometry library) | P1 | `a:prstGeom prst="…"` — ~187 preset shapes in DrawingML | 🔴 |
| Illustrations | SmartArt | P3 | `diagram*.xml` (data, colors, layout, quickStyle) + layout algorithms. Genuinely huge | 🔴 |
| Illustrations | Charts | P3 | `chart*.xml` + embedded `.xlsx`. Needs a chart engine | 🔴 |
| Illustrations | Screenshot / Screen clipping | P2 | `CGWindowListCreateImage` + screen-recording permission | 🟡 |
| Illustrations | 3D Models | P3 | `w:model3d`, glTF | 🔴 |
| Add-ins | Office Add-ins (JS API) | P3 | Would require hosting the Office.js runtime — realistically no | 🔴 |
| Media | Online Video | P3 | `w:drawing` + video rels | 🟡 |
| Links | Hyperlink (create/edit/remove, screen tip, bookmark target, `mailto:`) | P0 | `w:hyperlink r:id`, `w:instrText HYPERLINK` | 🟢 |
| Links | Bookmark | P0 | `w:bookmarkStart/End` + `w:name` | 🟢 |
| Links | Cross-reference (to heading/bookmark/footnote/figure/table/numbered item, insert as hyperlink, insert relative position) | P1 | `w:instrText REF _Ref123 \h` | 🔴 |
| Comments | New comment, threaded replies, resolve | P0 | `comments.xml`, `w:commentRangeStart/End`, `w:commentReference`; threading via `commentsExtended.xml` (`w15:paraIdParent`, `w15:done`) | 🟡 |
| Header & Footer | Header / Footer (gallery + Edit), Page Number (position/format/starting value), **Different First Page**, **Different Odd & Even** | P0 | `sectPr/w:headerReference type=default|first|even`, `w:titlePg`, `w:evenAndOddHeaders` in `settings.xml` | 🟡 |
| Header & Footer | Page number formats (arabic, roman, letters, chapter-prefixed `1-1`) | P1 | `w:pgNumType fmt=…` | 🟡 |
| Text | Text Box (simple + gallery, linked text boxes with flow) | P1 | `w:txbxContent`; linked = `w:link` chain. Text boxes participate in word count and can have their own columns | 🔴 |
| Text | Quick Parts / AutoText / Field / Building Blocks Organiser | P2 | `glossaryDocument.xml` | 🟡 |
| Text | WordArt | P3 | DrawingML `a:effectLst`, `a:xfrm`, text warp | 🔴 |
| Text | Drop Cap (dropped / in margin, lines, distance) | P2 | `w:framePr` on a paragraph | 🔴 |
| Text | Object (insert file as OLE / icon), Signature Line, Date & Time | P2/P3 | `w:object`, `o:OLEObject`. OLE on Mac is essentially dead — Word for Mac itself is weak here | 🔴 |
| Symbols | Symbol gallery, Equation insert, Special characters (em/en dash, NBSP, ZWSP, ©, ™, °, ±, ← ↑ → ↓), Unicode hex input, AutoCorrect symbols | P0 | `w:sym`, `w:noBreakHyphen`, `w:softHyphen` | 🟢 |
| Symbols | **Equation** (OMML) | P2 | `m:oMath`, `m:oMathPara` — linear vs professional form, the full Unicode math alphanumeric block, matrices, radicals, integrals, limits, accents, bars | 🔴 |

---

## Draw

Pens (colour, weight, custom) · Ruler · Lasso select · Insert Shapes · Convert ink to shape/text/math ·
Ink Replay · Delete ink · Ink-to-text.

**Implementation:** `PKCanvasView` / `PKDrawing` (PencilKit) is native on macOS and gives us
pens, lasso, and a serialisable ink model for free.

**OOXML:** ink is stored as DrawingML — `w:drawing` with `wps:wsp` freeform shapes
(`a:custGeom`) or, in newer Word, `inkml:` / `w16du:ink` parts. Round-tripping Word's own ink
is 🟡; *authoring* our own ink and exporting as DrawingML freeforms is 🟢.

Tier **P2**. Cheap win on macOS, and GenOffice's equivalent (`w:ink`) is minimal.

---

## Design

| Feature | Tier | OOXML | Risk |
|---|---|---|---|
| Document Formatting themes (a "Style Set" = coordinated style definitions) | P1 | `theme1.xml` (`a:themeElements`: colour scheme, font scheme, format scheme) + style set overrides | 🟡 |
| Themes: Colours / Fonts / Effects | P1 | `a:clrScheme` (12 slots), `a:fontScheme` (major/minor latin/ea/cs), `a:fmtScheme` (fill/line/effect styles ×3) | 🟡 |
| Set as Default | P1 | writes to `Normal.dotm` equivalent — for us, a user template | 🟢 |
| Page Colour | P1 | `w:background w:color` — note GenOffice bug #1683: paired `w:background` left behind | 🟢 |
| Page Borders (box, art borders, applies-to section/whole doc, measure from text/edge) | P1 | `w:pgBorders`, `w:display` | 🟡 |
| Watermark (gallery + custom text/image, scale, washout, diagonal/horizontal) | P1 | A header containing an anchored shape; **not** a first-class element | 🟡 |
| Paragraph Spacing presets (No paragraph space / Compact / Tight / Open / Relaxed / Double) | P1 | style-level `w:spacing` overrides | 🟢 |

---

## Layout

| Group | Feature | Tier | OOXML | Risk |
|---|---|---|---|---|
| Page Setup | Margins (presets + custom, gutter, mirror margins, book fold) | P0 | `w:pgMar` (`top/right/bottom/left/header/footer/gutter` in twips) | 🟢 |
| Page Setup | Orientation Portrait/Landscape | P0 | `w:pgSz w:orient` | 🟢 |
| Page Setup | Size gallery (Letter, A4, A3, Legal, Tabloid, B4/B5 JIS, Executive, Statement, plus custom; **and locale-dependent defaults**) | P0 | `w:pgSz w:w/h` (twips) | 🟢 |
| Page Setup | **Columns** (1/2/3, preset, custom with width+spacing, line between, apply to section/this point forward, right-to-left column order, balanced columns) | P1 | `w:cols w:num/space/equalWidth/sep`, `w:col w:w/space`; RTL via `w:bidi` | 🔴 |
| Page Setup | **Sections & Breaks**: Next Page, Continuous, Even Page, Odd Page; Column break; Text Wrapping break | P0 | `w:sectPr` (inline for non-final sections), `w:type`, `w:br type="column|textWrapping"` | 🔴 |
| Page Setup | Line Numbers | P2 | `w:lnNumType` (`countBy`, `start`, `distance`, `restart`) | 🟡 |
| Page Setup | **Hyphenation** | P1 | `w:autoHyphenation`, `w:consecutiveHyphenLimit`, `w:hyphenationZone`, `w:doNotHyphenate` | 🟡 |
| Paragraph | Indents & Spacing (same controls as Home) | P0 | | 🟡 |
| Arrange | Bring Forward / Send Backward / Bring to Front / Send to Back | P1 | `wp:anchor` `relativeHeight`, `w14:anchorId`/`editId`; z-order within the same anchor tree | 🟡 |
| Arrange | Selection Pane (list of objects, show/hide, rename, reorder) | P1 | app-level | 🟡 |
| Arrange | Align (left/centre/right/top/middle/bottom, align to page/margin/selected objects, distribute h/v) | P1 | `wp:positionH/V` relative offsets | 🟡 |
| Arrange | Rotate / Flip | P1 | `a:xfrm rot=`, `flipH`, `flipV` | 🟡 |
| Arrange | **Wrap Text**: In Line with Text, Square, Tight, Through, Top and Bottom, Behind Text, In Front of Text, **Edit Wrap Points**, More Layout Options | P1 | `wp:wrapNone/Square/Tight/Through/TopAndBottom`, `wp:effectExtent`, `a:wrapPolygon` with `a:polyline` points | 🔴 |
| Arrange | Position (absolute/relative horizontal & vertical position presets) | P1 | `wp:positionH relativeFrom="…"` + `wp:posOffset` | 🟡 |
| Arrange | View Grid / Grid Settings / Snap to Grid / Align to Grid / character grid for CJK | P2 | `w:docGrid` (`type`, `linePitch`, `charSpace`) — **materially changes layout for CJK** | 🔴 |

---

## References

| Feature | Tier | OOXML | Risk |
|---|---|---|---|
| **Table of Contents**: automatic gallery, custom TOC (levels, show page numbers, right-align, tab leader, hyperlinks, use outline levels or TC fields), Update (page numbers only / entire table) | P0 | `w:sdt` wrapping `TOC \o "1-3" \h \z \u` field; entries are `w:instrText` + cached result. Word stores the **computed result inline** and marks it `dirty="true"` to request an update | 🔴 |
| Add Text → set outline level for TOC inclusion | P1 | `w:outlineLvl` | 🟢 |
| Update Table | P0 | field re-evaluation | 🟡 |
| **Footnotes**: insert, next footnote, show notes; Footnote & Endnote dialog (number format, start at, apply changes to whole doc/section, custom mark) | P0 | `footnotes.xml`/`endnotes.xml`, `w:footnoteReference`, `w:footnoteRef`, separators `w:separator`/`w:continuationSeparator`/`w:continuationNotice` | 🔴 |
| Convert footnotes ↔ endnotes; Endnotes numbering per section/document | P1 | `w:endnotePlacement`, `w:numberingFormat` | 🟡 |
| **Citations & Bibliography**: Source Manager, Insert Citation, Style (APA / MLA / Chicago / IEEE / Harvard / ISO 690 / SIST02 / Turabian / GOST), Bibliography, Add New Source, Edit Source, Cross-reference a source, Placeholder sources, "Manage Sources" | P2 | `w:citation` / `w:source` — the source data lives in `people.xml`? No: Word uses the **`w:sources`/`Sources.xml`** part with the `http://schemas.openxmlformats.org/officeDocument/2006/bibliography` namespace, plus `ADDIN` fields for the rendered bibliography. Word's own CSL-like style engine is undocumented | 🔴 |
| Better path for citations | P2 | Adopt **CSL** (Citation Style Language, open, ~12,000 public styles at citationstyles.org) + **BibTeX/CSL-JSON/Zotero/Better BibTeX** import. Superset of what Word does, and genuinely open | 🟡 |
| **Captions**: Insert caption, label (Figure/Table/Equation/custom), position, exclude label, numbering (incl. chapter number), New Label | P1 | `SEQ Figure \* ARABIC` fields + `Caption` style | 🟡 |
| **Cross-reference** (see Insert → Links) | P1 | `REF`/`PAGEREF`/`NOTEREF` fields | 🔴 |
| **Index**: Mark Entry, Mark All, AutoMark, Insert Index (formats, columns, page numbers, run-in vs indented), Update | P2 | `INDEX \c "2"` field + `w:indexEntry` XE fields; Mellel's index tool is the benchmark here | 🔴 |
| **Table of Authorities**: Mark Citation, Insert TOA, category | P3 | `TA`/`TOA` fields — US legal only | 🔴 |
| Researcher / Research pane | P3 | Word's is Bing-backed; ours becomes **our AI provider layer** — see `04-AI-INTEGRATION.md` | — |

---

## Mailings

| Feature | Tier | Notes | Risk |
|---|---|---|---|
| Envelopes (size, printing, return address, font, postage) | P2 | | 🟡 |
| Labels (vendor/product catalogue — Avery etc., single label or full sheet, options) | P2 | We must author our own label-geometry catalogue; Avery's product numbers are facts, their artwork is not ours | 🟡 |
| Start Mail Merge: Letters / Email messages / Envelopes / Labels / Directory / Normal Word document | P2 | `w:mailMerge` in `settings.xml` (`w:mainDocumentType`, `w:dataType`, `w:connectString`, `w:query`, `w:linkToQuery`) | 🟡 |
| Select Recipients: Type a New List (with customise-columns), Use an Existing List (CSV/Excel/Outlook contacts/ODBC/Access) | P2 | Data sources via `Contacts.framework` for People; CSV/xlsx parsers | 🟡 |
| Edit Recipient List (sort, filter, find duplicates, validate addresses) | P2 | | 🟡 |
| Write & Insert Fields: Highlight Fields, Address Block, Greeting Line, Rules (**If…Then…Else**, **Ask**, **Fill-In**, **Skip If**), Insert Merge Field, Update Labels, Match Fields | P2 | `MERGEFIELD`, `IF`, `ASK`, `FILLIN`, `SKIPIF`, `NEXT`, `NEXTIF`, `MERGEREC`, `MERGESEQ`, `ADDRESSBLOCK`, `GREETINGLINE` — a whole **field-code interpreter** with switch parsing (`\b \e \f \h \l \p \s \v \* MERGEFORMAT \# "number picture" \@ "date picture"`) | 🔴 |
| Preview Results, Find Recipient, Auto Check for Errors | P2 | | 🟡 |
| Finish & Merge: Edit Individual Documents, Print Documents, Send Email Messages (subject, format, mail merge as attachment) | P2 | | 🟡 |

> **Opinion:** mail merge is a large, self-contained subsystem (a field interpreter + a data
> source layer + a batch renderer). It is high-value for a *specific* audience and near-zero
> for most. Recommend **P2, sequenced after the AI layer**, and implemented on top of the same
> field engine that TOC/REF/cross-references need — so the marginal cost drops a lot.

---

## Review

| Group | Feature | Tier | Notes | Risk |
|---|---|---|---|---|
| Proofing | Spelling & Grammar, Check Document Now, **Set Proofing Language**, auto-detect language, hide spelling/grammar errors, custom dictionaries (add/delete/edit), suggestions, "Ignore"/"Ignore All"/"Add to Dictionary" | P0 | `NSSpellChecker` gives us system dictionaries for free, per-language, with `NSGuessLanguage` detection. Plus optional LanguageTool self-hosted for grammar | 🟢 |
| Proofing | **AutoCorrect** (exceptions, "Replace text as you type", symbol autocorrect, initial-caps, two-initial-capitals, accidental caps, sentence caps, table cell caps, border keys `->`, `=>`, `--`, `__`, `*-*` → horizontal line, backspace-undoes-autocorrect) | P1 | A genuinely beloved feature and fiddly to get right. OOXML: `w:autoCorrect` isn't a doc element — autocorrect entries live in the *app*, and its output appears as normal runs + `w:proofErr` markers | 🟡 |
| Proofing | Word Count, Read Aloud (**Speech**), Thesaurus, Research, **Translator** (whole-doc translation producing a translated copy) | P0/P1 | Read Aloud: `AVSpeechSynthesizer` — native, free, and better than Word's. Translator: **our AI layer** | 🟢 |
| Proofing | `w:proofErr` markers (spellStart/End, gramStart/End) | P1 | Word persists these; we should too for round-trip fidelity | 🟡 |
| Accessibility | **Accessibility Checker** (missing alt text, heading order, reading order, contrast, table headers, blank cells used for layout, document title, language) | P1 | Word exports a report; we can go further with VoiceOver-integrated live checks | 🟡 |
| Accessibility | Alt text (auto-generate via Vision + on-device model), reading order pane | P1 | `VNGenerateImageCaptioningRequest` + AFM 3 Core Advanced (multimodal, on-device) — **free and private** | 🟢 |
| Language | Translation of selection, language preferences | P1 | | 🟢 |
| Comments | New / Delete / Delete All / Show Comments / Resolve / Reply / threaded / by-reviewer filtering / `@mentions` | P0 | see Insert → Comments | 🟡 |
| Tracking | **Track Changes** (`w:trackChanges` in settings), display modes (Simple Markup / All Markup / No Markup / Original), show markup by category & reviewer, balloons (In Line / In Balloons / Show All Revisions Inline), balloon width, highlight updates, review pane (vertical/horizontal) | P0 | `w:ins`, `w:del`, `w:moveFrom`, `w:moveTo`, `w:rPrChange`, `w:pPrChange`, `w:sectPrChange`, `w:tblPrChange`, `w:tcPrChange`, `w:trPrChange`, `w:numberingChange`, `w:cellIns/cellDel/cellMerge`. **This is the substrate our AI edits will use** | 🔴 |
| Changes | Accept / Reject (this / all / and move to next), Accept & Move, Show Changes | P0 | | 🟡 |
| Compare | **Compare** (original vs revised → produces a redlined doc), **Combine** (multiple reviewers' revisions into one) | P2 | A real diff engine over the doc model + revision synthesis | 🔴 |
| Protect | Restrict Editing (track-changes-only, comments-only, no changes/read-only, filling in forms, exceptions per range/user, start enforcement, password), Protect Group | P1 | `w:documentProtection` — and see GenOffice #1686 | 🟡 |
| Ink | (see Draw) | P2 | | 🟡 |

---

## View

| Group | Feature | Tier | Notes | Risk |
|---|---|---|---|---|
| Views | **Read Mode** (immersive, column-flip page metaphor, reading tools) | P1 | | 🟡 |
| Views | **Print Layout** | P0 | The default and the hard one | 🔴 |
| Views | **Web Layout** | P2 | Continuous, no pages, wraps to window | 🟡 |
| Views | **Outline** (show level, promote/demote, expand/collapse, show first line only, master document: create/show document/insert/subdocument/open/close/promote-demote/lock) | P2 | `w:outlineLvl`; master documents use `w:subDoc` + `.docx` subfiles | 🔴 |
| Views | **Draft** (no headers/footers/objects, fastest editing) | P1 | | 🟡 |
| Immersive | Focus / full-screen, column width, page colour, page margins toggle, text spacing, syllables, focus on lines, hide ribbon, Read Aloud | P2 | | 🟢 |
| Page Movement | Vertical / Side to Side | P2 | | 🟢 |
| Show | Ruler (horizontal + vertical), Gridlines, **Navigation Pane** (headings / pages / results) | P0 | | 🟢 |
| Zoom | Zoom %, 100%, One Page, Multiple Pages, Page Width, Text Width, Whole Page | P0 | | 🟢 |
| Window | New Window, Arrange All, Split, Freeze Panes, Cascade, View Side by Side, Synchronous Scrolling, Reset Window Position, switch between open documents, **tabbed documents** | P1 | Mac idiom: native tabs (`NSWindow.tabbingMode`) + `NSSplitViewController`. Word for Mac has tabs since 2019 — users expect them | 🟡 |
| Macros | View Macros, Record Macro, Run Macro, macro security | P3 | Word uses VBA. There is **no VBA on macOS in a sandboxed app**, and shipping a VBA host is impossible. Alternatives: (a) AppleScript/JXA + Shortcuts automation, (b) a JS/Lua scripting host (this is what Nisus and Mellel do — Mellel uses its own; Nisus has Perl + its macro language), (c) our AI agent as the "macro" replacement. **Recommend (a)+(c) at P1, (b) at P3** | 🔴 |

---

## Contextual tabs

| Tab appears when | Contents | Tier | Risk |
|---|---|---|---|
| **Picture Format** | Remove Background, Corrections, Colour (recolour/toning/saturation/temp), Artistic Effects, Transparency, Picture Styles gallery, Picture Border/Effects/Layout, Picture Shape, Crop (crop/aspect/shape/fill), Wrap Text, Position, Align, Rotate, Size (height/width/lock aspect/relative to page), Alt Text, Compress Pictures, Change Picture, Reset Picture | P1 | CoreImage filters for corrections/colour/effects; `a:blip` + `a14:imgLayer` for the format; crop via `a:srcRect` | 🔴 |
| **Shape Format** | Insert Shapes, Edit Shape (change shape, edit points), Shape Styles gallery, Shape Fill/Outline/Effects, WordArt Styles (fill, outline, shadow, glow, reflection, 3-D rotation, transform/warp), Arrange, Size, Selection Pane | P1 | DrawingML `a:solidFill/gradFill/pattFill/blipFill/noFill`, `a:effectLst` (outerShdw, innerShdw, glow, reflection, softEdge, prstTxWarp), `a:xfrm` + `a:xfrm3d` | 🔴 |
| **Table Design** | Header Row / First Column / Total Row / Last Column / Banded Rows / Banded Columns toggles, Table Style gallery, New Style, Table Style Options, Borders & Shading, Pen colour/weight/style, Border Painter, Table name | P1 | `w:tblStylePr` conditional formatting | 🔴 |
| **Table Layout** | View Gridlines, Properties, Insert Above/Below/Left/Right, Delete rows/columns/table/cells, Merge Cells / Split Cells / Split Table, Cell Size (height/width, distribute evenly), AutoFit, Margins, Alignment (9 positions + cell margins), Text Direction, Repeat Header Rows, Prevent Row Breaking, Sort, Formula | P0 | | 🟡 |
| **Header & Footer** | Header/Footer/Page Number galleries, Remove, Link to Previous, Different First Page, Different Odd & Even, Insert Alignment Tab, Go to Header/Footer/Next/Previous, Position (header/footer distance from edge), Show Text, Close | P0 | | 🟡 |
| **Link** | Open Link, Edit Link, Copy Address, Remove Link, Screen Tip | P0 | | 🟢 |
| **Math / Equation** | Equation gallery (built-ins: area of circle, binomial theorem, expansion of a sum, Fourier series, Pythagorean theorem, quadratic formula, Taylor expansion…), Insert New / Ink Equation, Tools (equation array, matrix, subscript/superscript, fraction, radical, integral, large operator, bracket, accent, bar, limit, operator), Symbols (Greek, operators, arrows, relations), Structures, Professional/Linear toggle, Normal Text, Change Limits, e to the iπ, All / Built-in / Insert / Change | P2 | OMML `m:*`. Microsoft ships `OMML2MML.XSL` / `MML2OMML.XSL` **inside Word** — redistributing them is not permitted. Implement OMML directly, or convert via MathML with our own transform | 🔴 |
| **Drawing Tools** | (see Draw) | P2 | | 🟡 |

---

## Cross-cutting behaviours (not ribbon items, but users notice them instantly)

| Behaviour | Tier | Notes |
|---|---|---|
| **AutoFormat As You Type**: `1.` → numbered list, `-`/`*`/`>` → bullet, `#` → heading styles (Word 365 added this), `---` → horizontal rule (border), `===` → double border, `***` → thick border, `~~~` → wavy, `###` → triple, `___` → thick, straight quotes → smart quotes, `--` → en dash, `---` → em dash, `(c)`→© `(r)`→® `(tm)`→™, `1/2`→½, ordinals `1st`→1ˢᵗ superscript, fractions, `->`→→, `<=`→≤, hyperlinks from typed URLs/emails, tables from `+---+---+`, bulleted lists from tab/backspace, border keys | P1 | This is *the* "it feels like Word" feature. Must be configurable and reversible |
| **Smart cut/copy/paste**: automatically adjust spacing around pasted words, merge pasted list items into the target list, adjust paragraph spacing on paste, "smart paragraph selection" (selecting a paragraph selects its mark), "smart sentence selection" (snap to sentence boundaries), snap to grid/object when selecting | P1 | Word's `w:doNotUseHTMLParagraphAutoSpacing` etc. in `settings.xml` |
| **Selection behaviours**: double-click word, triple-click paragraph, click-in-left-margin selects line, double-click-margin selects paragraph, Cmd-click sentence, Option-drag rectangular (column) selection, Shift+arrow extend, Option+arrow by word, Cmd+arrow to line ends | P0 | Rectangular/column selection is a real differentiator; GenOffice-style editors rarely have it |
| **Drag and drop editing**: drag selected text within the document (Cmd-drag to copy), drag from Finder, drag between windows, drag to the desktop to create a clipping | P0 | |
| **Insert-mode toggle (overtype)** | P1 | `w:documentProtection`? No — it's a view/editing option; `w:overType` isn't OOXML. App-level + `settings.xml` `w:doNotTrackMoves`? Actually Word stores it as a per-document setting. Treat as app state |
| **Undo granularity** matching Word: typing coalesces into one undo per pause/word-boundary; a Find & Replace All is **one** undo; formatting is one; table insert is one; deleting a selection with content is one | P0 | Get this wrong and the app feels broken |
| **Find & Replace with formatting and styles**; Find in Selection | P1 | |
| **Context menu**: cut/copy/paste/paste options, styles, synonyms, search, translate, share, services, Writing Tools, inspect, link, comment, new comment | P0 | **This is where Apple Writing Tools appears — see §Writing Tools** |
| **Status bar**: page x of y, word count, language, accessibility errors, comments/revisions count, zoom slider, view buttons, focus/immersive | P0 | |
| **Rulers**: indent markers (first-line, hanging, left, right), tab stops with leader styles, drag to adjust, column boundaries, margin boundaries; vertical ruler in Print Layout | P0 | |
| **Mini toolbar** on selection (floating formatting popover) | P1 | Word for Mac has this. `NSPopover`-style floating panel |
| **Live layout feedback**: page breaks, keep-with-next, widow/orphan applied *while typing*, not on save | P0 | Requires our layout engine to be incremental & fast |
| **`w:compat`** — Word's compatibility settings that change layout behaviour per source document (space-for-ul, wrap-trail-spaces, no-tab-hang-ind, do-not-expand-shift-return, balance-single-byte-double-byte, etc., ~40 flags) | P1 | **Respect the flags in the incoming file** or round trips drift |
| **Fonts & metrics**: theme font resolution, `w:rFonts` four-slot selection by script, `w:cs` complex-script handling, `w:lang` + `w:bidi` + `w:eastAsianLayout` | P0 | |
| **Kerning, ligatures, discretionary ligatures, contextual alternates** | P1 | CoreText feature settings |
| **Performance targets** | P0 | Open a 300-page / 200k-word doc < 1.5 s to first paint; scroll 60/120 fps; keystroke → glyph < 16 ms; 60 MB image-heavy doc stays responsive. **These are the metrics GenOffice misses (#526, #459)** |

---

## Feature-count summary

| Tier | Rough count | Meaning |
|---|---|---|
| P0 | ~95 | Without these nobody switches from Word |
| P1 | ~110 | The "power user" layer |
| P2 | ~70 | Specialist / professional |
| P3 | ~30 | Chart/SmartArt/3D/VBA/master-doc territory — may never ship |

**Honest statement:** P0 alone is a large project. P0+P1 is a multi-year effort for a small
team, and it is what LibreOffice has spent 20+ years on. The plan in `05-ROADMAP.md` is
sequenced so that a *useful, better-than-GenOffice* app exists at each stage rather than a
half-built monolith at the end.
