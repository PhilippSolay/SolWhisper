# SolWhisper Full Pre-Launch Review — SUMMARY

Date: 2026-07-13 · Baseline: `main` @ 8cad856 (v0.7.5 work) · Review branch: `claude/launch-review-2026-07-13`
Method: 4 Phase-1 verification agents (Opus) reconciling the 07-06 checklist + 5 Phase-2 full-codebase lenses
(security/correctness/architecture/quality/UX) + 2 cross-model Codex passes (review gate + adversarial challenge).
Every CRITICAL/HIGH was found by ≥1 lens; items found by 2+ independent reviewers are marked ⋆high-confidence.

## Verdict

**The core is materially safer than it was on 07-06.** All four meeting-pipeline CRITICALs and all three
security HIGHs from that review are verified genuinely fixed; the audio HAL, Kiros integration, and Sparkle
EdDSA chain re-certified as reference-quality; the new Import/Translate/MCP/paste surface is injection- and
traversal-clean (no new CRITICAL, no new HIGH *code* vulnerability).

**Two things still gate a public launch:**
1. **Notarization (process, not code)** — still blocker #1, unchanged since 07-06. Ad-hoc/unsigned is the
   shipped default; every update resets TCC permissions and now also weakens Keychain ACL binding. Fix is
   Apple Developer enrollment + the env vars `release.sh` already reads. **See [PHILIPP-ACTIONS.md](PHILIPP-ACTIONS.md) — start today (24–48h latency).**
2. **A cluster of contained code fixes** — 1 privacy BLOCKER + ~9 HIGH, none needing a rethink. Detailed below.

## Launch-BLOCKER / HIGH table (severity-ranked, deduped across all sources)

| # | Sev | Finding | Location | Fix | Found by |
|---|-----|---------|----------|-----|----------|
| 1 | BLOCKER | Translate bubble shows **"On-device"** badge on the Farsi-style path where text actually egresses to a cloud LLM — affirmative privacy falsehood | `TranslateResultBubble.swift:684,882-893` | Track engine actually used; badge "Sent to {provider}" on fallback | UX |
| 2 | BLOCKER(proc) | Ad-hoc/unsigned shipped default → Gatekeeper wall + TCC reset every update + weak Keychain ACL | `project.yml:18`, `release.sh:204-215` | Apple Dev enrollment (Phase 3) | Security, 07-06 |
| 3 | HIGH ⋆ | ChunkWriter rotation index off-by-one → meetings >30s land chunks in orphaned `.tmp`; recovery counts "1 chunk" for any meeting | `ChunkWriter.swift:100-126`, `CrashRecovery.swift:68` | Fix index; align stitch/recovery filters to final suffix | Tier1, Codex-challenge |
| 4 | HIGH ⋆ | Interrupted import → blank/orphan meeting; m4a import runs recording pipeline → empty transcript marked complete, import discarded | `FileImportController.swift:92`, `CrashRecovery.swift:44-47` | Branch recovery on `source==.import`, re-enqueue via ImportQueue | Arch, UX |
| 5 | HIGH | Writer-bootstrap failure (disk full/perms) → buffers accumulate, stop writes empty transcript.json + marks complete → silent total meeting loss | `MeetingController.swift:222`, `MeetingPostProcessor.swift:115` | Fail the meeting visibly if writer nil at stop | Codex-challenge |
| 6 | HIGH | Quit mid-dictation **discards** the transcript (`applicationWillTerminate`→`cancel()` zeroes it) | `AppDelegate.swift:255-256`, `TranscriptionController.swift:114-125` | Synchronously persist/finalize before return | Tier1 |
| 7 | HIGH | Wrong-app paste: focus stolen during 150ms window → dictated text fires into wrong app via System Events, no PID recheck | `PasteManager.swift:51-73` | Re-verify frontmost PID==target immediately before paste; abort if changed | Codex-challenge |
| 8 | HIGH | WhisperKit rescue silent vanish on empty/timeout — dots up to 60s then pill disappears, nothing pasted, no message | `AppleSpeechClient.swift:452-460`, `AppDelegate.swift:733-736` | Error banner on nil/timeout + labeled offline state | UX |
| 9 | HIGH | `failUnavailable` = 215-char 3-option jargon wall, auto-dismiss 4s, no button | `AppleSpeechClient.swift:324-327` | Persist, one sentence + "Open Settings" button, drop "WhisperKit" | UX |
| 10 | HIGH | Rescue invisible when "Show live transcript" off — no signal anything unusual happened | `OverlayWindowController.swift:334` | Drive rescue state through pill/banner tag | UX |
| 11 | HIGH | Release publishes appcast **before** GitHub asset exists → failed upload points Sparkle at a 404 | `release.sh:~405` | Create+upload+verify release first, THEN push appcast | Codex-challenge |
| 12 | HIGH | Release silently falls back to ad-hoc if env vars unset → could ship non-notarized build resetting all users' TCC | `release.sh:172` | Guard: refuse appcast push on ad-hoc unless explicit override | Codex-challenge |
| 13 | HIGH | `local-secrets.json` not excluded from app bundle → hand-cut DMG can ship dev's live API keys | `project.yml:53` | Add to excludes (**one-line**) | Tier3 |
| P0 | HIGH | Translate preflight downloads the WRONG pack for non-English-source→English (queues target not the missing source) — regression from 8b27d13 | `AppleTranslationEngine.swift:69-73`, `TranslateResultBubble.swift:876-881` | Detect which side of pair is missing; queue that | Codex-gate |

