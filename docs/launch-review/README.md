# SolWhisper — Public Launch Review

Date: 2026-07-06 · Branch: `feat/kiros-integration` · Method: **static review only, zero app
launches** (unsigned dev build re-prompts TCC on every launch). One compile-only build ran green.
Four parallel review lenses (architecture, security, Swift/macOS correctness, UX) plus a
`/cso` comprehensive security pass. **Every CRITICAL/HIGH/BLOCKER below was re-verified against the
actual code** — one security claim was rejected as a misread (documented in `03-security.md`).

## Verdict

The core is coherent and the newest work (Kiros) is genuinely well-built. But this is **not ready
for a wide, non-technical audience yet.** Two things stand between you and launch:

1. **Distribution:** the app ships unsigned/ad-hoc today. That's the Gatekeeper wall your friends
   worked around by hand, and it's why every update wipes permissions. A general audience won't do
   the `xattr` dance. **This is blocker #1 and it's mostly paperwork, not code.**
2. **Silent failures:** the first-run path has several places where the app does nothing and says
   nothing — denied mic, failed paste, mic-only meeting, offline transcript, missing summary. For
   "anyone can use it," these have to become visible, recoverable moments.

There are also **4 data-integrity issues in the meeting pipeline** that "mostly work" at friends-scale
and will bite at public scale (corrupted recordings, lost/zombie meetings). None need a rethink — all
are contained fixes.

Realistic effort: **~1.5–2.5 focused weeks of code** + Apple Developer enrollment ($99/yr, a few
hours of setup).

---

## Launch-blocker checklist (deduplicated across all four lenses)

### Tier 0 — Distribution (do this first; unblocks everything downstream)
- [ ] **Notarize + Developer ID sign as the default release path.** `project.yml` has
  `DEVELOPMENT_TEAM=""`; `release.sh` falls back to ad-hoc unless `SW_DEVELOPER_ID` +
  `SW_NOTARIZE_PROFILE` are set. Enroll in the Apple Developer Program, set those vars (steps already
  in `scripts/setup-notarization.sh`). Fixes the Gatekeeper wall **and** the permission-reset-on-update
  tax. `03-security.md` B1. **Effort: hours, once enrolled.**

### Tier 1 — Data loss & crashes (code)
- [ ] **Audio tap buffer forwarded across an async `Task`** → corrupts mic-channel recordings under
  load. `MeetingAudioEngine.swift:130`. Deep-copy in the tap. `02-architecture.md` C1. **~0.5 day.**
- [ ] **Post-processing is uncancellable + crash-recovery misses the processing window** → deleting or
  quitting during the multi-minute pipeline yields zombie or permanently-empty meetings.
  `MeetingController.swift:336`, `CrashRecovery.swift:28`. Store the task, add cancellation, split
  `done.flag`/`processed.flag`. `02-architecture.md` C3+C4. **~1.5–2 days.**
- [ ] **Force-cast on an Accessibility result crashes the app on a paste.**
  `PasteManager.swift:144`. One-line `CFGetTypeID` guard. `04-swift-correctness.md` C1. **~15 min.**
- [ ] **No `applicationWillTerminate`** → quitting mid-dictation loses it with no recovery.
  `04-swift-correctness.md` C2. **~0.5 day.**

### Tier 2 — Silent first-session failures (UX + one correctness)
- [ ] **Paste failure is invisible** (text only on clipboard, notice goes to debug log).
  `PasteManager.swift:92`. **The #1 "I dictated and nothing happened."**
- [ ] **Mic/speech denial = stuck "listening" pill, no error.** `TranscriptionController.swift:275`.
- [ ] **Screen-Recording missing → silent mic-only meeting** (one-sided call, no warning).
  `MeetingController.swift:156`.
