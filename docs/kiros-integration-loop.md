# Kiros integration — dev loop (SolWhisper side)

Goal loop. Paste the block below into Claude Code in `~/code/solwhisper`. It builds the
integration through milestones S0→S4 from `docs/kiros-integration-build.md`, against the
frozen Kiros contract in `Kiros/docs/solwhisper-ingest.md`.

```
TRIGGER: Manual — open Claude Code in /Users/philippsolay/code/solwhisper and paste this
loop. It runs continuously through milestones S0→S4 in one session.

GOAL: The SolWhisper-side Kiros integration is fully built and verified — `xcodebuild
test` is green for all new Kiros unit tests (models, client, extractor, integration), the
Settings UI exposes a working Kiros card, and a real end-to-end run files Philipp's
extracted tasks into Kiros (resending the same meeting dedupes) — all on a feature branch
with one atomic commit per milestone.

───────────────────────────────────────
INSPECT
───────────────────────────────────────
- Read state file /tmp/kiros-integration-loop.md. If absent, create it from the milestone
  list in docs/kiros-integration-build.md (S0–S4), each marked [TODO].
- Read docs/kiros-integration-build.md (build plan) and Kiros/docs/solwhisper-ingest.md
  (the FROZEN API contract — never edit it).
- Pick the next milestone not marked [PASS]. Read the code it mirrors: HermesIntegration,
  OutboundWebhook, KeychainStore, IntegrationFanout, IntegrationsSettingsView,
  SummaryGenerator, Summary.
- Confirm you are on branch feat/kiros-integration (not main) and that an XCTest target exists.

───────────────────────────────────────
ACTION  (one milestone per cycle; TDD)
───────────────────────────────────────
1. If on main, create branch feat/kiros-integration first.
2. Write the milestone's tests first (red), then the minimal implementation (green). New
   code under Sources/Integrations/Kiros/ and Resources/; tests in the test target. Run
   `xcodegen generate` after adding files (XcodeGen globs Sources/).
3. Scope changes to: Sources/, Tests/, Resources/, project.yml, docs/. Immutable structs,
   files <400 lines, validate every LLM/HTTP value at the boundary, bearer token via
   Keychain only (key kiros.bearerToken).
4. Unit tests use a mocked URLSession (URLProtocol) and a stubbed LLM returning recorded
   JSON fixtures — no live network or LLM in tests.
5. Self-review the diff against the project coding-style rules before committing.

───────────────────────────────────────
VERIFY  (fixed check — not your opinion)
───────────────────────────────────────
- S0–S3: `xcodebuild test -project SolWhisper.xcodeproj -scheme SolWhisper -destination
  'platform=macOS'` exits 0, the milestone's new tests are present and pass, AND the full
  suite stays green (no regressions). Record the test summary in the state file.
- S4: with sleep-guard on, launch the app, transcribe a sample meeting, and confirm the
  extracted "for-me" tasks appear in Kiros via the contract; then resend the same meeting
  and confirm the server reports duplicates (idempotency). If kairos.solay.cloud/api/ingest/*
  is unavailable/404 (backend not shipped yet), stand up a LOCAL MOCK server implementing
  the frozen contract and run the smoke against it — note which was used.
- On green: mark the milestone [PASS] with evidence, then `git commit` it atomically (no push).

───────────────────────────────────────
STOPPING CONDITIONS
───────────────────────────────────────
✅ STOP (success): state file shows S0–S4 all [PASS] with evidence; branch has one atomic
   commit per milestone; write VERDICT: COMPLETE at the top of the state file.

🔁 CONTINUE: the current milestone's gate is not yet green, or a fix may have regressed an
   earlier phase (re-run the full suite).

⏸ NO-OP STOP: state file already shows all milestones [PASS] and S4 verified — nothing to do.

🚫 ESCALATE (pause, ask Philipp):
- No XCTest target exists and creating one cleanly is non-trivial.
- The same milestone's tests fail 3 cycles in a row (can't reach green).
- The frozen contract is ambiguous/insufficient to implement a field.
- S4: real endpoint down AND a local mock can't be stood up; or tasks don't land / don't
  dedupe after one fix attempt; or a TCC permission dialog blocks the unattended launch
  (the unsigned build re-prompts on launch — notify Philipp so he can grant, then continue).
- Any needed change falls outside Sources/, Tests/, Resources/, project.yml, docs/.

❌ NEVER:
- Modify the Kiros repo, its backend, or the frozen contract doc.
- Push to a remote, open a PR, or merge.
- Commit the bearer token or any secret (Keychain only).
- Edit CLAUDE.md, ~/.claude memory, or settings.json.
- Make live LLM or live network calls inside unit tests.
- Work on main, or leave sleep-guard enabled after S4 (always run
  `sudo pmset -a disablesleep 0` when S4 finishes).

───────────────────────────────────────
HANDOFF
───────────────────────────────────────
- Branch feat/kiros-integration with ~5 atomic commits (S0–S4), no push.
- State file /tmp/kiros-integration-loop.md: goal, per-milestone status + evidence (test
  summaries, S4 task IDs), fixes made, blockers, and the final VERDICT.
```

─── LOOP NOTES ─────────────────────────────────────

Type: Goal loop (sequential milestones, deterministic test gates).

Run in: Claude Code. Command: `cd ~/code/solwhisper && claude` — then paste the block.

Budget: ~40 cycles max, or stop on no-progress (a milestone failing its gate 3× →
escalate). Clean run ≈ 5 productive cycles (one per milestone).

First-run tips:
- If SolWhisper has no XCTest target yet, the loop flags it at S0 — confirm how you want
  tests wired before it builds the harness.
- Put the staging bearer token in Keychain (key `kiros.bearerToken`) before S4, or S4
  falls back to a local mock.
- S4 reality check: the unsigned build re-prompts TCC permissions on launch (~5×), and
  those dialogs need a human click. "Fully autonomous incl. S4" will reach the launch and
  then notify you to grant them — plan to be at the keyboard for S4.
