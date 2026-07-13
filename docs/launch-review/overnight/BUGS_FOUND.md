# BUGS_FOUND — findings + fix status

**UPDATE:** every BLOCKER/HIGH below except notarization (#B-2, Philipp's) is now **FIXED on this branch**
(265 tests green) — see the table in SUMMARY.md for the commit per item. Their entries are kept here for the
record and because the behavior changes (paste/dictation/translate/import/rescue) still want runtime
confirmation on the signed build — each maps to a `QA-CHECKLIST.md` item. The **MEDIUM/LOW/jargon** sections
below remain genuinely open (not launch-blocking). Each item: what, where, fix approach, which QA item proves it.

## BLOCKER (must fix before public launch)

### B-1 · Privacy: cloud translation mislabeled "On-device"
`Sources/Translate/TranslateResultBubble.swift:684` (badge) + `:882-893` / `AppleTranslationEngine.swift:74-81` (fallback).
For an Apple-unsupported language (Farsi etc.) the "Apple / on-device" path silently routes text to a cloud LLM,
yet the result badge still reads **"On-device."** Affirmative privacy falsehood at the moment text egresses — the
worst version of this for a privacy-positioned product.
**Fix:** thread the engine actually used back to the bubble; when the LLM fallback fires, render "Sent to {provider}"
+ a one-line note. Never print "On-device" on a path that leaves the Mac. **Proven by QA §6 (Farsi).**

### B-2 · Distribution: notarization (process, tracked in PHILIPP-ACTIONS.md #1)
Ad-hoc/unsigned default → Gatekeeper wall + TCC reset every update + (now) unstable Keychain ACL binding.
Not a code fix — Apple Developer enrollment + the env vars `release.sh` already reads. **Proven by QA §0 + §8.**

## HIGH (fix before launch)

### H-1 · Quit mid-dictation discards the transcript  ⋆data loss
`AppDelegate.swift:250-252` → `TranscriptionController.cancel()` zeroes `liveTranscript`/`isFinalAccumulator`.
⌘Q before pressing Stop = text gone (not pasted, not in history). `applicationWillTerminate` exists but calls the
wrong method. **Fix:** synchronously persist/finalize in-flight dictation before returning (terminate can't await
async — needs a sync path in TranscriptionController). **QA §4 quit-mid-dictation.**

### H-2 · Wrong-app paste  ⋆confidentiality
`PasteManager.swift:51-73`. Methods A/B keystroke "System Events" = the *frontmost* app; the `isFront` check at :60
is logged not enforced, and a 150ms stabilize sleep opens a focus-steal window. Dictated text can land in Slack/
browser/terminal. **Fix:** re-verify `frontmostApplication.pid == target.pid` immediately before A/B/C; if not,
route to `onClipboardFallback` + return (method D already targets the pid via `postToPid`). **QA §3 wrong-app.**

### H-3 · Interrupted import → blank/orphan meeting  ⋆(Arch + UX agreed)
`FileImportController.swift:92` + `CrashRecovery.swift:44-47`. Import persists the meeting + copies audio before any
transcript; recovery only knows the recording shape (chunks/`audio.m4a`). Non-m4a import → permanent 0-segment card
never cleaned; m4a import → recovery runs the *recording* pipeline → empty transcript marked complete, import
discarded. **Fix:** branch recovery on `source == .import` (audio present, no `transcript.json`) → re-enqueue via
ImportQueue, or a launch sweep. **QA §5 quit-mid-import.**

### H-4 · Writer-bootstrap failure marks empty meeting "complete"  ⋆(Codex + quality)
`MeetingController.swift:222` / `MeetingPostProcessor.swift:115`. If `ChunkWriter` init fails (disk full/perms) the
error is only logged, `writer` stays nil, buffers accumulate, and stop writes an empty `transcript.json` + marks
complete — silent total meeting loss, recovery won't offer it. **Fix:** if writer is nil at stop, fail the meeting
visibly (don't write a "complete" empty transcript). **QA §4 disk-full (best-effort).**

### H-5 · WhisperKit rescue silent vanish on empty/timeout
`AppleSpeechClient.swift:452-460` + `AppDelegate.swift:733-736`. `showProcessing` hides the bubble, rescue runs up to
60s, nil/timeout returns with the overlay already hidden → dots for a minute then nothing, no message. Reintroduces
07-06 BLOCKER #1 on the rescue path. **Fix:** error banner on nil/timeout + a labeled "Transcribing offline…" state.
**QA §3 Siri-off rescue + no-model.**

### H-6 · Translate downloads the WRONG language pack (regression from 8b27d13)
`AppleTranslationEngine.swift:69-73` + `TranslateResultBubble.swift:876-881`. Translating from an uninstalled
non-English *source* into English (default target): status is `.supported` because the *source* pack is missing, but
the code always queues `targetCode` → deep-links Settings to download English→English; user is stuck. **Fix:** on
`.supported`, determine which side of the pair is uninstalled and queue that one. **Caught by the Codex review gate.
QA §6 non-English-source→English.**

### H-7 · Release chain can ship broken or unsigned updates  (two issues, `scripts/release.sh`)
(a) `:~405` pushes appcast to `main` **before** `gh release create`; a failed upload points Sparkle at a 404, and the
URL check is only a warning. **Fix:** create+upload+verify the release first, THEN push the appcast.
(b) `:172` silently falls back to ad-hoc signing if `SW_DEVELOPER_ID`/`SW_NOTARIZE_PROFILE` are unset, yet still
EdDSA-signs + publishes → a non-notarized build can ship to real users. **Fix:** refuse to push appcast / create
release on ad-hoc unless an explicit `SW_ALLOW_ADHOC_RELEASE=1` is set. **Proven by the Phase 5 dry-run.**

### H-8 · Mic-only meeting never marked; warning fully suppressible
`MeetingController.swift:162-194`. `Meeting` has no mic-only field; once the user ticks "don't warn again," a one-sided
(Screen-Recording-off) recording has zero indication ever. **Fix:** persist a `micOnly` flag on the meeting + a visible
badge; keep a subtle indicator even when the pre-warning is suppressed. **QA §4 mic-only.**

## MEDIUM (fix before or shortly after launch)
- **fftSetup use-after-free** — destroy in `deinit` (match `SpectrumComputer`) or use the declared-but-unused `fftQueue`. `AudioEngine.swift:85`, `AppleSpeechClient.swift:585`. [Correctness]
- **Offline first-meeting** = endless spinner, no error, no download % (`MeetingDetailView` transcriptSection; download is silent). [Tier2/UX]
- **Beta installer** trains users on an admin-password Gatekeeper-bypass flow — exclude `beta-dmg/installer.applescript` from public distribution. [Security M1]
- **Obsidian filename path-traversal** via calendar-invite event title on custom `{{title}}` templates — strip separators / `lastPathComponent` on the rendered filename. `ObsidianIntegration.swift:42-52`. [Security M2, ⋆Tier3+Security]
- **Crash after transcript, before summary** → summary/diarize/integrations silently dropped, no retry. `MeetingPostProcessor.swift:117`. [Tier1 C3]
- **Two inert Settings controls:** meeting "Chunk size" (hardcoded 30s, `MeetingController.swift:333`) and Voice Translate "Engine" (writes `voiceTranslateEngine`, nothing reads it). [Quality + UX]
- **ImportQueue cancel** doesn't await teardown → briefly two transcriptions on the shared WhisperKit instance. `ImportQueue.swift:161`. [Arch M1]
- **Import + LLMTranslationEngine test seams** — inject a controller factory / LLM client; both modules are near-zero coverage vs the 80% bar. [Arch M2/M3]
- **Silent write failures** (systemic): ~11 `try? store.update` (metadata), `try? KeychainStore.set` from Settings (API-key save), Keychain **write** failure log-only (`SecretsStore.swift:37-42`) → user believes key saved. [Quality]
- **No import-completion notification**; misleading "20–40s" model-download estimate; language-pack auto-download yanks focus with no confirm. [UX M2/M4/M5]
- **MCP memory-DoS** via unbounded `limit` / huge JSON line — clamp both. `MCPServer.swift:40`, `MCPTools.swift:86`. [Codex]
- **VoiceOver dead zone** — 2 labels app-wide; Settings icon-only buttons unlabeled. [Tier4]
- **Clipboard clobber** — no save/restore + no Universal-Clipboard opt-out marker, systemic across 8 files. [⋆Tier4+Codex+Security]
- **Deprecated mic-auth API** `AVCaptureDevice.requestAccess(for:.audio)` at 4 sites — modernize. [Correctness]

## LOW / catalogued (deferred, non-blocking)
- **Release build-product selection is ambiguous across checkouts** (found in the Phase 5 dry-run): `release.sh`
  selects the app to package via `find …/DerivedData/SolWhisper-*/…/Release -name SolWhisper.app | newest-mtime`.
  With more than one `SolWhisper-*` DerivedData dir (git worktree + main checkout, or Xcode leftovers) it can pick
  a **stale binary from a different checkout** — the dry-run built 0.7.5 correctly but the glob selected a stale
  0.7.4 and the version guard aborted. The guard prevents mis-shipping (good), but it turns a routine release into a
  confusing abort. **Fix:** build with an explicit `-derivedDataPath ./build` and package from there, so the product
  is deterministic. `scripts/release.sh`.
- Integration URLs not `https`-restricted (cleartext/SSRF); MCP `generate()` ignores `SecRandomCopyBytes` return (all-zero token if RNG fails) + atomic-write-then-chmod window; `/tmp` release staging predictable (→`mktemp -d`); supply chain unpinned (no `Package.resolved`, no WhisperKit model hash pin); Deepgram `print()` noise; ConcurrencyDesign.md still describes never-built actors.
- **Dead code (5, zero-ref):** `AppDelegate.openOnboardingFromMenu()`, `WhisperKitModelDownloader.isDownloading()`, `KeychainStore._wipeAllForTesting()`, `MCPTokenStore.regenerate()`, `OllamaClient.listModels()` — delete in Phase 6 (needs `xcodegen generate` + build verify, per plan; not moved to dead-code/ because XcodeGen would still compile a moved file).
- **Large files (split post-launch):** `MeetingDetailView.swift` (2000), `AppDelegate.swift` (1153), `TranslateResultBubble.swift` (926), `MeetingController.swift` (888).
- **Jargon sweep:** raw model IDs "base.en" in import copy; "Diarize"→"Label speakers"; "LLM"→"AI model"; "WER"/"25 EU+JA/ZH" Parakeet strings (07-06 said remove Parakeet for launch); rescue interim wording reads like a fault; unsupported-file rejection should list supported formats; download "resume" is actually restart.
