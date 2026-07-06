# Security Review — SolWhisper Public Launch

Static audit of the working tree on `feat/kiros-integration`. No app launches, no live
requests. Findings verified against code; one third-party-agent claim was **rejected as a
misread** and is documented at the bottom so it doesn't resurface.

## Posture summary

- **Secrets storage:** mostly Keychain (`KeychainStore`, `kSecAttrAccessibleAfterFirstUnlock`),
  **except** the Deepgram key, which is plaintext `UserDefaults` (H2 below).
- **Git history:** clean. No live secret patterns (`sk-…`, `AKIA…`, `ghp_…`, `xox[bp]-…`,
  private keys) in history or the working tree. `Resources/local-secrets.json` is gitignored and
  is **not** bundled into the built app (verified the build product). Only the `.example` stub
  with `YOUR_*` placeholders is tracked.
- **Sparkle update chain:** correctly EdDSA-signed. `SUPublicEDKey` present; `release.sh` fails
  loudly (`exit 1`) if signing can't produce a signature. This is the **strongest** control in the
  stack. No RCE found here.
- **No App Sandbox** (H4) and **unnotarized ad-hoc default** (B1) are the two structural gaps.
- TLS: no `NSAllowsArbitraryLoads`, no TLS-bypass code. All egress is HTTPS except opt-in
  `http://localhost:11434` (Ollama loopback) and whatever scheme a user types into a webhook field.

## Egress map (verified against code)

| Endpoint | Data leaving the machine | Auth | When |
|---|---|---|---|
| `wss://api.deepgram.com/v1/listen` | Live mic PCM16 (dictation) | `Authorization: Token` header | Deepgram STT selected |
| `api.deepgram.com/v1/listen?diarize=true` | **Full meeting audio (all participants)** | `Authorization: Token` header | Deepgram diarization |
| `api.assemblyai.com/v2/upload`,`/v2/transcript` | **Full meeting audio (all participants)** | `authorization` header (Keychain) | AssemblyAI diarization |
| `api.openai.com`, `api.anthropic.com`, `api.groq.com`, `openrouter.ai` | Transcript/summary text as LLM prompt | Bearer / `x-api-key` header | LLM polish/summary |
| `generativelanguage.googleapis.com/…?key=<KEY>` | Transcript/summary text **+ API key in URL** | **key in URL query** | LLM if Google selected (**H1**) |
| `http://localhost:11434` | Transcript/summary text | none (loopback) | Ollama selected |
| `kairos.solay.cloud` (user-set `kirosURL`) | LLM-extracted task titles/descriptions + meeting id/title (not raw transcript) | Bearer token (Keychain) | Kiros filing, if enabled |
| user-set Hermes URL | Full transcript + summary + metadata (JSON-escaped, safe) | optional HMAC (Keychain) | Hermes, if enabled |
| user-set custom webhook URL | Full transcript + summary via **unescaped string template** | optional HMAC + user headers | Custom webhook, if enabled (**H3**) |
| `raw.githubusercontent.com/…/appcast.xml` + GitHub release DMG | none (GET) | EdDSA-verified enclosure | Sparkle update |

---

## HIGH

### H1 — Google Gemini API key transmitted as a URL query parameter
`Sources/LLM/GoogleClient.swift:36` — **verified**
```swift
guard let url = URL(string: "\(Self.baseURL)/\(model):generateContent?key=\(apiKey)") else {
```
Every other provider puts the credential in a header. Keys in URLs land in proxy/MITM logs
(Charles, corporate egress boxes, mitmproxy — common on managed machines) and provider-side access
logs. **Fix:** switch to Google's documented `x-goog-api-key` header.

### H2 — Deepgram API key in plaintext UserDefaults (every other secret is in Keychain)
`Sources/Transcription/TranscriptionController.swift:131`, `Sources/Diarization/DeepgramDiarizer.swift:16`, `Sources/Onboarding/OnboardingView.swift:21` — **verified**

