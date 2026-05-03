# Meeting-Summary Skill Pack — Integration Plan

**Source:** [`meeting-summary.zip`](../meeting-summary.zip) — modular skill with 1 parent (`SKILL.md`) + 4 shared extractors + 8 type-specific modules (client-discovery, architectural-review, scrum-standup, development-session, exploration, retrospective, one-on-one, user-interview).

**Goal:** ship two capabilities into SolWhisper:
1. **Auto-recognize** the meeting type from the transcript at summary time.
2. **Manually select** a sub-skill (override or pre-set) for a specific meeting — at record time AND at re-summarize time.

This plan covers what changes in code, what ships when, and what gets deferred.

---

## What's different from today

Today, SolWhisper skills are flat JSON with a single `promptTemplate` string. One prompt → one LLM call → one summary. Built-ins live in `Resources/Skills/*.json`; user skills live in `~/Library/Application Support/SolWhisper/Skills/`.

The new skill pack is:
- **Hierarchical**: parent + shared modules + per-type modules.
- **Markdown-based** with YAML frontmatter (Claude-Skills convention).
- **Conditional**: parent says "if discovery, append types/client-discovery.md to the prompt".
- **Self-classifying**: parent has explicit logic for picking a type from the transcript.
- **Multi-file in a folder**, not a single file.

To honor the structure and not lose its design, SolWhisper needs a **Skill Pack** concept on top of the existing flat-Skill model.

---

## Architecture

### Two-layer model

```
Skill           // existing — flat, single prompt
SkillPack       // new — bundle of (parent + shared + types[])
```

A `SkillPack` is a Skill that knows how to **resolve** itself given a `meetingType`:

```swift
struct SkillPack {
    let id: String                       // "meeting-summary"
    let name: String                     // "Meeting Summary"
    let description: String
    let parent: SkillModule              // SKILL.md
    let shared: [SkillModule]            // shared/*.md
    let types: [String: SkillModule]     // "client-discovery" → types/client-discovery.md
    let isBuiltIn: Bool

    /// Concatenates parent + all shared + the picked type into one prompt.
    func render(meetingType: String?, transcript: String, participants: [String]) -> String
}

struct SkillModule {
    let frontmatter: [String: String]    // YAML frontmatter parsed from the .md file
    let body: String
}
```

A `SkillModule` is just `(frontmatter, body)`. The parent's frontmatter has `name` + `description` (used in the picker UI). Each type module has its own `name` + `description` — those become the meeting-type picker's options.

### Where Skill Packs live on disk

```
Resources/SkillPacks/                                   # built-ins
  meeting-summary/
    SKILL.md
    README.md
    shared/...
    types/...

~/Library/Application Support/SolWhisper/SkillPacks/    # user packs
  <pack-id>/...
```

Packs are folders, not zip files (zip is just the transport format the user shipped). Installation step: unzip into one of those locations; reload the registry.

### Coexistence with flat Skills

- The existing flat-JSON skills (`Resources/Skills/*.json`) keep working — they're loaded as before.
- `SkillsRegistry` exposes both flat skills and packs; the picker in Settings → Skills lists both with a small badge distinguishing them.
- For a skill pack, the picker shows `Pack name → meeting type` as a two-level submenu (e.g. `Meeting Summary → Client Discovery`).

---

## Execution model

For the LLM call, two viable patterns. Pick **A for alpha.5** (ship fast), **B for v0.5** (real auto-classify):

### A. Single mega-prompt (alpha.5)

Concatenate everything into one system prompt:

```
[parent SKILL.md body]
---
[shared/attribution.md]
[shared/action-items.md]
[shared/decisions.md]
[shared/core-output.md]
---
[types/<picked-type>.md]
---
Transcript:
<transcript>...</transcript>
Participants: ...
```

One LLM call. Works with any LLM via `LLMResolver`. Token-heavy (~5–8k tokens of skill content + the transcript) — fine for cloud models, may strain small Ollama models.

This is what we ship in alpha.5. Type comes from explicit user selection (manual override or set-at-record-time). If type is missing, we send the entire pack and let the LLM follow Step 1 of the parent skill ("classify from transcript") — works but slow.

### B. Two-pass: classify then extract (v0.5)

**Pass 1** — short prompt with just the routing table from `SKILL.md`. Returns JSON: `{type: "client-discovery", confidence: 0.78}`. Uses a cheap fast model (Haiku, llama-3.1-8b-instant, etc.) — separately routable.

**Pass 2** — full mega-prompt as in (A), but with the type pre-selected so we only include `types/<that-one>.md` instead of all 8.

Token + latency win on Pass 2. Pass 1 is ~$0.001 per meeting on Haiku. Net cheaper than (A) for any meeting longer than ~5 minutes.

