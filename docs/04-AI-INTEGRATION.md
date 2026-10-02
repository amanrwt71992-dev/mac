# AI Integration Design

> The user's requirement, verbatim: *"we can configure AI as well, and we can use the Apple AI
> intelligence as well there, so that things remain within Mac, and also we can configure our
> own AI providers."*

That is three separate requirements, and they map onto three separate layers:

1. **Apple Intelligence integration** — the OS-level surfaces (Writing Tools, Siri/Shortcuts,
   Spotlight, on-device model). Free, private, and something Electron apps structurally
   cannot have.
2. **Provider plurality** — one protocol, many backends: Apple on-device, Apple Private Cloud
   Compute, Claude, OpenAI, Gemini, OpenAI-compatible (Ollama / LM Studio / vLLM / a corporate
   gateway), and local MLX models.
3. **Data sovereignty** — a *policy* layer the user controls: what may leave the Mac, what
   never may, and what gets redacted on the way out.

The design below makes (3) the default and (1)+(2) pluggable.

---

## 1. Layer map

```
┌───────────────────────────────────────────────────────────────────────────┐
│ SURFACES — where AI shows up in the UI                                     │
│                                                                            │
│  ① Apple Writing Tools        system UI, Apple's own LoRA adapters,        │
│     (NSWritingToolsCoordinator)  inline rewrite + proofreading marks        │
│  ② Intelligence menu          our own menu, mirroring Writing Tools'       │
│     + ⌃⌘W / selection popover  vocabulary but routed to *our* providers    │
│  ③ Assistant panel            chat about the document; tool-calling agent   │
│  ④ Inline ghost / autocomplete continue-writing, next-sentence suggestion   │
│  ⑤ Ribbon commands            Summarise, Translate, Alt Text, ToC draft,   │
│                               Change reading level, Extract action items    │
│  ⑥ Siri / Shortcuts /         App Intents — "summarise this doc and        │
│     Spotlight                 email it to me", no plumbing required         │
│  ⑦ Review pane                every AI change appears as a tracked change   │
│                               with an author of "Assistant (<provider>)"    │
└───────────────────────────────────────────────────────────────────────────┘
                                   │
┌───────────────────────────────────────────────────────────────────────────┐
│ ORCHESTRATION — IntelligenceKit                                            │
│                                                                            │
│  DocumentContext        what the model is allowed to see (selection,       │
│                         surrounding block, outline, whole doc, comments)   │
│  Task                   a typed unit of work (see §4)                      │
│  Router                 Task × Policy × ProviderCapability → Provider      │
│  Policy                 privacy budget, cost budget, offline-only switch   │
│  Redaction              PII/sensitive-range scrubbing + restore map        │
│  ToolRegistry           the document tools an agent may call               │
│  MutationPlanner        model output → DocumentMutation (never a blob)     │
│  Evaluator              golden AI tests (Apple's Evaluations fw on 27)     │
└───────────────────────────────────────────────────────────────────────────┘
                                   │
┌───────────────────────────────────────────────────────────────────────────┐
│ PROVIDERS                                                                  │
│                                                                            │
│  AppleOnDeviceProvider      FoundationModels SystemLanguageModel           │
│                             AFM 3 Core (3B, 8k ctx) /                      │
│                             AFM 3 Core Advanced (20B sparse, multimodal)   │
│                             Free · offline · never leaves the Mac          │
│  ApplePCCProvider           PrivateCloudComputeLanguageModel               │
│                             Free under 2M App Store downloads + entitle    │
│                             Apple Silicon servers, no retention            │
│  ClaudeProvider             via Anthropic's ClaudeForFoundationModels      │
│                             (conforms to Apple's LanguageModel protocol)   │
│  GeminiProvider             via the Firebase Apple SDK                     │
│  OpenAIProvider             direct REST/SSE adapter                        │
│  OpenAICompatibleProvider   any base URL: Ollama, LM Studio, vLLM,         │
│                             llama-server, a corporate gateway, Tailscale   │
│  MLXLocalProvider           MLXLanguageModel (Apple OSS) — GGUF/MLX        │
│                             weights, runs on the Mac GPU                   │
│  CoreAIProvider             CoreAILanguageModel (Apple OSS) — Neural Engine│
└───────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Apple Intelligence integration — the details

### 2.1 Writing Tools (Tier 3, full inline experience)

Why this matters more than it sounds: **Apple's Writing Tools is not the base model.** It runs
task-trained LoRA adapters — one for proofreading, one per tone, one for summarising — that the
public `FoundationModels` API does not expose. You cannot reproduce that quality by prompting
AFM yourself. The only way to get it is to integrate Writing Tools.

Adoption plan:

| Step | Cost | Result |
|---|---|---|
| `EditorView` implements `NSTextInputClient` (required anyway for IME) + `NSServicesMenuRequestor` (`validRequestor(forSendType:returnType:)`, `readSelection`, `writeSelection`) | ~1 day | **Writing Tools appears in the context menu and Edit menu for free.** Tier 2. Works even before we finish the engine. |
| Set `writingToolsBehavior = .complete` and `allowedWritingToolsResultOptions = [.plainText, .richText, .list, .table, .presentationIntent]` | ~1 h | We declare we can render tables and structured results |
| Implement `NSWritingToolsCoordinator` + delegate | ~2 weeks | **Tier 3**: rewrite in place, Apple's animation, inline proofreading marks, presentation-intent structured results |

The delegate contract (from WWDC25 session 265) maps cleanly onto our architecture:

```swift
final class WritingToolsBridge: NSObject, NSWritingToolsCoordinatorDelegate {