- [ ] **Onboarding teaches the wrong shortcut** (`⌥⌘R` vs real `⌃⌥⌘R`). `OnboardingView.swift:191`.
- [ ] **First meeting: silent 74 MB model download; offline = empty transcript, error swallowed.**
  `MeetingController.swift:585`.
- [ ] **Auto-summarize shows ON but pipeline reads OFF on fresh install** → the marquee feature is
  silently broken first-run. `MeetingController.swift:550`. **~15 min.**
- [ ] **OpenRouter key written to one Keychain account, read from another** → silent LLM failure
  (incl. Kiros) for users who set the key via Settings → Models. `LLMClient.swift:130` vs
  `ModelsSettingsView.swift:179`. `02-architecture.md` C2. **~0.5 day.**
- [ ] **Rename "STT Short"/"STT Meetings"** top-level nav → "Dictation"/"Meetings".
  `SettingsView.swift:10`.

### Tier 3 — Security hardening before advertising the feature set
- [ ] **MCP server exposes all transcripts + dictation history to any local process, no consent/token.**
  Gate behind a copy-from-Settings token or in-app consent. `03-security.md` B2.
- [ ] **Google Gemini API key sent in the URL** (leaks to proxy/provider logs) → use a header.
  `GoogleClient.swift:36`. `03-security.md` H1.
- [ ] **Deepgram key in plaintext UserDefaults** (every other secret is in Keychain) → migrate.
  `03-security.md` H2. **~0.5 day.**
- [ ] **Custom-webhook template does unescaped transcript→JSON interpolation** (breaks/injects on a
  quote in speech) → JSON-escape or use `JSONSerialization`. `03-security.md` H3.
- [ ] **Decide App Sandbox go/no-go explicitly** (currently none) — document the call.
  `03-security.md` H4.

### Tier 4 — Fast-follow (don't block launch, but queue immediately)
- [ ] `NSUserNotification` permissions prompt is deprecated + its button is dead → `UNUserNotificationCenter`.
- [ ] AdditiveClipboard CGEvent tap never re-enables after an OS-forced disable.
- [ ] Zero `accessibilityLabel` in the app — VoiceOver dead zone on the core loop.
- [ ] Reconcile `ConcurrencyDesign.md` with reality (the actors/bounded-stream it mandates were never built).
- [ ] Clipboard clobber with no save/restore; transcript transits Universal Clipboard.
- [ ] Fix `CLAUDE.md` — 5 load-bearing claims are false (see `02-architecture.md`).

---

## What's genuinely good (calibration — it's not all red)

- **Kiros integration** is the reference module: injectable `URLSession`, a pure/testable extractor
  that treats LLM output as untrusted (clamps ranges, whitelists enums, caps lengths), failure
  isolation in fanout, Keychain token.
- **Sparkle update chain** is cryptographically correct — EdDSA-signed, `release.sh` fails without a
  signature. No RCE. (The gap is notarization/signing, not the update integrity.)
- **Recording consent disclaimer** (`PrivacyDisclaimer`) is well-worded and covers third-party consent.
- **Audio HAL teardown** (device release, FFT setup/destroy, continuation single-resume) is careful and
  correct across every exit path.
- **Git history is clean** — no committed secrets, ever. `local-secrets.json` is gitignored and not
  bundled.
- **~20 test files** exist, and the Kiros/extractor/voice-matcher logic is well-covered.

---

## Documents

| File | Lens |
|---|---|
| `02-architecture.md` | Module boundaries, the meeting-pipeline concurrency CRITICALs, LLM layer, persistence, MCP, doc drift |
| `03-security.md` | Egress map, secrets, Sparkle, sandbox, MCP exposure, injection surfaces, notarization blocker |
| `04-swift-correctness.md` | Leaks, crashes, deprecated APIs, permission flows, what's correct |
| `05-ux.md` | First-run golden paths, blockers, jargon hit-list, copy fixes |

*AI-assisted review (multi-agent + independent verification). Not a substitute for a professional
penetration test before a public launch that records third-party audio.*
