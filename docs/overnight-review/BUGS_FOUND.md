# Bugs found, not fixed

Each entry: what / where / why it matters / why I didn't fix it / suggested fix.

Severities track `~/.claude/rules/common/code-review.md` (CRITICAL / HIGH / MEDIUM / LOW), one level down because this is a single-user desktop app.

---

## 1. `LLMResolver` force-unwraps user-controlled URL string  ·  **MEDIUM**

**Where:** [Sources/LLM/LLMResolver.swift:57-58](../../Sources/LLM/LLMResolver.swift), and again at [:94-95](../../Sources/LLM/LLMResolver.swift).

```swift
let baseURL = URL(string: UserDefaults.standard.string(forKey: "ollamaBaseURL")
                  ?? "http://localhost:11434")!
```

**Why it matters:** `URL(string:)` returns nil for syntactically invalid URL strings. If a user (or a misbehaving migration / sync mechanism) sets `ollamaBaseURL` to something like `"localhost:11434"` (missing scheme) or any other garbage, the force-unwrap crashes the app on the next route to a summary/cleanup/diarization call. Mac apps usually survive bad UserDefaults; this one wouldn't.

**Why I didn't fix it:** A safe fix changes user-facing behavior — what should happen when the prefs string is invalid? Fall back to localhost silently? Log and skip the call? Surface an error UI? The right answer is a product call.

**Suggested fix:** Replace the force-unwrap with a `?? URL(string: "http://localhost:11434")!` fallback (the literal is compile-time safe) and emit a `DebugLog` warning. Adding a Settings-side validator on the text field would be even better.

---

## 2. `DeepgramClient` cross-queue race on `closeCompletion` / `accumulatedTranscript`  ·  **MEDIUM**

**Where:** [Sources/Transcription/DeepgramClient.swift:111-116](../../Sources/Transcription/DeepgramClient.swift) (`consumeCloseCompletion`), and the call sites at lines 89-98 (`closeAndWait` fallback), 132-141 (`receiveLoop` failure branch), 182-192 (`handleJSON` `speech_final` branch).

**Why it matters:** The `consumeCloseCompletion()` check-and-nil dance and the `accumulatedTranscript += ...` append run from at least three contexts:
1. URLSession's internal delivery queue (the `receive` callback's failure branch)
2. `DispatchQueue.main` (everything dispatched from `handleJSON`)
3. `DispatchQueue.main` (the 4-second fallback DispatchWorkItem)

Without explicit synchronization, two of these can race: both can see `closeCompletion != nil`, both can call the completion, both can mutate `accumulatedTranscript`. The window is narrow (it requires the WS to fail at the exact moment `speech_final` arrives or the fallback fires) but Swift's Optional check-and-nil isn't atomic.

**Why I didn't fix it:** Two reasonable fixes — (a) funnel every state mutation through `DispatchQueue.main.async` so URLSession's queue never touches state directly, or (b) wrap state in `OSAllocatedUnfairLock` like `WhisperKitClient.instanceCache`. Both are real refactors. Wanted human signoff on the chosen approach.

**Suggested fix:** Option (a) is the smaller diff and matches the rest of the file's pattern. Move the failure-branch state read into a `DispatchQueue.main.async` block.

---

## 3. `MCPStorage.searchTranscripts` index mismatch on locale-changing case folds  ·  **LOW**

**Where:** [MCP/MCPStorage.swift:118-134](../../MCP/MCPStorage.swift).

```swift
let lower = md.lowercased()
if let range = lower.range(of: q) {
    let lo = md.index(range.lowerBound, offsetBy: -80, ...)
    ...
    let snippet = String(md[lo..<hi]) ...
}
```

**Why it matters:** `range.lowerBound` is an index into `lower`, but it's used to walk `md`. For ASCII text these have identical layout, so it works. For text containing locale-folding code points (`İ → i̇`, `ß → ss`, sequences in Greek, Turkish, German), `lower` is *longer* than `md`, and the index can land mid-grapheme in `md` or off the end → `String.Index` operations crash or produce wrong offsets.

**Why I didn't fix it:** It needs a test fixture I'd want a human to sanity-check before committing.

**Suggested fix:** Switch to `md.range(of: q, options: .caseInsensitive)` and drop the `lowercased()` copy entirely. (Bonus: skips one O(n) allocation per meeting.)

---

## 4. `MeetingDetailView.swift` is 1,550 lines  ·  **LOW (code health)**

**Where:** [Sources/Transcripts/MeetingDetailView.swift](../../Sources/Transcripts/MeetingDetailView.swift).

**Why it matters:** The project's coding-style rule caps files at 800 lines (max). This is 1.9× over. SwiftUI views tend to be long, but at this size the view has accumulated multiple responsibilities (transcript display, segment editing, summary panel, speaker rename sheet, audio playback bar, action items).

**Why I didn't fix it:** Splitting it cleanly is a multi-PR refactor that risks visual regressions. Out of scope for an overnight pass; deserves a focused branch.

**Suggested approach:** Extract each subsection (`TranscriptList`, `SummaryPanel`, `SpeakerRenameSheet`, `AudioPlaybackBar`, `ActionItemsView`) into its own file under `Sources/Transcripts/MeetingDetail/`. Each can stay an `internal` type owned by `MeetingDetailView`.

---

## 5. FFT/spectrum logic duplicated across three files  ·  **LOW (code health)**

