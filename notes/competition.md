# SolWhisper — Landing Page Brief

Compiled from feature audit of the v0.4.0-alpha codebase + competitive research across 9 competitors (May 2026).

## 1. Feature stack (what we're actually selling)

SolWhisper is three products fused into one.

### Three transcription engines, user-switchable

- **Apple Speech** — free, on-device, en-US streaming
- **WhisperKit** — local Whisper (tiny → large-v3-turbo) via CoreML on Apple Silicon, fully offline
- **Deepgram nova-3** — cloud streaming for users who want best-in-class accuracy and don't mind BYO key

### LLM polish layer (post-processing)

- **OpenRouter** gateway → Claude (Sonnet/Haiku), GPT-4o, Gemini, Groq Llama, Mistral, all with one key
- **Ollama** local → free polish via llama3.2, gemma-3, qwen2.5, etc.
- Hallucination guard rejects bad rewrites (output/input word-ratio gate)
- Custom vocabulary, dictation-command replacement ("period" → ".")

### Meeting recorder + summarizer

- Mic + system audio dual-channel capture (ScreenCaptureKit)
- Speaker tagging ([Me] / [Other]), clipping detection, mid-call device hot-swap
- 6 built-in summary skills: generic, sales call, 1:1, standup, interview, brainstorm — each with its own model + temperature
- Auto fan-out to **Obsidian** (markdown notes), **Hermes VPS** webhook, **custom webhooks** with HMAC + Mustache templates

### OCR snipping

Hotkey region-grab → Vision framework on-device → paste into frontmost app.

### File import

Drag MP3/M4A/WAV/FLAC/OGG/CAF/AIFC/AIFF, transcribe + summarize via the same skills pipeline.

### Quality-of-life that punches above weight

- 5 configurable global hotkeys (start/stop, pause, snip, meeting, transcripts)
- 3-tier paste fallback (osascript → NSAppleScript → AX direct)
- Additive clipboard (multi-paste history)
- Spectrum waveform (300–3000 Hz speech band) + RMS meter
- All secrets in Keychain, no plaintext
- Sparkle auto-update with Ed25519 signing
- 6-step onboarding wizard

**Status:** v0.4.0-alpha, macOS 13+, Apple Silicon native. Not sandboxed (required for system audio + accessibility paste).

---

## 2. Competitive landscape (May 2026)

| Product | Pricing | Model | Positioning |
|---|---|---|---|
| **Wispr Flow** | $15/mo or $144/yr; free 2k words/wk | Cloud-only, subscription | "Don't type, just speak." Speed + AI auto-edits. Aggressive enterprise marketing (Amazon, Notion, Vercel logos). Karpathy-style influencer testimonials. |
| **Superwhisper** | $8/mo, $85/yr, **$250 lifetime** | Local + BYO cloud LLM | "Just speak. Write faster." Privacy + offline + 100+ languages. Lifetime is the headliner. |
| **MacWhisper** | Free / **€59 lifetime** (Gumroad) or $6.99/mo / $99.99 lifetime (App Store) | Local-first, file-focused | "Private transcription that never phones home." Heavy on file/YouTube/batch transcription. |
| **VoiceInk** | **$25–$49 one-time** (3 tiers by Mac count); free if you build from source | Open source GPLv3, local | "Best open-source alternative to Superwhisper & Wispr Flow. No subscription." 4,300+ GitHub stars. |
| **Aqua Voice** | $8/mo, $96/yr | Cloud, real-time | "We've typed for 150 years. It's time to speak." 230 WPM claim. Custom dictionary, screen-aware. |
| **TextSniper** | **$7.99–$11.99 one-time** | Local OCR | "Text Recognition Simplified." Single-purpose snipping tool. |
| **Otter.ai** | Free / $8/mo Pro / $20/user Business | Cloud meeting transcription | "Turn meetings into transcripts." Deep CRM integrations, OtterPilot bot joins calls. |
| **Fathom** | Free / $15/mo / $19–29/user team | Cloud meeting bot | "AI notetaking that is out of this world." 300K+ companies, ChatGPT/Claude export. |
| **Zoom AI Companion** | Bundled w/ paid Zoom; $10/mo standalone | Locked to Zoom ecosystem | Smart chapters, action items. Free for existing Zoom customers — hard to compete on price. |

### Patterns that matter