    /// "prepares the context for Writing Tools to work on"
    /// → we hand over the selected range as attributed content, or the whole
    ///   document when the user selected nothing. Because our DocumentModel
    ///   is structured, we can hand over real paragraph/style context rather
    ///   than flattened text — better results than a plain NSTextView gets.
    func writingToolsCoordinator(_ c: NSWritingToolsCoordinator,
                                 contextFor range: NSRange) async -> WritingToolsContext

    /// "incorporates changes" — async, so we can coalesce undo, pause AutoSave,
    /// and suspend the AI agent while Writing Tools owns the text.
    func writingToolsCoordinator(_ c: NSWritingToolsCoordinator,
                                 applyChange change: WritingToolsChange) async

    /// "provides preview objects to use during animations"
    /// → we render the affected blocks offscreen at the target size. A web
    ///   engine cannot do this crisply; our CoreText painter can.
    func writingToolsCoordinator(_ c: NSWritingToolsCoordinator,
                                 previewFor range: NSRange) async -> WritingToolsPreview

    /// "provides coordinates for Writing Tools to draw proofreading marks"
    /// → straight from our LayoutSnapshot: NSRange → [CGRect] in view coords.
    func writingToolsCoordinator(_ c: NSWritingToolsCoordinator,
                                 coordinatesFor range: NSRange) async -> [CGRect]

    /// "responds to state changes" → dim the ribbon, block edits, show progress.
    func writingToolsCoordinator(_ c: NSWritingToolsCoordinator,
                                 didChangeState state: WritingToolsState)

    /// We push these INTO the coordinator, which is the part that requires a
    /// real layout engine:
    ///   updateRange(_:withText:)      — when the user edits during a session
    ///   updateForReflowedText()       — when our paginator reflows. Writing Tools
    ///                                   then re-requests previews and mark coords.
}
```

`updateForReflowedText` is the detail that only a native engine can honour. In Word-terms:
when a rewrite changes the paragraph's height, our paginator reflows, possibly moving a page
break, and we tell Writing Tools so its proofreading marks land in the right place. A
DOM-based editor has no equivalent hook.

**Behaviour matrix:**

| Context | `writingToolsBehavior` |
|---|---|
| Document body | `.complete` |
| Find & Replace field | `.none` (exact text matters) |
| Field codes / `instrText` | `.none` |
| Math (OMML) linear form | `.none` |
| Comment body | `.complete` |
| Header/footer | `.complete` |
| Password / document-protection dialog | `.none` |

### 2.2 Foundation Models directly

```swift
// macOS 26 and 27 both:
let session = LanguageModelSession(
    model: SystemLanguageModel.default,          // AFM 3 Core, on device
    instructions: Instructions.writingAssistant
)

