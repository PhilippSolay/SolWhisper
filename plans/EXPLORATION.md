# SolWhisper — Exploration Notes

**Date:** 2026-05-12
**Status:** Research artifact; not an execution plan. Companion to [ROADMAP.md](./ROADMAP.md).

This document captures the research, reasoning, and pushback from a single
exploration session covering four loosely-connected ideas:

1. Split short STT into "STT Short" (paste) and "STT Agent" (route to agent).
2. "Hey {Name}" name-prefix routing on top of STT Agent.
3. Always-listening wake-word loop.
4. Exposing SolWhisper's transcripts to Claude / OpenAI / Cursor / other agents.

Each idea was evaluated against the current codebase and against what
competitors have actually shipped. Conclusions sit alongside the reasoning so
future me (or a new session) can pick up without re-litigating.

---

## TL;DR

| Idea | Verdict | Rationale |
|---|---|---|
| STT Agent mode | **Build (Phase 1)** | 1-2 days; reuses every existing system. |
| "Hey {Name}" routing | **Defer (Phase 2)** | Regex on the transcript, not a feature. Ship after Phase 1 has users. |
| Always-on wake word | **Defer indefinitely with disclosure** | Tech is a week; market validation is brutal. The orange dot, the lack of a low-power coprocessor path, and the empirical fact that *zero* successful Mac dictation apps ship this. |
| Transcripts → agents | **Build in tiers** | Filesystem mirror first (universal), then local MCP server (headline), then webhook extension. |
| F4 / mic-key takeover | **Don't fight macOS** | Document the 3-step "free F4" recipe and optionally ship a Karabiner snippet. |

---

## Part 1 — STT Agent mode (Phase 1, ready to build)

### The idea

A second hotkey that records → transcribes → cleans → **routes to a chosen
agent destination**. Distinct from existing short STT in two ways:

- Different cleanup prompt: "rewrite as a clear instruction for an AI agent,
  fix transcription errors, preserve intent — **do NOT answer the question**."
- Different terminal action: not paste-into-focused-app, but dispatch to a
  configured `AgentDestination` (OpenClaw / Hermes local / cloud agent).

### Why it's small

Every piece already exists:

| Concern | What's already wired |
|---|---|
| Hotkey registration | `Sources/HotKey/HotkeyManager.swift` — 5 Carbon hotkeys today, IDs 1-5. snip/meeting/transcripts already do the opt-in "ship unset, register on first pick" dance. Adding ID #6 is one more `EventHotKeyRef` + UserDefaults pair. |
| Recording pipeline | `Sources/Transcription/TranscriptionController.swift` — 3 interchangeable backends (Apple Speech / WhisperKit / Deepgram) behind a uniform interface. |
| LLM cleanup | `Sources/LLM/{OpenRouterClient, OllamaClient, AnthropicClient}.swift` + `LLMClient` protocol + `ModelStore` (7 providers, configurable). `OpenRouterClient.polish()` is the existing cleanup pattern to fork. |
| Agent destinations | `Sources/Integrations/{CustomWebhook, Obsidian, Hermes}` already exist as meeting-summary fan-out targets. Reuse the Hermes client directly. |
| Settings UI | `Sources/Settings/SettingsView.swift` — add `SettingsSection.agent`, an icon, a switch case rendering `AgentSettingsView()`. |
| Overlay | `Sources/Overlay/RecordingOverlayView.swift` — add a "→ Hermes" / "→ Claude" badge during agent recordings. |

### Sketched architecture

```
HotkeyManager (#6: agent) ──> AppDelegate.toggleAgent()
                                    │
                                    ▼
                       TranscriptionController.start(mode: .agent)
                                    │
                                    ▼
                              backend.transcribe()
                                    │
                                    ▼
                         agentCleanupPrompt + LLMClient
                                    │
                                    ▼
                            AgentDestination.dispatch(text)
                                ╱       │        ╲
                       OpenClaw   HermesLocal   CloudAgent
                       (URL/      (existing      (LLMClient
                        paste)    Hermes client) chat)
```

