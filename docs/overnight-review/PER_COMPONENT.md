# Per-component review

One section per component. Format: **Surface** (what I read) → **Findings** (concrete observations, severity in brackets) → **Fixed / Not fixed**.

Files I read in full: `AudioEngine`, `AudioFeedback`, `PreferredInputDevice`, all four `Transcription/*`, `PostProcessing/CleanupPass`, `PostProcessing/SkillPack`, `PostProcessing/SkillPackLoader`, `Meeting/MeetingController`, `Meeting/MeetingAudioEngine`, `Meeting/SystemAudioCapture`, `OCR/OCRPostProcessor`, all four `MCP/*`, `Security/KeychainStore`, `Diarization/SpeakerNameSuggester`, `People/VoiceMatcher`, `LLM/OllamaClient`, `LLM/LLMResolver` (partial). Everything else was greped for risk patterns rather than read line-by-line.

---

## Audio (`Sources/Audio/`)

**Surface:** `AudioEngine.swift` (234L), `AudioFeedback.swift` (174L), `PreferredInputDevice.swift` (143L). Total 3 files, ~550 LOC.

**Findings:**

- **[P2 — memory leak, fixed]** `AudioEngine.stop()` nils `fftSetup` without calling `vDSP_DFT_DestroySetup`. Each recording leaks one DFT setup (~1 KB plus internal buffers). The right-shaped version of this lives in `Meeting/MeetingAudioEngine.SpectrumComputer.deinit` (line 190) and `WhisperKitClient.deinit` (line 55). See "Fixed" below.
- **[P4 — code smell]** `fftQueue` declared at `AudioEngine.swift:33` is never used. Dead var; left in place rather than deleted (constraint: no deletions).
- **[P4 — concurrency smell]** `isPaused: Bool` mutated on MainActor, read on audio thread without sync. Single-word read on aligned architectures is atomic in practice; documented in `Meeting/ConcurrencyDesign.md` as an accepted simplification.
- **[OK]** `enhancementEnabled` read once at `start()`. If the user toggles AI Enhancement in Settings mid-recording, the change won't apply until restart — likely intentional, worth a comment.
- **[OK]** `PreferredInputDevice.applyToInputNode` carries an extremely well-documented HAL gotcha (the Uninitialize-before-SetProperty dance). Good defensive code with a clear paper trail.
- **[OK]** `AudioFeedback.savedSystemVolume`: if `recordingDidStart()` is called twice without an intervening `recordingDidEnd()`, the original volume is lost. Single-user MainActor flow makes this near-impossible in practice.

**Fix landed:** `AudioEngine.stop()` now calls `vDSP_DFT_DestroySetup(setup)` before nilling.

---

## Transcription (`Sources/Transcription/`)

**Surface:** `AppleSpeechClient.swift` (278L), `DeepgramClient.swift` (195L), `TranscriptionController.swift` (296L), `WhisperKitClient.swift` (459L). All read in full.

**Findings:**

- **[P2 — memory leak, fixed]** `AppleSpeechClient.tearDown()` nils `fftSetup` without destroying. Same fix shape as `AudioEngine`.
- **[P2 — privacy / log noise, fixed]** `DeepgramClient.swift:162` prints raw user transcripts to stdout: `print("Deepgram ← is_final=… speech_final=… : \"\(transcript)\"")`. The structured `DebugLog` already records this with truncation; the bare `print` is a leftover debug aid that escapes into release builds.
- **[P3 — data race]** `DeepgramClient.closeCompletion`, `fallbackTimer`, and `accumulatedTranscript` are mutated from both URLSession's delivery queue (the `receive` callback) and `DispatchQueue.main`. `consumeCloseCompletion()` does a check-and-nil dance without a lock; concurrent calls from the two queues could both fire the callback. The window is brief (only the WS-failure path crosses the queues) but the race is real.
- **[P4 — duplicated logic]** `emitSpectrum` / `emitLevel` are copy-pasted in `AppleSpeechClient` and `WhisperKitClient`. `MeetingAudioEngine.SpectrumComputer` (lines 174–244) is the consolidated version — the three dictation backends should use it. Out of scope for an overnight pass.
- **[OK]** `TranscriptionController` is a model of clean MainActor isolation. `[weak self]` is used consistently. The `audioWatchdog` Task is correctly cancelled in `stopRecording`/`cancel`. `handleLevel` correctly unsets `firstBufferReceived` and tears down the watchdog on first audible buffer.
- **[OK]** `WhisperKitClient.stopAndFinalize` uses an `NSLock` + `didFinish` flag to ensure the transcribe-task and the 90s safety-timeout don't both invoke `completion`. Solid defensive code.
- **[OK]** `WhisperKitClient.specialTokenRegex` is a `static let try? NSRegularExpression(...)` so a pattern-engine quirk doesn't crash app start. Good.