- **Two pricing camps split the market.** Subscription cloud (Wispr Flow $15, Otter $8, Fathom $15+, Aqua $8) vs. local-first lifetime (Superwhisper $250, MacWhisper €59, VoiceInk $39, TextSniper $8). There is no $129 lifetime player with a polished product — that's an open lane.
- **Privacy is the wedge** for every local-first competitor. "Never phones home," "your data never leaves your device," "no subscription" — these phrases recur verbatim.
- **Speed metrics sell.** "4x faster than typing" (Wispr), "5x faster, 230 WPM" (Aqua), "save 38 min/meeting" (Fathom). Your copy needs a number.
- **Voice/tone splits two ways.** Cloud players use punchy 3–4 word headlines ("Don't type, just speak", "Just speak. Write faster."). Indie/local players go technical-confident ("Text Recognition Simplified," "Private transcription assistant").
- **No competitor bundles dictation + meetings + OCR + integrations** in a single local-first app. Superwhisper has dictation + meetings. MacWhisper has files + meetings. TextSniper is just OCR. VoiceInk is just dictation. **SolWhisper has all four.**

---

## 3. Recommended positioning for SolWhisper

### The wedge

> **Everything Superwhisper, MacWhisper, and TextSniper do — in one app, local-first, with the LLM provider you already pay for.**

Not the cheapest. Not the most famous. But the only product that ties dictation + meetings + OCR + Obsidian/webhook integrations into one tool that runs offline, polishes with your existing OpenRouter or Ollama setup, and doesn't lock you into a SaaS bot.

### Three audiences worth targeting (pick one for the hero, rotate the rest)

1. **Privacy-conscious power users** — devs, lawyers, therapists, journalists who can't have meetings on a vendor's cloud. The local WhisperKit + Ollama stack is genuinely the only fully-offline option that includes meeting summarization.
2. **AI-native indie hackers** — already paying for OpenRouter/Anthropic. They get value from BYO-key (no double margin) and skill-based meeting summarization.
3. **Obsidian/PKM crowd** — the Obsidian + custom webhook integrations are unique. Meeting → Obsidian note with audio link is a Roam/Obsidian power-user dream.

### Headline options (pick a direction)

