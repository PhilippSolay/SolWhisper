# SolWhisper Future Roadmap

**As of:** 0.4.0-alpha.4 (May 2026)
**Source documents reviewed:** [MEETING-FEATURES-PLAN.md](./MEETING-FEATURES-PLAN.md), [OCR-FEATURES-PLAN.md](./OCR-FEATURES-PLAN.md), [V0.4-TEST-PROTOCOL.md](./V0.4-TEST-PROTOCOL.md)
**Companion:** [EXPLORATION.md](./EXPLORATION.md) — research notes, reasoning, and pushback for future-leaning ideas (STT Agent, wake word, transcripts→agents, F4 takeover).

This document is the single forward-looking source of truth. Anything called
"v0.5" in code comments or settings copy is enumerated here. Items are grouped
by **release target** and within each release by **priority** (P0 = blocks
release, P1 = should-have, P2 = nice-to-have).

---

## v0.4.0 GA — Polish & ship the alpha

Goal: take alpha.3 to a public-ready GA build.

### P0 — Release-blocking (still open)

- [ ] **Apple Developer notarization** — `scripts/release.sh` + `plans/RELEASE.md`
      are turnkey; export `SW_DEVELOPER_ID` / `SW_NOTARIZE_PROFILE` / `SW_TEAM_ID`
      and run. Pending the actual Developer ID Application cert.
- [ ] **Sparkle EdDSA-signed appcast** — `scripts/generate-sparkle-keys.sh`
      ready; release.sh prepends to `appcast.xml` and signs each DMG. Needs
      one notarized release pushed to GitHub to verify the end-to-end auto-update
      flow on a tester Mac.
- [ ] **TCC permission stability across CDHash changes** — directly blocked
      on notarization landing.

### P0 — Done

- [x] **Release flow documented** — `plans/RELEASE.md` covers ad-hoc + notarized
      paths, env vars, troubleshooting, and a printable checklist.
- [x] **First-launch onboarding pass** — verified the existing 7-step flow still
      runs cleanly. Alpha.3 controls (launch-on-login, retention, OCR auto-detect,
      additive clipboard, error logging) all have safe defaults so they don't
      need to be in the onboarding sheet.

### P1 — Done in alpha.4

