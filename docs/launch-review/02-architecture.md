# Architecture Review — SolWhisper Public Launch

Static review of the working tree on `feat/kiros-integration`. No app launches.
Every CRITICAL/HIGH below was re-verified against the cited code by the synthesizer.

## Actual architecture (as-built)

`AppDelegate` (1070 LOC) is the composition root and de facto god object: it owns
the status bar, every window, the hotkey manager, the Sparkle updater, and lazily
constructs each controller. Dependencies are hard-wired via `lazy var` + ~11 global
`.shared` singletons rather than injected.

Two parallel audio pipelines share no code by design:

- **Dictation:** `TranscriptionController` → (`AppleSpeechClient` | `WhisperKitClient` |
  `DeepgramClient`) → `OpenRouterClient.polish` → `PasteManager`.
- **Meetings:** `MeetingController` → `MeetingAudioEngine` (mic `AVAudioEngine` +
  `SystemAudioCapture` via ScreenCaptureKit) → per-buffer `Task` → `ChunkWriter` actor →
  on stop, `runPostProcessing`: stitch → `WhisperKitClient` ×2 channels → `CleanupPass` →
  diarize → `SummaryGenerator` → `IntegrationFanout`.

Persistence is file-per-meeting JSON folders under
`~/Library/Application Support/SolWhisper/`, read independently by the bundled
`solwhisper-mcp` binary via hardcoded paths (no IPC). LLM access flows through an
`LLMResolver` → `LLMClient` protocol with 7 provider clients.

A normative `Sources/Meeting/ConcurrencyDesign.md` exists, but its core primitives
(`MeetingFileActor`, `MeetingStoreActor`, `MeetingConfig`, bounded `AsyncStream`) were
**never built** — grep confirms those names appear only in the `.md`. This is the root
cause of the CRITICAL concurrency findings.

---

## CRITICAL

### C1 — Audio tap buffer forwarded across an async boundary (recording corruption)
`Sources/Meeting/MeetingAudioEngine.swift:130-142`, wired at `MeetingController.swift:193,222`

The mic tap forwards the raw `AVAudioPCMBuffer` into `Task { @MainActor in … self.onMicBuffer?(buffer) }`,
and `onMicBuffer` then does `Task { await writer.appendMic(buffer) }` — the buffer crosses
**two** async hops before being written to disk. `AVAudioEngine` recycles the tap buffer as
soon as the callback returns, so the write reads a buffer whose backing store the engine has
already reused. (Note: `rms()` and `spectrum.compute()` are computed synchronously in the
callback and are fine — only the forwarded raw buffer is the problem. The system-audio path
already allocates a fresh buffer per callback, so only the **mic channel** is affected.)

`ConcurrencyDesign.md §3` explicitly bans `Task { }` in audio callbacks and mandates a
synchronous copy. **Verified real.** Manifests as intermittent corrupted chunks / garbled
mic transcripts under load — "mostly works" on idle machines, degrades at public scale.

**Fix (~0.5 day):** deep-copy the buffer synchronously inside the tap before any async hop:
allocate `AVAudioPCMBuffer(pcmFormat:frameCapacity:)`, `memcpy` per channel, set `frameLength`,
forward the copy. The system path is the reference implementation.

### C2 — OpenRouter key written to one Keychain account, read from another (silent LLM failure)
`Sources/LLM/LLMClient.swift:130` vs `Sources/Settings/ModelsSettingsView.swift:179` + `Sources/LLM/ModelStore.swift:104`

`OpenRouterLLMClient.rawComplete` reads `SecretsStore.Keys.openRouterApiKey` (literal
`"openRouterApiKey"`). But adding an OpenRouter model via **Settings → Models** writes the key
to `provider.apiKeyKeychainKey` = `"model.provider.openrouter.apiKey"`. `LLMResolver.resolveConfigured`
routes configured OpenRouter models to `OpenRouterLLMClient()`, which reads the *legacy* key.
**Verified real.**

