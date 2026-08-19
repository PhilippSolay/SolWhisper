# Phase 4 — Live QA Checklist (signed build, clean account)

**Precondition:** notarized build from Phase 3, installed on a **fresh macOS user account**
(or VM) that has never run SolWhisper — so every TCC prompt fires for real. I drive; Philipp
grants/denies permissions and confirms on-screen results. ~30–45 min.

This is the **first-ever runtime test** of the app — every fix since 07-06 was static-only.
Items tagged `[verifies Xn]` exercise a specific ledger finding.

## 0. Install & Gatekeeper
- [ ] DMG opens without right-click-Open dance (notarization worked). `spctl -a -vv` = accepted.
- [ ] App launches, menu-bar icon appears, no crash.

## 1. Onboarding + permission GRANT paths
- [ ] Walk onboarding; shortcut shown = **⌃⌥⌘R** (not ⌥⌘R). `[verifies U-onboarding]`
- [ ] Grant mic, speech, accessibility, screen-recording as prompted. Each prompt has a clear purpose string.

## 2. Permission DENIAL paths (the silent-failure fixes)
- [ ] Deny microphone → dictation shows a visible, actionable error (not a stuck "listening" pill). `[verifies U2]`
- [ ] Revoke Accessibility, dictate → text appears on-screen "on your clipboard, press ⌘V" overlay, not silence. `[verifies U1]`
- [ ] AX granted but Automation denied, dictate into a browser field → **is failure visible?** (ledger U1: suspected still-silent — CONFIRM.)
- [ ] First-time speech denial at system prompt → is there guidance, or silent stop? (ledger U2 gap — CONFIRM.)

## 3. Dictation × engines + the paste confidentiality risk
- [ ] Apple Speech dictation → polished text pastes into the focused app.
- [ ] **Siri + Dictation OFF** in System Settings, dictate → WhisperKit rescue: interim "(transcribing offline…)"
      then real text. `[verifies STT rescue a813ae5]`
- [ ] Same, with **no WhisperKit model downloaded** → actionable error naming Settings → Models (not a dead pill).
- [ ] WhisperKit engine + Deepgram engine each produce text.
- [ ] **X2 wrong-app paste:** dictate a sentence, then Cmd-Tab to a DIFFERENT app right as it finalizes →
      does text land in the ORIGINAL app or the newly-focused one? (ledger X2 HIGH — if it pastes into the wrong
      app, that's a confirmed confidentiality bug.) `[verifies X2]`
- [ ] **Clipboard clobber:** copy something valuable, dictate → after paste, is your original clipboard restored?
      (ledger T3/X4 — expected NO; confirm severity.) `[verifies T3]`

## 4. Meeting pipeline E2E (the data-integrity core)
- [ ] Record a 2-min meeting with system audio (play a video) → mic + system both captured, both speakers in transcript.
- [ ] **X3 chunk rotation:** record **>2 min** (forces multiple 30s rotations) → full transcript, not just first 30s.
      Check `~/Library/Application Support/SolWhisper/<meeting>/chunks/` for orphaned `.tmp` files. `[verifies C2/X2]`
- [ ] Auto-summary appears on a fresh install (default ON). `[verifies U6]`
- [ ] **U3 mic-only:** disable Screen Recording, start meeting → warned before recording; is the resulting meeting
      marked mic-only anywhere visible? `[verifies U3]`
- [ ] **U4 offline:** turn off wifi, first meeting (no model yet) → is there download progress + a visible error,
      or an endless spinner? `[verifies U4]`
- [ ] **X1 disk-full:** (if feasible) fill disk / revoke folder perms at meeting start → does it report failure,
      or silently mark an empty meeting complete? `[verifies X1]`
- [ ] **C1 quit-mid-dictation:** dictate a paragraph, ⌘Q before pressing Stop → is the text preserved (history/paste)
      or lost? (ledger C1 HIGH — expected LOST; confirm.) `[verifies C1]`
- [ ] Kill app (Force Quit) mid-recording → relaunch → crash-recovery offers the meeting.
- [ ] Kill app mid-**post-processing** (after transcript, before summary) → relaunch: is summary retried or dropped? `[verifies C3]`

## 5. Import
- [ ] Drag 2–3 audio files → sequential queue processes them; per-file progress visible.
- [ ] Drop an unsupported file → clear rejection message, queue continues.
- [ ] Quit mid-import → relaunch behaves sanely (no zombie).

## 6. Translate
- [ ] Translate to a pack-not-installed language → deep-links Settings → Languages, download visible, text not lost. `[verifies translate deep-link]`
- [ ] **P0-CODEX:** translate FROM an uninstalled non-English source INTO English → does it download the RIGHT pack
      (the source), or wrongly try English→English and get stuck? (codex HIGH regression — CONFIRM.) `[verifies P0-CODEX]`
- [ ] Farsi (llmFallback) with an LLM configured → routes to AI model; without one → actionable error.

## 7. Integrations + MCP
- [ ] Configure a custom webhook, dictate text containing a `"` quote → payload well-formed (no broken JSON). `[verifies webhook escaping]`
- [ ] Kiros / Obsidian (whichever you use) receives a summary.
- [ ] MCP: point Claude Desktop at solwhisper-mcp with the token → reads transcripts. Without the token → denied. `[verifies MCP gate]`

## 8. Sparkle update (the notarization payoff)
- [ ] From an installed previous version, trigger update → downloads, installs, relaunches.
- [ ] **After update, TCC permissions PERSIST** (not reset). This is the whole point of notarization. `[verifies notarization]`

## 9. OCR / snip, modes, misc (never live-tested)
- [ ] OCR snip captures + copies text.
- [ ] Mode switching works via menu + shortcut.

---
**Record results in `QA-RESULTS.md`** — each item PASS/FAIL + note. FAILs feed the Phase 6 fix loop.
Any CONFIRMED ledger HIGH (C1, X1, X2, X3, P0-CODEX) that reproduces = launch blocker.