**Fix landed:** `AppleSpeechClient.tearDown()` destroys vDSP setup; `DeepgramClient` `print` removed.

---

## PostProcessing (`Sources/PostProcessing/`)

**Surface:** `CleanReportSheet.swift`, `CleanupPass.swift` (343L), `Skill.swift`, `SkillPack.swift` (137L), `SkillPackLoader.swift` (187L), `SkillsRegistry.swift`, `SummaryGenerator.swift`. Read all except `CleanReportSheet`, `SkillsRegistry`, `SummaryGenerator` (skimmed for force-unwraps + observer patterns).

**Findings:**

- **[OK]** `CleanupPass.cleanWithReport` batches segments (50/batch), pre-filters non-speech artifacts via a regex before paying the LLM call, and tolerates index drift in the response (missing keys → keep original). Strong defensive design. Has tests (`CleanupPassTests`).
- **[P4 — dead parameter]** `SkillPackLoader.seedBuiltInPacksIfMissing(force: Bool = false)` plumbs a `force` parameter that's never called with `true`. The only caller (`restoreMissingBuiltInPacks`) hard-codes `false`. YAGNI — left in place under the no-deletes constraint.
- **[OK]** `SkillPack.parseModule` is a deliberately minimal frontmatter parser (flat `key: value` only). Documented in the docstring and well-tested (`SkillPackTests`).
- **[OK]** `CleanupPass.cleanOneBatch` JSON extraction handles both object form (preferred) and array form (legacy). `extractJSONObject` / `extractJSONArray` use `firstIndex/lastIndex` of `{`/`[` and `}`/`]` — robust against LLM prose preambles.

**Fix landed:** none. This component is in good shape.

---

## Meeting (`Sources/Meeting/`)

**Surface:** All 9 files. Read `MeetingController.swift` (799L), `MeetingAudioEngine.swift` (244L), `SystemAudioCapture.swift` (233L) in full. Skimmed `DeviceMonitor`, `ChunkWriter`, `ClippingDetector`, `AudioMixer`, `PrivacyDisclaimer` for surface shape.

**Findings:**

- **[P2 — crash on retry, fixed]** `SystemAudioCapture.start()` precondition at line 67:
  ```swift
  precondition(phase == .idle || phase == .stopped || phase == .failed(""), ...)
  ```
  The `.failed("")` arm only matches a `.failed` with the empty-string payload (the equatable `==` on the enum compares payloads). If a previous `start()` failed with any real error message (which is the common case), `phase` is `.failed("System audio: ...")`, the precondition trips, and the app crashes when the user retries. Fix: switch to a pattern-match (`if case .failed = phase { … }`) so any failed state is accepted.