// macOS 27 adds the provider protocol — swap the model, keep everything else:
let session = LanguageModelSession(
    model: ClaudeForFoundationModels.ClaudeModel(.sonnet, auth: .proxied(headers:)),
    instructions: Instructions.writingAssistant
)
```

What we use it for, and what we deliberately don't:

| Task | Model | Why |
|---|---|---|
| Proofread (our own, distinct from Writing Tools) | AFM 3 Core, on device | Apple says the on-device model is optimised for summarisation, extraction and classification — **not** world knowledge or advanced reasoning. Proofreading fits. |
| Summarise selection / document | AFM 3 Core, chunked at 8k ctx | Context window is 8,192 tokens → we chunk by section and reduce. Map-reduce, on device. |
| Extract action items / entities / tags | AFM 3 Core + `@Generable` | Guided generation with constrained decoding gives type-safe output with no JSON parsing |
| Alt text for images | **AFM 3 Core Advanced** (multimodal, on device) + `VNGenerateImageCaptioningRequest` | Private, free, no upload |
| Reading level / tone classification | AFM 3 Core + content-tagging adapter | Apple ships a specialised adapter for exactly this |
| Long-form drafting, research, rewriting a whole chapter | **Cloud provider** (Claude/Gemini/OpenAI) or PCC | On-device is the wrong tool; escalate *with the user's permission and a visible indicator* |
| Agentic multi-step editing | Cloud provider or PCC, with tool calling | Needs reasoning |
| Code/math generation | **Not offered** | Apple explicitly warns the on-device model is unsuitable |

Availability must be checked and degraded gracefully:

```swift
switch SystemLanguageModel.default.availability {
case .available:                                 enable()
case .unavailable(.deviceNotEligible):           hideOnDeviceFeatures()   // Apple Silicon only
case .unavailable(.appleIntelligenceNotEnabled): showSetupHint()          // deep-link to System Settings
case .unavailable(.modelNotReady):               showProgress()           // model still downloading
@unknown default:                                hideOnDeviceFeatures()
}
```

Note that macOS 27 dropped Intel entirely, so `.deviceNotEligible` will mostly mean
"Apple Intelligence is off" or a region restriction.

### 2.3 App Intents → Siri, Shortcuts, Spotlight

WWDC26 added **App Schemas** (system-defined intent/entity schemas the on-device model
already understands), **View Annotations** (map views to entities for conversational
reference), and an **App Intents Testing framework**.

Intents we expose:

- `OpenDocumentIntent`, `CreateDocumentIntent(template:)`
- `SummariseDocumentIntent` → returns a summary entity + speaks/displays it
- `FindInDocumentIntent(query:)`
- `InsertTextIntent`, `ReplaceTextIntent`, `FormatSelectionIntent`
- `ExportDocumentIntent(format:)`
- `RunAssistantTaskIntent(task:)` — bridges Shortcuts to our whole Task taxonomy (§4)
- **Entity schemas** contributing documents and comments to the Spotlight **semantic index**,
  which WWDC26 wires into "LLM search using Core Spotlight" — meaning the *system's* assistant
  can reason over the user's documents with attribution back to us. That is a distribution
  channel, not just a feature.

### 2.4 Other Apple surfaces

- `NSSpellChecker` for spelling (system dictionaries, free, per-language, `NSGuessLanguage`
  detection) — this is *not* AI and should not be routed through a provider.
- `AVSpeechSynthesizer` for Read Aloud (better than Word's, native voices).
- `Vision` for OCR (PDF import, scanned images) — Apple's OCR is excellent and on-device.
  WWDC26 also exposes Vision OCR/barcode as **tools the model can call directly**.
- `Translation` framework for the selection/document translator — on-device for supported
  language pairs, and free.
- `NSCorrectionList` / autocorrection from the system for the AutoCorrect layer.

---

## 3. Our provider abstraction

We define our own protocol rather than binding to Apple's, for two reasons: we must support
macOS 26 (where Apple's `LanguageModel` protocol does not exist), and we need capability
metadata Apple's protocol does not carry (cost, privacy class, context window, structured-edit
support). On macOS 27 we **bridge** to Apple's protocol so third-party provider packages drop in.

```swift
public protocol AIProvider: Sendable {
    var id:            ProviderID          { get }   // "apple.ondevice", "anthropic.claude", …
    var displayName:   String              { get }
    var capabilities:  ProviderCapabilities{ get }
    var privacyClass:  PrivacyClass        { get }   // ← the important one
    func availability() async -> ProviderAvailability
    func stream(_ request: AIRequest) async throws -> AsyncThrowingStream<AIEvent, Error>
    func countTokens(_ text: String) async throws -> Int
}

public struct ProviderCapabilities: OptionSet, Sendable {
    public static let streaming        = …
    public static let toolCalling      = …
    public static let structuredOutput = …   // @Generable / JSON schema
    public static let multimodalImage  = …
    public static let longContext      = …   // > 8k
    public static let reasoning        = …
    public static let embeddings       = …
}

