# SolWhisper — Meeting Features Development Plan

**Author:** drafted with Claude, 2026-05-02 · revised 2026-05-03 after design review
**Target version:** v0.4.0
**Scope:** Add file-import transcription (B), meeting recording (C), summary skills, OpenRouter+Ollama LLM picker, Hermes/Obsidian/webhook integrations, plus the infra hardening that survived the cut. Mode A (records prompt) stays untouched.
**Stack assumptions** *(verified against current source)*:
- macOS 13+ deployment target (Xcode 15, Swift 5.9)
- **App is NOT sandboxed** — entitlements present but no `com.apple.security.app-sandbox`. Big win: ScreenCaptureKit + Core Audio access without temporary exceptions.
- Sparkle for auto-update (already wired)
- XcodeGen project file (`project.yml` is the source of truth)
- Existing entitlements: `audio-input`, `apple-events`, `network.client`. **Adds needed:** `NSScreenCaptureUsageDescription` and `com.apple.security.files.user-selected.read-only`.

---

## 0. The five-second summary

You're adding ~25 new focused Swift files (~7-9k LOC) without modifying the dictation hot path. The code that handles "press hotkey → dictate" doesn't get touched. New code lives in new directories.

**Ship in 9 sprints.** Sprint 0 (new) gets notarization out of the way so testers stop paying the TCC tax on every interim build. Sprint 4 is split into 4a (core recording) and 4b (quality polish). Silero VAD, 6-provider LLM matrix, custom skill fields, and chunked summarization are all cut from v0.4. Estimated calendar: **5-7 weeks part-time with Claude Code as engineering force-multiplier.**

### Cuts from the original plan (deferred to v0.5+)

| Cut | Reason |
|---|---|
| Silero VAD pre-filter | Meetings transcribe AFTER stop, not real-time; Whisper has internal VAD; CoreML conversion is fragile |
| 6 LLM providers (kept OpenRouter + Ollama only) | OpenRouter already wraps Anthropic/OpenAI/Groq/Mistral; 5 redundant API key flows |
| Custom skill fields (declared form fields per skill) | Friction at use-time; built-in skills cover 99%; ship free-form prompts only |
| Chunked summarization | Claude Sonnet 200k handles ~12hr meetings in one shot |
| Search index across transcripts | Use Obsidian for cross-meeting search; in-app search stays simple per-meeting |

---

## 1. Architecture: what's added, what stays

### Directory tree after the work

```
Sources/
├── App/                                    # ↻ small additions (tray menu items)
│   ├── AppDelegate.swift                   # ↻ extend status menu + add new windows
│   └── main.swift
├── Audio/
│   └── AudioEngine.swift                   # ✓ unchanged — mode A keeps using it
├── Transcription/
│   ├── AppleSpeechClient.swift             # ✓ unchanged
│   ├── DeepgramClient.swift                # ✓ unchanged
│   ├── TranscriptionController.swift       # ↻ add WhisperKit case
│   └── WhisperKitClient.swift              # ✚ NEW — Sprint 1
├── Overlay/
│   ├── OverlayWindowController.swift       # ✓ reused for meeting mode
│   └── RecordingOverlayView.swift          # ↻ small variant for meeting state
├── HotKey/, Paste/                         # ✓ all unchanged
├── LLM/
│   ├── OpenRouterClient.swift              # ✓ existing, extended with new models
│   ├── LLMClient.swift                     # ✚ NEW protocol — Sprint 5
│   └── OllamaClient.swift                  # ✚ NEW — Sprint 5 (local LLM)
├── Settings/
│   ├── SettingsView.swift                  # ↻ add 4 new sections
│   ├── MeetingSettingsView.swift           # ✚ NEW
│   ├── SkillsSettingsView.swift            # ✚ NEW
│   ├── LLMSettingsView.swift               # ✚ NEW (OpenRouter + Ollama only)
│   └── IntegrationsSettingsView.swift      # ✚ NEW
├── Meeting/                                # ✚ NEW directory — Sprints 4a/4b
│   ├── MeetingController.swift             # orchestrator (single-instance, NOT singleton)
│   ├── MeetingAudioEngine.swift            # standalone, NO AudioEngine reuse
│   ├── SystemAudioCapture.swift            # ScreenCaptureKit tap
│   ├── ChunkWriter.swift                   # 30s-window disk chunks
│   ├── CrashRecovery.swift                 # orphan chunk scanning
│   ├── DeviceMonitor.swift                 # BT + USB hot-swap detection (Sprint 4b)
│   ├── AudioMixer.swift                    # RMS-based ducking (Sprint 4b)
│   ├── ClippingDetector.swift              # peak meter (Sprint 4b)
│   └── ConcurrencyDesign.md                # ✚ design doc — Sprint 0
├── Import/                                 # ✚ NEW directory — Sprint 2
│   ├── FileImportController.swift
│   └── FileTranscriber.swift               # non-streaming, WhisperKit
├── Storage/                                # ✚ NEW directory — Sprint 3
│   ├── MeetingStore.swift                  # file-backed CRUD, NO singleton
│   ├── SchemaMigration.swift               # schemaVersion + migration table
│   ├── Models/Meeting.swift
│   ├── Models/TranscriptSegment.swift
│   └── Models/Summary.swift
├── PostProcessing/                         # ✚ NEW directory — Sprint 5
│   ├── CleanupPass.swift                   # LLM filler removal
│   ├── SkillsRegistry.swift                # built-in + user skills (free-form prompts)
│   ├── SummaryGenerator.swift
│   └── SpeakerLabeler.swift                # Me/Other channel tagging
├── Integrations/                           # ✚ NEW directory — Sprint 6
│   ├── OutboundWebhook.swift               # generic POST + HMAC
│   ├── HermesIntegration.swift             # preset wired to your VPS
│   └── ObsidianIntegration.swift           # writes markdown to vault
├── Tray/                                   # ✚ NEW directory — Sprint 1 stub, finalized in 7
│   └── TrayMenuController.swift            # consolidates AppDelegate menu
└── Transcripts/                            # ✚ NEW directory — Sprint 3
    ├── TranscriptsWindow.swift             # window controller
    ├── TranscriptsRootView.swift           # split layout
    ├── MeetingListView.swift               # sidebar list (no fuzzy search index)
    ├── MeetingDetailView.swift             # right panel
    ├── DetailHeaderToolbar.swift           # cleanup/summarize/skill/LLM/delete
    └── SkillPickerSheet.swift              # popover from "Settings" button
```

### What stays exactly the same (zero edits)