- [x] **`audioPlaybackOnRecord = "lower"` mode** — implemented via Core Audio
      HAL `kAudioDevicePropertyVolumeScalar` on the default output device.
      Saves current volume → ducks to 20% → restores on stop. Best-effort
      (no-ops for HDMI/external DACs that don't expose software volume).
- [x] **Models redesign Phase 2** — direct `AnthropicClient`, `LLMResolver`,
      routing pickers list `ConfiguredModel`s, dictation polish path
      resolver-driven. OpenAI/Google/Groq direct clients deferred to v0.5
      (route through OpenRouter for now).
- [x] **Error-log bridging** — `DebugLog.log(...)` now mirrors any `ok: false`
      entry to `ErrorLogger.shared.log` regardless of debug-mode state, so
      testers always get a durable error trail.
- [x] **Hotkey defaults decision** — keeping `⌃⌥⌘R / M / P / O / T` as
      shipped defaults, NOT shipping unset. Plans/MEETING-FEATURES-PLAN.md
      §2.2 and OCR-PLAN decision #1 are updated to acknowledge defaults
      are intentional (most users prefer working hotkeys to a blank slate;
      they can rebind in Settings → Hotkey).

### P1 — Punted to v0.5 (with UI honesty)

- [ ] **`audioAutoIncreaseVolume` (AGC)** — would need a tap shim in front of
      every STT client (Apple Speech, Deepgram, WhisperKit). Risk of degrading
      transcription if poorly tuned. Removed from Audio settings UI in
      alpha.4 to stop misleading testers; lives in v0.5 with a real DSP pass.
- [ ] **`audioSilenceRemoval`** — same reasoning. Removed from Audio settings
      UI in alpha.4. v0.5 will ship a leading-silence trim plus per-segment
      gating that doesn't risk eating quiet speech.

### P2 — Done in alpha.4

- [x] **Help tooltips** added to all five alpha.3 controls (launch-on-login,
      error-logging, keep-recordings-for, OCR language picker + auto-detect,
      additive-clipboard + clear-on-paste).

### P2 — Punted

- [ ] **`AppleSpeechClient` `@MainActor` audit** — internal cleanup, no user
      visibility. Moved to "Tech debt & internal cleanup" section below.

---

## v0.5 — Smarter routing, real partials, full skill UX

Goal: make SolWhisper feel like a finished product, not a power-user toolkit.
Theme: **resolve the "scaffold vs. real" gap**.

### Models Phase 2 — direct provider routing

Phase 1 (alpha.2) shipped the `ModelStore` data model + Add Model sheet UI.
Phase 2 makes those configured models actually drive transcription.

- [ ] **Direct provider clients** — `AnthropicClient`, `OpenAIClient`,
      `GoogleClient`, `GroqClient` behind the existing `LLMClient` protocol.
      OpenRouter stays as a meta-provider; Ollama already works.
- [ ] **Routing reads from `ModelStore`, not `openRouterModel` UserDefault** —
      the dictation cleanup, meeting cleanup, and meeting summary pickers
      currently store provider name strings (`openrouter` / `ollama`) in
      `dictationLLMProvider`, `cleanupLLMProvider`, `summaryLLMProvider`.
      Migrate these to store a `ConfiguredModel.id` (UUID).
- [ ] **Migrate legacy keys** — `openRouterModel`, `summaryOpenRouterModel`,
      `customOpenRouterModelsCSV` → on first launch, synthesize a
      `ConfiguredModel(provider: .openrouter, modelID: <legacy>)`, point
      the role pickers at its UUID, then delete the legacy keys. Add a
      one-shot migration flag like `modelStoreMigratedFromUserDefaults`.
- [ ] **Favorite (★) actually means "default"** — `ConfiguredModel.isFavorite`
      is currently visual only (`ModelStore.swift:100`). Wire it as the
      default selection when a role's explicit pick is missing or the
      pinned model has been deleted.
- [ ] **"+ Add custom model" non-stub** — the v0.5 stub ref in
      `ModelsSettingsView.swift:5` becomes a fully editable URL/header form
      via the existing `ModelProvider.custom` enum case (which already has
      no presets and opts out of API-key requirement).

### WhisperKit live partials (mode A)

- [ ] **Streaming pipeline** — `WhisperKitClient.swift:22` documents the
      v0.4 limitation. WhisperKit's streaming API needs the rolling buffer
      + partial decoding to match the live transcript bubble we already
      ship for Apple Speech and Deepgram.
- [ ] **Pill UI** — show in-progress text in the bubble during recording,
      not only after stop.

### Skill editor UI

Phased: a small flat-skill editor lands in alpha.5; the full pack editor
lands in v0.5 GA proper.

**Phase A — Flat-skill editor** (alpha.5, ~200 LOC):
- [ ] **Add / edit / delete user skills** via a SwiftUI form: id, name,
      description, prompt template, output template, default model override.
- [ ] Persists each skill to `~/Library/Application Support/SolWhisper/Skills/<id>.json`
      (existing user-skills folder; loader already picks them up).
- [ ] Doesn't touch the meeting-summary pack at all — that stays read-only
      built-in. Useful for users who want their own quick summarizer.
- [ ] "Reload skills" button on the registry already exists; the editor
      writes a file then calls `registry.reload()`.

**Phase B — Pack editor** (v0.5 GA, multi-day):
- [ ] **List + reorder + edit pack types** — for any user pack (the
      meeting-summary built-in stays read-only; users can duplicate it
      to a user pack to edit).
- [ ] **Per-type form**: name, description, body Markdown, frontmatter.
- [ ] **Pack creation**: scaffold a new pack with parent + shared/ +
      types/ skeleton. Validate against `SkillPack` schema before save.
- [ ] **Custom declarable form fields** — `Skill.swift:8` defers the
      original §3.5 design (variables/slots in the prompt template).
      Reintroduce as the editor matures.
- [ ] **Per-skill default model override** — let a skill say "always use
      claude-opus" regardless of the role-level routing.
- [ ] **Drag-drop `.zip` installer** for new skill packs (Settings →
      Skills → Install pack).
- [ ] **Export to ~/Library** — duplicate a built-in pack into the user
      packs folder so it can be edited freely.

### Diarization / better speaker tagging

- [ ] **Real diarization** — current `[Me]/[Other]` is channel-based
      (mic vs. system). Wire `pyannote.audio` or Apple's
      `SFSpeechRecognizer` speaker labels (macOS 14+). Plan §11 spec.
- [ ] **Per-app system-audio capture** — `SystemAudioCapture` currently
      grabs all-system audio; ScreenCaptureKit supports per-app filters.

### Audio quality (Sprint 4b finishing pass)

- [ ] **DeviceMonitor full BT/USB hot-swap flow** — alpha.2 already
      monitors the listener; v0.5 adds the user-facing prompt
      ("New mic detected — switch?") and handles mid-recording switch.
- [ ] **Dual-meter pill UI** — separate mic + system meters during meetings;
      v0.4 ships single waveform.
- [ ] **Mid-call mic switch** — pairs with DeviceMonitor.
- [ ] **Auto mic-volume normalization (AGC)** — peak-normalize mic input
      before STT, capped at +6dB to avoid distortion. Was an alpha.3 toggle
      that did nothing; UI removed in alpha.4 until the real DSP ships.
- [ ] **Silence removal** — leading + trailing silence trim before STT
      (-50dB, 0.3s+ window). Was an alpha.3 toggle that did nothing; UI
      removed in alpha.4 until the real implementation lands.

### Integrations

- [ ] **Generic webhook editor UI** — `OutboundWebhook` infrastructure
      already works (used internally by Hermes); expose multi-webhook
      management UI in Settings → Integrations.
- [ ] **Failed-send retry queue** — durable disk-backed queue with
      exponential backoff. v0.4 logs failures to DebugLog only.

### Crash recovery — full restitch

- [ ] **End-to-end orphan recovery** — Sprint 4a stub flags + logs.
      v0.5 finishes by re-running the chunk stitcher + post-processing
      pipeline on recovered orphans without user interaction.

### Home stats — real data

- [ ] **`HomeStats` real wiring** — `HomeSettingsView.swift:6` flags this
      as scaffolded. Wire all four tiles (WPM, Words this week, Apps used,
      Saved this week) to `DictationHistoryStore.entries` + meeting
      durations. The math is straightforward; just hasn't been done.

### Transcripts window

- [ ] **Manual "Summarize" / "Resummarize" button** — auto-summarize on
      stop ships in v0.4; manual trigger still missing.
- [ ] **Export / share UI** — `TranscriptsRootView.swift:94` shows
      "Coming in v0.5" placeholder. Export to .txt / .md / .pdf,
      share to Apple Notes / Mail / paste destination.
- [ ] **Dictation history replay** — re-paste, re-polish a past dictation.

---

## v0.6 — Workflows & power-user features

Goal: durable workflows, not just one-shot dictation/recordings.

- [ ] **Modes system** (per `CLAUDE.md`) — context-specific transcription
      behavior. Mode = preset of (output formatting + AI Polish rules
      + custom vocabulary subset + skill mapping). Switch via tray /
      hotkey.
- [ ] **Per-app mode rules** — "When I'm in Slack, use the chat mode;
      when I'm in Notes, use long-form."
### Agent access to transcripts (to explore — replaces the prior one-line "MCP server integration")

Make SolWhisper's transcript store reachable from Claude Desktop, Claude Code,
Cursor, Zed, Codex, ChatGPT, and other agents. Mental model: **pull** (agent
reaches in) vs **push** (SolWhisper reaches out). Ship at least one of each.
Multiple options below; not all will ship — captured here so the choice is
deliberate. `CLAUDE.md` previously flagged "MCP server integration" as P1;
this section supersedes that.

**Pull paths**

- [ ] **Local MCP server** (recommended headline integration). Use the
      official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk).
      Two transport options — pick HTTP/SSE on a fixed localhost port +
      bearer token for the easiest install (one config snippet, supported
      by Claude Desktop / Cursor / Zed / most newer clients), or stdio via
      a sidecar CLI in `Contents/MacOS/solwhisper-mcp` (matches every
      existing MCP install flow but adds moving parts and XPC/socket
      plumbing back to the running app). Tools: `list_recent_transcripts`,
      `search_transcripts`, `get_transcript`, `get_meeting_summary`, and
      resources (`solwhisper://transcripts/recent`, `solwhisper://transcripts/{id}`)
      for auto-context injection. Settings pane shows port, token,
      copy-paste config snippets per client, and a "verify connection"
      check. The install UX is roughly half the work.