/// THE key type. Determines what the Router will ever send here.
public enum PrivacyClass: Int, Sendable, Comparable {
    case onDevice          // never leaves the Mac. AFM Core / Core Advanced, MLX, CoreAI,
                           // Ollama & LM Studio & llama-server on 127.0.0.1
    case applePCC          // leaves the Mac for Apple Silicon servers under a
                           // verifiable no-retention guarantee
    case thirdPartyCloud   // leaves the Mac for a vendor the user configured
    case selfHosted        // leaves the Mac for a URL the user configured
                           // (their own gateway, Tailscale, on-prem vLLM)
}

public struct AIRequest: Sendable {
    public var instructions: String
    public var messages:       [Message]
    public var tools:          [ToolSchema]
    public var outputSchema:   OutputSchema?     // constrained decoding / JSON schema
    public var budget:         TokenBudget
    public var provenance:     RequestProvenance // which UI surface, which Task,
                                                 // for logging & the privacy indicator
}

public enum AIEvent: Sendable {
    case textDelta(String)
    case snapshot(StructuredPartial)      // Apple's snapshot-streaming model
    case toolCall(ToolCall)
    case usage(TokenUsage)                // macOS 27: input/cached/reasoning breakdown
    case done(StopReason)
}
```

### Key management

- Secrets live in the **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
  never in `UserDefaults`, never in a config file, never in a crash report.
- Per-provider config (base URL, model name, temperature, max tokens, extra headers) lives in
  an app-support plist; secrets stay in Keychain and are referenced by identifier.
- `.proxied(headers:)`-style auth supported so a user can point at their own proxy that holds
  the key — no key in the app at all.
- A **"Reveal key" is never possible**; we show a fingerprint (last 4 chars + provider) only.
- **Local-network providers** (Ollama on `localhost:11434`, LM Studio, `llama-server`) get an
  explicit `PrivacyClass.onDevice` classification *only* when the host resolves to loopback;
  anything else is `selfHosted`. GenOffice shipped a bug exactly here (#1775: a missing or
  malformed `Host` header escaped their MCP loopback guard). We validate the resolved
  address, not the header.

### The Preferences → Intelligence pane

```
┌ Intelligence ──────────────────────────────────────────────────────────────┐
│                                                                             │
│  PRIVACY DEFAULT                                                            │
│  (●) Keep everything on this Mac                                            │
│      Only Apple's on-device model and local models you add are used.        │
│      Nothing leaves your computer, ever. Works offline.                     │
│  ( ) Allow Apple Private Cloud Compute                                      │
│      Escalate to Apple's servers when the on-device model can't cope.       │
│      Free for this app. Apple does not retain your text.                    │
│  ( ) Allow the cloud providers I've added                                   │
│      You choose per task below exactly what may be sent where.              │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │ ALWAYS ON THIS MAC — never leaves, regardless of the above         │    │
│  │   • Document content used for spelling & grammar                   │    │
│  │   • Alt text generation from your images                           │    │
│  │   • Anything inside a range you've marked Sensitive                │    │
│  │   • Anything in a document flagged "Private"                       │    │
│  └────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ROUTING                                                                    │
│   Proofread                [ Apple on-device          ▾ ]                    │
│   Summarise                [ Apple on-device          ▾ ]                    │
│   Rewrite / tone           [ Apple on-device          ▾ ]                    │
│   Draft long-form          [ Claude Sonnet            ▾ ]                    │
│   Research & citations     [ Claude Opus              ▾ ]                    │
│   Translate                [ Apple Translation fw     ▾ ]                    │
│   Agentic editing          [ Claude Sonnet            ▾ ]                    │
│   Autocomplete             [ Apple on-device          ▾ ]  (latency budget)  │
│                                                                             │
│  PROVIDERS                                                     [ + Add ]    │
│   ● Apple Intelligence     on device        AFM 3 Core Advanced   ready     │
│   ● Apple PCC              Apple servers    AFM 3 Cloud Pro       entitled  │
│   ● Claude                 anthropic.com    sonnet / opus / haiku  ✓ key    │
│   ○ OpenAI                 api.openai.com   —                     no key    │
│   ● Ollama                 127.0.0.1:11434  qwen3:32b             ✓ 6 models│
│   ○ Custom endpoint        —                —                     —         │
│                                                                             │
│  REDACTION                                                                  │
│   [✓] Scrub names, emails, phone numbers before any cloud request           │
│   [✓] Scrub text in ranges I marked Sensitive                               │
│   [ ] Show me exactly what will be sent before the first request            │
│                                                                             │
│  TRANSPARENCY                                                               │
│   [  Show request log…  ]   every request, its provider, tokens, duration.  │
│                             Stored locally. Never uploaded.                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Always-visible privacy indicator:** while a request is in flight, the Assistant button in
the ribbon shows a coloured dot — 🟢 on-device, 🟡 Apple PCC, 🔴 third-party cloud. Hovering
shows the provider and model. The same dot appears in the status bar. Users should never have
to wonder where their text went.