- `AudioEngine.swift` — your existing mic capture, AGC, FFT, level metering
- `AppleSpeechClient.swift`, `DeepgramClient.swift`
- `HotkeyManager.swift`, `PasteManager.swift`, `OnboardingView.swift`, `DebugLog.swift`
- `OpenRouterClient.swift` (extended with model list, but interface stays)
- The pill UI behavior for mode A
- `project.yml` structure — only adds package deps (`WhisperKit`)

This means **breaking mode A is impossible** unless you actively go edit those files.

### Component dependency diagram

```
                    ┌──────────────┐
                    │ TrayMenu     │ ← new entry points: Upload, Record Meeting, Transcripts
                    └──┬───────────┘
                       │
        ┌──────────────┴───────────────────┐
        ▼                                  ▼
┌──────────────────┐                ┌──────────────────┐
│  FileImport      │                │  MeetingRecord   │
│  Controller      │                │  Controller      │
└──┬───────────────┘                └──┬───────────────┘
   │                                   │
   │           ┌───────────────────────┴──────┐
   │           │     MeetingAudioEngine        │  ← NEW, standalone
   │           │  ┌────────────┐ ┌──────────┐  │
   │           │  │ Mic        │ │ System   │  │
   │           │  │ (Core      │ │ Audio    │  │
   │           │  │  Audio)    │ │ (SCKit)  │  │
   │           │  └─────┬──────┘ └────┬─────┘  │
   │           │        ▼            ▼         │
   │           │   ┌───────────────────┐       │
   │           │   │  AudioMixer +     │ 4b    │
   │           │   │  RMS ducking      │       │
   │           │   └─────────┬─────────┘       │
   │           │             ▼                 │
   │           │   ┌───────────────────┐       │
   │           │   │  ChunkWriter      │ 4a    │
   │           │   │  (30s disk chunks)│       │
   │           │   └─────────┬─────────┘       │
   │           └─────────────┼─────────────────┘
   │                         ▼
   │                ┌─────────────────────┐
   └───────────────►│ FileTranscriber     │
                    │  (WhisperKit)       │
                    └──────────┬──────────┘
                               ▼
                    ┌─────────────────────┐
                    │  PostProcessing      │
                    │  ─ SpeakerLabeler    │
                    │  ─ CleanupPass       │
                    │  ─ SummaryGenerator  │
                    └──────────┬──────────┘
                               ▼
              ┌───────────────────────────────┐
              │    MeetingStore (file-based)   │
              └─┬──────────────────────────┬───┘
                ▼                          ▼
        ┌─────────────────┐      ┌─────────────────┐
        │ Transcripts UI  │      │ Integrations    │
        │ (browse, edit)  │      │ (Hermes/Obsidian│
        │                 │      │  /webhook)      │
        └─────────────────┘      └─────────────────┘
```

---

## 2. Data model and storage

### Decision: file-based, not Core Data or SwiftData

**Rationale:**
- macOS 13 deployment target — SwiftData requires 14
- Core Data is overkill for this scale + adds migration headaches
- File-based is greppable, easy to back up to Dropbox, easy to debug
- Each meeting is self-contained — copying out is trivial
- **Search across meetings = Obsidian's job, not ours** — we ship to Obsidian and let it handle cross-meeting full-text search

### Meeting folder structure

```
~/Library/Application Support/SolWhisper/Meetings/
└── 2026-05-02-quarterly-strategy-review/
    ├── meeting.json              # canonical metadata + summary, with schemaVersion
    ├── audio.wav                 # final stitched audio (mic+system mix)
    ├── audio_mic.wav             # raw mic channel (kept for re-processing)
    ├── audio_system.wav          # raw system channel
    ├── transcript.json           # all segments with timestamps + speaker tags
    ├── transcript.md             # human-readable export
    ├── summary.md                # generated summary, current version
    ├── session.log               # per-meeting debug log (audio device, errors, timings)
    ├── chunks/                   # transient — only present mid-recording
    │   ├── chunk-0000-mic.wav
    │   ├── chunk-0000-sys.wav
    │   ├── chunk-0000.metadata.json
    │   └── done.flag             # written only on clean stop
    └── attachments/              # future — for inline screenshots etc
```

### Models

```swift
// Sources/Storage/Models/Meeting.swift
struct Meeting: Codable, Identifiable {
    let id: UUID
    let schemaVersion: Int                 // ALWAYS present, starts at 1
    var title: String                      // "Untitled" until renamed/auto-titled
    let createdAt: Date
    var updatedAt: Date
    var durationSeconds: Double
    var source: MeetingSource              // .recording or .import
    var sourceApp: String?                 // "Zoom", "WhatsApp" if detectable
    var participants: [String]             // populated by summary, editable
    var transcriptionBackend: String       // "whisperkit-base.en", "apple", etc.
    var summarySkillId: String?
    var summaryLLMProvider: String?
    var folderName: String
}

enum MeetingSource: String, Codable {
    case recording
    case `import`
}

// Sources/Storage/Models/TranscriptSegment.swift
struct TranscriptSegment: Codable, Identifiable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let confidence: Double?
    let speaker: SpeakerLabel              // .me / .other / .unknown
    var cleanedText: String?
}

enum SpeakerLabel: String, Codable {
    case me
    case other
    case unknown
}

// Sources/Storage/Models/Summary.swift
struct Summary: Codable {
    var skillId: String
    var llmProvider: String                // "openrouter" or "ollama"
    var llmModel: String
    var generatedAt: Date
    var sections: [SummarySection]
    var rawMarkdown: String
}

struct SummarySection: Codable, Identifiable {
    let id: UUID
    let heading: String
    let body: String
    let kind: SummarySectionKind
}

enum SummarySectionKind: String, Codable {
    case overview, actionItems, decisions, openQuestions, nextSteps,
         deadlines, participants, notes, custom
}
```

### Schema versioning (Sprint 0 deliverable)

```swift
// Sources/Storage/SchemaMigration.swift
enum SchemaMigration {
    static let currentVersion = 1

    /// Returns a migrated meeting.json dictionary, or nil if not migratable.
    static func migrate(_ json: [String: Any]) -> [String: Any]? {
        let version = json["schemaVersion"] as? Int ?? 0
        guard version <= currentVersion else { return nil }  // future schema we don't know
        var out = json
        // future: if version < 2 { out = migrateV1ToV2(out) }
        out["schemaVersion"] = currentVersion
        return out
    }
}
```

### MeetingStore API surface