`deepgramApiKey` is `@AppStorage`/`UserDefaults`, readable in cleartext from
`~/Library/Preferences/cloud.solay.SolWhisper.plist` by any process running as the user (no sandbox
— see H4), and recoverable via `defaults read` / Time Machine / any plist backup. `seedLocalSecrets`
(`AppDelegate.swift:407`) even seeds it there. It's a paid third-party key → exposure enables billing
abuse. Every other key (OpenRouter, Anthropic, OpenAI, Google, Groq, AssemblyAI, Hermes, Kiros,
custom-webhook HMAC) is correctly in Keychain. **Fix:** migrate to Keychain reusing the OpenRouter
Sprint-0 migration pattern (`SecretsStore.migrateFromUserDefaultsIfNeeded`).

### H3 — Custom-webhook payload does unescaped interpolation of transcript into JSON
`Sources/Integrations/MustacheRenderer.swift:11-18`, `Sources/Integrations/CustomWebhook.swift` (`defaultTemplate`) — **verified, ships**

`MustacheRenderer.render` is raw `replacingOccurrences` with the doc comment "no escaping rules —
values pass through verbatim." The default template embeds transcript inside a JSON string literal:
`"transcript": "{{transcript_markdown}}"`. Any transcript containing `"`, `\`, or a newline (constant
in real speech) breaks the JSON, and crafted speech from a meeting participant can inject sibling JSON
keys into the payload POSTed to the user's endpoint — a transcript-driven injection into an external
system. `HermesIntegration` avoids this via `JSONSerialization` (safe); the user-editable custom-webhook
path does not. Feature is wired (`CustomWebhookStore.shared`, IntegrationsSettingsView). **Fix:**
JSON-escape values before substitution, or route the custom-webhook body through `JSONSerialization`
like Hermes.

### H4 — No macOS App Sandbox
`Resources/SolWhisper.entitlements`, `project.yml` — **verified** (only audio-input, apple-events,
network.client; **no** `com.apple.security.app-sandbox`)

The running app can read/write everything the user can — no container jail. This is the OS layer that
would otherwise contain H2 (plaintext key), the transcript files, and the SkillPacks prompt-injection
surface (M3). For an app that records third-party audio and holds API keys, this is a deliberate
go/no-go, not a silent default — many "record your meetings" apps are sandboxed. **Fix:** evaluate
sandboxing with scoped entitlements (audio-input, apple-events, outgoing-network, security-scoped
bookmark for the user-chosen meetings/Obsidian folders). If infeasible near-term, document the decision
and compensate with Keychain-only secrets (H2).

---

## Launch blockers (ordered)

### B1 — Unnotarized, ad-hoc-signed builds are the current shipped default
`project.yml` (`DEVELOPMENT_TEAM=""`), `scripts/release.sh:158-201` — **verified**

`release.sh` only Developer-ID-signs + notarizes when **both** `SW_DEVELOPER_ID` and
`SW_NOTARIZE_PROFILE` are set; the default path is `codesign --force --deep --sign -` (ad-hoc). The
app's own release notes confirm this is production reality across 13 releases (v0.2.0–v0.7.1). Two
consequences for a public audience:
- **Gatekeeper does zero vetting.** Users must `xattr -cr` + right-click-open (the script even prints
  these instructions). A wide audience will not do this — it reads as "this app is broken/unsafe."
- **Every Sparkle auto-update changes the CDHash, silently revoking Microphone / Speech / Accessibility /
  Screen-Recording grants.** Users must re-grant 4 permissions on every update. (This is also the exact
  constraint that makes this review "don't relaunch the app" — it's a real user-facing tax.)

Not RCE (Sparkle EdDSA is enforced independently), but there is no Apple-vetted trust chain for a public
app that records third-party audio. **This is process, not code:** enroll in the Apple Developer Program,
then `SW_DEVELOPER_ID` + `SW_NOTARIZE_PROFILE` + `SW_TEAM_ID` become hard release prerequisites.
`scripts/setup-notarization.sh` already documents the steps. **This is launch blocker #1.**

### B2 — MCP server exposes all transcripts + dictation history to any local process, no consent
`MCP/MCPServer.swift`, `MCP/MCPTools.swift`, `MCP/MCPStorage.swift` — **verified: grep for
token/auth/consent/allowlist in `MCP/` returns nothing**

`solwhisper-mcp` is a stdio binary reachable by anything on the machine that can spawn a subprocess.
`list_dictation_history` returns `originalText`/`polishedText` for every past dictation (potentially
anything ever dictated — passwords, drafts); `get_meeting`/`search_transcripts` return full meeting
transcripts including third-party speech. No token, no allowlist, no in-app "Claude wants to read your
meetings" consent. Path traversal is **not** present (folder names resolve through UUID-validated
`loadMeeting(id:)` — good). This is a scope/consent gap, not a filesystem escape. **Fix before
advertising MCP as a public feature:** require a token the user copies from SolWhisper Settings (mirror
the Kiros/Hermes token pattern) and/or an in-app consent gate like `PrivacyDisclaimer` already does for
recording.

---

## MEDIUM

- **M1 — Sparkle appcast served from mutable `main` branch path (integrity rests solely on EdDSA).**
  `Info.plist:66-69`. HTTPS + `SUPublicEDKey` present + release.sh fails without a signature = correct.
  Residual risk is process-level: anyone who can push to `main` or hijack the release-builder's GitHub
  session can prepend an appcast item, but still needs the EdDSA **private key** (in the builder's
  Keychain, never in the repo) to make Sparkle accept it. **Recommend:** branch protection + required
  signed commits on `main`; move the EdDSA key to a hardware token / CI secret store as cadence grows.
- **M2 — User-writable SkillPacks dir loaded as trusted LLM prompt content.**
  `Sources/PostProcessing/SkillPackLoader.swift`. Any same-user process can drop a `SKILL.md` into
  `~/Library/Application Support/SolWhisper/SkillPacks/` and inject into the system prompt alongside the
  transcript — a local persistence+exfil chain (via the custom-webhook path) for malware already running
  as the user. High bar (needs local code-exec), but the missing sandbox (H4) means the app doesn't
  reduce that blast radius. Size-cap loaded skills; visually flag "custom" packs in Settings.
- **M3 — `PasteManager.paste` clobbers the system clipboard with no save/restore.**
  `Sources/Paste/PasteManager.swift:29-33`. Every dictation destroys the user's prior clipboard (a
  password, a copied path) with no snapshot/restore. Transcript content (incl. third-party meeting
  speech) also transits `NSPasteboard.general`, visible to Universal Clipboard (syncs to nearby Apple
  devices) and any clipboard manager. **Fix:** snapshot all pasteboard types before writing, restore
  after; mark transcript pastes `org.nspasteboard.ConcealedType`/`TransientType` to opt out of Universal
  Clipboard + clipboard managers.
- **M4 — Diarization/API error bodies passed into logs untruncated.**
  `DeepgramDiarizer.swift:47-50`, `AssemblyAIDiarizer.swift:62-107`. If a provider ever echoes request
  metadata/partial key on auth failure, it flows into `ErrorLogger`/`DebugLog` unfiltered. Cap length +
  scrub key-shaped patterns before logging.

## LOW

- **L1 — No secure-input-field awareness before text injection.** `PasteManager` (whole file). macOS's
  Secure Event Input already blocks CGEvent injection into password fields, so this is defense-in-depth:
  the app doesn't warn "you're about to dictate into a password field." Query `kAXRoleAttribute` before
  injecting; skip/warn on a secure field.
- **L2 — Kiros prompt-injection surface is well-contained (no action).** Transcript includes third-party
  speech, but `KirosTaskExtractor.validate` whitelists + length-caps every field before POST. Impact is
  bounded to "an attacker-influenced string appears as a task title in the user's own inbox." This is the
  right pattern.
- **L3 — appcast `minimumSystemVersion` = 13.0 but app floor is macOS 14.** `release.sh` NEW_ITEM
  template. A macOS 13 user could be offered an update that then fails `LSMinimumSystemVersion` at launch.
  Bump to 14.0.

---

## Rejected finding (documented so it doesn't resurface)

**"Transcript content printed to stdout regardless of debug-mode setting" — REJECTED (misread).**
`Sources/Debug/DebugLog.swift`. The claim was that `print(line)` (line 57) runs unconditionally. It does
not: `guard enabled else { return }` at **line 47** precedes it, so `print` only fires when the
`debugMode` UserDefault is on. Transcript segments do **not** reach stdout for normal users. The `!ok`
branch (lines 41-45) that routes to the on-disk `ErrorLogger` carries only error labels, not transcript
content, at the STT call sites. No transcript-to-disk/stdout leak exists via this path. No fix needed.

---

*AI-assisted scan (cso comprehensive + independent verification). Not a substitute for a professional
penetration test before a public launch that handles third-party audio.*
