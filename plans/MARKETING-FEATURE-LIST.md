# SolWhisper — Marketing Feature List

**Build target:** 0.4.0-alpha.4
**Audience:** marketing, sales, landing page, App Store description, press kit.
**Tagline candidates:** "Your meetings, your data, your AI." · "Speech intelligence without the cloud premium." · "Voice-first productivity for your Mac."

---

## Primary features — what we lead with

### 1. Privacy-first voice intelligence
- **100% on-device option** — WhisperKit (Apple Silicon CoreML Whisper) and Apple Speech run fully offline.
- **Bring-your-own-keys** — every cloud call uses *your* API key, stored in macOS Keychain. No SolWhisper-operated servers in the path.
- **All data stays local** — meetings, transcripts, summaries, dictation history, voice profiles all live in `~/Library/Application Support/SolWhisper/`. Never uploaded unless *you* choose a cloud feature.
- **Configurable retention** — auto-delete recordings older than 7d / 30d / 90d / 1y / never.

### 2. Press-to-talk dictation anywhere on your Mac
- **Global hotkey** opens dictation in any focused app — Slack, Notion, Mail, browsers, IDEs.
- **Live transcript bubble** below the recording pill shows what's heard in real time.
- **Auto-paste** into the focused app at stop, or copy-to-clipboard mode.
- **Three STT engines**, switchable per session: **Apple Speech** (free, on-device), **WhisperKit** (offline, highest accuracy, multiple model sizes), **Deepgram** (real-time cloud streaming).
- **Pause/resume** mid-dictation without losing the recording.
- **AI polish** — optional LLM-driven filler removal, punctuation, light grammar fixes, with custom-vocabulary support for proper names + jargon.

### 3. Two-channel meeting recording
- **Captures both sides** — your microphone *and* the other app's audio (Zoom, Meet, Teams, FaceTime, browser tab) in a single recording.
- **Channel-separated `[Me] / [Other]` tagging** — no diarization needed for a typical 1:1.
- **Pause / resume / cancel** during the call.
- **Crash recovery** — orphan meetings are detected on next launch and recoverable.
- **Privacy disclaimer** on first record reminds you to confirm consent where required.

### 4. AI summaries with specialist frameworks
- **Meeting-summary skill pack** — 10 type-specific templates that go far beyond generic bullet lists:
  - **Client discovery** — MEDDIC / BANT-lite qualification
  - **Architectural review** — ADR-style decisions with context, options, consequences, revisit-when
  - **Hiring interview** — per-competency signal table, evidence-quoted, with bias guardrails
  - **1:1** — CAPS (Career, Achievements, Problems, Support) framework with privacy redaction rules
  - **Scrum standup** — round-robin per-person status table + escalations
  - **Retrospective** — Start / Stop / Continue with action ownership
  - **Exploration** — analytical ideation with hypotheses, references, JTBD
  - **Development session** — pair-programming gotchas, TODOs, design decisions inline
  - **User interview** — JTBD framework, verbatim-quote rules, hypothesis tracking
  - **Creative brainstorm** — full idea inventory, themes, top picks, parking-lot
- **Auto-detect meeting type** from the transcript, or pick manually.
- **Custom skills** — built-in flat-skill editor for your own quick templates.
- **Editable skill pack** — every Markdown module ships into your user folder; tweak with any editor.

### 5. Speaker diarization with name resolution
- **Three engines**: **AssemblyAI** (cloud, accurate on noisy meetings), **Deepgram** (cloud, fast), **FluidAudio** (local CoreML pyannote, scaffolded for v0.6 — full local privacy).
- **Per-segment speaker letters** mapped onto your existing transcript by time-overlap.
- **LLM-powered name suggestions** — "Speaker A → Pierre, Speaker B → Ricardo" inferred from meeting context, calendar attendees, and transcript signals. Per-row review with confidence scoring.
- **Voice profiles** — save voice fingerprints per recurring collaborator (v0.6 unlocks auto-matching across meetings).
- **macOS Calendar integration** — pulls attendees from the event scheduled at recording time. Match-and-confirm dialog when multiple events overlap.

### 6. MCP server — make your AI assistant *meeting-aware*
- **Bundled local binary** — `solwhisper-mcp` ships inside the app, ready for Claude Desktop / Cursor / Zed.
- **One-click config snippets** — Settings → Integrations → MCP server has copy-config buttons for both clients.
- **Stdio transport** — no network port, no exposure beyond the parent process.
- **5 tools**: `list_meetings`, `get_meeting`, `search_transcripts`, `list_dictation_history`, `list_skills`.
- **3 resource URIs per meeting**: transcript Markdown, summary Markdown, metadata JSON.
- **Use case**: "Claude, summarize my last sales call" / "Find the action item from yesterday's standup" — answered without leaving your assistant.

### 7. Multi-provider LLM routing
- **Six direct integrations**: **Anthropic** (Claude 4.7 / 4.6 / 4.5), **OpenAI** (GPT-4o, o1, o3), **Google** (Gemini 2.0 Flash + 1.5 Pro), **Groq** (Llama 3.3, DeepSeek R1), **OpenRouter** (everything else), **Ollama** (local).
- **Per-role routing** — Dictation cleanup, Meeting cleanup, and Meeting summary each get their own model. Mix providers freely.
- **Configured Models picker** — visual model library with provider icons, edit pencil, delete. Every preset list is updated to the current model generation (Jan 2026).