## MEDIUM (fix before or shortly after launch)
- Beta installer applescript trains users on privileged Gatekeeper bypass — exclude from public distribution (`beta-dmg/installer.applescript:30-37`). [Security M1]
- Obsidian filename path-traversal via **calendar-invite event title** → note written outside vault on custom `{{title}}` templates (`ObsidianIntegration.swift:42-52`). [Security M2, ⋆ Tier3+Security]
- Mic-only meeting never marked persistently; warning fully suppressible → silent one-sided recordings (`MeetingController.swift:162-194`). [Tier2 U3]
- Offline first-meeting → endless spinner, no error, no download progress (`MeetingDetailView` transcriptSection). [Tier2 U4]
- Deepgram key re-seeded to plaintext UserDefaults by `seedLocalSecrets` (`AppDelegate.swift:450`) — add to keychainKeys (**one-line**). [⋆ Tier3+Security]
- Crash after transcript.json (mid-pipeline) → summary/diarize/integrations silently dropped, no retry (`MeetingPostProcessor.swift:117`). [Tier1 C3]
- ImportQueue advances on cancel without awaiting teardown → briefly 2 transcriptions on shared WhisperKit (`ImportQueue.swift:161`). [Arch M1]
- Import module + LLMTranslationEngine: zero/low tests, non-injectable seams — below the 80% bar (`Sources/Import/*`). [Arch M2/M3]
- Voice Translate "Engine" setting is a dead control (writes a key nothing reads). [UX M1]
- No import-completion notification; misleading "20–40s" model-download estimate; language-pack auto-download yanks focus with no confirm. [UX M2/M4/M5]
- MCP memory-DoS via unbounded `limit`/huge JSON line (`MCPServer.swift:40`). [Codex-challenge X5]
- VoiceOver: only 2 accessibilityLabels app-wide; Settings icon-only buttons a dead zone. [Tier4 T1]
- Clipboard clobber with no save/restore + no Universal-Clipboard opt-out, systemic across 8 files. [⋆ Tier4+Codex+Security]

## LOW / jargon / carry-over
Integration URLs not https-restricted (SSRF/cleartext); MCP token RNG-return ignored (all-zero token if RNG fails)
+ TOCTOU chmod; `/tmp` release staging predictable (→mktemp); supply chain unpinned (no `Package.resolved`, no model
hash pin); Deepgram `print()` noise; ConcurrencyDesign.md still describes unbuilt actors; jargon sweep (base.en/
"Diarize"/"LLM"/"WER"/Parakeet strings); AppDelegate god object; fanout single-attempt result discarded; `.custom`
provider dead-end. Full detail in [BUGS_FOUND.md](BUGS_FOUND.md) + [PER_COMPONENT.md](PER_COMPONENT.md).

## Release path — dry-run validated (Phase 5)
`SW_DRY_RUN=1 SW_SKIP_UNIVERSAL=1 release.sh 0.7.5` ran green: build 0.7.5 → sign → DMG (10.9 MB) → **EdDSA
signed** → stop-before-publish → Info.plist restored. The Sparkle EdDSA gate survived the +209-line release.sh
rewrite (07-06 strength re-certified at runtime). EdDSA signing key confirmed in Keychain, pubkey matches
Info.plist — **release signing needs no setup from Philipp beyond the Developer-ID notarization step.** One
fragility found: the build-product glob can select a stale binary across multiple checkouts (version guard
caught it; fix in BUGS_FOUND). Ad-hoc path shown here; the notarized path needs Phase 3 enrollment.