New code is roughly:
- `Sources/Integrations/AgentDestination.swift` (protocol + 3 impls)
- `Sources/Settings/AgentSettingsView.swift`
- ~30 lines in `HotkeyManager.swift` (new hotkey ref + handler)
- ~50 lines in `TranscriptionController.swift` (mode enum, branch in `finish()`)
- ~10 lines in `RecordingOverlayView.swift` (destination badge)
- Settings enum case + icon (1 line each)

### Open questions before scoping the build

1. **OpenClaw integration shape** — does OpenClaw expose a URL scheme, a
   CLI, or do we paste into a frontmost OpenClaw window via `NSWorkspace`?
   Different code paths.
2. **Cloud agent UX** — when the cloud agent responds, where does the
   response go? (a) Paste into focused window, (b) overlay panel,
   (c) dedicated chat window. Materially different scope.
3. **Hotkey default** — ship unset like meeting/snip/transcripts (per
   the OCR plan), or ship a default (like the alpha.4 hotkey-defaults
   decision in the current ROADMAP)? Stay consistent with whichever
   convention the project lands on.

---

## Part 2 — "Hey {Name}" name-prefix routing (Phase 2, deferred)

### The idea

After cleanup, if the transcript starts with `"Hey {name}, ..."`, look up
`{name}` in a configurable name→destination map, strip the prefix, route
accordingly. Example: "Hey Samantha, write a status update" → routes to
the cloud Claude destination; "Hey Hermes, log this" → routes to local
Hermes; "Hey Cody, refactor this function" → routes to OpenClaw.

### Why it's not a feature, just a routing rule

After Phase 1 ships, the cleaned transcript text is already in hand at the
`AgentDestination.dispatch` boundary. The prefix check is a regex:

```
^hey\s+(\w+)[,!.]?\s+(.*)$    // case-insensitive
```

If the captured name is in the names map → route accordingly and pass the
stripped tail. Otherwise route to the default destination. That's ~20
lines including settings storage for the names map.

### Why defer

The reason to ship this *after* Phase 1 has real users: we don't yet know
whether (a) users actually want to switch destinations mid-flow, or
(b) one hotkey per destination is enough. Don't over-design before there's
signal. The Phase 2 work is half a day whenever it happens; no rush.

### If/when shipped

Settings pane addition: a "Names" table — `Name | Destination` rows.
The names map lives in UserDefaults as a `[String: AgentDestinationID]`
dictionary. Recommendation: keep the per-destination hotkeys *and* allow
name-prefix override, so the fast path is hotkey-based and the override
is for cases where you want to switch mid-thought.

---

## Part 3 — Always-on wake word (Phase 3, deferred with pushback)

### The idea

A background loop that continuously listens to the mic, detects a wake
word ("Hey Samantha"), and routes the following speech either to an LLM
agent or to the currently-focused window as a prompt.

### Honest pushback

The technical work is real but tractable. The reasons this has failed
in the consumer Mac market are structural and don't go away with better
engineering:

#### Apple uses a path third parties don't get

"Hey Siri" on Apple Silicon Macs runs on the Neural Engine + Secure
Enclave via a fixed quantized model. Power draw is ~0.8-1.3 mW
(<0.4% of idle). It bypasses the main audio pipeline and the orange
microphone privacy indicator. No public API exposes this path to
third-party apps. Anything SolWhisper ships runs on the main CPU
through `coreaudiod`, lights the orange dot, and pays the full power
tax.

#### The orange dot stays on forever

The macOS microphone privacy indicator stays lit the entire time the
mic stream is open. Apple offers no public API to suppress it. As of
macOS 14.4 the only relevant toggle hides it on *external displays*.
For a productivity app this reads to most users as "spyware always
on." This is the single biggest UX killer and is unfixable.

#### Battery and CPU on Apple Silicon

`coreaudiod` alone sits at 12-15% sustained CPU on M1 when an input
stream is open. A small wake-word net (livekit-wakeword via ONNX
Runtime + CoreML Execution Provider) adds ~1-4%. The mic pipeline is
the dominant cost. On battery, this is a measurable 1-3%/hour hit.
Not catastrophic, but noticeable enough that users notice.

#### Meeting apps will break it

Zoom, Meet, FaceTime, Teams grab the audio device and switch the
default I/O route (the well-known "ZoomAudioDevice" hijack). Your
listener silently dies. Mitigation: `NSWorkspace.didActivateApplicationNotification`
+ a hardcoded bundle-ID pause list. Workable but fragile across
macOS releases.

