# Philipp's Action List — items only you can do

Two of these gate the launch and have real-world latency. Start #1 **today**.

---

## 1. Apple Developer enrollment + notarization (START FIRST — 24–48h approval latency)

This is launch blocker #1 (the Gatekeeper wall + the permission-reset-on-update tax).
The *code* path is already built (`release.sh` signs+notarizes+staples when the env vars
are set). This is paperwork + waiting on Apple.

**Step 1 — Enroll ($99/yr, do this now, approval is async):**
- https://developer.apple.com/programs/enroll/ — enroll the Apple ID you'll ship under.
- Approval typically lands in 24–48h. Nothing downstream can finish until it does.

**Step 2 — After approval, create the signing cert:**
- https://developer.apple.com/account/resources/certificates/list → **+** → **Developer ID
  Application** (NOT "Mac App Distribution" — we're not shipping via the App Store).
- Download the `.cer`, double-click to import into Keychain Access.

**Step 3 — App-specific password for notarization:**
- https://appleid.apple.com → Sign-In and Security → App-Specific Passwords → generate one,
  label it "SolWhisper notary". Copy it.

**Step 4 — Run the setup helper (already in repo):**
```bash
./scripts/setup-notarization.sh
```
It finds your cert, asks for your Apple ID + the app-specific password, stores a Keychain
profile, and prints three `export` lines. Add them to your shell rc / `.envrc`:
```bash
export SW_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export SW_NOTARIZE_PROFILE="SolWhisperNotary"
export SW_TEAM_ID="TEAMID"
```

**Step 5 — Fill the team ID in project.yml** (currently `DEVELOPMENT_TEAM: ""`):
set it to your Team ID, then `xcodegen generate`.

**Step 6 — Verify (the real acceptance test):**
```bash
./scripts/release.sh <next-version>          # signs + notarizes + staples
spctl -a -vv /path/to/SolWhisper.app          # must say "accepted / Notarized Developer ID"
```
On a *clean* Mac (or fresh user account), the notarized DMG must open without the
right-click-Open dance, and a Sparkle update from the previous version must NOT reset TCC
permissions. That's the whole point of this blocker.

---

## 2. Privacy policy hosting (required before public launch)

The app records third-party audio (meetings) and sends transcript text to cloud providers
(Deepgram/AssemblyAI STT, your chosen LLM). A public launch needs a privacy policy live at a
stable URL, linked from onboarding/site. I've drafted one at
`docs/launch-review/overnight/PRIVACY-POLICY-DRAFT.md` — review, adjust to what's true for
your deployment, and host it (GitHub Pages / your site). **Your call: where it lives.**

---

## 3. Pen-test decision (judgment call)

The 07-06 review flagged that an AI-assisted review is "not a substitute for a professional
penetration test before a public launch that records third-party audio." Decide: pen test
**before** launch (safer, slower, costs money) or **fast-follow after** a soft/limited launch.
No wrong answer — but it's yours to make. My recommendation: soft-launch to a small waitlist
first, pen-test in parallel, then open wide.

---

## 4. During QA (Phase 4) — you at the keyboard

Live QA needs TCC permission grants (mic, screen recording, accessibility, etc.) that only a
human at the physical machine can approve. When the signed build is ready, I'll drive the
scripted checklist in `QA-CHECKLIST.md`; you grant/deny permissions when prompted and confirm
what you see on screen. ~30–45 min, one session.