## Re-certified as genuinely good (evidence in PER_COMPONENT.md)
07-06's four meeting-pipeline CRITICALs (audio-tap deepCopy, OpenRouter dual-key, cancellable post-processing +
delete-race, crash-recovery window) · all three security HIGHs (Gemini header, Deepgram Keychain, webhook JSON) ·
MCP token gate (4 data methods fail-closed) · Kiros (injectable session, exhaustive untrusted-output clamping) ·
audio HAL single-resume-safe every exit path · Sparkle EdDSA fail-closed (survived the release.sh rewrite) ·
import correctly reuses the shared MeetingPostProcessor · git history secret-free through HEAD.

## Fixes applied on the review branch (`[REVIEW]` commits, **265 tests green**, build clean)

**All of the code BLOCKER + HIGH items are now fixed on-branch** (+17 new tests). The notarization
blocker (#2) and privacy-policy hosting remain Philipp's. Runtime behavior of the UI/paste/dictation fixes
still needs confirmation on the signed build — see [QA-CHECKLIST.md](QA-CHECKLIST.md) (items tagged with each `H-n`).

| # | Fix | Commit |
|---|-----|--------|
| 1 | Translate badge reflects engine actually used (no "On-device" on cloud path); "AI model" copy | `fix(translate)` |
| 3 | ChunkWriter rotation index off-by-one + `ChunkWriterTests` | `fix(meeting): ChunkWriter` |
| 4 | Interrupted-import recovery (scan excludes imports; re-enqueue from copied audio) | `fix(meeting)` + `fix(dictation)` |
| 5 | Writer-bootstrap failure → visible error + discard empty meeting (not empty-complete) | `fix(meeting)` |
| 6 | Quit-mid-dictation salvages in-flight text to history | `fix(dictation)` |
| 7 | Wrong-app paste → abort to clipboard on focus loss + `PasteManagerTests` | `fix(paste)` |
| 8 | WhisperKit-rescue empty/timeout → visible banner (no silent vanish) | `fix(dictation)` |
| 9 | `failUnavailable` — *deferred* (see note) | — |
| 11 | Release: create+verify asset before appcast; ad-hoc publish guard; deterministic build product | `fix(release)` |
| 13 | `local-secrets.json` bundle exclude | `fix(security)` |
| H-6 | Translate queues the actually-missing language pack (not English→English) | `fix(translate)` |
| — | Deepgram + all `Keys.migratable` secrets seeded to Keychain | `fix(security)` |
| — | Mic-only meeting flag + "Mic only" badge (H-8) | `fix(meeting)` |

**Decisions I took** (flagged in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) — override if you disagree): translate
fallback = label-and-proceed (no consent gate); quit-mid-dictation = save-to-history, not paste; wrong-app
paste = abort-to-clipboard, not retry.

**Still open** (MED/LOW, not launch-blocking) in [BUGS_FOUND.md](BUGS_FOUND.md): fftSetup use-after-free, offline
first-meeting spinner, mic-only warning suppressibility, `failUnavailable` banner copy, Obsidian filename
traversal, beta-installer exclusion, dead-code deletions, VoiceOver labels, jargon sweep.

## Correctness & coverage (lenses 4–5)
- **No new crash** beyond the ChunkWriter path: the one remaining force-cast (`PasteManager` `as!`) is guarded by
  a `CFGetTypeID` check on the line above — verified safe (a lens flagged it, rejected on inspection).
- **New MED:** `fftSetup` can be destroyed on the main thread while the audio-tap thread is mid-`vDSP_DFT_Execute`
  (use-after-free); a `fftQueue` meant to guard it is declared but never used. `AudioEngine.swift:85`.
- **Two inert Settings controls** (dead settings): meeting "Chunk size" picker (hardcoded 30s) and Voice Translate
  "Engine" picker (writes a key nothing reads).
- **Systemic silent writes:** ~11 `try? store.update` sites (metadata saves can silently fail), `try? KeychainStore.set`
  from Settings (API-key save can silently fail), Keychain **write** failure log-only (user thinks key saved).
- **Coverage:** 132 files / 25k lines Sources, 29 test files. Security fully covered; CrashRecovery + Keychain
  migration well-covered. 10 launch-critical untested behaviors (PasteManager, TranscriptionController state
  machine, MustacheRenderer webhook escaping, RetentionSweep deletion, HotkeyManager…) — see [TEST_COVERAGE.md](TEST_COVERAGE.md).
- **Dead code** (5 zero-ref functions) + **magic numbers** (duplicated ns delays) catalogued in BUGS_FOUND — deletions
  deferred to Phase 6 (XcodeGen regen needed).

---
*AI-assisted multi-agent review with cross-model (Codex) verification. Not a substitute for a professional
penetration test before a public launch that records third-party audio — see PHILIPP-ACTIONS.md #3.*
