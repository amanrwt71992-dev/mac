# Open Questions — decisions needed before code

Grouped by how much they block. **A** blocks the first commit, **B** blocks M1, **C** blocks
M3, **D** can wait.

---

## A. Blocks the first commit

### A1. Product name
Shortlist and evidence in `06-LEGAL-AND-IP.md` §1. Recommendation: **Galley** (runner-up
**Incipit**). `Quire` is rejected — Getty holds `Quire™` for an open-source publishing tool.

Needed because it determines: GitHub org, repo name, bundle identifier, our own UTI,
domain, App Store listing. Changing it later is cheap in code and expensive in identity.

### A2. Repository strategy
The current repo is `amanrwt71992-dev/mac` — private, one commit, no licence, name says
nothing about the product.

| Option | Pros | Cons |
|---|---|---|
| **Keep `amanrwt71992-dev/mac`** | zero friction now | name is meaningless; personal namespace, not a project; awkward to hand to contributors later |
| **New repo in a new org** (`<name>/<name>`) | reserves the org, clean identity, can stay private until ready | one-time setup |
| **New repo under the personal account** with a real name | middle ground | still personal-namespace |

Recommendation: create the org + repo **as soon as the name is picked**, keep it **private**
until M1 is demoable, and migrate this branch across. Nothing is announced either way.

### A3. Licence
See `06-LEGAL-AND-IP.md` §2. Recommendation: **Apache-2.0** for the engine packages
(patent grant matters given the OOXML question), decide separately for the app. Must be
chosen before anything goes public.

### A4. Distribution channel
**Mac App Store (sandboxed)** vs **Developer-ID direct download** vs **both**.

This matters earlier than it looks: it determines the sandbox entitlements, whether we can
load local model files from arbitrary paths, whether we can offer a scripting host, and —
critically — whether we can claim the **free Private Cloud Compute tier** (requires App Store
Small Business Program enrolment *and* fewer than 2 M cumulative first-time downloads).

Recommendation: **build sandboxed from day one**, ship MAS as primary, and produce a
Developer-ID `.dmg` as a secondary build with a relaxed entitlement set for power users who
want local models in arbitrary directories. Retrofitting sandbox compliance is far worse
than starting with it.

### A5. Minimum macOS version
| Floor | What we gain | What we lose |
|---|---|---|
| **macOS 27 Golden Gate** (2026-09-14) | Apple's `LanguageModel` protocol → drop-in Claude/Gemini/MLX provider packages; AFM 3 (incl. the 20 B multimodal on-device model); Dynamic Profiles; Evaluations framework; `/usr/bin/fm`; App Schemas | Excludes everyone still on Tahoe. macOS 27 is Apple-Silicon-only anyway. |
| **macOS 26 Tahoe** (Sept 2025) | One extra year of users; Foundation Models v1 + Writing Tools coordinator both exist | We must hand-write provider adapters for 26 and `#available`-gate everything for 27. Roughly +2 weeks of work, permanent maintenance cost. |
| **macOS 15 Sequoia** | Maximum reach | No Foundation Models at all on 15 → the entire AI thesis needs a bespoke stack, and Writing Tools coordinator APIs don't exist. **Not recommended.** |

Recommendation: **macOS 26 floor, macOS 27 optimised.** The on-device model and the Writing
Tools coordinator both exist on 26, so the core promise holds; the 27-only provider protocol
is a genuinely nice-to-have that we gate. If the user is happy to require 27, the work gets
simpler and better.

---

## B. Blocks M1 (DOCX round trip)

### B1. Fidelity target — how honest do we want to be?
This is the most important product decision in the project and it is not technical.

| Posture | Meaning | Precedent |
|---|---|---|
| **"Best-in-class round trip"** | We never *break* a document (byte-preserving save, unknown elements preserved verbatim), and we render the 90 % of documents people actually have *well*. We publish the known limitations. | GenOffice, OnlyOffice |
| **"Pixel-identical to Word"** | We chase Word's layout exactly, including its bugs, `w:compat` flags, and undocumented table algorithm. | 20 years of LibreOffice effort, still not there |
| **"Our own renderer, faithful model"** | We get the *content and structure* perfectly right and accept that pagination may differ by a line here and there. | Pages |

Recommendation: **Posture 1 + Posture 3's honesty.** Never break a file (testable, and we
make CI enforce it); render as accurately as we can; publish a living fidelity matrix per
feature so users know exactly what is supported. Chasing pixel-identity is how office-suite
projects die.