#### False positives are brand-killers

Even at 1/day, a false trigger during a Zoom call ("Hey, who said
that?") is the kind of event that makes people uninstall and write
a 1-star review.

#### Empirical market signal

| Product | Always-on wake word? |
|---|---|
| Wispr Flow | No — push-to-talk |
| Superwhisper | No — push-to-talk |
| MacWhisper | No — push-to-talk |
| BetterDictation | No — push-to-talk |
| Raycast Whisper | No — push-to-talk |
| Voice Pilot / Voice Type / TypeVox / Whispering | No — push-to-talk |
| Talon | Yes-ish, but for *commands* not wake-words |
| Apple "Hey Siri" | Yes — but on dedicated silicon |

Every commercial Mac dictation app has independently chosen push-to-talk.
That's not technology limitation; that's the market telling us something.

#### Trust deficit

Wispr Flow caught flak on Reddit/HN for screenshot capture; Superwhisper
for default audio storage. The trust baseline for an always-listening
Mac app is below zero. To overcome it requires: local-only processing,
no audio storage by default, an unencrypted wake-word ONNX model shipped
in the bundle so anyone can audit it, and an explicit onboarding
disclosure about the orange dot.

### What it would take if eventually built

Architecture:

```
Background process (in-app or XPC helper)
    │
    ▼
AVAudioSinkNode tap @ 16 kHz on default input
    │
    ▼
1.5s ring buffer; classifier runs every ~80ms
    │
    ▼
livekit-wakeword (ONNX, MIT license)
    │ trained on "Samantha" via 1-command CLI
    │ runs on ANE via ONNX Runtime CoreML EP
    ▼
Wake detection → switch into capture mode →
    feed post-detection audio into existing WhisperKitClient →
    route through STT Agent pipeline
```

Engine choice:
- **livekit-wakeword** (MIT, ONNX, Swift demo, ANE-capable). Recommended.
- **Picovoice Porcupine** — best commercial-grade engine, but commercial
  license starts ~$6k/yr. Not worth it for an indie app.
- **Snowboy** — dead since 2020-12-31. Don't.
- **openWakeWord** — Python/ONNX upstream. Use for training, ship the
  livekit classifier.

Required UX guardrails:
- Off by default. Opt-in onboarding sheet that explicitly says:
  *"Enabling this will keep the orange microphone indicator visible
  whenever SolWhisper is running. The wake-word detector runs entirely
  on your Mac; no audio is sent or stored."*
- Visible menu-bar state ("listening for Samantha" / "paused — Zoom").
- Auto-pause on Zoom/Meet/Teams/FaceTime via NSWorkspace.
- Ship the ONNX model unencrypted at `Resources/WakeWord/samantha.onnx`
  so anyone can verify it.
- Configurable wake word, but with a curated "tested phrases" list
  (long phonetically-distinct phrases have <1/day false positive
  rates; short generic ones do not).

Estimated build: 1 week tech, 1 week UX guardrails + onboarding,
2 weeks of false-positive tuning across realistic scenarios. So 4
weeks, mostly tuning.

**My recommendation: don't build this until Phase 1 and Phase 2 have
shipped and at least 100 real users are asking for it.**

---

## Part 4 — F4 / mic-key takeover

### The reality

Mac keyboards have evolved differently across model years:

| Keyboard | F4 |
|---|---|
| Pre-2021 Magic Keyboard | Launchpad |
| 2021+ Magic Keyboard | Spotlight / Dictation (icon) |
| M2+ MacBook Air/Pro | Mic icon — fn-mode triggers Apple Dictation |

The mic-icon function emits a system-defined event captured by the Siri /
Dictation daemon at a layer below normal apps. CGEventTap with the
HID-level tap (`kCGHIDEventTap`) and Accessibility permission can *see*
it, but Apple protects this path — parallel signals still fire, and macOS
14/15 tightened it further. Brittle, version-dependent, and not worth
shipping.

### Three real paths

1. **Plain F4 as a normal hotkey** (recommended, supported). User
   disables Apple Dictation shortcut (System Settings → Keyboard →
   Dictation → Shortcut: Off), enables "Use F1, F2, etc keys as standard
   function keys" (or holds fn+F4), then SolWhisper registers F4 via
   the existing Carbon `RegisterEventHotKey` flow. This is what
   BetterDictation tells users to do.

2. **Karabiner-Elements remap** (optional power-user path). Karabiner
   installs a virtual HID device driver and can remap the mic key to
   any other keycode. Ship a one-click `karabiner.json` recipe at
   `Resources/karabiner/solwhisper-mic-key.json`. We don't bundle
   Karabiner.

3. **Native CGEventTap interception** (not recommended). Brittle,
   Apple-can-break-it-anytime, requires Accessibility (already on
   demand). Skip.

### Recommendation

Add a "Free up F4 for SolWhisper" page to onboarding when STT Agent
ships, with the 3-step recipe. Optionally ship the Karabiner snippet
as a side-door for users who already have Karabiner installed.

---

## Part 5 — Transcripts → agents (the headline integration question)

### The mental model

Two directions, ship at least one of each:

- **Pull** — agent reaches into SolWhisper. Best for "Claude, summarize
  my meetings this week." Requires SolWhisper to expose an interface
  and the agent to support it.
- **Push** — SolWhisper sends transcripts somewhere. Best for "every
  dictation gets logged to my Notion." Requires user-side wiring.

### The four pull paths

#### 1. Local MCP server (recommended headline)

The right answer in 2026. Use the official Swift SDK:
`modelcontextprotocol/swift-sdk`.

Tools to expose:
- `list_recent_transcripts(limit, since)`
- `search_transcripts(query, date_range, mode)` — substring or semantic
- `get_transcript(id)` — full text + summary + metadata
- `get_meeting_summary(id)`

Resources (for auto-context injection):
- `solwhisper://transcripts/recent`
- `solwhisper://transcripts/{id}`

Transport options — this choice matters more than the tools:

| Transport | Pros | Cons |
|---|---|---|
| **HTTP/SSE on localhost** (port 7842, bearer token) | One process, one config snippet. Supported by Claude Desktop, Claude Code, Cursor, Zed, most newer clients. Easiest distribution. | None major for local-only. |
| **stdio via sidecar CLI** at `Contents/MacOS/solwhisper-mcp` | Matches every existing MCP install convention. Works in sandboxed contexts cleanly. | Two binaries to ship. XPC or UNIX-socket plumbing back to the running app. |

**Pick HTTP/SSE first.** Add stdio later if a major client demands it.

Settings UX matters: a pane that shows port + token + copy-paste config
snippets for Claude Desktop / Code / Cursor / Zed + a "verify connection"
button. The install UX is roughly half the work.

#### 2. Local HTTP/JSON API (parallel to MCP)

Same handlers, plain REST framing. Cheap to add once the MCP server
exists. Catches agents that don't speak MCP yet — ChatGPT Desktop,
OpenAI Operator, and most OpenAI Agents SDK setups before they wire
MCP support.

#### 3. Filesystem mirror with Spotlight

Write each transcript as
`~/Documents/SolWhisper/Transcripts/{yyyy-mm-dd}-{slug}.md` with YAML
frontmatter:

```yaml
---
id: 01HXY...
mode: short | agent | meeting
duration_sec: 47
source_app: Safari
created_at: 2026-05-12T14:33:21Z
summary: |
  ...
---
{transcript body}
```

Spotlight auto-indexes. **Any** tool with file access — Claude Code,
OpenAI Operator, Raycast, Alfred, `grep` — finds them. Cheapest path;
ship regardless of the MCP decision.

#### 4. Documented SQLite schema

If `Sources/Storage/` already persists to SQLite (unconfirmed —
unexplored area of the codebase), point agents at the DB file and
publish the schema. Claude Code and Cursor can query it directly via
their bash tools. Effectively free integration.

### The two push paths

#### 5. Extend the existing webhook fan-out

`Sources/Integrations/CustomWebhook` already fires post-meeting-summary.
Extend it to fire on every transcript completion, with per-mode toggles
(short / agent / meeting). Users wire the webhook to:

- n8n / Zapier / Make → Claude or ChatGPT
- A serverless function that POSTs to OpenAI/Anthropic
- A vector DB ingestion endpoint
- Slack / Discord / Telegram bots

Lowest-effort push path. Pairs with the existing v0.5 "Generic webhook
editor UI" item.

#### 6. "Always send dictation to {chosen agent}" toggle

Reuses `OpenRouterClient` / `OllamaClient` / `ModelStore`. Off by default
(noisy in normal use); useful for users who want all dictation logged
into a Claude conversation as ambient context.

### Sequencing

1. **Filesystem mirror + Spotlight** — universal fallback, unblocks
   every file-aware agent today, costs nothing.
2. **Local MCP server over HTTP/SSE** — the headline integration.
3. **Webhook fan-out extension** — re-uses existing infra.
4. **Defer**: stdio MCP, REST parallel, always-send-to-agent.

### Auth model

For the MCP / HTTP server: bearer token generated per install, displayed
in settings with a "regenerate" button, copy-pasted into agent config.
Avoid OAuth — overkill for a local-only server.

### Things NOT to plan around

- ChatGPT Desktop and Claude Desktop URL schemes are not "create chat
  with this text" capable as of early 2026.
- ChatGPT does not natively speak MCP yet (this may change; don't bet
  the roadmap on it).
- Claude.ai web doesn't have a "connector to localhost" path. Claude
  Desktop does.

---

## Part 6 — Cross-cutting open questions

Each of these blocks a more concrete plan. Resolve before committing to
timelines.

1. **Persistence model.** `Sources/Storage/` and `Sources/Transcripts/`
   exist but were not read in this session. If transcripts are durable
   SQLite with stable IDs, the MCP server is days of work. If they're
   ephemeral paste-and-forget, step 0 is designing the durable store
   and the timeline roughly doubles. **Highest-leverage thing to learn
   next.**

2. **OpenClaw integration surface.** URL scheme? CLI? Pasteboard
   convention? Drives the OpenClawDestination implementation.

3. **Cloud agent response UX.** When the cloud agent responds to an
   STT Agent dispatch, where does the response surface? Paste / overlay /
   chat window? Materially different scope.

4. **Hotkey default convention.** ROADMAP alpha.4 changes decided to
   ship hotkeys with sensible defaults rather than unset. Stay consistent
   for the new STT Agent hotkey.

5. **MCP server hosting model.** In-process inside SolWhisper, or a
   separate background daemon? Affects sandboxing and how the server
   behaves when the main app isn't running.

---

## Sources

Wake-word engines:
- Picovoice Porcupine — https://github.com/Picovoice/porcupine
- livekit/livekit-wakeword — https://github.com/livekit/livekit-wakeword
- livekit-examples/hello-wakeword — https://github.com/livekit-examples/hello-wakeword
- dscripka/openWakeWord — https://github.com/dscripka/openWakeWord
- OHF-Voice/micro-wake-word — https://github.com/kahrendt/microWakeWord

Whisper + Speech on macOS:
- argmaxinc/WhisperKit — https://github.com/argmaxinc/WhisperKit
- Apple Speech framework — https://developer.apple.com/documentation/speech
- WWDC23 Customize on-device speech recognition — https://developer.apple.com/videos/play/wwdc2023/10101/
- soniqo/speech-swift — https://github.com/soniqo/speech-swift

Voice-assistant architecture references:
- OHF-Voice/wyoming — https://github.com/OHF-Voice/wyoming
- rhasspy/wyoming-satellite — https://github.com/rhasspy/wyoming-satellite
- OHF-Voice/linux-voice-assistant — https://github.com/OHF-Voice/linux-voice-assistant

MCP:
- modelcontextprotocol/swift-sdk — https://github.com/modelcontextprotocol/swift-sdk

Competitor reference points:
- Wispr Flow, Superwhisper, MacWhisper, BetterDictation, Raycast Whisper
  Dictation, Voice Type, Voice Pilot, TypeVox, Whispering, Talon
- Apple "Hey Siri" privileged-coprocessor architecture

---

## How to use this document

- This is research and reasoning. Actionable items live in
  [ROADMAP.md](./ROADMAP.md).
- When a decision here lands as a concrete build, link the ROADMAP
  item back to the section here for the "why."
- If a future session re-opens any of these threads, update the
  relevant section in place rather than starting fresh — preserve the
  pushback so the same arguments don't get re-litigated.
- New exploration threads either get appended here (as a new Part N) or
  spun out into their own file under `plans/` if they grow past ~200
  lines.
