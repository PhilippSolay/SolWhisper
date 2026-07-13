# SolWhisper — Full Pre-Launch Review Plan

Date: 2026-07-13 · Baseline: v0.7.4 + uncommitted v0.7.5 work · Prior review: 2026-07-06
(`README.md` in this dir — static-only, zero launches, pre-v0.7.2). This plan **extends**
that review: its checklist is the Phase 1 input, its verdict items are re-tested here.
Key fact: every fix since 07-06 was verified **statically only** — no launch has ever
confirmed them at runtime. Phase 4 closes that gap.

Since that review, ~10 commits claim to close most checklist tiers (d61f363 security,
8f5299e meeting criticals, cc557a6 crash hardening, 3d97473/d46912a UX, b85343a keychain,
6204f3c docs) **plus new surface it never saw**: Import module (fa15cc7), Apple Speech
fallback chain (841657d + pending v0.7.5), WhisperKit download-state fix (2b303ae),
release.sh arm64/universal rewrite (uncommitted).

## Phases

### Phase 0 — Land pending v0.7.5 work (~0.5 day)
- Code-review the uncommitted diff: `AppleSpeechClient.swift` (+249), its tests (+72),
  `release.sh` (+209).
- **`codex review` gate on the diff** (independent second model, pass/fail) before commit.
- Run full test suite, commit. Nothing else reviews cleanly on a dirty tree.

### Phase 1 — Reconcile the 07-06 checklist (~0.5 day, parallel agents)
For every Tier 0–4 item in `README.md`: verify the claimed fix against **current** code,
not the commit message. Tick, or reopen with evidence. Item → claiming commit map:

| 07-06 item | Claimed fixed by | Verified |
|---|---|---|
| T1: audio tap deep-copy, uncancellable post-processing, crash-recovery window (4 criticals) | `8f5299e` | ☐ |
| T1: paste force-cast crash, `applicationWillTerminate` | `cc557a6` | ☐ |
| T2: silent failures — paste, mic denial, screen-rec, shortcut, model DL, auto-summarize, nav rename | `3d97473`, `d46912a` | ☐ |
| T2: OpenRouter key dual-Keychain-account | `b85343a` | ☐ |
| T3: MCP token gate, Gemini key→header, Deepgram→Keychain, webhook JSON-escape | `d61f363` | ☐ |
| T3: App Sandbox go/no-go | CLAUDE.md notes trade-off — formalize in `03-security.md` | ☐ |
| T4: CLAUDE.md false claims | `6204f3c` | ☐ |
| T4: VoiceOver labels | `d46912a` (partial?) | ☐ |
| T4: NSUserNotification→UN, CGEvent tap re-enable, clipboard clobber/Universal Clipboard, ConcurrencyDesign.md drift | **unclaimed — likely still open** | ☐ |

- Output: this table completed + checkboxes updated in `README.md`; reopened items feed
  Phase 6.

### Phase 2 — FULL code review + test pass (1 day + 1 overnight run; lenses + Codex)
Whole codebase, not just the delta: all 21 `Sources/` modules, `MCP/` target, SkillPack
loader, all `Tests/` targets. Same method as 07-06 (independent lenses, adversarial
re-verification of every CRITICAL/HIGH) — post-07-06 surface gets priority depth.