- **[P3 — concurrency smell]** `MeetingController.startInternal` captures `pendingMic` / `pendingSystem` arrays by reference in the `onMicBuffer` / `onSystemBuffer` closures. I initially flagged this as a multi-thread race; closer reading of `MeetingAudioEngine` shows both callbacks are dispatched to MainActor (`Task { @MainActor in ... }`), so the captures are serialized on the main actor. No race in practice. Worth a comment though — the contract is non-obvious.
- **[P3 — Sendable]** `Task { @MainActor in self.onMicBuffer?(buffer) }` captures an `AVAudioPCMBuffer` (non-Sendable) into a Sendable closure. Swift 5.9 doesn't enforce this; Swift 6 strict-concurrency would warn. Documented as a future-Swift hazard in `Meeting/ConcurrencyDesign.md`.
- **[P4 — force unwrap, low risk]** `mixToCombined` at lines 679–681 force-unwraps three `AVAudioPCMBuffer` inits in a row. Format is pinned to `micFile.processingFormat`; capacity is 4096; the only failure mode is OOM. Acceptable.
- **[P4 — sort fragility]** `stitchChunks` sorts by `lastPathComponent` lexicographically. Works because `ChunkWriter` zero-pads to four digits — breaks at the 10,000th chunk (~83 hours of 30s chunks). Effectively unreachable.
- **[OK]** State machine is well-formed: `.idle → .starting → .recording → .paused ↔ .recording → .stopping → .processing → .idle`. All error paths return to `.idle`.
- **[OK]** `deviceHealthTask` is correctly cancelled in `stop` / `cancel`. The comment even calls out the leak it prevents.

**Fix landed:** `SystemAudioCapture.start()` precondition pattern-matches `.failed` correctly.

---

## OCR (`Sources/OCR/`)

**Surface:** 5 files. Read `OCRPostProcessor.swift` (98L) in full; grep'd the rest.

**Findings:**

- **[OK]** `OCRPostProcessor.process` is pure logic, well-commented (Vision Y-axis quirk → top-down sort, median-line-height gap threshold for paragraph detection). Has tests (`OCRPostProcessorTests`).
- **[OK]** `collapseWhitespace` is hand-rolled but correct — runs O(n) without regex, preserves `\n\n` paragraph separators.
- **[OK]** `SnipResultBubble` uses `[weak self]` in dispatched closures consistently.

**Fix landed:** none.

---

## MCP target (`MCP/`)

**Surface:** `main.swift` (19L), `MCPServer.swift` (134L), `MCPStorage.swift` (273L), `MCPTools.swift` (180L). All read in full.

**Findings:**

- **[P3 — String indexing bug]** `MCPStorage.searchTranscripts` (line 126–130): computes `range` via `lower.range(of: q)`, then uses that range to slice `md` (the un-lowercased original). For inputs where lowercasing changes string length (Turkish `İ` → `i̇`, German `ß` → `ss`), indices in `lower` are not valid indices in `md`. The slice can crash or produce garbage offsets. Not exploitable; affects search snippets in non-English transcripts. The fix is to do the substring search on `md` with `[.caseInsensitive]` rather than pre-lowercasing.
- **[P4 — perf nit]** `ISO8601DateFormatter()` is instantiated per row in `listMeetings` mapping. Should be a static `let`. Minor.
- **[OK]** MCP stdio transport uses line-delimited JSON (`readLine`), which is correct for current MCP spec versions. The comment at `MCPServer.swift:8` matches the implementation.
- **[OK]** Tool schemas correctly declare `required` fields. Error responses use the right JSON-RPC `code` ranges (`-32700`, `-32601`, `-32602`, `-32000`).
- **[OK]** No mutating operations exposed in v1 — entire surface is read-only. Local-only stdio server, so the typical MCP supply-chain risks don't apply.

**Fix landed:** none. The `searchTranscripts` index bug needs care (and a test) — flagged for human triage.

---

## Settings + Security (`Sources/Settings/`, `Sources/Security/`)

**Surface:** 12 Settings files (skimmed), `KeychainStore.swift` (108L), `SecretsStore.swift`. Read `KeychainStore.swift` in full.

**Findings:**

- **[OK]** `KeychainStore.set` uses `kSecAttrAccessibleAfterFirstUnlock`. Good default — accessible to the app after first unlock, but not before. Migration path from `UserDefaults` is tested (`SecretsStoreMigrationTests`).
- **[P4 — silently-ignored attribute]** `KeychainStore.set` puts `kSecAttrAccessible` into the `attributes` dict for `SecItemUpdate`. Apple docs say accessibility is primary-key — `SecItemUpdate` ignores it. Harmless because the `Add` path also sets it correctly, but the line is dead config on update.
- **[OK]** `KeychainStore._wipeAllForTesting` is correctly namespaced under the bundle ID, so it can't accidentally trash other apps' Keychain items.
- **[OK]** `SettingsView` is 737L — large for a single SwiftUI view, but it's a settings root that dispatches to per-tab sub-views. Acceptable.