```swift
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []

    // Owned by AppDelegate, NOT a singleton (testability)
    init(rootDirectory: URL = MeetingStore.defaultRoot) { ... }

    func loadAll() async                                  // scan + parse meeting.json files
    func create(source: MeetingSource) -> Meeting        // new folder, returns model
    func update(_ meeting: Meeting) async throws
    func delete(_ meeting: Meeting) async throws         // moves folder to ~/.Trash
    func transcript(for: Meeting) async throws -> [TranscriptSegment]
    func saveTranscript(_:for:) async throws
    func summary(for: Meeting) async throws -> Summary?
    func saveSummary(_:for:) async throws

    /// Per-meeting in-document search. NO global index — use Obsidian for cross-meeting.
    func searchWithin(_ meeting: Meeting, query: String) async -> [TranscriptSegment]

    func recoverableSessions() async -> [Meeting]        // chunks/ exists, no done.flag
}
```

---

## 3. UI specification

### 3.1 Tray icon menu — 6 items

```
┌─────────────────────────────────┐
│ ◉ Records prompt        ⌥⌘Space │  ← existing pill flow
│ ⬆ Upload audio file…            │  ← B
│ 🎙 Record meeting               │  ← C, shows red dot when recording
│ 📑 Transcripts…                 │  ← opens Transcripts window
│ ─────────────────────────────── │
│ ⚙ Settings…                     │
│ ─────────────────────────────── │
│ Check for updates              │
│ Quit SolWhisper                 │
└─────────────────────────────────┘
```

State variants on the recording row:
- Stopped: `🎙 Record meeting`
- Starting: `🔄 Starting…` (disabled)
- Recording: `⏸ Pause meeting` + `⏹ Stop meeting`
- Paused: `▶ Resume meeting` + `⏹ Stop meeting`
- Stopping: `⏹ Stopping…` (disabled)

`Sources/Tray/TrayMenuController.swift` extracts menu logic out of `AppDelegate`. State binds to `MeetingController.state` via Combine.

### 3.2 Records prompt — existing pill

**No changes.** Mode A untouched.

### 3.3 Record Meeting — pill during recording

When the tray "Record meeting" item fires:
1. Spawn `OverlayWindowController` pill **with `mode: .meeting`**
2. Pill shows: timer, mic level, **second meter** for system audio level, record dot, pause/stop buttons
3. Closing the pill (or clicking Stop) ends the meeting → kicks off transcription → opens Transcripts window with new meeting selected

`RecordingOverlayView.swift` gains a `mode` enum parameter (`.dictation` vs `.meeting`). Branches one section to show the dual-meter view + meeting controls. ~80 LOC delta.

### 3.4 Transcripts Window — full spec

```
┌────────────────────────────────────────────────────────────────────┐
│  ●●●                                                                │
├────────────────────────────────┬───────────────────────────────────┤
│                                │  ┌───────────────────────────────┐│
│  ┌──────────────────────────┐  │  │ Header toolbar                ││
│  │ 🔍 Filter meetings…      │  │  │ [Clean up] [Summarize ▾] [⚙] ││
│  └──────────────────────────┘  │  │                       [🗑]    ││
│  ┌──────────────────────────┐  │  └───────────────────────────────┘│
│  │ ⬆ Upload audio file      │  │                                   │
│  └──────────────────────────┘  │  Quarterly Strategy Review        │
│                                │  ─────────────────────────────    │
│  Today                          │  May 2, 2026 • 45 min • Zoom     │
│  ▸ Quarterly Strategy Rev…     │                                   │
│    May 2 • 45 min     ✓ active │  ## Summary                       │
│                                │  Discussed Q2 priorities at Acme  │
│  Yesterday                      │  Corp. Agreed to ship Crea v2…    │
│  ▸ 1:1 with Sarah               │                                   │
│    May 1 • 22 min               │  ## Action Items                  │
│  ▸ team standup                 │  - Philipp: ship Crea v2 by 6/30 │
│    May 1 • 14 min               │  - Sarah: budget review for…      │
│                                │                                   │
│  Earlier                        │  ## Transcript                    │
│  ▸ podcast.mp3 (imported)      │  [Me] Welcome everyone, today…   │
│    Apr 30 • 1h 12m              │  [Other] Right, so the design…   │
│  ▸ vendor demo                  │  [Me] Lets table that and…       │
│    Apr 28 • 38 min              │                                   │
│                                │                                   │
└────────────────────────────────┴───────────────────────────────────┘
   sidebar (~280px)                  detail panel (flex)
```

#### Sidebar (`MeetingListView`)

- **Filter field** at top — **simple in-memory title-prefix filter only** (no transcript search index). Cross-meeting search lives in Obsidian.
- **Upload audio file** button — opens NSOpenPanel for `.wav`, `.mp3`, `.m4a`, `.mp4`, `.flac`, `.ogg`. Drag-and-drop onto the Transcripts window also works.
- **Grouped list** — Today / Yesterday / This Week / Earlier. Each row shows title + date + duration; recording-in-progress row shows a pulse dot and "active" badge.
- **Right-click context menu** per row: Reveal in Finder, Rename…, Export as .md, Send to Hermes, Send to Obsidian, Delete.
- **Bottom of sidebar:** "12 meetings · 1.2 GB" → links to Settings → Storage.

#### Detail panel (`MeetingDetailView`)

- **Header toolbar** (`DetailHeaderToolbar.swift`):
  - **Clean up** — runs cleanup pass (preserves original; cleaned version stored as `cleanedText` per segment).
  - **Summarize ▾** — split button. Click main face → summarizes with current default skill + LLM. Click ▾ → popover with skill picker.
  - **Settings ⚙** — popover sheet with two pickers: **Skill** and **LLM provider/model**. Saves as the meeting's preferred skill+model.
  - **Delete 🗑** — confirmation dialog.
- **Body** — vertically scrollable, three regions stacked:
  1. **Header card** — title (inline-editable), date, duration, source app, participants pills, transcription backend used.
  2. **Summary** — rendered markdown via `AttributedString(markdown:)`.
  3. **Transcript** — scrollable list of segments with speaker badges, timestamps, click-to-seek audio.
- **Empty state** — centered card "Pick a meeting" with two CTAs: "Record new meeting" / "Upload audio file".

### 3.5 Settings — new sections

```swift
enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case transcription   // existing — gets WhisperKit added
    case meetings        // ✚ NEW
    case skills          // ✚ NEW
    case llm             // ✚ NEW (renamed from "AI Polish", OpenRouter + Ollama only)
    case integrations    // ✚ NEW
    case vocabulary
    case hotkey
    case debug
    case about
}
```

#### Transcription section — additions