### B2. What is our native format?
`.docx`-native (recommended) vs our own format with `.docx` import/export.
See `01-RESEARCH.md` §4 → "Our own file format". `.docx`-native avoids the "which file is
the real one" problem and means every save is an interop test.

### B3. Real-world fixture corpus
We cannot run Word in this sandbox. Fidelity work needs real documents, and the person who
has them is the user. Needed: 10–30 representative `.docx` files the user actually works
with (contract, CV, report, paper, newsletter, something with tables, something with tracked
changes, something non-English, something with images). ⚖️ Must be the user's own or cleared
before they go into a repo.

### B4. Non-English priority
Which languages/scripts must be right in v1.0? This changes the layout engine's workload
materially: RTL (Arabic/Hebrew) bidi, Indic complex shaping and matra reordering, CJK kinsoku
line breaking and character grid (`w:docGrid`), Thai/Lao word breaking (no spaces), Japanese
ruby/phonetic guides. **GenOffice has no RTL at all** — shipping RTL properly is a visible
differentiator. Recommendation: RTL + CJK in v1.0; Indic in v1.x.

---

## C. Blocks M3 (AI)

### C1. Which providers ship in v1.0?
Recommendation: Apple on-device, Apple PCC, Claude (via Anthropic's own package), OpenAI,
Gemini, and **any OpenAI-compatible base URL** (which single-handedly covers Ollama,
LM Studio, vLLM, llama-server, Together, Groq, OpenRouter, DeepInfra, and corporate
gateways). Plus MLX local. That is broad coverage for modest work, because most of them are
one adapter.

### C2. Is there ever an "our cloud" option?
Recommendation: **no.** It is the single most-criticised thing about GenOffice (their
most-discussed issue is literally "Other AI integration?", followed by a request for
"user-owned AI configuration: custom model endpoint, proxy, agent rules/skills"). Staying
server-less is both a moral position and a competitive one.

### C3. Default privacy posture
Recommendation: **"Keep everything on this Mac" is the factory default**, with cloud
providers opt-in and per-task routed. This is the honest reading of the user's requirement
("so that things remain within Mac").

### C4. Does the AI ever edit without asking?
Recommendation: **never.** Every AI change is a proposal, rendered as a tracked change,
individually acceptable. Autocomplete/ghost text is the only exception and it requires an
explicit keystroke to accept.

### C5. Monetisation
Free / one-time purchase / subscription / free-with-paid-AI? Independent of the architecture,
but it affects whether we build a licence system in M0. Recommendation: decide before M3;
the app can be paid while the AI stays entirely BYOK (no metering, no credits, no account).

---

## D. Can wait

- **D1. Icon & brand design.** Needs a designer; SF Symbols-derived is a fine placeholder.
- **D2. Localisation plan.** Which UI languages at launch.
- **D3. Scripting host.** JS/Lua vs AppleScript-only. Nisus ships Perl + its own macro
  language; Mellel ships its own. VBA is impossible for us. Decide at M5/M6.
- **D4. Citations strategy.** CSL (open, ~12,000 styles) vs cloning Word's undocumented
  bibliography engine. Recommendation: CSL — a superset, and genuinely open.
- **D5. Crash reporting.** Opt-in only, no content, ever.
- **D6. Team & cadence.** Solo or small team; weekly or per-milestone releases.
- **D7. Public communication.** Blog / changelog / X account. Only after the name is cleared.

---

## Summary of recommendations (the short version)

| # | Question | Recommendation |
|---|---|---|
| A1 | Name | **Galley** (runner-up Incipit); never Quire |
| A2 | Repo | New private org repo once named; keep this branch as the working branch meanwhile |
| A3 | Licence | Apache-2.0 for engine packages |
| A4 | Distribution | Sandboxed from day one; MAS primary + Developer-ID `.dmg` secondary |
| A5 | Min macOS | **macOS 26** floor, macOS 27 optimised (or 27-only if we want it simpler) |
| B1 | Fidelity | Never break a file (CI-enforced); render as accurately as we can; publish a fidelity matrix |
| B2 | Native format | `.docx` |
| B3 | Fixtures | Need 10–30 real documents from the user |
| B4 | Languages | RTL + CJK in v1.0; Indic in v1.x |
| C1 | Providers | Apple on-device, Apple PCC, Claude, OpenAI, Gemini, any OpenAI-compatible URL, MLX |
| C2 | Our cloud | Never |
| C3 | Default privacy | "Keep everything on this Mac" |
| C4 | AI autonomy | Never edits without asking; everything is a tracked change |
| C5 | Monetisation | Decide before M3; paid app + BYOK AI is clean |