---

## 4. Task taxonomy

Everything the AI can do is a typed `Task`. This matters because it gives us: deterministic
prompt templates, per-task routing, per-task privacy policy, per-task evaluation, and a
Shortcuts/Siri bridge for free.

```swift
public enum AITask: Sendable {
    // --- transform a selection (returns a DocumentMutation) ---
    case proofread                       // grammar, spelling, punctuation — minimal edits
    case rewrite(tone: Tone)             // professional / friendly / concise / vivid …
    case shorten                         // preserve meaning, cut words
    case expand                          // add detail
    case changeReadingLevel(target: ReadingLevel)
    case changeTense(tense: Tense)
    case changePerson(person: Person)    // first / second / third
    case changeVoice(voice: Voice)       // active / passive
    case translate(to: Locale, keepFormatting: Bool)
    case convertToList
    case convertToTable
    case convertToProse
    case fixFormattingConsistency        // "make all the headings consistent"

    // --- analyse (returns structured data, not edits) ---
    case summarise(scope: Scope, length: SummaryLength)
    case extractActionItems
    case extractEntities
    case extractKeyDates
    case generateQuestions               // study aid
    case assessReadability
    case checkConsistency                // terminology, spelling variants, number formats
    case detectContradictions
    case citeClaimsNeedingSources

    // --- create (returns new blocks) ---
    case draft(topic: String, outline: [String]?, lengthHint: LengthHint, style: StyleID)
    case continueWriting                 // inline ghost, next sentence/paragraph
    case suggestOutline(from: Scope)
    case draftTableOfContentsAbstracts
    case generateAltText(image: ImageRef)
    case suggestCaptions

    // --- agentic (tool-calling loop over the whole document) ---
    case applyInstructions(natural: String)   // "make all H2s bold and add a summary
                                              //  under each one" → plans → tool calls
    case restructure(target: StructureGoal)
    case factCheckAgainst(sources: [SourceRef])
}

public enum Scope: Sendable {
    case selection
    case block(NodeID)
    case section(Int)
    case document
    case documentWithOutline      // cheap: headings + first sentences only
}
```

---

## 5. Structured edits — the thing that makes AI usable in a word processor

**Never return a text blob.** A blob cannot be reviewed, cannot be undone granularly, cannot
preserve formatting, and destroys tracked changes. GenOffice does block-granular snapshots
with diffs, which is better than most; we go further and use Word's own revision machinery.

```swift
/// The only shape an AI result may take when it wants to change the document.
public struct DocumentMutation: Sendable {
    public var operations: [MutationOp]
    public var rationale:  String?          // shown in the review pane
    public var provider:   ProviderID
    public var task:       AITask
    public var usage:      TokenUsage

    /// Applied as ONE undo unit, and — when Track Changes is on — as OOXML
    /// w:ins / w:del with author "Assistant (<provider>)".
    /// The user then accepts/rejects per operation in the Review pane,
    /// exactly like a human reviewer's edits. Word shows them too.
}

public enum MutationOp: Sendable {
    case replaceText(node: NodeID, range: NodeRange, with: [Run])
    case insertBlocks(after: NodeID, blocks: [Block])
    case deleteBlocks(ids: [NodeID])
    case moveBlocks(ids: [NodeID], after: NodeID)
    case setParagraphProperty(node: NodeID, key: ParagraphPropertyKey, value: PropertyValue)
    case setRunProperty(node: NodeID, range: NodeRange, key: RunPropertyKey, value: PropertyValue)
    case applyStyle(node: NodeID, styleID: StyleID)
    case insertComment(anchor: NodeRange, body: String, resolved: Bool)
    case insertFootnote(anchor: NodeRange, body: [Block])
    case setAltText(image: NodeID, text: String)
    // deliberately NO "replaceWholeDocument" — an agent that wants that must
    // decompose into block ops so every change is individually reviewable.
}
```

### The agentic loop

