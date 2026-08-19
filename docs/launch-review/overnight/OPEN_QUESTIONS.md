# OPEN_QUESTIONS — decisions I'd want from Philipp before changing

## ✅ RESOLVED (Philipp, 2026-07-13) — applied on the review branch
1. **Translate consent** — not raised; kept label-and-proceed (badge shows "Sent to {provider}").
2. **Quit-mid-dictation → DISCARD.** Reverted the salvage-to-history fix; ⌘Q mid-dictation discards (a
   half-finished take isn't worth persisting). `applicationWillTerminate` back to `cancel()`.
3. **Wrong-app paste → BEST-EFFORT.** Changed from abort to: re-activate the target and retry once on focus
   loss; only fall back to clipboard if it still won't come forward.
4. **Beta installer → confirmed dev/tester only.** Added a "NOT FOR PUBLIC RELEASE" header to
   `installer.applescript`; public path stays the notarized drag-DMG.
5. **Chunk-size setting → REMOVE PICKER, keep hardcoded 30s.** Deleted the inert control + its `@AppStorage`.
6. **Voice Translate engine picker → DELETE.** Removed the dead picker + `VoiceTranslateController.translate`/
   `engineKind`/`engineDefaultsKey` + the dead registered default + the tests that covered them. VT now
   transparently uses the shared translate engine (`TranslationEngineKind.current`).
7. **Pen test → SOFT LAUNCH first**, pen-test in parallel/after. No code.
8. **Supply chain → LATEST-MATCHING.** Not pinning `Package.resolved` / model revisions. No code (left as-is).
9. **Dead-code deletions** — not raised; the 5 zero-ref functions remain listed in BUGS_FOUND for a later
   cleanup pass (kept out of the launch diff).

---

*(original questions below, for the record)*

These are judgment calls where I stopped rather than guess. Each affects how a Phase 6 fix is done.

1. **Translate fallback — is silent cloud routing intended at all?** The Farsi-style path sends text to the user's
   LLM without an explicit opt-in for *that translation*. The B-1 fix makes it honest ("Sent to {provider}"), but
   do you want it to (a) label + proceed, or (b) require a one-time "OK to translate unsupported languages via your
   AI model?" consent? (a) is less friction; (b) is safer for a privacy-positioned launch.

2. **Quit-mid-dictation (H-1) — persist to history, or paste, or both?** On ⌘Q with dictation in flight, should the
   text be (a) saved to dictation history only, (b) also pasted into the focused app, or (c) just history + a
   notification? Pasting during termination is racy; I'd default to (a)+notification unless you prefer otherwise.

3. **Wrong-app paste (H-2) — abort vs. best-effort on focus loss?** When the target app is no longer frontmost at
   paste time, abort-to-clipboard (safe, but the user must ⌘V) vs. re-activate the target and retry once (smoother,
   small mis-paste risk)? I lean abort-to-clipboard with the visible notice.

4. **Beta installer (Security M-1)** — confirm the `beta-dmg/installer.applescript` admin-bypass flow is dev/tester
   only and can be excluded from anything public. If testers rely on it, we need a notarized-DMG tester path instead.

5. **Chunk-size Setting (MED)** — the picker is currently inert (hardcoded 30s). Wire it up, or remove the control?
   30s is a reasonable fixed default; the setting may be vestigial.

6. **Voice Translate "Engine" Setting (MED)** — same question: wire `voiceTranslateEngine` into the bubble, or
   delete the dead picker + `VoiceTranslateController.translate`?

7. **Pen test timing** — before public launch, or after a soft/waitlist launch? (Also in PHILIPP-ACTIONS.md #3.)
   Recommendation: soft-launch small, pen-test in parallel, then open wide.

8. **Supply-chain pinning (LOW)** — commit `Package.resolved` and pin WhisperKit model revisions now, or accept
   latest-matching for launch? Pinning is safer but you lose auto-patch of the deps.

9. **Dead-code deletions** — the 5 zero-ref functions (BUGS_FOUND LOW) are safe to delete but touch `AppDelegate`,
   `MCPTokenStore`, `KeychainStore`, `OllamaClient`, `WhisperKitModelDownloader`. Delete in Phase 6, or leave for a
   dedicated cleanup PR to keep the launch diff tight?