Trigger: a user who did **not** set the OpenRouter key during onboarding (which writes the
legacy key via `SecretsStore`) but instead adds an OpenRouter model in the Models tab and types
their key there. Their key lands in the provider account; the client reads the empty legacy
account → `LLMError.missingApiKey("openrouter")` → silent no-op for dictation cleanup, meeting
summary, translation, **and Kiros task extraction** (all call `LLMResolver`). The key field shows
their key, so the failure is invisible and confusing. Not universal, but a first-run trust-killer
for an entire entry path.

**Fix (~0.5 day):** have `OpenRouterLLMClient` read `ModelProvider.openrouter.apiKeyKeychainKey`
with a fallback to the legacy key; add a one-shot copy migration; add a test asserting a
Models-tab-configured OpenRouter model resolves a non-empty key.

### C3 — Post-processing is an unretained, uncancellable `Task`; delete-during-processing races the store
`Sources/Meeting/MeetingController.swift:336,379` + `Sources/Transcripts/MeetingDetailView.swift` (delete shown during `pipelineActive`)

`stopInternal`/`recover` launch `Task { await self.runPostProcessing(for: meeting) }` with no
stored handle and no `Task.isCancelled` checks inside the pipeline (confirmed: no `processingTask`
property exists). Meanwhile the meeting detail view exposes Delete while the pipeline is active,
and delete calls `store.delete(meeting)` (trashes the folder). A user who deletes mid-pipeline
trashes the folder out from under `runPostProcessing`, which keeps writing
`transcript.json`/`summary.md`/`meeting.json` into a trashed path and re-inserts the meeting via
`store.update`. **Verified real.** Result: resurrected "zombie" meetings, orphaned files, or lost
transcripts. `ConcurrencyDesign.md §7` required the cancellation check that was never implemented.

**Fix (part of ~1.5–2 day bundle with C4):** store `processingTask: Task<Void,Never>?`, check
`Task.checkCancellation()` between phases, cancel it in `delete()` (or disable Delete until `.idle`).

### C4 — Crash/quit during the processing window is unrecoverable (flagship-feature data loss)
`Sources/Meeting/MeetingController.swift:332,336` + `Sources/Meeting/ChunkWriter.swift:80-86` + `Sources/Meeting/CrashRecovery.swift:22-31`

`stopInternal` calls `writer.finalize()` (writes `chunks/done.flag`, verified ChunkWriter:84-86)
**before** launching `runPostProcessing` (line 336). `CrashRecovery.scan` only surfaces a meeting
as recoverable if `chunks/` exists **and** `done.flag` is absent (lines 28-29). So during the
multi-minute, LLM-bound processing phase, `done.flag` already exists → a crash/quit there leaves a
meeting with no transcript that the recovery scanner will **skip forever**; `runPostProcessing`
also deletes the chunks dir after stitching, so the raw audio may be gone too. **Verified real.**
`ConcurrencyDesign.md §7` promised "transcription resumes on next launch" — it doesn't. Long
meetings (highest-value data, most likely to hit a mid-processing interruption) are exactly what's
exposed.

**Fix (part of ~1.5–2 day bundle with C3):** split `done.flag` (recording finalized) from a new
`processed.flag` (pipeline complete); have recovery re-run processing when `done.flag` exists but
`transcript.json` doesn't; gate chunk deletion on `processed.flag`.

---

## HIGH

### H1 — The normative concurrency contract is entirely unimplemented
`Sources/Meeting/ConcurrencyDesign.md` vs `MeetingController`/`MeetingAudioEngine`

The doc mandates actors, an immutable `MeetingConfig` settings snapshot, and a bounded
`AsyncStream(bufferingNewest(60))` audio handoff with drop-oldest + stall logging. None exist.
Instead: per-buffer `Task{}` fan-out (unbounded) and settings read **live** from `UserDefaults`
mid-pipeline (`runPostProcessing` reads `meetingsAutoClean`/`AutoDiarize`/`AutoSummarize`/`AutoIntegrate`
at call time), so toggling a setting mid-recording changes in-flight behavior — the exact thing
§9 forbids. This is the root of C1/C3/C4. Danger: the team likely believes this contract is in force.