| Control | Purpose |
|---|---|
| **Default backend** picker (existing) | Add "WhisperKit" option |
| **WhisperKit model** picker | tiny / tiny.en / base / base.en / small / small.en / medium / medium.en / large-v3 / large-v3-turbo |
| **Manage models…** button | Opens download/delete sheet |
| **Language** picker | Per-backend |

#### Meetings section — NEW

| Subsection | Control |
|---|---|
| Recording | **Save folder** path picker (default `~/Library/Application Support/SolWhisper/Meetings/`) |
| Recording | **Auto-summarize on stop** toggle |
| Recording | **Auto-send to integrations on stop** toggle |
| Audio | **Microphone** device picker |
| Audio | **System audio source** picker |
| Audio | **Bluetooth warning** toggle |
| Audio | **Audio enhancement: ducking** toggle (default ON) |
| Audio | **Audio enhancement: clipping detector** toggle (default ON) |
| Audio | **Chunk size** slider — 15 / 30 / 60 sec (default 30) |
| Privacy | **Show recording disclosure overlay** toggle (default ON) |
| Privacy | **Recording consent disclaimer on first launch** (one-time, see §M4) |

*VAD pre-filter toggle removed (deferred to v0.5).*

#### Skills section — NEW

A list of all installed skills with **+ New** and per-row **Edit** / **Duplicate** / **Delete**. Built-in skills are read-only but duplicable.

Each skill editor (v0.4 simplified):
- **Name** (text)
- **Description** (textarea)
- **Output template** — markdown skeleton
- **Prompt template** — multiline with `{{transcript}}` and `{{participants}}` substitutions
- **LLM preference** (provider + model + temperature) — overrides global default
- **"Test on a meeting…"** button

*Custom declarable form fields removed (deferred to v0.5).*

Bundled skills:
1. **Generic** — overview / action items / decisions / open questions / next steps
2. **Sales call** — discovery / objections / next steps / proposed terms
3. **1:1** — agenda recap / blockers / commitments / culture pulse
4. **Standup** — yesterday / today / blockers / risks
5. **Brainstorm** — ideas / pros & cons / votes / chosen direction
6. **Interview** — candidate signals / next steps

#### LLM section — NEW (replaces "AI Polish")

**Two providers only.**

| Provider | Settings |
|---|---|
| **OpenRouter** | API key (existing, kept), expanded model list, default model per role |
| **Ollama** | Base URL (default `http://localhost:11434`), auto-discovered model list |

Plus global controls:
- **Default model for AI Polish (mode A)** — keeps existing behavior
- **Default model for cleanup (meetings)**
- **Default model for summaries (meetings)** — recommend Claude Sonnet 200k for long meetings
- **API keys stored in Keychain only** (Sprint 0 migration from UserDefaults)

#### Integrations section — NEW

| Integration | Controls |
|---|---|
| **Hermes (your VPS)** | Webhook URL, HMAC secret (Keychain), test button, "Send last meeting now", on/off, "Send transcript" + "Send summary" + "Send full audio file" toggles |
| **Obsidian** | Vault path picker, target folder (default "Calls"), filename template (`{{date}}-{{slug}}.md`), include audio link toggle, on/off |
| **Generic webhook** | One row per webhook — URL, HMAC secret, headers, payload template (Mustache), on/off. + button to add more |
| **Send-on-completion rules** | "Auto-send recordings to: [pick]" "Auto-send imports to: [pick]" |

**Failed-send queue:** all integration sends go through a durable retry queue (`~/Library/Application Support/SolWhisper/PendingSends/`). Failed sends auto-retry on next app launch with exponential backoff.

---

## 4. Settings — count summary

- **Transcription additions:** 4 controls
- **Meetings:** 11 controls (was 13; VAD removed, "show segment timestamps" merged into the transcript view itself)
- **Skills:** list + simplified per-skill editor (6 fields, was 8)
- **LLM:** 2 providers × ~3 fields + 3 default-model pickers ≈ 9 controls
- **Integrations:** 3 default cards + arbitrary webhooks + 2 send-on-completion rules

Roughly **45-50 settings entries** (down from 70+). Ship in the order they're needed by sprint.

---

## 5. Sprint plan

### Sprint 0 — Notarization + foundations (1.5-2 days) ✚ NEW

**Goal:** Stop paying the TCC tax on every interim build. Get foundational infrastructure in before the real work starts.

**Tasks:**
- **Notarization setup** with active Apple Developer account:
  - Configure `DEVELOPMENT_TEAM` in `project.yml`
  - Add Developer ID Application signing in Xcode
  - Update `scripts/release.sh`: `xcrun notarytool submit … --wait` after DMG creation
  - Update `scripts/release.sh`: `xcrun stapler staple` to staple notarization ticket
  - Update `scripts/deploy-local.sh`: keep ad-hoc for fast iteration, but document when to switch
  - Verify TCC permissions persist across notarized builds (this is the whole point)
- **Concurrency design doc** (`Sources/Meeting/ConcurrencyDesign.md`):
  - Define which queues own which state
  - Audio-thread → main-actor handoff strategy (likely `AsyncStream` with bounded buffering)
  - File I/O strategy (background actor, never main-actor blocking writes)
  - VAD/inference threading (off-main, completion handlers on main)
- **Schema versioning baseline:**
  - Add `schemaVersion: 1` to all model types
  - `SchemaMigration.swift` skeleton
  - Tests verifying load fails gracefully on unknown future versions
- **Keychain migration:** move existing `openRouterApiKey` from UserDefaults to Keychain. Provide a one-launch migration that reads UserDefaults if present, writes to Keychain, deletes from UserDefaults.

**Deliverable:** signed + notarized build. Tester installs once, never re-grants permissions for any v0.4 milestone.

**Demo criteria:** install v0.3.x → upgrade to a notarized v0.4-alpha → mic, accessibility, automation permissions persist without re-granting.

---

### Sprint 1 — WhisperKit backend (2-3 days)

**Goal:** drop WhisperKit into `TranscriptionController` as a third backend without touching mode A.

**Pre-flight verification (must do before writing code):**
- Confirm WhisperKit non-streaming API exposes:
  - Progress callbacks (0-1) for full-file transcription
  - Cancellation (so user can abort a 5-minute import mid-flight)
  - Per-segment timestamps
- If any of those are missing → design alternative path (chunk-and-progress wrapper, or streaming API).

**Tasks:**
- Add WhisperKit Swift Package (`https://github.com/argmaxinc/WhisperKit`) to `project.yml` packages
- New file `Sources/Transcription/WhisperKitClient.swift`:
  - `transcribe(file: URL, model: String, progress: @escaping (Double) -> Void) async throws -> [TranscriptSegment]`
  - For mode A live: streaming via `AVAudioPCMBuffer` feed (only if API allows, otherwise punt)