### 8. Screen Text Snap (OCR)
- **Hotkey-triggered** marquee selection over any portion of the screen.
- **Apple Vision** powers extraction — fully on-device, no cloud.
- **Auto-detect language** or pin a specific one (English, Spanish, German, French, Italian, Portuguese, Chinese, Japanese, Korean, Russian, Ukrainian).
- **Result lands on clipboard** with a one-tap "paste into focused app" bubble.
- **Silent capture** mode (no shutter sound).

---

## Secondary features — the "and also" list

### Workflow & productivity
- Custom vocabulary (proper names, jargon, acronyms feed into the AI polish prompt)
- Multiple keyboard shortcuts: dictation, pause/resume, meeting record, OCR snip, transcripts window
- Meeting context field — type background ("This was Pierre & Ricardo on the Onsen architecture"), feeds the summarizer
- Editable meeting titles (double-click)
- Re-transcribe with a different model on existing recordings
- Clean transcript — chunked, JSON-object-keyed, batch-resilient (handles 1h+ recordings without count drift)
- Copy transcript as Markdown
- Additive clipboard mode (append each new dictation to the clipboard)
- Auto-paste toggle

### Audio quality
- Per-channel mic + system audio capture (`audio_mic.wav` + `audio_system.wav` + mixed `audio.wav`)
- Side-chain ducking — lowers other-app audio when you speak during meetings
- Clipping detector
- "Lower volume during recording" mode via Core Audio HAL master volume
- Pluggable input device — any USB / Bluetooth mic; quick switcher in tray menu
- Smart "warming" UI for file imports — animated indicator during CoreML compilation, not a flat 0% bar

### Transcripts window
- Search across meeting titles + transcript bodies (toggleable search bar)
- Time-bucket grouping — Today / Yesterday / This Week / Earlier
- Audio scrubber with click-segment-to-seek
- Transcript / Summary tabs per meeting
- Speaker badges with cycling color palette per letter
- Click-to-rename popover with autocomplete from participants + calendar attendees + voice profiles
- Save-as-profile button in the rename popover
- Calendar event card showing linked event title + attendees with Change / Unlink actions

### Customization
- 11-pane Settings sidebar (Home / STT Short / STT Meetings / Screen Capture / Audio / Hotkey / Models / Skills / People / Vocabulary / Integrations / Debug)
- Skill editor for flat skills (id, name, description, prompt template, output skeleton, default model override, temperature)
- Multi-file skill pack with editable Markdown modules — edit in any Markdown editor, click Reload
- Configured Models manager (BYO-key) with per-provider presets and edit pencil
- Restore-defaults flows for skills, skill packs, and hotkeys

### Visual polish
- Liquid Glass UI on macOS 26+ (graceful fallback on macOS 13–25)
- Anthropic-orange tray icon while recording (clearly distinguishable from macOS's red privacy indicator)
- Glass-prominent primary buttons in the Transcripts window
- Cycling 8-color speaker palette (with colorblind-safe ordering)
- Per-action progress states with rotating subtitle hints

### Integrations
- **Hermes** — POST JSON to your webhook with HMAC-SHA256 signature
- **Obsidian** — write summaries directly into your vault folder, configurable filename template, optional audio link
- **Custom webhook** framework underneath both
- **Calendar match dialog** with multi-event picker when more than one event overlaps the recording window
- **MCP** (covered above)

### File import
- Drag-and-drop or file-picker for any audio: `.wav .mp3 .m4a .mp4 .flac .ogg .aac .aiff .caf`
- Progress UI with model-load → warming → transcribing → writing phases
- Same downstream pipeline as live recordings (cleanup → diarize → summarize → integrate)
- Cancel mid-import cleanly trashes the partial folder

### Onboarding & lifecycle
- First-launch onboarding for permissions + backend choice
- Sparkle auto-update with EdDSA-signed appcasts
- Notarization-ready release pipeline (`scripts/release.sh`)
- Launch on login via SMAppService
- Error logging to `~/Library/Logs/SolWhisper/` with 14-day rotation
- One-shot data migrations preserve legacy state across version bumps
- "What's new?" feed bundled with each release

### Diagnostics
- Settings → Debug → in-app log panel with timing + token-usage tracking
- Copy-log-to-clipboard for support
- Reveal-in-Finder buttons for every user folder (Skills, SkillPacks, Voices, Logs)

---

## What's not here yet (honest roadmap notes for product/sales conversations)

- **Live diarization for long-form meetings** — currently runs as a post-stitch step; v0.6 brings live partial labels.
- **Local FluidAudio diarization** — scaffolded; ships v0.6 with a one-time ~30 MB model download.
- **WhisperKit live partials in dictation** — non-streaming today (transcribes on stop); streaming partials ship in v0.5 GA.
- **Per-app system audio capture** — captures everything system-wide today; per-app filtering is on the roadmap.
- **Skill pack visual editor** — flat-skill editor ships now; full pack editor (drag/reorder type modules) lands in v0.5 GA.
- **iOS / iPad companion** — not on the v0.5/v0.6 roadmap.

---

## One-liner positioning

> SolWhisper is a privacy-first voice intelligence app for macOS. Press a hotkey to dictate into any app. Record a meeting and get a structured AI summary with action items. Connect Claude or Cursor to query your meeting history natively. Bring your own API keys for any LLM provider. Your audio, your transcripts, your decisions — your Mac.