- **Privacy-first angle:** "Dictate, transcribe, and summarize meetings — without ever leaving your Mac."
- **Power-user angle:** "Bring your own AI. Keep your audio offline."
- **All-in-one angle:** "One app for dictation, meetings, and OCR. Local by default."
- **Speed angle (riskier — can't out-WPM Aqua):** "Talk it out. SolWhisper handles the rest."

**Recommended:** "Dictate, record, and summarize meetings — without leaving your Mac." Specific, telegraphs the bundle, and "without leaving your Mac" is the honest privacy claim.

### Subheadline draft

> Local Whisper transcription, meeting recording with summary export to Obsidian, and on-device OCR — all hooked up to your own OpenRouter or Ollama keys. No subscription, no cloud uploads you didn't ask for.

### Feature pillars for the page (3–4 max)

1. **Three transcription engines, your choice** — Apple Speech, WhisperKit local, or Deepgram cloud. Switch per-task.
2. **Meeting recorder with skill-based summaries** — sales calls, 1:1s, standups, interviews each get their own prompt. Auto-export to Obsidian or a webhook.
3. **OCR snipping built in** — replaces TextSniper. Hotkey region grab, paste into anything.
4. **Bring your own AI** — OpenRouter (Claude, GPT-4o, Gemini, Llama via one key) or Ollama for fully offline polish. Pay providers directly, never us.

### Pricing recommendation

Three options, ranked:

**Option A — Lifetime, one tier, $99 launch / $129 standard**
- Single tier, no decision fatigue. Undercuts Superwhisper ($250) and Voibe ($198), beats VoiceInk's open-source price ($39–49) by being more polished + supported. Sits in the gap between MacWhisper (€59) and Superwhisper ($250).
- Risk: leaves money on the table from teams.

**Option B — Two-tier lifetime: Personal $79, Pro $149**
- Personal: dictation + OCR. Pro: + meetings + integrations + skill editor. Mirrors VoiceInk's seat-tier model but value-tiered instead.
- Captures TextSniper-replacement buyers cheaply, upsells meeting users.

**Option C — Hybrid: $9/mo or $129 lifetime**
- Hedges against ongoing costs (Sparkle hosting, app signing, support). Wispr Flow / Aqua price-point on monthly, but lifetime escape hatch keeps the indie crowd.
- Most flexible but most cognitive load.

**Recommendation: Option B (two-tier lifetime).** The moat is "I bought it once and it works offline forever." Subscriptions undercut that story. Two tiers serve both the $8 TextSniper buyer and the $250 Superwhisper buyer.

Add **student/journalist/nonprofit 50% off** (everyone does it, costs nothing, generates goodwill) and a **30-day refund** (matches Superwhisper).

### Sales copy do/don't

**Do:**
- Lead with concrete numbers: 8 file formats supported, 6 skill templates, 5 hotkeys, 3 engines.
- Show the engine switcher screenshot. The "three engines" angle is unique and immediately legible.
- Include a comparison table — but only against the closest 3 (Superwhisper, MacWhisper, VoiceInk). Skip Otter/Fathom; different category.
- Use "Apple Silicon native" — M1+ support is a quality signal.
- Testimonial collection: ask 5–10 alpha users now for one-line quotes about a specific use case. Karpathy/Levels-style endorsements drive Superwhisper's whole funnel.

**Don't:**
- Don't market it as "an AI app" — it's a Mac app that uses AI. The Mac-app framing wins this audience.
- Don't claim WPM or accuracy without a methodology — Aqua's 230 WPM is shaky and the audience knows it.
- Don't put OpenRouter/Ollama logos in the hero. Power users get it; everyone else gets confused. Keep BYO-AI in the second fold.
- Don't undersell privacy. "Local by default" should be in the hero, not page 3.

### Page structure

1. Hero — headline, subheadline, demo video (15-second loop showing dictation → OCR → meeting summary)
2. Three pillars (dictation / meetings / OCR) with one screenshot each
3. "Bring your own AI" section — OpenRouter + Ollama + the skill system
4. Privacy posture — explicit list of when data does and doesn't leave the device (this builds enormous trust; competitors are vague here)
5. Comparison table vs. Superwhisper / MacWhisper / VoiceInk
6. Pricing (two tiers + student discount + refund policy)
7. Testimonials from beta users
8. FAQ — sandboxing, why not App Store, model download size, M1 vs Intel, etc.
9. Footer — Sparkle update info, GitHub link if any pieces are open-sourced (trust signal), changelog

---

## 4. Gaps to address before launch

- **Languages:** transcription is en-US hardcoded across all three engines. Competitors flaunt 100+ languages. Either add multi-language before launch or lean hard into "built for English speakers, by an English speaker — multi-language coming."
- **No streaming for WhisperKit** — it's record-then-transcribe. Wispr/Superwhisper stream. Worth disclosing if asked, not worth featuring.
- **Not sandboxed** — needs a privacy-page paragraph explaining *why* (system audio capture, accessibility paste) and what entitlements are actually granted.
- **Alpha status** — decide if the launch page is for beta signups (waitlist + email capture) or paid pre-orders (Stripe + lifetime discount for early buyers).

---

## Sources

- [Wispr Flow Pricing](https://wisprflow.ai/pricing) · [Wispr Flow homepage](https://wisprflow.ai/)
- [Superwhisper Pricing 2026 — Voibe](https://www.getvoibe.com/resources/superwhisper-pricing/) · [Superwhisper homepage](https://superwhisper.com/)
- [MacWhisper Pricing 2026 — Voibe](https://www.getvoibe.com/resources/macwhisper-pricing/)
- [VoiceInk Pricing 2026 — Voibe](https://www.getvoibe.com/resources/voiceink-pricing/) · [VoiceInk GitHub](https://github.com/Beingpax/VoiceInk) · [VoiceInk homepage](https://tryvoiceink.com/superwhisper-alternative)
- [Aqua Voice homepage](https://aquavoice.com/) · [Aqua Voice Pricing — Voibe](https://www.getvoibe.com/resources/aqua-voice-pricing/)
- [TextSniper homepage](https://textsniper.app/)
- [Otter.ai homepage](https://otter.ai/) · [Otter.ai Pricing](https://otter.ai/pricing)
- [Fathom homepage](https://www.fathom.ai/) · [Fathom Pricing](https://www.fathom.ai/pricing)
- [Zoom AI Companion Pricing](https://zoom.us/pricing/aic)
- [Voice Dictation Pricing comparison 2026 — Weesper](https://weesperneonflow.ai/en/blog/2026-03-17-voice-dictation-pricing-comparison-lifetime-deals-2026/)