Defer to v0.5 because it requires:
- a separate "classifier model" routing key,
- LLM-agnostic structured-output handling (some models don't reliably emit JSON),
- a confidence threshold + fallback to user-prompt path.

### C. Heuristic-only auto-classify (fallback)

Keyword matching on the transcript. Cheap, no LLM. Brittle for hybrid meetings, but a useful **fallback when no LLM is configured**. Implement as a sidecar:

```swift
enum MeetingTypeClassifier {
    static func heuristic(transcript: String) -> (type: String, confidence: Double)?
}
```

Rules:
- Standup: ≥3 occurrences of "yesterday", "today", "blockers" within 5 min of transcript start
- Discovery: high question-mark density from one speaker
- Architectural review: "tradeoff", "ADR", "options", "should we"
- One-on-one: exactly 2 distinct speakers
- ...etc.

Use heuristics as a low-confidence tie-breaker even when LLM classification runs.

---

## UX changes

### 1. Meeting-type picker in Settings → Skills

Today: a flat list of skills. Selecting "Meeting Summary" sets the default for new meetings.

Change: when "Meeting Summary" is selected (it's a pack, not a flat skill), show a secondary picker — **Default sub-type for new meetings**: `Auto-detect | Client discovery | Architectural review | …`. Defaults to `Auto-detect`.

### 2. Meeting-type picker at record time (optional)

In the meeting start flow (currently: tray menu → Record meeting → privacy disclaimer → start). Add an optional pre-meeting sheet:

```
┌─────────────────────────────────────────────┐
│ What kind of meeting is this? (optional)    │
│                                              │
│ ◉ Auto-detect from transcript               │
│ ○ Client discovery                          │
│ ○ Architectural review                      │
│ ○ Scrum standup                             │
│ ○ ... (8 options)                           │
│                                              │
│ [Skip]                          [Continue]  │
└─────────────────────────────────────────────┘
```

Skipping is fine — auto-detect runs at summary time. The setting is per-meeting, stored on the `Meeting` model as `meetingType: String?`. Pass-through to `SummaryGenerator.generate(meeting:segments:skill:type:)`.

This sheet is **opt-out** via `Settings → STT Meetings → Ask for meeting type at record start` (default ON; users who always do the same kind of meeting will turn it off).

### 3. Re-summarize with a different type (Transcripts window)

In the meeting detail view (`MeetingDetailView.swift`), replace the single "Summarize" button with a split control: button + dropdown chevron. The dropdown lists `Auto-detect` and the 8 sub-types. Picking one re-runs the summary with that type pinned.

### 4. Display picked type in the summary header

The output template already includes `Type:` in the metadata block. The detail view should surface it prominently so users can see "this was summarized as a client-discovery meeting" and decide whether to re-run.

---

## Data model changes

### `Meeting` (in `Storage/Models/Meeting.swift`)

Add one optional field:

```swift
var meetingType: String?    // "client-discovery", "auto", or nil (= use default)
```

`SchemaMigration` already handles missing fields → no migration needed.

### `Summary` (in `Storage/Models/Summary.swift`)

The pack writes a `Type:` line in the markdown header. Also persist the resolved type in the JSON sidecar:

```swift
struct Summary {
    // ... existing fields
    var meetingType: String?            // "client-discovery", etc.
    var classificationSource: String?   // "user-set" | "auto-llm" | "auto-heuristic"
    var classificationConfidence: Double?
}
```

This lets the UI distinguish "user said this is a standup" vs "we guessed it's a standup with 0.62 confidence".

### `SkillsRegistry` extensions

```swift
@Published private(set) var skills: [Skill] = []           // existing
@Published private(set) var skillPacks: [SkillPack] = []   // new
```

Loader walks `Resources/SkillPacks/*` and `~/Library/.../SkillPacks/*`, reading each subfolder as a pack. Failure to parse a pack is a logged error, not a crash; the rest of the registry stays usable.

---

## Code map

New files:
- `Sources/PostProcessing/SkillPack.swift` — data model, frontmatter parser, render method
- `Sources/PostProcessing/SkillPackLoader.swift` — folder walker + Markdown reader
- `Sources/PostProcessing/MeetingTypeClassifier.swift` — heuristic + LLM-classify
- `Sources/Settings/SkillPackInstallerSheet.swift` — drag-drop / pick-a-zip UI
- `Sources/Onboarding/MeetingTypePickerSheet.swift` — pre-meeting sheet (Phase 2)

Modified files:
- `Sources/PostProcessing/SkillsRegistry.swift` — add packs alongside flat skills
- `Sources/PostProcessing/SummaryGenerator.swift` — accept `meetingType` parameter
- `Sources/Storage/Models/Meeting.swift` — add `meetingType` field
- `Sources/Storage/Models/Summary.swift` — add classification metadata
- `Sources/Settings/SkillsSettingsView.swift` — show packs with sub-type sub-pickers
- `Sources/Settings/MeetingSettingsView.swift` — "Ask for meeting type at start" toggle
- `Sources/Transcripts/MeetingDetailView.swift` — split summarize button + type display
- `Sources/Meeting/MeetingController.swift` — read `Meeting.meetingType` and pass through

Resources:
- Unzip `meeting-summary.zip` into `Resources/SkillPacks/meeting-summary/`
- Add `Resources/SkillPacks/.gitkeep` so xcodegen picks up the directory

---

## Phasing

### v0.4-alpha.5 — minimum viable (ships in days)

- [ ] `SkillPack` model + loader (`SkillPackLoader`)
- [ ] Bundle `meeting-summary` pack as a built-in (unzipped under `Resources/SkillPacks/`)
- [ ] `SummaryGenerator` accepts `meetingType` parameter; concatenates parent + shared + chosen type into one mega-prompt (execution model A)
- [ ] Manual type picker on `MeetingDetailView` summarize button (8 options + Auto)
- [ ] If type is `Auto`, send the full pack and rely on the parent skill's Step 1 to classify in-prompt
- [ ] Settings → Skills: when a pack is selected, show a secondary "Default sub-type" picker
- [ ] Persist `meetingType` on Meeting + Summary
- [ ] Display picked type in the summary header

**Skipped in alpha.5:** record-time picker, two-pass auto-classify, heuristic classifier, drag-drop installer (manual unzip into the user folder is fine for early testers).

### v0.5 — real auto-classify + UX polish

- [ ] Two-pass classifier: Pass 1 hits a fast model with the routing table, returns `{type, confidence}`; Pass 2 runs full extraction with type pinned
- [ ] Heuristic classifier as fallback when no LLM is configured
- [ ] Pre-meeting "What kind of meeting?" sheet (toggleable in settings)
- [ ] Drag-drop `.zip` installer for new skill packs (Settings → Skills → Install pack)
- [ ] Per-pack `defaultLLMModel` override — the meeting-summary pack works best with Sonnet-class models; surface that in the pack's frontmatter
- [ ] User-editable packs (export to ~/Library, edit, reload)

### v0.6 — composable extractors

The pack's README explicitly calls out that "the same extractors (action items, decisions, risks) repeat across many sub-skills" and suggests refactoring toward composable extractors. That's a v0.6 architectural revisit — separate plan.

---

## Open questions for you

1. **Built-in vs user-installed?** I'm assuming we ship `meeting-summary` as a built-in (in the bundle, read-only). Alternative: ship it as a default-installed user pack so you can edit it freely. Built-in is safer for v0.5 GA; user pack is more flexible for power users.

2. **Drop the existing flat built-ins?** The current flat skills (`sales-call.json`, `standup.json`, `interview.json`, `one-on-one.json`, `brainstorm.json`) overlap heavily with the new pack's types. Options:
   - (a) Keep both — pack is opt-in, old skills stay for users who like them
   - (b) Replace — delete the flat built-ins; new pack is the canonical "summary" path
   - (c) Migrate — old skills auto-route into the pack's matching type
   I lean toward (b) for cleanness, but (a) is the safest GA move.

3. **Auto-detect at summary time vs at record time?** Both are useful, but if forced to pick one for v0.4-alpha.5, I'd go with **summary-time auto-detect** because it's simpler (no UI change at record start) and the meeting-summary pack's parent skill is built to do classification in-prompt. Record-time is a v0.5 UX add.

4. **Token cost for option A in alpha.5?** The pack is ~5–8k tokens of skill content. For a 30-minute meeting (~10k tokens of transcript), that's ~18k tokens input. ~$0.05/meeting on Sonnet, ~$0.01 on Haiku. Cheap, but worth knowing before we wire it.

---

## Acceptance criteria

For alpha.5 to ship this:

- [ ] Bundle the unzipped meeting-summary pack
- [ ] `SkillPack` model + loader, with one passing unit test (parses parent + 8 types)
- [ ] `MeetingDetailView` summarize button shows a type-picker dropdown with 9 options (Auto + 8 types)
- [ ] Picking a type re-runs the summary against that pack-resolved prompt
- [ ] `Auto` works (LLM classifies via the parent skill's Step 1)
- [ ] The summary header shows the resolved type
- [ ] No regressions to the existing flat-skill path (sales-call, standup, etc. still work)
- [ ] Test protocol updated with a Sprint 11 section walking through all 8 types
