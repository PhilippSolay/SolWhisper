# PER_COMPONENT — findings by module

One section per component: state, what was found, what was fixed. Severity tags reference the tables in
SUMMARY.md / BUGS_FOUND.md. "Re-certified" = a 07-06 strength re-verified against current code.

## Meeting / Audio (core pipeline)
- **Fixed this pass:** ChunkWriter rotation index off-by-one (H, table #3) + new `ChunkWriterTests`.
- **Re-certified:** all four 07-06 CRITICALs genuinely fixed — mic-tap `deepCopy` before the MainActor hop;
  cancellable `processingTask` + delete-race guard; crash recovery keyed off `transcript.json` (chunks OR stitched
  audio); OpenRouter dual-key. Audio HAL single-resume-safe on every exit path. Import correctly reuses the shared
  `MeetingPostProcessor` (no drift).
- **Open:** writer-bootstrap failure → empty "complete" meeting (H-4); mic-only unmarked + suppressible (H-8);
  crash-after-transcript drops summary/diarize/integrations (MED); `fftSetup` use-after-free (MED); chunk-size
  Setting inert/hardcoded 30s (MED); per-buffer unbounded `Task{}` fan-out + uncapped `pendingMic/System` (07-06
  carry-over); `MeetingController.swift` 888 lines / `startInternal` 180 lines (split post-launch).

## Transcription (dictation + Apple-Speech→WhisperKit rescue)
- **Re-certified/confirmed correct:** rescue completion is resume-exactly-once (first-finish lock + 60s timeout),
  stash deep-copied under `stashLock`, request-pointer swap lock-synced. No double-resume, no data race.
- **Open:** rescue silent-vanish on empty/timeout (H-5); `failUnavailable` dense jargon banner auto-dismisses (H);
  rescue invisible when live-transcript off (H); `finish(nil)` swallow makes "transcription failed" look like
  "user said nothing" (MED); deprecated mic-auth API (MED); `TranscriptionController` state machine untested.

## Paste / Accessibility
- **Verified safe:** the `focusedRef as! AXUIElement` force-cast is guarded by `CFGetTypeID` on the line above
  (a lens flagged it as a crash; rejected on inspection). CGEvent tap re-enables after OS disable.
- **Open:** wrong-app paste — methods A/B target frontmost, not the stored pid (H-2, confidentiality); clipboard
  clobber with no save/restore + no Universal-Clipboard opt-out (MED, systemic); `osascriptPaste` swallows errors
  silently; PasteManager untested (launch-critical).

## Import (new module)
- **Confirmed clean:** extension allowlist + `AVAudioFile` validation + dedupe + slug-normalized folder (no
  traversal); `[weak self]` throughout; `CancellationError` distinguished from real failures; transcribe-phase
  progress UI is genuinely good (fraction + clock + cancel + continue-on-failure).
- **Open:** interrupted-import recovery gap (H-3); cancel-without-await → double transcription (MED); no completion
  notification / misleading download estimate (UX MED); zero tests + non-injectable seams (MED, below 80% bar).

## Translate (new fallback + deep-link)
- **Confirmed correct:** translation continuations resume once (`didFinish` + 30s timeout); empty-input guarded;
  deep-link covers both pane-open and pane-closed.
- **Open:** "On-device" badge on a cloud-egress path (**BLOCKER B-1**); wrong-pack download regression (H-6);
  Voice Translate "Engine" is a dead control (MED); `pendingLanguageDownload` no expiry (LOW); `LLMTranslationEngine`
  resolves its client internally → untestable (MED).

## Security / Secrets / Integrations
- **Fixed this pass:** `local-secrets.json` bundle exclude; all `Keys.migratable` secrets seeded to Keychain.
- **Re-certified:** Gemini key → header, Deepgram → Keychain, webhook JSON-escape, MCP token gate (4 data methods
  fail-closed, 256-bit token, 0600). Kiros reference-quality (injectable session, exhaustive untrusted-output
  clamping, per-integration isolation). Git history secret-free. No new CRITICAL/HIGH code vuln.
- **Open:** Obsidian filename traversal via calendar title (MED); beta installer Gatekeeper-bypass flow (MED); MCP
  DoS + RNG-return-ignored + chmod window (MED/LOW); integration URLs not https-restricted (LOW); supply chain
  unpinned (LOW); Keychain-write failure log-only + `try? KeychainStore.set` from Settings (MED, silent save-fail).

## MCP server
- **Confirmed clean:** all data methods token-gated + fail-closed; resource folder resolves from trusted
  `meeting.json`, never a client URI (no traversal); no unauthenticated read; stdio only, no network listener.
- **Open:** memory-DoS via unbounded `limit`/line (MED); token is a consent gate not a same-user boundary
  (= accepted no-sandbox trade-off); `regenerate()` rotation exists but unwired (dead).

## Settings / App / Overlay / Onboarding
- **Re-certified:** onboarding shows the real ⌃⌥⌘R (reads live config); nav renamed Dictation/Meetings;
  auto-summarize default consistent UI↔pipeline; NSUserNotification→UNUserNotificationCenter.
- **Open:** `AppDelegate` 1153 lines / god object (now +import+recovery); two inert Settings pickers; VoiceOver
  dead zone on Settings icon-only buttons; `applicationWillTerminate` discards dictation (H-1).

## PostProcessing / Diarization / LLM / Storage / People / OCR
- **Confirmed sound:** LLM provider layer consistent (timeout + guard-let decode + HTTP≥400 across providers,
  bounded AssemblyAI poll); storage writes `.atomic` (MCP cross-process reads can't tear); schema migration has
  per-doc version + future-version rejection + tests; People/voice-matcher well-covered.
- **Open:** fanout single-attempt, `Result` discarded on auto-fire → integration failures invisible (07-06 H5
  carry-over); `SummaryGenerator`/`VoiceMatcher` swallow errors with zero logging (MED); `.custom` provider is a
  selectable dead-end; Ollama client not wrapped in `LLMRetry` (LOW); RetentionSweep (irreversible deletion) untested.