**Where:**
- [Sources/Audio/AudioEngine.swift:167-228](../../Sources/Audio/AudioEngine.swift) (`computeSpectrum`)
- [Sources/Transcription/AppleSpeechClient.swift:219-272](../../Sources/Transcription/AppleSpeechClient.swift) (`emitSpectrum`)
- [Sources/Transcription/WhisperKitClient.swift:406-458](../../Sources/Transcription/WhisperKitClient.swift) (`emitSpectrum`)

vs. the consolidated version in [Sources/Meeting/MeetingAudioEngine.swift:170-244](../../Sources/Meeting/MeetingAudioEngine.swift) (`SpectrumComputer`).

**Why it matters:** Three near-identical implementations of: Hann window apply, complex DFT, magnitude, log-spaced 300–3000 Hz bin mapping, temporal smoothing. Any tuning change (e.g. shifting the speech band, smoothing constant) has to be made four places. The leak fix I just shipped had to touch two of them; if `MeetingAudioEngine` didn't already do this right, it would have been three.

**Why I didn't fix it:** The consolidation is mechanical but touches three audio-thread hot paths. Wanted a separate, focused review on it.

**Suggested fix:** Promote `SpectrumComputer` out of `MeetingAudioEngine.swift` into its own file under `Sources/Audio/`, then replace the three duplicates with a `SpectrumComputer` instance per backend. Add a test that fixed-input gives fixed-output bins.

---

## 6. `DeepgramClient.send` and other Bool/Int races on audio thread  ·  **LOW**

**Where:** [Sources/Transcription/DeepgramClient.swift:68](../../Sources/Transcription/DeepgramClient.swift) (`bytesSent += audioData.count`). Mutated on whatever queue the audio tap delivers from; read on the main queue at line 83.

Similar pattern in `AudioEngine.isPaused`, `AppleSpeechClient.isPaused`, `WhisperKitClient.isPaused`: written from MainActor, read from the audio thread.

**Why it matters:** Single-word reads/writes on aligned 64-bit values are atomic on Apple Silicon and modern Intel, so in practice nothing breaks. Under Swift 6 strict concurrency these would all be warnings/errors. Under TSan they'd flag.

**Why I didn't fix it:** Whole-codebase concurrency cleanup is its own project, ideally paired with the Swift 6 migration.

**Suggested fix:** Wrap each as an `OSAllocatedUnfairLock<Bool>` or convert to `actor`-based state. When the codebase migrates to Swift 6 concurrency, this is the natural ratchet point.

---

## 7. `KeychainStore.set` puts `kSecAttrAccessible` into the update attribute dict  ·  **LOW (dead code)**

**Where:** [Sources/Security/KeychainStore.swift:60-65](../../Sources/Security/KeychainStore.swift).

**Why it matters:** Apple's docs say `kSecAttrAccessible` is a primary-key attribute — `SecItemUpdate` silently ignores it. The `SecItemAdd` path on line 71-72 sets it correctly. So the line on update is dead config, not a bug — but it's misleading code.

**Why I didn't fix it:** No-deletes constraint. Also: future-proofing for if Apple ever does allow the attribute on update.

**Suggested fix:** Remove the `kSecAttrAccessible` key from the `attributes` dict, or add a comment that it's intentional dead config for documentation purposes.

---

## 8. `AppleSpeechClient.latestText` read from non-main thread  ·  **LOW**

**Where:** [Sources/Transcription/AppleSpeechClient.swift:118](../../Sources/Transcription/AppleSpeechClient.swift) — `let snap = latestText` runs synchronously inside `stopAndFinalize`. Caller is `TranscriptionController` (MainActor), so this is fine in practice, but the field is mutated on `DispatchQueue.main.async` inside `handleResult`. If anyone ever calls `stopAndFinalize` off-main, it's a race.

**Why I didn't fix it:** It is documented in `TranscriptionController` that stop is called from MainActor. Tightening this would mean marking the method `@MainActor` and adjusting every caller.

---

## 9. `AudioEngine.fftQueue` is declared but never used  ·  **LOW (dead code)**

**Where:** [Sources/Audio/AudioEngine.swift:33](../../Sources/Audio/AudioEngine.swift).

**Why I didn't fix it:** No-deletes constraint. Likely intended to dispatch the FFT off the audio thread; never wired up.

**Suggested fix:** Delete the var or wire it up.

---

## 10. `SkillPackLoader.seedBuiltInPacksIfMissing(force:)` parameter unused  ·  **LOW (dead param)**

**Where:** [Sources/PostProcessing/SkillPackLoader.swift:39](../../Sources/PostProcessing/SkillPackLoader.swift). Plumbed through `seedFiles(... force: Bool)` but the only call site uses `force: false`.

**Why I didn't fix it:** No-deletes constraint.

**Suggested fix:** Either drop the param entirely, or expose `restoreMissingBuiltInPacks(force: Bool)` so it's actually reachable.

---

## 11. `AudioFeedback.savedSystemVolume` overwritten on double-start  ·  **LOW**

**Where:** [Sources/Audio/AudioFeedback.swift:99-115](../../Sources/Audio/AudioFeedback.swift).

If `recordingDidStart()` is called twice without an intervening `recordingDidEnd()`, the second call overwrites `savedSystemVolume` with the now-ducked volume → `restoreSystemOutput()` restores to the ducked level, not the original. MainActor enum can't double-start in normal flow, but the safety is brittle.

**Suggested fix:** Guard with `guard savedSystemVolume == nil else { return }` before saving.