**Fix:** implement the bounded-stream + actor subset (or at minimum snapshot settings into an
immutable `MeetingConfig` at record-start and cap the pending buffers), and rewrite the doc to
match reality.

### H2 — Unbounded PCM buffer accumulation before the writer bootstraps
`Sources/Meeting/MeetingController.swift:189-233,305-306`

`pendingMic`/`pendingSystem` buffer raw (by-reference) `AVAudioPCMBuffer`s until the format is
resolved and `bootstrapWriter` runs, with no cap. If the mic is slow to deliver while system audio
flows, `pendingSystem` grows unbounded holding 48kHz stereo float buffers — and (compounding C1)
they're borrowed buffers with already-stale contents.

**Fix:** cap the pending arrays (drop-oldest with a logged warning) and deep-copy on capture.

### H3 — `AppDelegate` god object blocks testing and iteration (1070 LOC)
`Sources/App/AppDelegate.swift`

Mixes 7 inline one-shot launch migrations (lines ~106-191), permission-health checks, paste-target
tracking, orphan-recovery queueing, voice-translate orchestration, audio-device menu building, and
window lifecycle — none behind a protocol, none unit-testable. You'll be adding migrations here
forever post-launch.

**Fix:** extract `LaunchMigrations` (array of idempotent, testable steps), `MenuBarController`, and
`PasteTargetTracker`; target <300 LOC.

### H4 — `MeetingDetailView` at 1995 LOC with ~45 `@State` vars is a maintainability wall
`Sources/Transcripts/MeetingDetailView.swift`

No view model — all orchestration (LLM calls, store writes, `Task` management) lives in the view,
spanning 6 independent async operations each with its own `-ing`/`error`/progress state. 20× the
project's own "<100 line" guideline. Single biggest brake on iterating the meeting UI.

**Fix:** extract `MeetingDetailViewModel: ObservableObject`; split transcript/summary/action-row
into child views.

### H5 — Integration fanout has no retry/queue despite the design promising a durable one
`Sources/Integrations/IntegrationFanout.swift` + `MeetingController.swift:729`

Each integration is a single attempt; failures are logged and dropped. `ConcurrencyDesign.md §8.5`
says failures go to a durable retry queue. A Kiros/Obsidian/webhook send that fails on a network
blip silently loses that side effect with no user-visible signal in the auto-fire path. Transcript
stays safe (fanout is last + isolated — good), but silently dropping a task-capture feature's output
is a correctness issue users notice.

**Fix:** surface failures in the meeting row (a re-send affordance already exists in the detail view)
and/or add a bounded retry.

---

## MEDIUM

- **M1 — Schema migration is a single-version stub with no golden-file test.**
  `Sources/Storage/SchemaMigration.swift` (`currentVersion = 1`, migrate only stamps the version).
  Fine today; the first real field rename/removal will migrate existing users' on-disk meetings with
  no test harness and one shared version across meeting.json/transcript.json/summary.json. Add a
  golden-file migration test and per-document versions before the first breaking change.
- **M2 — Meetings folder grows unbounded; 3 audio copies retained.**
  `Sources/Storage/MeetingStore.swift`, `RetentionSweep.swift`. Each recording keeps
  `audio.m4a` + `audio_mic.m4a` + `audio_system.m4a` plus JSON/MD indefinitely; retention is manual,
  no size cap, no disk dashboard. Delete the per-channel files after the mixed file is verified;
  surface total footprint in Settings.
- **M3 — MCP binary re-declares app models by hand → silent schema drift.**
  `MCP/MCPStorage.swift:13-48` re-decodes `Meeting`/segment structs separately with `try?`, so a
  future model change makes the MCP server silently return empty/stale results to users' Claude
  Desktop/Cursor. Share the model files with the `solwhisper-mcp` target.