```
User: "Turn the methodology section into numbered steps and add a summary at the top."
   │
   ▼
Router → task .applyInstructions → policy says agentic ⇒ cloud provider (user-approved)
   │
   ▼
DocumentContext built: outline of the whole doc + full text of the Methodology section
   (NOT the whole document — token budget + privacy minimisation)
   │
   ▼
Tool-calling loop, max N iterations, each tool call validated against the model:
     get_document_outline()
     get_section(id)
     get_blocks(sectionID)
     get_block(nodeID)
     get_style(styleID)
     list_styles(filter)
     search(query, scope)
     propose_mutation([MutationOp])      ← always a *proposal*
     explain_change(opIndex, text)
   │
   ▼
MutationPlanner validates every proposed op:
     · NodeID exists?
     · range inside the node?
     · property key/value legal for this OOXML element?
     · style ID present in the style table?
     · would this break a field, a bookmark, a comment anchor, or a table grid?
     · does it exceed the user's approved blast radius?
   invalid op ⇒ rejected with a reason fed back to the model (bounded retries)
   │
   ▼
Preview UI: side-by-side or inline diff, per-operation accept/reject,
   "Accept all", "Reject all", "Show what the model said and why"
   │
   ▼
Apply as ONE undo unit, as tracked changes if Track Changes is on
```

**Guardrails worth naming:**
- Prompt-injection resistance: document text is always *data*, never instructions. The
  instruction channel is separate and the model is trained to prefer instructions over prompt
  content (Apple's design), but we additionally wrap document content in explicit delimiters
  and refuse tool calls that originate from quoted document text.
- Blast-radius limit: a single `applyInstructions` may touch at most K blocks (default 50)
  without asking. Beyond that we stop and ask.
- Every tool call and its arguments are logged locally and shown in the request log.
- A **dry-run mode** that shows the plan without applying it.

---

## 6. Redaction — how we honour "keep it on the Mac" honestly

If the user allows any cloud provider, we minimise what goes:

1. **Scope minimisation** — send the smallest context the task needs (selection → block →
   section → outline → document), never the whole document by default.
2. **Range protection** — the user can select text and mark it *Sensitive* (a character
   property we store in our custom XML part). Sensitive ranges are replaced with typed
   placeholders (`⟦NAME:1⟧`, `⟦EMAIL:2⟧`) before serialisation and restored on the way back.
   The restore map never leaves the Mac.
3. **Automatic PII scrubbing** (opt-in, on by default for cloud): `NSDataDetector` for dates,
   addresses, phone numbers, links; plus on-device NER via the AFM content-tagging adapter for
   person/organisation names. Substituted, restored on return.
4. **Document-level "Private" flag** — forces `PrivacyClass.onDevice` for that document
   regardless of global settings.
5. **Hard floor** — some tasks *never* go to the cloud: spelling/grammar (system), alt text
   (Vision + on-device multimodal), anything in a protected document.
6. **Pre-flight disclosure** — a toggle to show exactly what will be sent before the first
   request of each kind.

---

## 7. Evaluation

AI features rot silently. We test them:

- **Golden task suite**: `Tests/IntelligenceKit/Evaluation/` — a fixture document plus a set
  of `(Task, expected-property)` assertions. Not "does the text match" (it never will) but
  *structural* invariants: proofreading changes ≤ N characters, summary ≤ 30 % of source
  length, `MutationOp`s validate, reading-level target within ±1 grade, no operations outside
  the requested scope.
- On macOS 27, adopt Apple's **Evaluations framework** (WWDC26 sessions 298/299/335) for the
  agentic paths — it is designed for exactly the "did the agent behave correctly across
  dynamic conditions" question that unit tests miss.
- A CI job runs the suite against a **deterministic local provider** (a stub) so the harness
  itself is tested without spending tokens, plus a nightly job against real providers.
- Regression detection: GenOffice #1819 ("generation significantly more stupid after v0.11.0")
  is what happens without this.

---

## 8. What we are NOT building

| Tempting idea | Why not |
|---|---|
| Our own credit/billing system | The #1 complaint about GenOffice. No account, no credits, no metering. The user pays their provider directly. |
| A server in the middle | No. App → provider, direct. Nothing to breach, nothing to subpoena, nothing to shut down. |
| Training on user documents | Never. No telemetry, no logging of content, no opt-in that could be flipped later. |
| Reproducing Apple's Writing Tools adapters | Can't — the LoRA adapters aren't exposed. We *integrate* Writing Tools instead and get them for free. |
| Code generation / math solving via the on-device model | Apple explicitly warns against it. Route to a cloud model with a visible 🔴 indicator, or don't offer it. |
| An always-on background agent | Too dangerous, too expensive, too surprising. The agent only runs when invoked, and shows its plan. |