- Add backend case to `TranscriptionController.startRecording()` (`else if activeBackend == "whisperkit"`)
- Settings: add "WhisperKit" to the backend picker, model picker (start with `base.en` and `large-v3-turbo`)
- Model download UX: small modal on first selection. Robust resumable download with checksum verification.
- Tests: verify model download succeeds / handles network failure / handles disk-full.

**Deliverable:** mode A users can opt into WhisperKit. Defaults stay Apple Speech.

**Demo criteria:** record a 30-second prompt with each of three backends, transcripts all reasonable.

---

### Sprint 2 — File import (mode B), local-only (3 days)

**Goal:** drag-and-drop or pick an audio file → produce a transcript saved to a meeting folder.

**Tasks:**
- Storage scaffold: `Sources/Storage/MeetingStore.swift` + `Models/*.swift`. File-based, with `schemaVersion: 1`.
- `Sources/Import/FileImportController.swift` — orchestrates: validate → create meeting folder → run transcription → write `transcript.json` + `transcript.md` → mark meeting active.
- `Sources/Import/FileTranscriber.swift` — wraps WhisperKit non-streaming. Reports progress.
- Tray menu item "Upload audio file…" — opens `NSOpenPanel`, allowed types `.wav`, `.mp3`, `.m4a`, `.mp4`, `.flac`, `.ogg`. Toast "Transcribing…" with progress.
- Drag-and-drop on dock icon (`applicationOpenURLs` in `AppDelegate`).
- Drop overlay shown over any window when audio dragged into app.
- **Per-meeting `session.log`** populated from the start.
- Unit tests for `MeetingStore.create / update / delete` lifecycle.

**Deliverable:** SolWhisper is functionally a file-import dictation app for any local audio file.

**Demo criteria:** drop a 5-minute MP3 → meeting appears in `~/Library/Application Support/SolWhisper/Meetings/` with full content.

---

### Sprint 3 — Transcripts window + storage UI (3 days)

**Goal:** browse meetings. Read-only at this point — no editing or deletion.

**Tasks:**
- `Sources/Transcripts/TranscriptsWindow.swift` — `NSWindowController`
- `TranscriptsRootView.swift` — SwiftUI `NavigationSplitView` per spec
- `MeetingListView.swift` — sidebar with **simple title-prefix filter** (no full-text), upload button, grouped list
- `MeetingDetailView.swift` — right pane scaffold (header card + transcript scroll, summary placeholder)
- Tray menu: "Transcripts…" item opens window
- Auto-open after Sprint 2 imports complete
- Audio playback: `AVAudioPlayer` with seek-on-segment-click

**Deliverable:** all of yesterday's meetings (Sprint 2 imports) browsable.

**Demo criteria:** import 3 audio files, all show up, clicking each shows its transcript.

---

### Sprint 4a — Core meeting recording (5-6 days)