- [ ] **Local HTTP/JSON API** parallel to MCP. Same handlers, plain REST
      framing. Catches agents that don't speak MCP yet (ChatGPT Desktop,
      OpenAI Operator, most OpenAI Agents SDK setups before MCP wiring).
      Cheap addition once the MCP server exists.
- [ ] **Filesystem mirror with Spotlight indexing**. Write each transcript
      as `~/Documents/SolWhisper/Transcripts/{yyyy-mm-dd}-{slug}.md` with
      YAML frontmatter (id, mode, duration, source app, summary). Universal
      fallback — anything with file access (Claude Code, Operator, Raycast,
      Alfred, `grep`) finds them. Cheapest path; ship regardless of MCP
      decision.
- [ ] **Documented SQLite schema** if `Sources/Storage/` already persists
      transcripts to SQLite. Point agents at the DB file and publish the
      schema so Claude Code / Cursor can query directly via their bash
      tool. Effectively free integration if the schema is stable.

**Push paths**

- [ ] **Extend webhook fan-out to short + agent transcripts.**
      `Sources/Integrations/CustomWebhook` already fires post-meeting-summary;
      add per-mode toggles (short / agent / meeting) so users can pipe into
      n8n / Zapier / Make / their own endpoint that POSTs to Claude or
      ChatGPT. Lowest-effort push path. Pairs with the v0.5 "Generic webhook
      editor UI" bullet above.