- **M4 — Adding an LLM provider touches ~4 places; `.custom` is a user-selectable dead-end.**
  `Sources/LLM/LLMResolver.swift` (`resolveConfigured` returns nil + logs for `.custom`, yet the
  Add-Model sheet offers it). Also the ModelsSettingsView "routes through OpenRouter" copy is now
  wrong — `resolveConfigured` calls direct `OpenAIClient()`/`GroqClient()`/`GoogleClient()`. Gate/remove
  `.custom` in the UI; fix the copy.
- **M5 — `.shared` singletons used as `@StateObject` in ~14 view sites.**
  e.g. `SkillEditorSheet.swift:16-17`. `@StateObject` tells SwiftUI the view owns the singleton's
  lifecycle — semantically wrong; `@ObservedObject` is correct. Works today (singletons outlive the
  view) but inconsistent (`SettingsView.swift:502` does it right).
- **M6 — Session teardown is spread across timer/deviceHealthTask/deviceMonitor.**
  `MeetingController.swift:944-952`. Consolidate into one `teardownSession()` called from every exit
  path so a missed path can't leak.

## LOW

- **L1 — Kiros is the reference pattern (no action).** `Sources/Integrations/Kiros/*` — injectable
  `URLSession`, pure testable extractor that treats LLM output as untrusted (clamps ranges, whitelists
  enums, caps lengths/count), failure isolation in fanout, Keychain token. Best-architected module in
  the review. Nit: re-fetches fronts + re-resolves the LLM per meeting with no caching.
- **L2 — `KirosClient` sends `User-Agent: SolWhisper/0.4` while the app is at 0.7.1.** Derive from
  `CFBundleShortVersionString`.
- **L3 — `CFBundleVersion` = epoch-minutes couples build identity to wall-clock.** Two builds in the
  same minute collide; a clock-skewed CI runner could regress. Works now; not a content hash.

---

## Doc drift — `CLAUDE.md` is materially wrong on 5 load-bearing claims (all verified false)

1. **"No network access required (local-only processing)"** — false. `network.client` entitled; the
   app calls OpenRouter, Anthropic, OpenAI, Google, Groq, Deepgram, AssemblyAI, Kiros, Hermes, the
   Sparkle appcast, and custom webhooks.
2. **"Sandboxed: no access to filesystem outside app container"** — false. There is **no**
   `com.apple.security.app-sandbox` entitlement (only audio-input, apple-events, network.client).
3. **"No package manager (SPM) yet — dependencies vendored"** — false. `project.yml` declares 4 SPM
   packages: Sparkle, WhisperKit (`argmax-oss-swift`), FluidAudio, MarkdownUI.
4. **"MCP server integration is P1 roadmap — not yet implemented"** — false. `MCP/` is a shipped
   target (606 LOC) bundled into the app via a postBuildScript, with a Settings card + 5 tools.
5. **"macOS dictation and transcription app"** — understates the product to the point of misleading
   (now also meeting recording, diarization, translation, OCR, LLM summarization, integrations).

Fix `CLAUDE.md` before it misleads contributors (and future Claude sessions).

## Top 5 architecture actions (ranked)

1. Fix the audio-buffer race (C1) — deep-copy in the tap. **~0.5 day.**
2. Fix the OpenRouter dual-key bug (C2) — read provider key + fallback + migration + test. **~0.5 day.**
3. Make post-processing cancellable + crash-recoverable (C3+C4) — `processingTask`, cancellation
   checks, `processed.flag`. **~1.5–2 days.**
4. Reconcile the concurrency contract (H1/H2) — snapshot `MeetingConfig`, cap pending buffers, update
   the doc. **~2–3 days pragmatic; ~1 week full.**
5. Deepgram key → Keychain + extract launch migrations from AppDelegate (H3 + security). **~1–1.5 days.**