**Execution mode: overnight autonomous run** (adapted from Philipp's overnight prompt):
- Component-by-component sweep, per component: map public surface/callers → hunt defect
  classes (dead code, duplicated logic, uncovered error paths, missing nil-checks, retain
  cycles, MainActor violations, force-unwraps in prod paths, **secret leakage in logs**)
  → **write/extend behavior tests for uncovered paths** → run tests → fix or log.
- Mechanical, obviously-correct fixes: committed immediately — small single-concern
  commits, `[REVIEW]` prefix, on branch `claude/overnight-review-<date>`. Judgment calls:
  logged, not fixed.
- Every commit: `xcodebuild build` + `test` green (with `DEVELOPER_DIR=` prefix — repo
  convention). No public-API signature changes. No app launches (TCC tax — unit tests via
  headless host only; runtime verification is Phase 4).
- Stop conditions: 3 consecutive same-kind failures, or 30 min zero progress → `STOPPED.md`.
- End state: branch pushed, **draft PR** with summary as description, no merge.
- Sleep guard ON for the run (lid-closed), restored after.

**Deliverables** (under `docs/launch-review/overnight/` — one review home, not a new dir):
`SUMMARY.md` (severity-ranked) · `PER_COMPONENT.md` · `BUGS_FOUND.md` (found-not-fixed,
needs human judgment → Phase 6 input) · `TEST_COVERAGE.md` (before/after per file) ·
`OPEN_QUESTIONS.md` (ask-before-changing).

**Corrections vs the original overnight prompt:**
- ~~Read AGENTIC_PLAYBOOK.md~~ — doesn't exist (weekly-review prompt already notes this).
- ~~Move dead code to dead-code/~~ — conflicts with "don't touch project.yml": XcodeGen
  means removing a compiled file requires regen. Instead: flag in `BUGS_FOUND.md`, delete
  in Phase 6 with `xcodegen generate` + build verify.

**Claude lenses (parallel agents):**
- **Security** (`solay-security`): full-repo pass — Keychain/SecretsStore, all egress
  (Deepgram, AssemblyAI, LLM providers, integrations, Sparkle), MCP token gate, Import
  file-handling, new release.sh, webhook/JSON injection surfaces, secrets re-scan.
- **Swift/macOS correctness** (`swift-check`): all 21 `Sources/` modules — concurrency/
  MainActor, force-unwraps/casts, leaks, deprecated APIs, permission-flow lifecycles.
  Priority: Import queue, AppleSpeechClient fallback chain, WhisperKit rescue.
- **Architecture** (`solay-reviewer`): module boundaries, meeting vs import pipeline,
  LLM layer, storage, fallback-chain state machine, doc drift vs CLAUDE.md.
- **Quality checklist sweep**: file sizes >800, functions >50 lines, deep nesting,
  swallowed errors, magic numbers, dead code, TODO/FIXME inventory, test coverage map.
- **UX**: golden paths incl. Import, fallback visibility (does the user know which engine
  transcribed?), error surfacing in new flows.

**Codex cross-model pass (independent, runs alongside):**
- **`codex challenge`** on the highest-risk modules: meeting pipeline (Audio/Meeting/
  Storage), Paste/Accessibility, MCP server + token gate, release/update chain —
  adversarial "try to break it" mode.
- **`codex consult`** full-repo architecture opinion — the outside voice on structure.
- Merge step: Claude vs Codex findings cross-checked; agreement = high confidence,
  disagreement = re-verify by hand before it hits the checklist.

**Re-certify the 07-06 "genuinely good" list where code was touched since:**
- Sparkle **EdDSA fail-without-signature gate survived the release.sh rewrite** (+209
  uncommitted lines — the certification predates them).
- Kiros module still reference-quality after fanout/import changes.
- Audio HAL teardown still correct after the 8f5299e pipeline fixes.
- Git history still secret-free (re-scan through HEAD).

- Output: `06-full-review.md` + new blockers appended to checklist.

### Phase 3 — Signing + notarization (Philipp action — START DAY 1, gates Phase 4)
- Enroll Apple Developer Program ($99/yr; approval can take 24–48 h → kick off before
  anything else).
- Then: `scripts/setup-notarization.sh`, set `SW_DEVELOPER_ID` + `SW_NOTARIZE_PROFILE`,
  fill `DEVELOPMENT_TEAM` in `project.yml`. Code path already built; this is paperwork.
- Verify: `spctl -a -vv` passes on a fresh DMG download; permissions survive an update.

### Phase 4 — Live QA on the SIGNED build (~0.5–1 day; blocked by Phase 3)
Prior review was zero-launch; signed build ends the TCC re-prompt tax that forced that.
**This doubles as runtime proof of every Tier 1/2 fix** — items 1–3 below deliberately
exercise them (denial paths, paste visibility, kill-mid-processing, offline transcript).
Clean user account (or VM), scripted checklist, one session:
1. First-run onboarding: every permission grant + every **denial** path (degradation, not silence).
2. Dictation × engines: Apple Speech (incl. Siri/Dictation-OFF regression → WhisperKit
   rescue), WhisperKit, Deepgram. Paste via Accessibility; paste-failure visibility.
3. Meeting E2E: mic + system audio → stitch → transcribe → diarize → summary → fanout.
   Kill-app-mid-processing recovery. Offline transcription path.
4. Import: drag-and-drop, sequential queue, full pipeline.
5. Integrations: Kiros, Hermes, Obsidian, custom webhook (quote-in-speech escaping).
6. MCP: token gate enforced, Claude Desktop reads transcripts.
7. Sparkle: real update v0.7.4 → v0.7.5-signed; permissions persist after update.
8. OCR/snip, translate, modes switching (never live-tested).
- Output: `07-qa-results.md`. I write the script; grants need Philipp at the keyboard.

### Phase 5 — Release rehearsal + launch collateral (~0.5 day, parallel with 4)
- `SW_DRY_RUN` release.sh pass; appcast EdDSA + min-OS validation; changelog/version.
- Launch assets: privacy policy (app records third parties — needed), landing page/README,
  support channel.
- Document App Sandbox go/no-go decision (open since 07-06).
- Decide: professional pen test before or after public launch (07-06 review flagged it).

### Phase 6 — Fix loop + go/no-go
- Inputs: Phase 1 reopened items, `BUGS_FOUND.md` + `OPEN_QUESTIONS.md` from the overnight
  run, Phase 4 QA failures. Merge/review the `claude/overnight-review-*` draft PR first.
- Triage: CRITICAL/HIGH = fix + re-verify; MEDIUM = judgment call; LOW = fast-follow list.
- Dead-code deletions happen here (with `xcodegen generate` + build verify).
- Exit criteria: ☐ zero open CRITICAL/HIGH ☐ notarized DMG passes Gatekeeper on a clean
  machine ☐ Phase 4 checklist 100 % pass ☐ update-from-previous-version works ☐ privacy
  policy live.

## Sequencing

```
Day 1:     Phase 3 enrollment (Philipp, async) ──────────────┐
           Phase 0 (+codex gate) → Phase 1                   │
Night 1:   Phase 2 OVERNIGHT RUN (sweep+tests+[REVIEW] fixes │
           ∥ codex challenge/consult) → branch + draft PR    │
Day 2:     Review/merge overnight PR → Phase 6 triage of     │
           BUGS_FOUND + Phase 1 reopens · Phase 5 collateral │
Day 3-4:   ├── Apple approval lands ─────────────────────────┘
           Phase 3 finish → Phase 4 signed QA → Phase 6 → GO
```

**Total: ~3–4 focused days + 1 overnight** + Apple enrollment latency. Philipp-only items:
enrollment, payment, TCC grants during QA, pen-test decision, privacy-policy hosting.