**Fix landed:** none.

---

## Voice profiles (`Sources/People/`, `Sources/Diarization/`)

**Surface:** 4 People files, 7 Diarization files. Read `VoiceMatcher.swift` (139L) and `SpeakerNameSuggester.swift` (152L) in full.

**Findings:**

- **[OK]** `VoiceMatcher.cosine` is defensively normalized (handles non-L2-normalized embedders) and explicitly guards `denom > 0`. Well-tested (`VoiceMatcherTests`).
- **[P4 — apparent force-unwrap, actually safe]** `SpeakerNameSuggester.swift:83` `\(meeting.context!)` is guarded by the `if context?.isEmpty ?? true` check three lines up. Safe but stylistically risky — `if let` would be clearer.
- **[OK]** `VoiceMatcher.match` correctly guards against macOS < 14 (deployment target is 14 but the API is `@available(macOS 14.0, *)`-gated on the diarizer side).
- **[OK]** All four People files are small, focused, and individually testable. `VoiceProfileStore` uses atomic file writes for the profile JSON.

**Fix landed:** none.

---

## App / Overlay / Paste / HotKey / LLM / Onboarding / Transcripts / Integrations / Import / Storage (sweep)

**Surface:** Grep-driven only — patterns: `try!`, `as!`, `fatalError`, `addObserver`, `Timer`, force-unwrap heuristic, MainActor mix, `[weak self]`.

**Findings (component-by-component, brief):**

- **`App/AppDelegate.swift` (909L):** Adds one `NSWorkspace.shared.notificationCenter.addObserver` (line 297) without `removeObserver`. AppDelegate lives for app lifetime — leak is bounded. Many `Task { @MainActor in self?.method() }` blocks; `[weak self]` used consistently. No force-unwraps in user-action paths except `URL(string: "x-apple.systempreferences:…")!` (compile-time constant).
- **`Paste/PasteManager.swift`:** Sole `as!` in the codebase — `(focusedRef as! AXUIElement)` at line 144. AX API contract says the value is always an AXUIElement; safe.
- **`HotKey/HotkeyManager.swift`:** Carbon `RegisterEventHotKey` / `UnregisterEventHotKey` paired correctly. `deinit { stopListening() }` performs all cleanup. NotificationCenter observer cleaned in both `stopListening()` and `deinit`.
- **`Overlay/OverlayWindowController.swift`:** One `addObserver` for `NSWindow.didMoveNotification`, properly removed in `deinit`.
- **`Meeting/DeviceMonitor.swift`:** `addObserver` for the preferred-input-device-changed notification, removed in `deinit`. Good.
- **`LLM/`:** `OllamaClient` / `OpenRouterClient` / etc. share an `LLMClient` protocol. The `URL(string: "https://api.X.com/...")!` force-unwraps are compile-time URL constants — safe. *Exception:* `LLMResolver.swift:57-58` and `:94-95` force-unwrap `URL(string: UserDefaults.string ?? "default")!` — if the user puts garbage in the `ollamaBaseURL` UserDefaults key, init returns nil → crash. Low probability, real bug. Flagged.
- **`Storage/`:** `MeetingStore` writes are atomic (`Data.write(to:options:.atomic)`); has tests. `SchemaMigration` has explicit schema-version stamping with tests. `CrashRecoveryTests` covers the orphan-chunks recovery path.
- **`Integrations/`:** Generic webhook path renders user-controlled Mustache templates and POSTs them — but the secret (HMAC key) is read from Keychain, never logged. URL is constructed via `URL(string:)`, returns nil on garbage → safely skipped. No injection surface.
- **`Onboarding/OnboardingView.swift`:** Multiple `URL(string: "https://…")!` to render external links. All compile-time constants → safe.
- **`Transcripts/MeetingDetailView.swift` (1,550L):** **>2× the 800-line rule.** Splitting into per-section subviews would be a multi-PR refactor. Out of scope here, but the size is a real code-health concern.

**Fix landed:** none in this sweep. The `LLMResolver` force-unwrap is flagged for human triage in `BUGS_FOUND.md`.