- [ ] **"Always send dictation to {chosen agent}" toggle.** Reuse
      `OpenRouterClient` / `OllamaClient` / `ModelStore`. Off by default
      (noisy in normal use); useful for users who want all dictation logged
      into a Claude conversation as ambient context.

**Suggested sequencing**

1. Filesystem mirror + Spotlight (cheap, universal, unblocks every agent
   that can read files — including Claude Code today).
2. Local MCP server over HTTP/SSE (the headline integration; serious agent
   users will care about this).
3. Extend webhook fan-out to all transcript modes (re-uses existing infra).
4. Defer until demand is proven: stdio MCP transport, REST parallel to MCP,
   always-send-to-agent.

**Open questions to resolve before scoping**

- What's the current persistence model in `Sources/Storage/` and
  `Sources/Transcripts/`? If transcripts are ephemeral (paste-and-forget),
  designing the durable store is step 0 and the timeline roughly doubles.
- Auth for the MCP server: bearer token in settings, regenerated per
  install, copy-pasted into agent config. Avoid OAuth — overkill for a
  local-only server.
- ChatGPT/Claude Desktop URL schemes are still not "create chat with this
  text" capable as of early 2026; don't plan around them.
- [ ] **Skill marketplace / sharing** — the OG plan had skill-via-URL
      sharing; was cut. Reconsider once the editor UI is mature.
- [ ] **Cloud sync** (opt-in) — backup meetings/dictation history to
      iCloud Drive or user-supplied S3. End-to-end-encrypted with a
      passphrase the app never sees.

---

## Tech debt & internal cleanup (background)

Not feature work, but worth tracking so it doesn't compound.

- [ ] **`Sources/Audio/DSP.swift` extraction** — three FFT/RMS impls
      across `MeetingController.SpectrumComputer`, `ClippingDetector`,
      and the pill waveform. Consolidate into one tested helper.
- [ ] **`Sources/Storage/JSONCoders.swift` extraction** — every store
      defines its own `JSONEncoder()` / `JSONDecoder()` with the same
      ISO-8601 + sorted-keys + pretty-printed config. One factory.
- [ ] **`AppleSpeechClient` MainActor-ize** — current double-hop through
      DispatchQueue.main is a v0.3 holdover.
- [ ] **`AsyncStream` per channel for buffer pumping** — meeting recording
      uses callback closures across actor boundaries. AsyncStream is the
      idiomatic replacement.
- [ ] **Sprint-ref comment polish** — many headers reference
      "Sprint 4a", "Sprint 7", etc. After GA, swap for capability
      descriptions ("// Meeting recording controller", not
      "// Sprint 4a: meeting recording").
- [ ] **Delete `_DELETE_AIPolish_DEAD`** — the `#if false` fence at
      `SettingsView.swift:235` was kept for type reference during the
      restructure. Once nothing else needs it, delete the whole block.
- [ ] **Default hotkey decision** — either ship them all unset (matches
      both plans) or update the plans to acknowledge the shipped defaults.

---

## How to use this document

- When you finish an item, check it off here AND remove the matching
  v0.5/deferred reference from the source code or test protocol.
- When you ship a new release, move "completed since last release"
  out of this file and into a "Done" section in `Resources/whats-new.json`.
- New ideas land in v0.6 unless they're release-blocking.
- This doc replaces ad-hoc "v0.5 will…" comments scattered across the
  codebase. Future v0.5 references should link here.