**Goal:** mic + system audio capture working end-to-end, with chunked disk recording and crash recovery. **No** device monitoring, ducking, or clipping detection yet (that's 4b).

**Tasks:**

**4a.1 — System audio capture (2 days)**
- Add `NSScreenCaptureUsageDescription` to Info.plist
- `Sources/Meeting/SystemAudioCapture.swift` — wraps SCKit's `SCStream` with audio-only configuration
  - `SCContentFilter` with `excludingApplications: [SolWhisper.bundleID]` to avoid audio loop
  - Output: `Int16` PCM, 48 kHz stereo
- Stress-test: BT headphones, aggregate devices, macOS 13/14/15 differences
- Diagnostic recording mode in Settings → Debug

**4a.2 — Dual-stream MeetingAudioEngine (2 days)**
- `MeetingAudioEngine.swift` — **standalone, no AudioEngine reuse**
  - Owns mic stream + system audio stream
  - Time-aligns via buffer presentation timestamps
  - Outputs synchronized `(micBuffer, systemBuffer)` at 50 ms windows
  - Follows the concurrency design doc from Sprint 0

**4a.3 — Chunked disk recording (1.5 days)**
- `ChunkWriter.swift` — receives synchronized buffer pairs, writes mic + system to separate WAV chunks every 30s
- Files: `chunk-NNNN-mic.wav`, `chunk-NNNN-sys.wav`, `chunk-NNNN.metadata.json`
- Atomic writes (write to `.tmp`, rename on close)
- `done.flag` written only on clean stop

**4a.4 — Crash recovery (½ day)**
- `CrashRecovery.swift` — on launch, scans `Meetings/` for sessions with `chunks/` but no `done.flag`
- Recovery dialog listing orphan sessions
- Recovery: stitch chunks → final WAV → run transcription → save as normal meeting
- Edge case: if transcription fails after chunk recovery, keep chunks + show "retry transcription" affordance

**4a.5 — MeetingController orchestrator (1 day)**
- `MeetingController.swift` — single-instance state machine, owned by `AppDelegate`
  - `idle → starting → recording → paused → stopping → processing → idle`
  - Owns the pill UI lifecycle for meeting mode
  - Coordinates audio engine, chunk writer, transcription, post-processing
  - Exposes `@Published` state for SwiftUI binding
- Per-meeting `session.log` populated throughout

**Deliverable:** click "Record meeting" → pill appears → record while playing audio in another app → stop → transcript appears with [Me]/[Other] tags. **Audio quality may be rough** (no ducking, no clipping protection); that's 4b.

**Demo criteria:** record a 5-minute "meeting" with a podcast playing + your voice. After stop:
- Transcript shows mic and system contributions correctly tagged
- Both raw audio files saved
- Force-quit mid-recording → relaunch → recovery dialog appears → recover successfully

---

### Sprint 4b — Audio quality + device monitoring (3-4 days)

**Goal:** add the polish that makes recordings actually pleasant to listen to and recover from device changes mid-call.

**Tasks:**

**4b.1 — Device monitoring: BT + USB hot-swap (1.5 days)**
- `DeviceMonitor.swift` — singleton listening for:
  - `kAudioHardwarePropertyDefaultOutputDevice` change → re-check transport type for BT
  - `kAudioHardwarePropertyDevices` change → check if active input still present
  - `AVAudioEngineConfigurationChange` notification → graceful pause + reconnect prompt
- Surfaces three states to UI: `.healthy` / `.btWarning(deviceName)` / `.disconnected(lostDevice)`
- Pill UI shows colored dot + tooltip per state
- **Mic switch flow during long calls** (your specific use case):
  - User unplugs USB mic → switches to AirPods or built-in
  - DeviceMonitor catches `AVAudioEngineConfigurationChange` → pauses recording → shows "switch to [new device]?" prompt → user accepts → engine reconfigures → resumes recording
  - Chunks remain continuous (gap recorded as silence in mic channel during switch)

**4b.2 — Audio mixer with RMS ducking (1 day)**
- `AudioMixer.swift` — receives synchronized buffer pairs, outputs mixed buffer
- Side-chain RMS computation on mic via `vDSP_meamgv`
- When mic RMS > -40 dBFS → reduce system gain by 8 dB
- Smooth attack 10 ms, release 200 ms
- Tunables exposed in Settings

**4b.3 — Clipping detector (½ day)**
- `ClippingDetector.swift` — `vDSP_maxv` peak detection per buffer, threshold -1 dBFS
- Visual indicator in pill UI: small red bar when clipping in last second

**4b.4 — Pill UI dual-meter (½ day)**
- `RecordingOverlayView.swift` `mode: .meeting` variant: dual level meters (mic + system)
- Device state chip (healthy / BT warning / disconnected)
- Clipping indicator

**4b.5 — Stress tests (½ day)**
- 2-hour meeting completes cleanly
- Mic unplug → reconnect mid-recording works
- BT headphones connect mid-call → warning + continues
- System audio app (Zoom) crashes mid-recording → mic continues, system goes silent

**Deliverable:** meeting recordings sound good. Device changes don't kill the meeting.

**Demo criteria:**
- Mid-meeting: pull USB mic → switch dialog appears → continue with AirPods → recording resumes seamlessly
- Mid-meeting: BT connect → warning chip appears, recording continues
- Playback of mixed audio shows ducking working (system audio quiet when you speak)

---

### Sprint 5 — Post-processing pipeline (3 days)

**Goal:** Cleanup pass + summary generation via skills + LLM provider abstraction.

**Tasks:**
- `Sources/LLM/LLMClient.swift` — protocol with `complete(messages:model:temperature:) async throws -> String`
- `Sources/LLM/OllamaClient.swift` — implements protocol against `http://localhost:11434/api/chat`
- Existing `OpenRouterClient.swift` adopts the protocol
- `Sources/PostProcessing/CleanupPass.swift` — given transcript segments, calls LLM with cleanup prompt, returns updated segments
- `SkillsRegistry.swift` — manages built-in + user skills
  - Built-ins as JSON in `Resources/Skills/*.json`
  - User skills in `~/Library/Application Support/SolWhisper/Skills/`
  - **Free-form prompts only** (no custom fields in v0.4)
- `Skill.swift` model — name, description, prompt template, output schema, LLM preference
- `SummaryGenerator.swift` — given meeting + skill, fills prompt, calls LLM, parses response
- `SpeakerLabeler.swift` — for separated channels: source-channel → speaker. For imports: `.unknown`.
- Default summary model: **Claude Sonnet 200k via OpenRouter** (no chunking needed for typical meetings)
- Long-meeting fallback: if estimated tokens > 150k, warn user + suggest using a different skill
- Unit tests: `Skill` template substitution, `Summary` JSON round-trip

**Deliverable:** Clean up + Summarize buttons functional.

**Demo criteria:** record a meeting → Summarize with "Generic" skill → markdown summary with sections. Switch to "Sales call" → re-summarize → different sections.

---

### Sprint 6 — Integrations: Hermes / Obsidian / generic webhook (2-3 days)

**Goal:** complete the loop — meeting recording → external destinations.

**Tasks:**
- `Sources/Integrations/OutboundWebhook.swift` — generic POST with HMAC-SHA256 (header `X-Webhook-Signature`)
- `HermesIntegration.swift` — preset using your VPS URL + the schema `ingest.py` already accepts
- `ObsidianIntegration.swift` — writes markdown directly to vault folder
- **Mustache template engine** for payload templating (small Swift package, ~5 KB)
- "Send last meeting now" button per integration in Settings
- "Send to…" right-click action on meetings
- Auto-send rule: if "Auto-send recordings to integrations" is on, fire after summary completes
- **Durable retry queue** (`~/Library/Application Support/SolWhisper/PendingSends/`):
  - Failed sends serialized as JSON files
  - Retry with exponential backoff on next app launch
  - User-visible "12 pending sends" banner in Transcripts window
- Tests: HMAC signature verification, retry queue serialization

**Deliverable:** record meeting → 30 seconds later, Telegram message via Hermes; markdown file in Obsidian vault.

**Demo criteria:** end-to-end flow originating from SolWhisper.

---

### Sprint 7 — Settings UI completion (3 days)

**Goal:** wire every new control listed in §3-4 into the existing `SettingsView.swift`.

**Tasks:**
- Add 4 new sections to the enum + sidebar
- `MeetingSettingsView.swift` — 11 controls
- `SkillsSettingsView.swift` — list + simplified editor + import/export
- `LLMSettingsView.swift` — OpenRouter card + Ollama card + 3 default-model pickers
- `IntegrationsSettingsView.swift` — 3 default cards + dynamic webhook list
- Migrate "AI Polish" section content into "LLM" section (preserve user's keys via Keychain — already migrated in Sprint 0)

**Deliverable:** every Sprint 1-6 feature is configurable; nothing hardcoded.

---

### Sprint 8 — Polish + edge cases + QA (3-4 days)

**Goal:** ship-ready quality.

**Tasks:**
- Onboarding additions: explain meeting permissions on first launch
- **Privacy disclaimer** on first "Record meeting" click — "By recording, you confirm you have consent from all participants where required by law" (one-time, persisted)
- Error states: every async operation has a user-facing error
- Permissions onboarding: when user first clicks "Record meeting", prompt for Screen Recording with rationale, deep-link to System Settings if denied
- Memory profiling: confirm idle baseline ~150 MB, recording ~400-700 MB (lower than original estimate since no Silero/large model in memory by default), post-recording back to baseline
- Sparkle appcast for v0.4.0
- Comprehensive QA pass per §8 below

**Deliverable:** v0.4.0 ready for release.

---

## 6. Engineering decisions to make on day 1

### 6.1 WhisperKit model choice

**Default `base.en` (74 MB), opt-in `large-v3-turbo` (1.5 GB).** Don't bundle in DMG — download on first use.

### 6.2 Audio file format

**WAV for storage, opt-in m4a/AAC for archive.** Settings toggle to convert to m4a after summarization.

### 6.3 Chunk size

**30 seconds default, tunable 15/30/60.**

### 6.4 ~~Silero VAD~~

**Cut from v0.4.** Whisper's internal VAD plus the ChunkWriter writing everything raw is sufficient. Re-evaluate if real CPU pain emerges.

### 6.5 Meetings folder location

**`~/Library/Application Support/SolWhisper/Meetings/`.** NOT in iCloud or Dropbox by default. Settings toggle for post-write copy to a sync path.

### 6.6 Naming convention

**`YYYY-MM-DD-<slug>` folder, `meeting.json` canonical.** Slug from summary's first heading or `Meeting-<HHMM>` fallback. Inline-editable in Transcripts window.

### 6.7 LLM providers

**OpenRouter (cloud) + Ollama (local) only.** Both implement `LLMClient` protocol. API keys in Keychain. No direct Anthropic/OpenAI/Groq for v0.4.

### 6.8 Default summary model

**Claude Sonnet 200k via OpenRouter** for cloud users; **gemma-3** for Ollama users. No chunked summarization unless transcript exceeds 150k tokens.

### 6.9 Concurrency

**Defined explicitly in `Sources/Meeting/ConcurrencyDesign.md`** before any audio code is written (Sprint 0 deliverable).

---

## 7. Risks and unknowns

### 7.1 ScreenCaptureKit + audio capture quirks

**Risk:** SCKit audio-only mode has reported issues with BT route changes, aggregate devices, macOS version differences.
**Mitigation:** stress-test in Sprint 4a.1 before relying on it. Diagnostic recording mode in Settings → Debug.

### 7.2 WhisperKit model download UX

**Risk:** first-run download is 74 MB-1.5 GB.
**Mitigation:** robust resumable download manager with checksum + retries. Apple Speech remains fallback during download.

### 7.3 ~~Silero CoreML conversion~~

**Removed — feature cut.**

### 7.4 Long transcript LLM token limits

**Risk:** 2-hour meeting ≈ 30k-50k tokens; 6-hour meeting could push 150k.
**Mitigation:** default Claude Sonnet 200k handles up to ~12 hours in one shot. Warn user if estimated tokens > 150k.

### 7.5 Apple Developer signing + notarization

**Risk:** moving from local-only to notarized adds complexity.
**Mitigation:** **Sprint 0 deliverable** — fight the Xcode setup once, never again. Without this the entire dev cycle inflicts TCC tax on testers.

### 7.6 ScreenCaptureKit permission UX

**Risk:** Sequoia (15) added a weekly re-grant prompt for Screen Recording.
**Mitigation:** clear in-app rationale. Onboarding deep-link to System Settings. Recovery if user revokes mid-session.

### 7.7 Multi-app meetings (Zoom + browser tabs)

**Risk:** SCKit's "all audio" picks up Spotify, notification dings.
**Mitigation:** v0.4 ships "all audio" with "Mute Spotify before meeting" hint. Per-app source picker is v0.5.

### 7.8 Mid-call mic switch (your specific use case)

**Risk:** USB mic disconnect during 1+ hour call → recording stops or corrupts.
**Mitigation:** **Sprint 4b.1** — `DeviceMonitor` catches the configuration change, pauses recording, prompts for new device, resumes seamlessly. Gap recorded as silence in mic channel.

---

## 8. Testing approach

### 8.1 Mode A regression tests (must NOT break)

Manual checklist after every sprint:
- [ ] Press hotkey → pill appears
- [ ] Speak → live transcript shows in pill
- [ ] Stop → text pasted into target app
- [ ] AI Polish toggle on/off behaves correctly
- [ ] Pause hotkey works
- [ ] Three transcription backends produce reasonable text

### 8.2 Per-sprint demo criteria

Each sprint has explicit demo criteria. Don't merge to main until you can demo it.

### 8.3 Unit tests (NEW commitment)

Minimum coverage targets per sprint:
- **Sprint 0:** schema migration, Keychain migration
- **Sprint 2:** `MeetingStore` CRUD lifecycle
- **Sprint 5:** skill template substitution, `Summary` JSON round-trip
- **Sprint 6:** HMAC signature, retry queue serialization

No SwiftUI snapshot tests in v0.4 (out of scope). Can add later.

### 8.4 Meeting capture stress tests (Sprint 4a + 4b)

- 2-hour meeting completes cleanly, no memory leak
- Recording during macOS sleep → wake — graceful failure
- Mid-recording: USB mic unplug → switch prompt → reconnect different mic
- Mid-recording: BT headphones connect mid-call
- Mid-recording: System audio source app crashes
- Mid-recording: SolWhisper force-quit → recovery dialog on next launch
- Disk full during recording — graceful failure, chunks preserved
- 4 GB recording — playback in detail view stays responsive

### 8.5 Integration tests

- Hermes webhook end-to-end: record → auto-send → Telegram arrives
- Obsidian: record → markdown file in vault
- LLM provider switching: OpenRouter key invalid → graceful error → switch to Ollama → works
- Skill switching: same meeting, two skills, different summaries
- Retry queue: kill app during a send → relaunch → resends successfully

### 8.6 Performance baselines (Sprint 8)

- Idle memory (Transcripts window closed)
- Idle memory (Transcripts open, 50 meetings)
- Recording memory (mic + system, 30 min in)
- Memory after stop + transcription
- Time from "click Stop" to "summary visible" for 30-min, 1-hr, 2-hr meetings
- Disk usage per minute

---

## 9. What stays exactly the same

These files **must not change** during this work. If a sprint's diff includes them, something has gone wrong.

```
Sources/Audio/AudioEngine.swift
Sources/Transcription/AppleSpeechClient.swift
Sources/Transcription/DeepgramClient.swift
Sources/HotKey/HotkeyManager.swift
Sources/Paste/PasteManager.swift
Sources/Onboarding/OnboardingView.swift
Sources/Debug/DebugLog.swift
```

These get **small targeted additions** (no logic changes to existing paths):

```
Sources/App/AppDelegate.swift                       # 3-4 new menu items + 2 window openers + MeetingStore owner
Sources/Transcription/TranscriptionController.swift # 1 new backend case
Sources/Settings/SettingsView.swift                 # 4 new section enum cases
Sources/Overlay/RecordingOverlayView.swift          # 1 new mode variant
Sources/LLM/OpenRouterClient.swift                  # adopt LLMClient protocol
Resources/SolWhisper.entitlements                   # 1 new entitlement (file-read)
Resources/Info.plist                                # 1 new usage description (Screen Recording)
project.yml                                         # WhisperKit + Mustache packages, signing
```

---

## 10. Summary in one table

| Sprint | Days | What ships | Key new files |
|---|---:|---|---|
| 0 | 1.5-2 | Notarization, concurrency design, schema versioning, Keychain migration | 2 (design doc + migration) |
| 1 | 2-3 | WhisperKit backend in mode A | 1 |
| 2 | 3 | File import (mode B) | 5 |
| 3 | 3 | Transcripts window + storage UI | 6 |
| 4a | 5-6 | Core meeting recording (SCKit + dual-stream + chunks + recovery + controller) | 5 |
| 4b | 3-4 | Device monitoring, ducking, clipping, dual-meter UI | 3 |
| 5 | 3 | Cleanup + summary skills + Ollama + LLMClient protocol | 6 |
| 6 | 2-3 | Hermes / Obsidian / webhook integrations + retry queue | 3 |
| 7 | 3 | Settings UI for everything | 4 |
| 8 | 3-4 | Polish + privacy disclaimer + notarization-of-release + QA | 0 (existing) |
| **Total** | **~29-34 days** | **v0.4.0** | **~35 new files, ~7-9k LOC** |

**Expected calendar duration: 5-7 weeks part-time** with Claude Code as engineering force-multiplier.

---

## 11. Decisions locked in (was: open questions)

| # | Decision | Resolution |
|---|---|---|
| 1 | Apple Developer Team ID | Active. Sprint 0 wires it in. |
| 2 | Sandbox: keep or add? | **Keep unsandboxed.** Required for ScreenCaptureKit + clean Core Audio access. |
| 3 | Distribution channel | **Direct + Sparkle.** No Mac App Store (sandbox required). |
| 4 | Hermes auth on Mac side | **Keychain only**, never UserDefaults. |
| 5 | Skill format custom fields | **Cut from v0.4.** Free-form prompts only. Reconsider in v0.5. |
| 6 | LLM providers count | **OpenRouter + Ollama.** No direct Anthropic/OpenAI/Groq. |
| 7 | Silero VAD | **Cut from v0.4.** |
| 8 | Cross-meeting search | **Use Obsidian.** No SQLite index in app. |
| 9 | Sprint 4 size | **Split into 4a (core) + 4b (quality).** |
| 10 | MeetingController shape | **Single-instance, owned by AppDelegate. Not singleton.** |
| 11 | AudioEngine reuse | **No reuse. Standalone MeetingAudioEngine.** |
| 12 | BT detection / hot-swap | **Kept.** Real use case during long calls. |
| 13 | Concurrency design doc | **Sprint 0 deliverable.** |
| 14 | JSON schema versioning | **`schemaVersion: 1` from commit 1.** |
| 15 | Per-meeting session log | **Always written**, lives next to audio. |
| 16 | Privacy / consent disclaimer | **First-launch one-time** + always-visible REC indicator. |
| 17 | Unit tests | **Yes, per-sprint targets.** No SwiftUI snapshots. |
| 18 | Default summary model | **Claude Sonnet 200k.** No chunked summarization in v0.4. |
| 19 | Webhook templating | **Mustache.** Small Swift package. |
| 20 | Failed-send retry | **Durable queue** in `PendingSends/`, exponential backoff. |

---

## 12. v0.5+ roadmap (decided, deferred)

All four open items are now locked. v0.4 ships without them; tracked here for the next planning cycle.

### 12.1 WhisperKit streaming for mode A (v0.5)

**v0.4 status:** non-streaming only — used for file import (Sprint 1+2).
**v0.5 plan:** if Sprint 1 pre-flight shows WhisperKit's streaming API is mature, add it as an opt-in for mode A live dictation.

**Pre-flight checklist (Sprint 1, 1-2 hrs):**
- Does WhisperKit expose a streaming API that accepts `AVAudioPCMBuffer` feeds?
- Are partial results emitted during streaming with usable latency (<1s for first token)?
- Does cancellation work cleanly mid-stream?

**v0.5 task:** add streaming branch to `WhisperKitClient.swift`, add "WhisperKit (streaming)" option to mode A backend picker. Apple Speech remains the default; WhisperKit is opt-in for users wanting fully offline dictation with state-of-the-art quality.

### 12.2 Per-app system audio capture (v0.5)

**v0.4 status:** captures all system audio. Onboarding includes "Mute Spotify before meetings" hint.
**v0.5 plan:** smart-preset picker, NOT free-form app selection.

**Why not free-form:** Zoom uses multiple internal aggregate devices, browsers route audio through complex pipelines, and `SCContentFilter` behavior differs across macOS versions. Free-form picker would silently fail in too many cases.

**v0.5 task:** real testing across the apps users actually use, then ship curated presets:
- **Zoom** preset
- **Google Meet** (browser-based) preset
- **FaceTime** preset
- **WhatsApp Desktop** preset
- **Slack huddles** preset
- **All audio** (current behavior, default)

Each preset bundles whatever filter combination works for that app on macOS 13/14/15+.

### 12.3 Real speaker diarization (v0.5)

**v0.4 status:** channel-based labels only — `[Me]` (mic) / `[Other]` (system) / `[Unknown]` (imports).
**v0.5 plan:** add pyannote-based diarization for the system channel via ONNX Runtime Swift.

**Why pyannote + ONNX Runtime:**
- Stays local (no cloud diarization, preserves privacy)
- Doesn't bump deployment target (vs Apple's SpeechAnalyzer which needs macOS 15+)
- ~250 MB model, runs ~5x real-time on M-series
- Battle-tested

**Budget:** ~1 sprint (5 days) including model download UX, integration with the post-processing pipeline, and tuning.

**Required UX work (v0.5 separate task):** speaker rename in the Transcripts detail view. pyannote outputs `Speaker 1`, `Speaker 2`, … — user needs an inline rename ("Speaker 1" → "Sarah") that propagates through the transcript and summary.

### 12.4 Skill sharing via URL ~~(deferred)~~ **CUT**

**Decision: not shipping.** Custom skills remain file-based in `~/Library/Application Support/SolWhisper/Skills/`. Users can share skills by sending the JSON file via DM/Dropbox if they want — no in-app URL fetching, no remote registry.

**Rationale:** built-in 6 skills cover 95% of use cases; URL fetching adds prompt-injection attack surface; no clear demand from beta testers yet.

If demand emerges later, ship as drag-and-drop `.skill.json` import only — never URL fetching.

---

*End of revised plan. Cuts: Silero VAD, 4 LLM providers, custom skill fields, chunked summarization, search index. Adds: Sprint 0 (notarization + foundations), split 4a/4b, durable retry queue, Mustache templating, per-meeting session.log, privacy disclaimer, schema versioning, unit test targets per sprint.*
